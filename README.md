# DriveStitch

<p align="center">
  <img src="icon.png" alt="DriveStitch icon" width="128" />
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green.svg" alt="License: MIT"></a>
  <a href="https://www.python.org"><img src="https://img.shields.io/badge/python-3.12%2B-3776AB?logo=python&logoColor=white" alt="Python 3.12+"></a>
  <a href="https://www.qt.io/qt-for-python"><img src="https://img.shields.io/badge/GUI-PySide6%20(Qt)-41CD52?logo=qt&logoColor=white" alt="PySide6"></a>
  <a href="https://learn.microsoft.com/powershell"><img src="https://img.shields.io/badge/engine-PowerShell-5391FE?logo=powershell&logoColor=white" alt="PowerShell"></a>
  <img src="https://img.shields.io/badge/platform-Windows%2010%2F11-0078D6?logo=windows11" alt="Windows 10/11">
  <img src="https://img.shields.io/github/stars/stavros-it/DriveStitch?style=flat" alt="Stars">
</p>

Standalone failing-disk rescue tool with a PySide6 GUI. Maps a failing disk's
readable vs damaged regions with read-only watchdog-protected probes, then
copies files off it — skipping damaged areas (zero-filled) instead of stalling
forever. Resumable maps, per-file copy report, lost-files list.

## How it works

1. **Refresh Disks** — lists the physical disks in the table.
2. **Scan Selected...** — builds a GOOD/BAD map of the failing disk
   (adjustable step numbers: probe sample size, refine floor, timeout).
   Read-only; interrupting is safe (the scan resumes).
3. **Copy From Selected...** — copies every file to a folder on a DIFFERENT
   healthy disk, skipping known-damaged regions and reading the rest through
   the same watchdog.
4. **Map Report... / Lost Files...** — inspect the map or list files that did
   not fully recover.

Maps and copy reports are saved to the portable `DiskRescue` folder inside the
app directory (any other folder can be chosen in the dialogs).

## Getting started

- Windows 10/11, Administrator rights
- Python 3.12+ with PySide6 (`python -m pip install -r requirements.txt`)
- Launch `DriveStitch.pyw` — it requests Administrator rights through UAC on
  start (raw disk access requires elevation), or run
  `Create Desktop Shortcut.bat` once to put a shortcut with the app icon on
  your desktop.

## Development

- `make_icon.py` — regenerates the application icon (`app.ico` +
  `icon.png` for the README); needs Pillow
  (`python -m pip install pillow`).
- `tests/test-worker.ps1` — probe-worker test suite (15 checks: protocol,
  base64 file reads, wedge watchdog, respawn, dispose). Must run elevated;
  raw-disk checks target a SanDisk SDSSDP064G 64 GB test disk (disk 5).

## Provenance

DriveStitch is inspired by the GOOD-first recovery concept of the
[AdaptiveDisk](https://github.com/orloxgr/AdaptiveDisk) project (GPL-3.0).
No code was taken from it: the engine (`engine/DiskRescueLib.ps1`) is an
original implementation, and its native I/O layer is a clean-room
implementation written from the documented Win32 APIs.

## License

This project is licensed under the [MIT License](LICENSE).

Third-party components (PySide6/Qt, Pillow) are governed by their own
licenses — see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
