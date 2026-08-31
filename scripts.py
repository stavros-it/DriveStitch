"""PowerShell script catalogue for SA DiskFileDigger.

Each action runs as a non-interactive ``powershell.exe -File`` subprocess.
Tokens (``__ENGINE__`` / ``__DISKRESCUE_DATA__`` / ``__INPUT__`` /
``__MAP__`` / ``__PROBEMIB__`` / ``__MINSTEP__`` / ``__TIMEOUTMS__`` /
``__DRIVE__`` / ``__DEST__``) are substituted by the GUI before launch.

The engine lives in ``engine/DiskRescueLib.ps1`` - original proprietary code
(c) Stavros Antoniou, inspired by the GOOD-first recovery concept of the
GPL-3.0 AdaptiveDisk project. No code was taken from it.
"""

from __future__ import annotations

import os

APP_ROOT = os.path.dirname(os.path.abspath(__file__))
ENGINE_PATH = os.path.join(APP_ROOT, "engine", "DiskRescueLib.ps1")
DATA_DIR = os.path.join(APP_ROOT, "DiskRescue")

PREAMBLE = r"""$ProgressPreference='SilentlyContinue'
$ErrorActionPreference='Continue'
$FormatEnumerationLimit=-1
try { [Console]::OutputEncoding=[System.Text.Encoding]::UTF8 } catch {}
try { $OutputEncoding=[System.Text.Encoding]::UTF8 } catch {}
"""

# Disk inventory as JSON for the GUI table (not part of the engine lib).
DISKS_JSON = r"""$rows = foreach ($d in (Get-Disk | Sort-Object Number)) {
    $letters = '-'
    try {
        $ls = @(Get-Partition -DiskNumber ([int]$d.Number) -ErrorAction SilentlyContinue |
            Where-Object { $_.DriveLetter } |
            Sort-Object PartitionNumber |
            ForEach-Object { '{0}:' -f $_.DriveLetter })
        if ($ls.Count -gt 0) { $letters = ($ls -join ',') }
    } catch { }
    $media = '?'
    try {
        $serial = ([string]$d.SerialNumber).Trim()
        $pd = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object {
            ([string]$_.DeviceId) -eq ([string]$d.Number) -or
            ($serial -and (([string]$_.SerialNumber).Trim() -eq $serial))
        } | Select-Object -First 1)
        if ($pd.Count -gt 0) { $media = [string]$pd[0].MediaType }
    } catch { }
    [pscustomobject]@{
        Number  = [int]$d.Number
        Letters = $letters
        Model   = ([string]$d.FriendlyName).Trim()
        SizeGB  = [math]::Round([double]$d.Size / 1GB, 1)
        Media   = $media
        Bus     = [string]$d.BusType
        Serial  = ([string]$d.SerialNumber).Trim()
        Boot    = [bool]$d.IsBoot
        System  = [bool]$d.IsSystem
        Offline = [bool]$d.IsOffline
    }
}
Write-Output '__DFD_JSON_BEGIN__'
$rows | ConvertTo-Json -Compress -Depth 4
Write-Output '__DFD_JSON_END__'
"""


def _data_line() -> str:
    return "$script:DiskRescueDataDir = '__DISKRESCUE_DATA__'\n"


STUB_LIST = (
    ". '__ENGINE__'\n"
    + _data_line()
    + "Show-DiskRescueDisks\n"
)

STUB_SCAN = (
    ". '__ENGINE__'\n"
    + _data_line()
    + "$v = '__INPUT__'\n"
    "if ($v -match '^(\\d+)\\|(.+)$') {\n"
    "    $diskNum = [int]$Matches[1]\n"
    "    $mapPath = $Matches[2]\n"
    "} elseif ($v -match '^\\d+$') {\n"
    "    $diskNum = [int]$v\n"
    "    $mapPath = '__MAP__'\n"
    "} else {\n"
    "    Write-Output \"[ERROR] '$v' is not a disk number.\"\n"
    "    return\n"
    "}\n"
    "if ([string]::IsNullOrWhiteSpace($mapPath)) {\n"
    "    $mapPath = Get-DiskRescueMapPath -DiskNumber $diskNum\n"
    "}\n"
    "try {\n"
    "    Invoke-DiskRescueScan -Disk $diskNum -Map $mapPath -ProbeMiB __PROBEMIB__ -MinStepMiB __MINSTEP__ -TimeoutMs __TIMEOUTMS__\n"
    "} catch {\n"
    "    Write-Output (\"[ERROR] \" + $_.Exception.Message)\n"
    "    Write-Output '[HINT] The map must be saved on a DIFFERENT physical disk than the one being scanned.'\n"
    "}\n"
)

STUB_REPORT = (
    ". '__ENGINE__'\n"
    + _data_line()
    + "$v = '__INPUT__'\n"
    "if ($v -match '^\\d+$') { $p = Get-DiskRescueMapPath -DiskNumber ([int]$v) } else { $p = $v }\n"
    "if (-not (Test-Path -LiteralPath $p)) {\n"
    "    Write-Output \"[ERROR] Map not found: $p\"\n"
    "    return\n"
    "}\n"
    "Show-DiskRescueReport -Map $p\n"
)

STUB_COPY = (
    ". '__ENGINE__'\n"
    + _data_line()
    + "$src = '__DRIVE__:'\n"
    "$dest = '__DEST__'\n"
    "$mv = '__MAP__'\n"
    "if ([string]::IsNullOrWhiteSpace($dest)) {\n"
    "    Write-Output '[ERROR] No destination folder was given.'\n"
    "    return\n"
    "}\n"
    "$mp = ''\n"
    "if ($mv -match '^\\d+$') {\n"
    "    $mp = Get-DiskRescueMapPath -DiskNumber ([int]$mv)\n"
    "} elseif (-not [string]::IsNullOrWhiteSpace($mv)) {\n"
    "    $mp = $mv\n"
    "} else {\n"
    "    try {\n"
    "        $dn = (Get-Partition -DriveLetter $src.TrimEnd(':') -ErrorAction Stop).DiskNumber\n"
    "        $cand = Get-DiskRescueMapPath -DiskNumber $dn\n"
    "        if (Test-Path -LiteralPath $cand) { $mp = $cand }\n"
    "    } catch { }\n"
    "}\n"
    "if ([string]::IsNullOrWhiteSpace($mp)) {\n"
    "    Write-Output '[INFO] No map found for this disk - copying with per-chunk watchdog protection only.'\n"
    "}\n"
    "try {\n"
    "    Invoke-DiskRescueCopy -Source $src -Destination $dest -Map $mp\n"
    "} catch {\n"
    "    Write-Output (\"[ERROR] \" + $_.Exception.Message)\n"
    "    Write-Output '[HINT] The destination must be a folder on a DIFFERENT physical disk than the source.'\n"
    "}\n"
)

STUB_LOST = (
    ". '__ENGINE__'\n"
    + _data_line()
    + "$v = '__INPUT__'\n"
    "if ($v -match '^\\d+$') { $p = Get-DiskRescueReportPath -DiskNumber ([int]$v) } else { $p = $v }\n"
    "if (-not (Test-Path -LiteralPath $p)) {\n"
    "    Write-Output \"[ERROR] Copy report not found: $p\"\n"
    "    return\n"
    "}\n"
    "Show-DiskRescueLost -Report $p\n"
)


def resolve(script: str, subs: dict[str, str] | None = None) -> str:
    out = (script
           .replace("__ENGINE__", ENGINE_PATH)
           .replace("__DISKRESCUE_DATA__", DATA_DIR))
    for token, value in (subs or {}).items():
        out = out.replace(token, value)
    return out
