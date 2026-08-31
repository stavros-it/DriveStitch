"""Physical disk inventory via PowerShell (JSON, no Python WMI deps)."""

from __future__ import annotations

import json
import subprocess

from scripts import DISKS_JSON, PREAMBLE

_CREATION_FLAGS = getattr(subprocess, "CREATE_NO_WINDOW", 0)


def list_disks() -> list[dict]:
    """Return one dict per physical disk.

    Keys: Number, Letters, Model, SizeGB, Media, Bus, Serial, Boot,
    System, Offline. Raises RuntimeError when PowerShell fails.
    """
    script = PREAMBLE + "\n" + DISKS_JSON
    result = subprocess.run(
        ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
         "-Command", script],
        creationflags=_CREATION_FLAGS,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=60,
    )
    out = result.stdout or ""
    if result.returncode != 0:
        raise RuntimeError(
            f"Get-Disk query failed (exit {result.returncode}): "
            f"{(result.stderr or out).strip()[:300]}"
        )
    start = out.find("__DFD_JSON_BEGIN__")
    end = out.find("__DFD_JSON_END__")
    if start < 0 or end < 0:
        raise RuntimeError(f"Unexpected disk query output: {out[:200]}")
    payload = out[start + len("__DFD_JSON_BEGIN__"):end].strip()
    if not payload:
        return []
    data = json.loads(payload)
    if isinstance(data, dict):
        data = [data]
    disks: list[dict] = []
    for row in data:
        try:
            disks.append({
                "Number": int(row.get("Number", -1)),
                "Letters": str(row.get("Letters", "-") or "-"),
                "Model": str(row.get("Model", "") or ""),
                "SizeGB": float(row.get("SizeGB", 0.0) or 0.0),
                "Media": str(row.get("Media", "?") or "?"),
                "Bus": str(row.get("Bus", "") or ""),
                "Serial": str(row.get("Serial", "") or ""),
                "Boot": bool(row.get("Boot", False)),
                "System": bool(row.get("System", False)),
                "Offline": bool(row.get("Offline", False)),
            })
        except (TypeError, ValueError):
            continue
    return disks
