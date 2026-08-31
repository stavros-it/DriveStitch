# SA DiskFileDigger

Standalone failing-disk rescue tool with a PySide6 GUI. Maps a failing disk's
readable vs damaged regions with read-only watchdog-protected probes, then
copies files off it — skipping damaged areas (zero-filled) instead of stalling
forever. Resumable maps, per-file copy report, lost-files list.

Launched via `DiskFileDigger.pyw` (requests Administrator rights through UAC
on start — raw disk access requires elevation).

## Usage

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

## Requirements

- Windows 10/11, Administrator rights
- Python 3.12+ with PySide6 (`python -m pip install -r requirements.txt`)

## Provenance

The engine (`engine/DiskRescueLib.ps1`) is an original proprietary
implementation (© 2026 Stavros Antoniou) inspired by the GOOD-first recovery
concept of the [AdaptiveDisk](https://github.com/orloxgr/AdaptiveDisk) project
(GPL-3.0). No code was taken from it. Part of the SysDigger tool suite.
