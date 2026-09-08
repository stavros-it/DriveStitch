"""DriveStitch - standalone failing-disk rescue GUI (PySide6).

Workflow: pick a disk from the table -> Scan (builds a GOOD/BAD map with
watchdog-protected read-only probes) -> Copy Files (bad-aware, skips damaged
regions) -> review the map report and the lost-files list. The engine runs
as a PowerShell subprocess (engine/DiskRescueLib.ps1) and streams its output
into the log panel. Maps and copy reports are saved to the portable
DiskRescue folder inside the app directory unless another folder is chosen.
"""

from __future__ import annotations

import os
import time

from PySide6.QtCore import Qt
from PySide6.QtGui import QColor, QFont, QIcon
from PySide6.QtWidgets import (
    QApplication, QDialog, QDialogButtonBox, QFileDialog, QGridLayout,
    QHBoxLayout, QInputDialog, QLabel, QLineEdit, QMainWindow, QMessageBox,
    QPlainTextEdit, QPushButton, QSpinBox, QTableWidget, QTableWidgetItem,
    QVBoxLayout, QWidget,
)

from disks import list_disks
from runner import EngineRunner
from scripts import DATA_DIR, STUB_COPY, STUB_LIST, STUB_LOST, STUB_REPORT, STUB_SCAN, resolve

APP_TITLE = "DriveStitch - Failing Disk Rescue"

ACCENT = "#4aa3ff"
BG = "#1b1d21"
BG_PANEL = "#232529"
TEXT = "#e4e6ea"
TEXT_DIM = "#9aa0a8"
DIVIDER = "#3a3d44"
LOG_BG = "#151619"

DARK_QSS = f"""
QMainWindow {{ background: {BG}; color: {TEXT}; }}
QWidget {{ background: {BG}; color: {TEXT}; font-size: 13px; }}
QLabel {{ color: {TEXT}; background: transparent; }}
QPushButton {{
    background: {BG_PANEL}; color: {TEXT}; border: 1px solid {DIVIDER};
    border-radius: 4px; padding: 6px 14px;
}}
QPushButton:hover {{ border-color: {ACCENT}; }}
QPushButton:pressed {{ background: {BG_PANEL}; }}
QPushButton:disabled {{ color: {TEXT_DIM}; border-color: {DIVIDER}; }}
QLineEdit, QSpinBox {{
    background: {LOG_BG}; color: {TEXT}; border: 1px solid {DIVIDER};
    border-radius: 4px; padding: 4px 6px;
}}
QTableWidget {{
    background: {LOG_BG}; color: {TEXT}; border: 1px solid {DIVIDER};
    gridline-color: {DIVIDER}; alternate-background-color: #191b1e;
}}
QTableWidget::item:selected {{ background: {ACCENT}; color: #000000; }}
QHeaderView::section {{
    background: {BG_PANEL}; color: {TEXT}; border: none;
    border-right: 1px solid {DIVIDER}; padding: 4px 8px;
}}
QPlainTextEdit {{
    background: {LOG_BG}; color: {TEXT}; border: 1px solid {DIVIDER};
    font-family: 'Consolas', monospace; font-size: 12px;
}}
QScrollBar:vertical, QScrollBar:horizontal {{
    background: {BG}; border: none; width: 12px; height: 12px;
}}
QScrollBar::handle:vertical, QScrollBar::handle:horizontal {{
    background: {DIVIDER}; border-radius: 6px; min-height: 24px; min-width: 24px;
}}
QScrollBar::add-line, QScrollBar::sub-line {{ height: 0; width: 0; }}
QMessageBox {{ background: {BG_PANEL}; }}
"""


class ScanDialog(QDialog):
    """Scan settings: disk number, map path, and the scan step numbers."""

    def __init__(self, parent, disk_number: int, disk_size_gb: float) -> None:
        super().__init__(parent)
        self.setWindowTitle("Scan Disk - Build Map")
        self.setMinimumWidth(540)
        v = QVBoxLayout(self)
        v.setSpacing(10)
        warn = QLabel(
            f"Disk {disk_number} ({disk_size_gb:.1f} GB) will be mapped with read-only\n"
            "watchdog-protected probes. Nothing is written to the disk.\n"
            "Interrupting the scan is safe - it resumes where it stopped."
        )
        warn.setWordWrap(True)
        v.addWidget(warn)
        v.addWidget(QLabel("1. Disk number to scan:"))
        self.disk_edit = QLineEdit(str(disk_number))
        v.addWidget(self.disk_edit)
        v.addWidget(QLabel("2. Map file (default: the app's DiskRescue folder):"))
        map_row = QHBoxLayout()
        self.map_edit = QLineEdit()
        self.map_edit.setPlaceholderText(
            "blank = default (DiskRescue\\diskN-map.json in the app folder)"
        )
        map_row.addWidget(self.map_edit)
        map_btn = QPushButton("Browse...")
        map_row.addWidget(map_btn)
        v.addLayout(map_row)

        def _pick_map():
            default = os.path.join(
                DATA_DIR, f"disk{self.disk_edit.text().strip() or disk_number}-map.json"
            )
            path, _ = QFileDialog.getSaveFileName(
                self, "Select map file (optional)", default,
                "Disk Rescue maps (*.json);;All files (*.*)",
                options=QFileDialog.Option.DontConfirmOverwrite,
            )
            if path:
                self.map_edit.setText(path)
        map_btn.clicked.connect(_pick_map)

        v.addWidget(QLabel("3. Scan step numbers:"))
        grid = QGridLayout()
        grid.addWidget(QLabel("Probe sample size (MiB):"), 0, 0)
        self.probe_spin = QSpinBox()
        self.probe_spin.setRange(1, 64)
        self.probe_spin.setValue(1)
        self.probe_spin.setToolTip("Bytes read per probe. Larger = faster scan, coarser map.")
        grid.addWidget(self.probe_spin, 0, 1)
        grid.addWidget(QLabel("Refine floor (MiB):"), 1, 0)
        self.floor_spin = QSpinBox()
        self.floor_spin.setRange(1, 1024)
        self.floor_spin.setValue(8)
        self.floor_spin.setToolTip("How fine BAD region boundaries are refined (8 = balanced, 1 = very deep).")
        grid.addWidget(self.floor_spin, 1, 1)
        grid.addWidget(QLabel("Probe timeout (ms):"), 2, 0)
        self.timeout_spin = QSpinBox()
        self.timeout_spin.setRange(500, 60000)
        self.timeout_spin.setSingleStep(500)
        self.timeout_spin.setValue(5000)
        self.timeout_spin.setToolTip("Give up a probe after this long. Raise it (10-20s) for slow or USB disks.")
        grid.addWidget(self.timeout_spin, 2, 1)
        v.addLayout(grid)
        bb = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel
        )
        bb.accepted.connect(self.accept)
        bb.rejected.connect(self.reject)
        v.addWidget(bb)
        self.disk_edit.setFocus()

    def values(self) -> dict:
        return {
            "disk": self.disk_edit.text().strip(),
            "map": self.map_edit.text().strip().replace("'", "''"),
            "probe": str(self.probe_spin.value()),
            "floor": str(self.floor_spin.value()),
            "timeout": str(self.timeout_spin.value()),
        }


class CopyDialog(QDialog):
    """Copy settings: source drive, destination folder, optional map."""

    def __init__(self, parent, source_letter: str, disk_number: int) -> None:
        super().__init__(parent)
        self.setWindowTitle("Copy Files - Bad-Aware")
        self.setMinimumWidth(540)
        v = QVBoxLayout(self)
        v.setSpacing(10)
        warn = QLabel(
            f"Copy from drive {source_letter}: (disk {disk_number}) to a folder on a\n"
            "DIFFERENT healthy disk. Damaged regions are skipped and zero-filled.\n"
            "Existing files with the same size + timestamp are skipped (resume)."
        )
        warn.setWordWrap(True)
        v.addWidget(warn)
        v.addWidget(QLabel(f"1. Source drive: {source_letter}: (disk {disk_number})"))
        v.addWidget(QLabel("2. Destination folder (on a different physical disk):"))
        dest_row = QHBoxLayout()
        self.dest_edit = QLineEdit()
        self.dest_edit.setPlaceholderText(r"e.g. D:\Recovered")
        dest_row.addWidget(self.dest_edit)
        dest_btn = QPushButton("Browse...")
        dest_row.addWidget(dest_btn)
        v.addLayout(dest_row)

        def _pick_dest():
            path = QFileDialog.getExistingDirectory(
                self, "Select destination folder", self.dest_edit.text() or ""
            )
            if path:
                self.dest_edit.setText(path)
        dest_btn.clicked.connect(_pick_dest)

        v.addWidget(QLabel("3. Map file (optional - default: the app's DiskRescue folder):"))
        map_row = QHBoxLayout()
        self.map_edit = QLineEdit()
        self.map_edit.setPlaceholderText(
            f"blank = auto-find DiskRescue\\disk{disk_number}-map.json"
        )
        map_row.addWidget(self.map_edit)
        map_btn = QPushButton("Browse...")
        map_row.addWidget(map_btn)
        v.addLayout(map_row)

        def _pick_map():
            path, _ = QFileDialog.getOpenFileName(
                self, "Select map file (optional)", DATA_DIR,
                "Disk Rescue maps (*.json);;All files (*.*)",
            )
            if path:
                self.map_edit.setText(path)
        map_btn.clicked.connect(_pick_map)

        bb = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel
        )
        bb.accepted.connect(self.accept)
        bb.rejected.connect(self.reject)
        v.addWidget(bb)
        self.dest_edit.setFocus()

    def values(self) -> dict:
        return {
            "dest": self.dest_edit.text().strip().replace("'", "''"),
            "map": self.map_edit.text().strip().replace("'", "''"),
        }


class LogView(QPlainTextEdit):
    """Read-only monospace log panel with a block cap."""

    def __init__(self) -> None:
        super().__init__()
        self.setReadOnly(True)
        self.setMaximumBlockCount(20000)
        self.setFont(QFont("Consolas", 10))
        self.setLineWrapMode(QPlainTextEdit.LineWrapMode.NoWrap)


class MainWindow(QMainWindow):
    def __init__(self) -> None:
        super().__init__()
        self.setWindowTitle(APP_TITLE)
        self.setWindowIcon(QIcon(os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "app.ico")))
        self.resize(1060, 780)
        self.runner = EngineRunner(self)
        self.runner.line.connect(self._on_runner_line)
        self.runner.started.connect(self._on_runner_started)
        self.runner.finished.connect(self._on_runner_finished)

        central = QWidget()
        self.setCentralWidget(central)
        v = QVBoxLayout(central)
        v.setSpacing(10)
        v.setContentsMargins(12, 12, 12, 12)

        title = QLabel("Failing Disk Rescue")
        title.setStyleSheet(f"font-size: 18px; font-weight: 700; color: {ACCENT}; background: transparent;")
        v.addWidget(title)

        self.table = QTableWidget(0, 8)
        self.table.setHorizontalHeaderLabels(
            ["Disk", "Letters", "Model", "Size GB", "Media", "Bus", "Serial", "Flags"]
        )
        self.table.verticalHeader().setVisible(False)
        self.table.setSelectionBehavior(QTableWidget.SelectionBehavior.SelectRows)
        self.table.setSelectionMode(QTableWidget.SelectionMode.SingleSelection)
        self.table.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        self.table.setAlternatingRowColors(True)
        self.table.setMinimumHeight(170)
        v.addWidget(self.table)

        btn_row = QHBoxLayout()
        self.btn_refresh = QPushButton("Refresh Disks")
        self.btn_scan = QPushButton("Scan Selected...")
        self.btn_copy = QPushButton("Copy From Selected...")
        self.btn_report = QPushButton("Map Report...")
        self.btn_lost = QPushButton("Lost Files...")
        self.btn_list = QPushButton("List Details")
        for b in (self.btn_refresh, self.btn_list, self.btn_scan,
                  self.btn_copy, self.btn_report, self.btn_lost):
            btn_row.addWidget(b)
        btn_row.addStretch()
        v.addLayout(btn_row)

        self.log = LogView()
        v.addWidget(self.log, 1)

        bottom = QHBoxLayout()
        self.status = QLabel("Ready. Refresh the disks, pick the failing one, then Scan.")
        self.status.setStyleSheet(f"color: {TEXT_DIM}; background: transparent;")
        bottom.addWidget(self.status, 1)
        self.btn_stop = QPushButton("Stop")
        self.btn_clear = QPushButton("Clear")
        bottom.addWidget(self.btn_stop)
        bottom.addWidget(self.btn_clear)
        v.addLayout(bottom)

        self.btn_refresh.clicked.connect(self.refresh_disks)
        self.btn_list.clicked.connect(self.run_list)
        self.btn_scan.clicked.connect(self.on_scan)
        self.btn_copy.clicked.connect(self.on_copy)
        self.btn_report.clicked.connect(self.on_report)
        self.btn_lost.clicked.connect(self.on_lost)
        self.btn_stop.clicked.connect(self.on_stop)
        self.btn_clear.clicked.connect(self.log.clear)

        self.set_busy(False)
        self.refresh_disks(quiet=True)

    # -- disk table -------------------------------------------------------

    def refresh_disks(self, quiet: bool = False) -> None:
        try:
            disks = list_disks()
        except Exception as exc:
            if not quiet:
                QMessageBox.warning(self, "Disk Query Failed", str(exc))
            self.log.append(f"[ERROR] {exc}")
            return
        self.table.setRowCount(0)
        flags_font = QFont()
        flags_font.setBold(True)
        for d in disks:
            row = self.table.rowCount()
            self.table.insertRow(row)
            flags = []
            if d["Boot"]:
                flags.append("BOOT")
            if d["System"]:
                flags.append("SYSTEM")
            if d["Offline"]:
                flags.append("OFFLINE")
            values = [
                str(d["Number"]), d["Letters"], d["Model"],
                f"{d['SizeGB']:.1f}", d["Media"], d["Bus"], d["Serial"],
                " ".join(flags),
            ]
            for col, val in enumerate(values):
                item = QTableWidgetItem(val)
                if col == 7 and flags:
                    item.setForeground(QColor(ACCENT))
                    item.setFont(flags_font)
                self.table.setItem(row, col, item)
        self.table.resizeColumnsToContents()
        self.table.setColumnWidth(2, 240)
        if not quiet:
            self.status.setText(f"{len(disks)} physical disk(s) found.")

    def _selected_disk(self) -> dict | None:
        row = self.table.currentRow()
        if row < 0:
            QMessageBox.information(
                self, "No Disk Selected",
                "Select a disk in the table first (click a row)."
            )
            return None
        try:
            return {
                "number": int(self.table.item(row, 0).text()),
                "letters": self.table.item(row, 1).text(),
                "model": self.table.item(row, 2).text(),
                "size": float(self.table.item(row, 3).text() or 0),
            }
        except (ValueError, AttributeError):
            return None

    # -- actions ------------------------------------------------------------

    def run_list(self) -> None:
        self._start("List Disks", resolve(STUB_LIST))

    def on_scan(self) -> None:
        disk = self._selected_disk()
        if disk is None:
            return
        dlg = ScanDialog(self, disk["number"], disk["size"])
        if dlg.exec() != QDialog.DialogCode.Accepted:
            return
        vals = dlg.values()
        if not vals["disk"].isdigit():
            QMessageBox.warning(self, "Input Required", "Enter a valid disk number (digits only).")
            return
        self._start(
            f"Scan Disk {vals['disk']} (Build Map)",
            resolve(STUB_SCAN, {
                "__INPUT__": vals["disk"], "__MAP__": vals["map"],
                "__PROBEMIB__": vals["probe"], "__MINSTEP__": vals["floor"],
                "__TIMEOUTMS__": vals["timeout"],
            }),
        )

    def on_copy(self) -> None:
        disk = self._selected_disk()
        if disk is None:
            return
        letters = [x.strip() for x in disk["letters"].split(",") if x.strip() and x.strip() != "-"]
        if not letters:
            QMessageBox.warning(
                self, "No Volume Letter",
                "The selected disk has no mounted volume letter. Mount it first\n"
                "(Disk Management) so its files can be enumerated."
            )
            return
        dlg = CopyDialog(self, letters[0], disk["number"])
        if dlg.exec() != QDialog.DialogCode.Accepted:
            return
        vals = dlg.values()
        if not vals["dest"]:
            QMessageBox.warning(self, "Input Required", "Choose a destination folder first.")
            return
        dest_display = vals["dest"].replace("''", "'")
        confirm = QMessageBox.question(
            self, "Confirm Copy",
            f"Copy files from {letters[0]}: (disk {disk['number']}) to:\n\n{dest_display}\n\n"
            "Damaged regions are skipped and zero-filled. The destination must be\n"
            "on a different physical disk. Continue?",
        )
        if confirm != QMessageBox.StandardButton.Yes:
            return
        self._start(
            f"Copy Files from {letters[0]}:",
            resolve(STUB_COPY, {
                "__DRIVE__": letters[0], "__DEST__": vals["dest"], "__MAP__": vals["map"],
            }),
        )

    def on_report(self) -> None:
        path, _ = QFileDialog.getOpenFileName(
            self, "Select a map file (or type a disk number)", DATA_DIR,
            "Disk Rescue maps (*.json);;All files (*.*)",
        )
        text, ok = self._ask_text(
            "Show Map Report",
            "Map .json file path (or just a disk number):",
            path or "",
        )
        if not ok:
            return
        self._start("Show Map Report", resolve(STUB_REPORT, {"__INPUT__": text.replace("'", "''")}))

    def on_lost(self) -> None:
        path, _ = QFileDialog.getOpenFileName(
            self, "Select a copy report (or type a disk number)", DATA_DIR,
            "Copy reports (*.txt);;All files (*.*)",
        )
        text, ok = self._ask_text(
            "Show Lost Files",
            "Copy-report .txt path (or just a disk number):",
            path or "",
        )
        if not ok:
            return
        self._start("Show Lost Files", resolve(STUB_LOST, {"__INPUT__": text.replace("'", "''")}))

    def _ask_text(self, title: str, label: str, value: str) -> tuple[str, bool]:
        text, ok = QInputDialog.getText(self, title, label, text=value)
        text = text.strip()
        if not ok or not text:
            return "", False
        return text, True

    # -- runner plumbing ----------------------------------------------------

    def _start(self, label: str, script: str) -> None:
        stamp = time.strftime("%H:%M:%S")
        self.log.append("")
        self.log.append(f"[{stamp}] ===== STARTED: {label} =====")
        self.log.append("")
        self.runner.start(label, script)

    def _on_runner_line(self, line: str) -> None:
        self.log.append(line)

    def _on_runner_started(self, label: str) -> None:
        self.status.setText(f"RUNNING: {label}")
        self.set_busy(True)

    def _on_runner_finished(self, code: int) -> None:
        stamp = time.strftime("%H:%M:%S")
        if code == -1:
            self.log.append("")
            self.log.append(f"[{stamp}] ===== TERMINATED BY USER =====")
            self.status.setText("TERMINATED")
        elif code == 0:
            self.log.append("")
            self.log.append(f"[{stamp}] ===== COMPLETED SUCCESSFULLY =====")
            self.status.setText("COMPLETED")
        else:
            self.log.append("")
            self.log.append(f"[{stamp}] ===== COMPLETED WITH ERRORS (exit {code}) =====")
            self.status.setText(f"FAILED (exit {code})")
        self.set_busy(False)

    def on_stop(self) -> None:
        if self.runner.running:
            self.runner.stop()

    def set_busy(self, busy: bool) -> None:
        for b in (self.btn_refresh, self.btn_list, self.btn_scan,
                  self.btn_copy, self.btn_report, self.btn_lost):
            b.setEnabled(not busy)
        self.btn_stop.setEnabled(busy)

    def closeEvent(self, event) -> None:  # noqa: N802
        if self.runner.running:
            self.runner.stop()
        event.accept()


def main() -> int:
    app = QApplication.instance() or QApplication([])
    app.setStyleSheet(DARK_QSS)
    win = MainWindow()
    win.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
