"""Subprocess-based runner: launches PowerShell scripts and streams output.

One engine process at a time, run on a daemon thread with CREATE_NO_WINDOW
(no console flash). Stop kills the whole process tree via taskkill - safe for
the engine (maps are checkpointed, per-file copies resume).
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import threading

from PySide6.QtCore import QObject, Signal

from scripts import PREAMBLE

_CREATION_FLAGS = getattr(subprocess, "CREATE_NO_WINDOW", 0)


class EngineRunner(QObject):
    """Runs one PowerShell script and streams its output line by line."""

    line = Signal(str)
    started = Signal(str)          # action label
    finished = Signal(int)         # exit code (-1 when killed)

    def __init__(self, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self._proc: subprocess.Popen | None = None
        self._label = ""
        self._running = False
        self._kill_requested = False

    @property
    def running(self) -> bool:
        return self._running

    @property
    def label(self) -> str:
        return self._label

    def start(self, label: str, script: str) -> None:
        if self._running:
            return
        fd, path = tempfile.mkstemp(suffix=".ps1", prefix="dfd_")
        # utf-8-sig writes a BOM so Windows PowerShell 5.1 detects UTF-8.
        with os.fdopen(fd, "w", encoding="utf-8-sig") as f:
            f.write(PREAMBLE)
            f.write("\n")
            f.write(script)
        self._label = label
        self._running = True
        self._kill_requested = False
        self.started.emit(label)
        threading.Thread(
            target=self._worker, args=(path,), daemon=True, name="dfd-engine"
        ).start()

    def _worker(self, script_path: str) -> None:
        code = -1
        try:
            proc = subprocess.Popen(
                ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
                 "-File", script_path],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                creationflags=_CREATION_FLAGS,
            )
            self._proc = proc
            assert proc.stdout is not None
            for raw in iter(proc.stdout.readline, b""):
                self.line.emit(raw.decode("utf-8", errors="replace").rstrip("\r\n"))
            code = proc.wait()
        except Exception as exc:
            if self._running and not self._kill_requested:
                self.line.emit(f"[ERROR] {exc}")
            code = -1
        finally:
            try:
                os.remove(script_path)
            except OSError:
                pass
            self._proc = None
            self._running = False
            self.finished.emit(-1 if self._kill_requested else code)

    def stop(self) -> None:
        """Kill the running engine (whole process tree, force)."""
        self._kill_requested = True
        proc = self._proc
        if proc is None or proc.poll() is not None:
            return
        try:
            subprocess.run(
                ["taskkill", "/T", "/F", "/PID", str(proc.pid)],
                creationflags=_CREATION_FLAGS,
                timeout=5,
                capture_output=True,
            )
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass
