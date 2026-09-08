# DriveStitch - standalone failing-disk rescue tool.
# Copyright (c) 2026 Stavros Antoniou. MIT License - see LICENSE.
#
# Launches the PySide6 GUI. Requires Administrator privileges for raw disk
# access - relaunches itself elevated through UAC when started normally.

import ctypes
import os
import sys


def is_admin() -> bool:
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:
        return False


def elevate() -> None:
    script = os.path.abspath(__file__)
    params = f'"{script}"'
    ret = ctypes.windll.shell32.ShellExecuteW(
        None, "runas", sys.executable, params, None, 1
    )
    if ret <= 32:
        # 1223 = user cancelled the UAC prompt
        ctypes.windll.user32.MessageBoxW(
            None,
            "Administrator privileges are required for raw disk access.\n"
            "The app was not started because the UAC prompt was cancelled.",
            "DriveStitch",
            0x10,
        )


def main() -> int:
    if not is_admin():
        elevate()
        return 0
    os.chdir(os.path.dirname(os.path.abspath(__file__)))
    from PySide6.QtWidgets import QApplication
    from app_window import APP_TITLE, DARK_QSS, MainWindow

    app = QApplication(sys.argv)
    app.setApplicationName(APP_TITLE)
    app.setStyleSheet(DARK_QSS)
    win = MainWindow()
    win.show()
    return app.exec()


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        # Automated check: build the window offscreen, query disks, exit.
        os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
        from PySide6.QtCore import QTimer
        from PySide6.QtWidgets import QApplication
        from app_window import DARK_QSS, MainWindow
        from disks import list_disks

        app = QApplication(sys.argv)
        app.setStyleSheet(DARK_QSS)
        win = MainWindow()
        disks = list_disks()
        assert win.table.rowCount() == len(disks), (
            f"table rows {win.table.rowCount()} != disks {len(disks)}"
        )
        assert win.runner is not None
        print(f"SELFTEST OK: {len(disks)} disk(s) listed")
        QTimer.singleShot(0, app.quit)
        raise SystemExit(app.exec())
    raise SystemExit(main() or 0)
