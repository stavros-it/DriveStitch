# DiskRescueLib.ps1 - failing-disk mapper and bad-aware file copier.
# Copyright (c) 2026 Stavros Antoniou. MIT License - see LICENSE.
#
# A failing HDD often stalls whole-file copies on a handful of unreadable
# sectors. This library takes a different approach in two phases:
#
#   1. SCAN  - read-only raw probing of the physical disk with per-probe
#              timeouts, building a GOOD/BAD map (JSON) with resume support.
#   2. COPY  - walk every file, translate its NTFS extents to physical disk
#              offsets, skip known-BAD regions (zero-fill them) and read
#              everything else through a watchdog that aborts a hung read
#              after a timeout instead of stalling forever.
#
# Scan never writes to the source disk. Copy writes only to the destination.
# Every entry point is non-interactive and streams plain text progress lines,
# so it works inside a log panel with no console interaction.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:MiB = [int64]1048576
$script:GiB = [int64]1073741824

# Default data folder for maps and copy reports. The GUI stubs override this
# with the app's root DiskRescue folder (portable); direct lib use falls back
# to Documents\DiskRescue.
$script:DiskRescueDataDir = ''

# ---------------------------------------------------------------------------
# Native I/O helpers - clean-room C# written from the documented Win32 APIs
# (independent implementation, no third-party code).
# ---------------------------------------------------------------------------

$script:DiskRescueIo = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace DiskRescueIo
{
    // Outcome of one watchdog-protected read. Status: Good | Timeout | Error.
    // Win32Error carries the driver error code (1460 = watchdog timeout).
    public sealed class ReadReport
    {
        public string Status;
        public byte[] Data;
        public int BytesRead;
        public long DurationMs;
        public int Win32Error;
        public string Message;
    }

    // Capacity and sector size of a physical drive.
    public sealed class DriveGeometry
    {
        public long CapacityBytes;
        public int SectorSize;
    }

    // Single declaration point for the Win32 surface used below.
    internal static class Win
    {
        public const uint GENERIC_READ = 0x80000000;
        public const uint FILE_SHARE_READ = 0x1;
        public const uint FILE_SHARE_WRITE = 0x2;
        public const uint FILE_SHARE_DELETE = 0x4;
        public const uint OPEN_EXISTING = 3;
        public const uint FILE_FLAG_NO_BUFFERING = 0x20000000;
        public const uint FILE_FLAG_OVERLAPPED = 0x40000000;
        public const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
        public const uint IOCTL_DISK_GET_DRIVE_GEOMETRY_EX = 0x000700A0;
        public const uint FSCTL_GET_RETRIEVAL_POINTERS = 0x00090073;
        public const int ERROR_IO_PENDING = 997;
        public const int ERROR_HANDLE_EOF = 38;
        public const int ERROR_MORE_DATA = 234;
        public const int ERROR_TIMEOUT = 1460;
        public const uint WAIT_OBJECT_0 = 0;

        [StructLayout(LayoutKind.Sequential)]
        public struct Overlapped
        {
            public IntPtr Internal;
            public IntPtr InternalHigh;
            public uint Offset;
            public uint OffsetHigh;
            public IntPtr hEvent;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct DiskGeometryPrefix
        {
            public long Cylinders;
            public int MediaType;
            public int TracksPerCylinder;
            public int SectorsPerTrack;
            public int BytesPerSector;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern SafeFileHandle CreateFileW(string name, uint access, uint share,
            IntPtr security, uint creation, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool ReadFile(SafeFileHandle file, IntPtr buffer, uint toRead,
            IntPtr readRef, IntPtr overlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool DeviceIoControl(SafeFileHandle file, uint code,
            byte[] inBuf, int inSize, IntPtr outBuf, int outSize,
            out uint returned, IntPtr overlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool DeviceIoControl(SafeFileHandle file, uint code,
            byte[] inBuf, int inSize, byte[] outBuf, int outSize,
            out int returned, IntPtr overlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetOverlappedResult(SafeFileHandle file, IntPtr overlapped,
            out uint transferred, bool wait);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool CancelIoEx(SafeFileHandle file, IntPtr overlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr CreateEventW(IntPtr attrs, bool manualReset,
            bool initialState, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern uint WaitForSingleObject(IntPtr handle, uint ms);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetDiskFreeSpaceW(string root, out int sectorsPerCluster,
            out int bytesPerSector, out int freeClusters, out int totalClusters);
    }

    // Runs one overlapped read under the watchdog: wait up to timeoutMs for
    // the driver, then cancel and wait cancelGraceMs more. A driver that
    // ignores the cancellation keeps kernel ownership of the request block -
    // that memory is dropped on purpose (freeing it would corrupt the
    // in-flight request) and the caller is told to recycle its handle.
    internal static class Watchdog
    {
        public static ReadReport Read(SafeFileHandle file, long offset, int length,
            int timeoutMs, int cancelGraceMs, bool copyOut, out bool wedged)
        {
            var report = new ReadReport { Status = "Error", Message = "" };
            wedged = false;
            IntPtr block = IntPtr.Zero, slot = IntPtr.Zero, signal = IntPtr.Zero;
            bool inFlight = false;
            var clock = Stopwatch.StartNew();
            try
            {
                signal = Win.CreateEventW(IntPtr.Zero, true, false, null);
                if (signal == IntPtr.Zero)
                    throw new Win32Exception(Marshal.GetLastWin32Error(),
                        "A completion event could not be created.");
                block = Marshal.AllocHGlobal(length);
                slot = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(Win.Overlapped)));
                var op = new Win.Overlapped();
                op.Offset = unchecked((uint)(offset & 0xFFFFFFFFL));
                op.OffsetHigh = unchecked((uint)((ulong)offset >> 32));
                op.hEvent = signal;
                Marshal.StructureToPtr(op, slot, false);

                if (Win.ReadFile(file, block, unchecked((uint)length), IntPtr.Zero, slot))
                {
                    Harvest(file, slot, block, length, copyOut, report);
                    return report;
                }
                int immediate = Marshal.GetLastWin32Error();
                if (immediate != Win.ERROR_IO_PENDING)
                {
                    report.Win32Error = immediate;
                    report.Message = new Win32Exception(immediate).Message;
                    return report;
                }
                inFlight = true;
                if (Win.WaitForSingleObject(signal, unchecked((uint)timeoutMs)) == Win.WAIT_OBJECT_0)
                {
                    inFlight = false;
                    Harvest(file, slot, block, length, copyOut, report);
                    return report;
                }
                Win.CancelIoEx(file, slot);
                if (Win.WaitForSingleObject(signal, unchecked((uint)cancelGraceMs)) == Win.WAIT_OBJECT_0)
                {
                    inFlight = false;
                    uint done;
                    Win.GetOverlappedResult(file, slot, out done, false);
                    report.Status = "Timeout";
                    report.Win32Error = Win.ERROR_TIMEOUT;
                    report.Message = "The watchdog cancelled the read.";
                    return report;
                }
                report.Status = "Timeout";
                report.Win32Error = Win.ERROR_TIMEOUT;
                report.Message = "The driver never completed the cancelled request; handle recycled.";
                wedged = true;
                return report;
            }
            catch (Exception ex)
            {
                report.Status = "Error";
                report.Message = ex.Message;
                return report;
            }
            finally
            {
                clock.Stop();
                report.DurationMs = clock.ElapsedMilliseconds;
                if (!inFlight)
                {
                    if (signal != IntPtr.Zero) Win.CloseHandle(signal);
                    if (slot != IntPtr.Zero) Marshal.FreeHGlobal(slot);
                    if (block != IntPtr.Zero) Marshal.FreeHGlobal(block);
                }
            }
        }

        private static void Harvest(SafeFileHandle file, IntPtr slot, IntPtr block,
            int length, bool copyOut, ReadReport report)
        {
            uint moved;
            if (!Win.GetOverlappedResult(file, slot, out moved, false))
            {
                report.Win32Error = Marshal.GetLastWin32Error();
                report.Message = new Win32Exception(report.Win32Error).Message;
                return;
            }
            report.BytesRead = unchecked((int)moved);
            if (copyOut)
            {
                // A short tail at end-of-file is a normal, successful chunk.
                report.Status = "Good";
                var data = new byte[(int)moved];
                if (moved > 0) Marshal.Copy(block, data, 0, (int)moved);
                report.Data = data;
                return;
            }
            if (moved == (uint)length)
            {
                report.Status = "Good";
            }
            else
            {
                report.Message = "Short read: the device returned " + moved + " of " + length + " bytes.";
            }
        }
    }

    // Raw \\.\PhysicalDriveN prober. NO_BUFFERING reads require
    // sector-aligned offsets (the scan layer guarantees this).
    public sealed class DriveProbe : IDisposable
    {
        private readonly string _device;
        private SafeFileHandle _file;
        private bool _closed;

        public DriveProbe(int diskNumber)
        {
            _device = @"\\.\PhysicalDrive" + diskNumber;
            _file = OpenDevice();
        }

        private SafeFileHandle OpenDevice()
        {
            SafeFileHandle h = Win.CreateFileW(_device, Win.GENERIC_READ,
                Win.FILE_SHARE_READ | Win.FILE_SHARE_WRITE, IntPtr.Zero, Win.OPEN_EXISTING,
                Win.FILE_FLAG_NO_BUFFERING | Win.FILE_FLAG_OVERLAPPED, IntPtr.Zero);
            if (h.IsInvalid)
                throw new Win32Exception(Marshal.GetLastWin32Error(),
                    "Cannot open " + _device + "; raw disk access needs elevation and a valid disk number.");
            return h;
        }

        public bool Recycle()
        {
            SafeFileHandle old = _file;
            _file = null;
            if (old != null) { try { old.Dispose(); } catch { } }
            try { _file = OpenDevice(); return true; }
            catch { _file = null; return false; }
        }

        public DriveGeometry GetGeometry()
        {
            IntPtr geoBuf = Marshal.AllocHGlobal(1024);
            try
            {
                uint returned;
                if (!Win.DeviceIoControl(_file, Win.IOCTL_DISK_GET_DRIVE_GEOMETRY_EX, null, 0,
                    geoBuf, 1024, out returned, IntPtr.Zero))
                    throw new Win32Exception(Marshal.GetLastWin32Error(),
                        "The disk did not answer the geometry query.");
                var head = (Win.DiskGeometryPrefix)Marshal.PtrToStructure(
                    geoBuf, typeof(Win.DiskGeometryPrefix));
                long capacity = Marshal.ReadInt64(geoBuf, Marshal.SizeOf(typeof(Win.DiskGeometryPrefix)));
                if (head.BytesPerSector <= 0 || capacity <= 0)
                    throw new InvalidOperationException("The device reported an implausible geometry.");
                return new DriveGeometry { CapacityBytes = capacity, SectorSize = head.BytesPerSector };
            }
            finally { Marshal.FreeHGlobal(geoBuf); }
        }

        public ReadReport ReadAt(long offset, int length, int timeoutMs, int cancelGraceMs)
        {
            SafeFileHandle file = _file;
            if (file == null || file.IsInvalid)
            {
                if (!Recycle())
                    return new ReadReport { Status = "Error", Message = "The raw device handle could not be reopened." };
                file = _file;
            }
            bool wedged;
            ReadReport report = Watchdog.Read(file, offset, length, timeoutMs, cancelGraceMs, false, out wedged);
            if (wedged) Recycle();
            return report;
        }

        public void Dispose()
        {
            if (_closed) return;
            _closed = true;
            SafeFileHandle file = _file;
            _file = null;
            if (file != null) { try { file.Dispose(); } catch { } }
            GC.SuppressFinalize(this);
        }
    }

    // Per-file chunk reader: buffered overlapped reads, so arbitrary offsets
    // and lengths are allowed; a hanging chunk is cancelled by the watchdog.
    public sealed class FileChunkReader : IDisposable
    {
        private readonly string _source;
        private SafeFileHandle _file;
        private bool _closed;

        public FileChunkReader(string path)
        {
            _source = path;
            _file = OpenSource();
        }

        private SafeFileHandle OpenSource()
        {
            SafeFileHandle h = Win.CreateFileW(_source, Win.GENERIC_READ,
                Win.FILE_SHARE_READ | Win.FILE_SHARE_WRITE | Win.FILE_SHARE_DELETE,
                IntPtr.Zero, Win.OPEN_EXISTING, Win.FILE_FLAG_OVERLAPPED, IntPtr.Zero);
            if (h.IsInvalid)
                throw new Win32Exception(Marshal.GetLastWin32Error(),
                    "The file could not be opened: " + _source);
            return h;
        }

        public bool Recycle()
        {
            SafeFileHandle old = _file;
            _file = null;
            if (old != null) { try { old.Dispose(); } catch { } }
            try { _file = OpenSource(); return true; }
            catch { _file = null; return false; }
        }

        public ReadReport ReadAt(long offset, int length, int timeoutMs, int cancelGraceMs)
        {
            SafeFileHandle file = _file;
            if (file == null || file.IsInvalid)
            {
                if (!Recycle())
                    return new ReadReport { Status = "Error", Message = "The file handle could not be reopened." };
                file = _file;
            }
            bool wedged;
            ReadReport report = Watchdog.Read(file, offset, length, timeoutMs, cancelGraceMs, true, out wedged);
            if (wedged) Recycle();
            return report;
        }

        public void Dispose()
        {
            if (_closed) return;
            _closed = true;
            SafeFileHandle file = _file;
            _file = null;
            if (file != null) { try { file.Dispose(); } catch { } }
            GC.SuppressFinalize(this);
        }
    }

    // NTFS placement helpers: cluster size and physical run lookup.
    public static class NtfsLayout
    {
        public static int BytesPerCluster(string driveRoot)
        {
            int spc, bps, freeC, totalC;
            if (Win.GetDiskFreeSpaceW(driveRoot, out spc, out bps, out freeC, out totalC))
                return spc * bps;
            return 4096;
        }

        // Physical placement of a file on its volume. Each entry is a
        // { fileOffset, volumeOffset, length } byte triple; volumeOffset is
        // -1 for sparse runs. NTFS volumes only.
        public static List<long[]> PhysicalRuns(string path, int clusterSize)
        {
            var runs = new List<long[]>();
            SafeFileHandle h = Win.CreateFileW(@"\\?\" + path, Win.GENERIC_READ,
                Win.FILE_SHARE_READ | Win.FILE_SHARE_WRITE | Win.FILE_SHARE_DELETE,
                IntPtr.Zero, Win.OPEN_EXISTING, Win.FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero);
            if (h.IsInvalid)
                throw new Win32Exception(Marshal.GetLastWin32Error(),
                    "The file could not be opened for extent lookup: " + path);
            try
            {
                byte[] reply = new byte[64 * 1024];
                long vcn = 0;
                while (true)
                {
                    int returned;
                    if (!Win.DeviceIoControl(h, Win.FSCTL_GET_RETRIEVAL_POINTERS,
                        BitConverter.GetBytes(vcn), 8, reply, reply.Length, out returned, IntPtr.Zero))
                    {
                        int rc = Marshal.GetLastWin32Error();
                        if (rc == Win.ERROR_HANDLE_EOF) break;
                        if (rc == Win.ERROR_MORE_DATA)
                        {
                            if (reply.Length >= 16 * 1024 * 1024)
                                throw new IOException("The file is too fragmented to map its runs.");
                            reply = new byte[reply.Length * 2];
                            continue;
                        }
                        throw new Win32Exception(rc, "FSCTL_GET_RETRIEVAL_POINTERS did not answer.");
                    }
                    if (returned < 16) break;
                    int count = BitConverter.ToInt32(reply, 0);
                    long startVcn = BitConverter.ToInt64(reply, 8);
                    int cursor = 16;
                    long nextVcn = startVcn;
                    for (int i = 0; i < count; i++)
                    {
                        nextVcn = BitConverter.ToInt64(reply, cursor);
                        long lcn = BitConverter.ToInt64(reply, cursor + 8);
                        cursor += 16;
                        long span = (nextVcn - startVcn) * (long)clusterSize;
                        long where = lcn < 0 ? -1 : lcn * (long)clusterSize;
                        runs.Add(new long[] { startVcn * (long)clusterSize, where, span });
                        startVcn = nextVcn;
                    }
                    vcn = nextVcn;
                }
            }
            finally { h.Dispose(); }
            return runs;
        }
    }
}
'@

if (-not ('DiskRescueIo.DriveProbe' -as [type])) {
    Add-Type -TypeDefinition $script:DiskRescueIo -Language CSharp
}

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

function Test-DiskRescueAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Format-DiskRescueBytes {
    param([int64]$Bytes)
    $abs = [Math]::Abs($Bytes)
    if ($abs -ge $script:GiB) { return ('{0:N2} GiB' -f ($Bytes / $script:GiB)) }
    if ($abs -ge $script:MiB) { return ('{0:N1} MiB' -f ($Bytes / $script:MiB)) }
    if ($abs -ge 1024) { return ('{0:N1} KiB' -f ($Bytes / 1024)) }
    return ('{0} B' -f $Bytes)
}

function Format-DiskRescueDuration {
    param([double]$Seconds)
    if ([double]::IsNaN($Seconds) -or [double]::IsInfinity($Seconds) -or $Seconds -lt 0) { return '--:--:--' }
    $ts = [TimeSpan]::FromSeconds([Math]::Ceiling($Seconds))
    if ($ts.TotalDays -ge 1) {
        $days = [int][Math]::Floor($ts.TotalDays)
        return ('{0}d {1:00}:{2:00}:{3:00}' -f $days, $ts.Hours, $ts.Minutes, $ts.Seconds)
    }
    return ('{0:00}:{1:00}:{2:00}' -f $ts.Hours, $ts.Minutes, $ts.Seconds)
}

function Get-DiskRescueDataDir {
    # Default folder for maps + copy reports. The GUI overrides
    # $script:DiskRescueDataDir with the app's root DiskRescue folder
    # (portable - travels with the app); direct lib use falls back to
    # Documents\DiskRescue.
    if (-not [string]::IsNullOrWhiteSpace($script:DiskRescueDataDir)) {
        return [string]$script:DiskRescueDataDir
    }
    $docs = [Environment]::GetFolderPath('MyDocuments')
    if ([string]::IsNullOrWhiteSpace($docs)) { $docs = $env:USERPROFILE }
    return (Join-Path $docs 'DiskRescue')
}

function Get-DiskRescueMapPath {
    param([int]$DiskNumber)
    return (Join-Path (Get-DiskRescueDataDir) ('disk{0}-map.json' -f $DiskNumber))
}

function Get-DiskRescueReportPath {
    param([int]$DiskNumber)
    return (Join-Path (Get-DiskRescueDataDir) ('disk{0}-copy-report.txt' -f $DiskNumber))
}

# ---------------------------------------------------------------------------
# Map persistence (JSON, atomic save)
# ---------------------------------------------------------------------------

function New-DiskRescueMap {
    param(
        [Parameter(Mandatory = $true)]$DiskObject,
        [Parameter(Mandatory = $true)][int]$BytesPerSector
    )
    $serial = ([string]$DiskObject.SerialNumber).Trim()
    $now = (Get-Date).ToUniversalTime().ToString('o')
    return [pscustomobject]@{
        Format         = 'sysdigger-diskrescue-1'
        DiskNumber     = [int]$DiskObject.Number
        Model          = [string]$DiskObject.FriendlyName
        Serial         = $serial
        DiskSizeBytes  = [int64]$DiskObject.Size
        BytesPerSector = [int]$BytesPerSector
        CreatedUtc     = $now
        UpdatedUtc     = $now
        Completed      = $false
        ProbeCount     = 0
        TimeoutMs      = 5000
        CancelWaitMs   = 2000
        ProbeMiB       = 1
        MinStepMiB     = 8
        BadRanges      = @()   # array of @{ s = int64; e = int64 } (exclusive end)
        GoodRanges     = @()
    }
}

function Save-DiskRescueMap {
    param(
        [Parameter(Mandatory = $true)]$Map,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $Map.UpdatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $tmp = "$Path.tmp"
    $json = $Map | ConvertTo-Json -Depth 6 -Compress
    [System.IO.File]::WriteAllText($tmp, $json, [System.Text.Encoding]::UTF8)
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Load-DiskRescueMap {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $json = [System.IO.File]::ReadAllText($Path)
        return ($json | ConvertFrom-Json)
    } catch {
        Write-Output ("[WARN] Map file could not be parsed: {0}" -f $_.Exception.Message)
        return $null
    }
}

function Test-DiskRescueMapMatchesDisk {
    param($Map, $DiskObject)
    if ($null -eq $Map) { return $false }
    $mapSize = [int64]$Map.DiskSizeBytes
    $curSize = [int64]$DiskObject.Size
    if ($mapSize -ne $curSize) { return $false }
    $mapSerial = ([string]$Map.Serial).Trim()
    $curSerial = ([string]$DiskObject.SerialNumber).Trim()
    if (-not [string]::IsNullOrWhiteSpace($mapSerial) -and
        -not [string]::IsNullOrWhiteSpace($curSerial)) {
        return ($mapSerial -eq $curSerial)
    }
    return $true
}

# ---------------------------------------------------------------------------
# Range helpers - sorted disjoint ranges with coalescing
# ---------------------------------------------------------------------------

function Add-DiskRescueRange {
    # Merge [s,e) into $Ranges (mutated IN PLACE - PowerShell unrolls
    # function-returned collections, so these helpers must never return one).
    # Coalesces with any overlapping or touching range.
    param(
        [System.Collections.Generic.List[object]]$Ranges,
        [Parameter(Mandatory = $true)][int64]$S,
        [Parameter(Mandatory = $true)][int64]$E
    )
    if ($null -eq $Ranges) { throw 'Add-DiskRescueRange: Ranges list is required.' }
    if ($E -le $S) { return }
    $lo = $S
    $hi = $E
    $keep = New-Object System.Collections.Generic.List[object]
    foreach ($r in $Ranges) {
        $rs = [int64]$r.s
        $re = [int64]$r.e
        if ($re -lt $lo -or $rs -gt $hi) {
            $keep.Add($r)
        } else {
            if ($rs -lt $lo) { $lo = $rs }
            if ($re -gt $hi) { $hi = $re }
        }
    }
    $keep.Add([pscustomobject]@{ s = $lo; e = $hi })
    $Ranges.Clear()
    foreach ($r in ($keep | Sort-Object { [int64]$_.s })) { $Ranges.Add($r) }
}

function Populate-DiskRescueRangeList {
    # Copy saved map ranges (null / single object / array / List) into an
    # existing List[object] - never returns a collection through the pipeline.
    param(
        $Ranges,
        [System.Collections.Generic.List[object]]$Target
    )
    if ($null -eq $Target) { throw 'Populate-DiskRescueRangeList: Target list is required.' }
    if ($null -eq $Ranges) { return }
    if ($Ranges -is [System.Collections.IEnumerable] -and $Ranges -isnot [pscustomobject] -and $Ranges -isnot [string]) {
        foreach ($r in $Ranges) { [void]$Target.Add($r) }
    } else {
        [void]$Target.Add($Ranges)
    }
}

function Test-DiskRescueOverlap {
    param($Ranges, [int64]$S, [int64]$E)
    if ($null -eq $Ranges) { return $false }
    foreach ($r in $Ranges) {
        $rs = [int64]$r.s
        $re = [int64]$r.e
        if ($rs -lt $E -and $re -gt $S) { return $true }
        if ($rs -ge $E) { break }   # sorted
    }
    return $false
}

function Get-DiskRescueRangeTotal {
    param($Ranges)
    [int64]$total = 0
    if ($null -ne $Ranges) {
        foreach ($r in $Ranges) { $total += ([int64]$r.e - [int64]$r.s) }
    }
    return $total
}

function Get-DiskRescueRangeCount { param($Ranges) if ($null -eq $Ranges) { 0 } elseif ($Ranges -is [System.Collections.ICollection]) { $Ranges.Count } else { 1 } }

# ---------------------------------------------------------------------------
# LIST - disk inventory
# ---------------------------------------------------------------------------

function Show-DiskRescueDisks {
    $rows = foreach ($d in (Get-Disk | Sort-Object Number)) {
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
            Disk    = [int]$d.Number
            Letters = $letters
            Model   = ([string]$d.FriendlyName).Trim()
            Size    = (Format-DiskRescueBytes ([int64]$d.Size))
            Media   = $media
            Bus     = [string]$d.BusType
            Serial  = ([string]$d.SerialNumber).Trim()
            Boot    = [bool]$d.IsBoot
            System  = [bool]$d.IsSystem
            Offline = [bool]$d.IsOffline
        }
    }
    Write-Output 'Physical disks on this computer:'
    Write-Output ''
    $rows | Format-Table Disk, Letters, Model, Size, Media, Bus, Serial, Boot, System, Offline -AutoSize |
        Out-String -Width 4096 | Write-Output
    Write-Output 'Workflow for a failing disk:'
    Write-Output "  1. Note the disk number of the FAILING disk (the one losing data)."
    Write-Output "  2. 'Scan Disk (Build Map)' - read-only, builds a GOOD/BAD map (resumes if interrupted)."
    Write-Output "  3. 'Show Map Report' - see where the damage is concentrated."
    Write-Output "  4. 'Copy Files (Bad-Aware)' - copy readable files to a DIFFERENT healthy disk."
    Write-Output "  5. 'Show Lost Files' - list anything that did not fully recover."
    Write-Output ''
    Write-Output 'IMPORTANT: never copy data back onto the failing disk, and stop using it'
    Write-Output 'for anything else until the recovery is finished - every hour of use'
    Write-Output 'can make the damage worse.'
}

# ---------------------------------------------------------------------------
# Raw probing with recovery gate
# ---------------------------------------------------------------------------

function Invoke-DiskRescueProbe {
    param(
        [Parameter(Mandatory = $true)]$Session,
        [Parameter(Mandatory = $true)][int64]$Offset,
        [Parameter(Mandatory = $true)][int]$Length,
        [Parameter(Mandatory = $true)][int]$TimeoutMs,
        [Parameter(Mandatory = $true)][int]$CancelWaitMs
    )
    return $Session.ReadAt($Offset, $Length, $TimeoutMs, $CancelWaitMs)
}

function Wait-DiskRescueDriveReady {
    # After a timeout the drive may stay busy internally. Do not classify any
    # further location until a known-good anchor answers again. A negative
    # AnchorOffset means "no anchor yet" and skips the gate.
    param(
        [Parameter(Mandatory = $true)]$Session,
        [Parameter(Mandatory = $true)][int64]$AnchorOffset,
        [Parameter(Mandatory = $true)][int]$TimeoutMs,
        [Parameter(Mandatory = $true)][int]$CancelWaitMs
    )
    if ($AnchorOffset -lt 0) { return $true }
    $attempt = 0
    while ($true) {
        $res = $Session.ReadAt($AnchorOffset, 512, $TimeoutMs, $CancelWaitMs)
        if ($res.Status -eq 'Good') { return $true }
        $attempt++
        Write-Output ("[WAIT] Drive unresponsive (attempt {0}) - waiting for known-good anchor to answer..." -f $attempt)
        Start-Sleep -Seconds (3 + [Math]::Min(12, $attempt * 2))
        if ($attempt -ge 60) {
            Write-Output '[WAIT] Giving up after 60 attempts - aborting scan so the map is not corrupted with false BAD ranges.'
            return $false
        }
    }
}

# ---------------------------------------------------------------------------
# Probe worker (process isolation for driver-level stalls)
# ---------------------------------------------------------------------------
#
# A USB mass-storage bridge stalled on a damaged sector can ignore CancelIoEx:
# the kernel call itself never returns and no in-process watchdog can recover
# (observed on a Toshiba USB 3.0 bridge - killing the process is the only way
# to release the I/O). All timed reads therefore run in a child "worker"
# process that owns the raw/file handles. The parent writes one command per
# read and waits on the response with a hard watchdog; when the worker stalls,
# taskkill /F releases the wedge, a fresh worker is spawned with the same
# handle set, and the read is reported as Timeout so the usual BAD / zero-fill
# logic proceeds. Protocol (one line each way, UTF-8):
#   PING                          -> PONG
#   OPENDISK <n> [id]             -> OK <id>
#   OPENFILE <path...> [id]       -> OK <id>
#   READ <id> <off> <len> <tMs> <cwMs> <wantData> -> OK <id> <status> <bytes> <err> <ms> <b64?>
#   CLOSE <id>                    -> OK <id>
#   SLEEP <ms>                    -> OK SLEEP <ms>     (diagnostic wedge trigger)
#   QUIT                          -> BYE

function New-DiskRescueWorkerState {
    return @{ Handles = @{}; NextId = 1 }
}

function Invoke-DiskRescueWorkerCommand {
    # Execute one protocol line against the worker state. Returns the plain
    # response line. Kept free of console I/O so it is testable in-process.
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)]$State
    )
    $trimmed = $Command.Trim()
    if ($trimmed -eq '') { return 'ERR empty command' }
    if ($trimmed -eq 'PING') { return 'PONG' }
    if ($trimmed -eq 'QUIT') { return 'BYE' }
    $tokens = $trimmed -split ' '
    $cmd = $tokens[0].ToUpperInvariant()
    try {
        switch ($cmd) {
            'OPENDISK' {
                if ($tokens.Count -lt 2) { return 'ERR OPENDISK needs a disk number' }
                $id = -1
                if ($tokens.Count -ge 3 -and $tokens[2] -match '^\d+$') { $id = [int]$tokens[2] }
                else { $id = $State.NextId; $State.NextId = $State.NextId + 1 }
                $ses = New-Object DiskRescueIo.DriveProbe([int]$tokens[1])
                $State.Handles[$id] = @{ Kind = 'Disk'; Obj = $ses }
                return ('OK {0}' -f $id)
            }
            'OPENFILE' {
                if ($tokens.Count -lt 2) { return 'ERR OPENFILE needs a path' }
                $id = -1
                $pathEnd = $tokens.Count
                if ($tokens.Count -ge 3 -and $tokens[$tokens.Count - 1] -match '^\d+$') {
                    $id = [int]$tokens[$tokens.Count - 1]
                    $pathEnd--
                } else {
                    $id = $State.NextId; $State.NextId = $State.NextId + 1
                }
                $path = ($tokens[1..($pathEnd - 1)] -join ' ')
                $reader = New-Object DiskRescueIo.FileChunkReader($path)
                $State.Handles[$id] = @{ Kind = 'File'; Obj = $reader }
                return ('OK {0}' -f $id)
            }
            'READ' {
                if ($tokens.Count -lt 7) { return 'ERR READ needs: id offset len timeoutMs cancelWaitMs wantData' }
                $id = [int]$tokens[1]
                if (-not $State.Handles.ContainsKey($id)) { return ('ERR unknown handle {0}' -f $id) }
                $h = $State.Handles[$id]
                $offset = [int64]$tokens[2]
                $len = [int]$tokens[3]
                $tMs = [int]$tokens[4]
                $cwMs = [int]$tokens[5]
                $wantData = [int]$tokens[6]
                $res = $h.Obj.ReadAt($offset, $len, $tMs, $cwMs)
                $b64 = ''
                if ($wantData -eq 1 -and $res.Status -eq 'Good' -and $res.BytesRead -gt 0 -and $null -ne $res.Data) {
                    $b64 = [Convert]::ToBase64String($res.Data)
                }
                # Message goes last (may contain spaces); b64 is a single token.
                return ('OK {0} {1} {2} {3} {4} {5} {6}' -f $id, $res.Status, $res.BytesRead, $res.Win32Error, $res.DurationMs, $b64, $res.Message)
            }
            'CLOSE' {
                if ($tokens.Count -lt 2) { return 'ERR CLOSE needs a handle id' }
                $id = [int]$tokens[1]
                if (-not $State.Handles.ContainsKey($id)) { return ('ERR unknown handle {0}' -f $id) }
                try { $State.Handles[$id].Obj.Dispose() } catch { }
                $State.Handles.Remove($id)
                return ('OK {0}' -f $id)
            }
            'SLEEP' {
                if ($tokens.Count -lt 2) { return 'ERR SLEEP needs milliseconds' }
                $ms = [int64]$tokens[1]
                if ($ms -gt 300000) { $ms = 300000 }
                Start-Sleep -Milliseconds $ms
                return ('OK SLEEP {0}' -f $ms)
            }
            default { return ('ERR unknown command: {0}' -f $cmd) }
        }
    } catch {
        return ('ERR ' + $_.Exception.Message)
    }
}

function Enter-DiskRescueWorkerLoop {
    # Worker-mode entry point: reads protocol lines from stdin until QUIT/EOF.
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
    $stdin = New-Object System.IO.StreamReader(
        [Console]::OpenStandardInput(), (New-Object System.Text.UTF8Encoding($false)))
    $state = New-DiskRescueWorkerState
    try {
        while ($true) {
            $line = $stdin.ReadLine()
            if ($null -eq $line) { break }
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $resp = Invoke-DiskRescueWorkerCommand -Command $line -State $state
            [Console]::Out.WriteLine($resp)
            [Console]::Out.Flush()
            if ($resp -eq 'BYE') { break }
        }
    } catch {
        try {
            [Console]::Out.WriteLine(('ERR worker fatal: ' + $_.Exception.Message))
            [Console]::Out.Flush()
        } catch { }
    } finally {
        foreach ($h in $state.Handles.Values) {
            try { $h.Obj.Dispose() } catch { }
        }
    }
}

class DiskRescueWorkerSession : IDisposable {
    # Parent-side handle to the worker child process. Exposes ReadAt with the
    # same shape as the native ReadReport so scan/copy call sites
    # stay unchanged, plus a hard per-command watchdog that kills and respawns
    # a stalled worker.
    hidden [string]$_enginePath
    hidden [System.Diagnostics.Process]$_proc
    hidden [System.IO.StreamWriter]$_stdin
    hidden [System.IO.StreamReader]$_stdout
    hidden [System.Threading.Tasks.Task]$_stderrTask
    hidden [object]$_onWedge
    hidden [hashtable]$_handles = @{}
    hidden [int]$_nextHandleId = 1
    hidden [int]$_diskId = -1
    hidden [int]$_graceMs = 15000
    hidden [int]$_consecutiveWedges = 0
    hidden [bool]$_disposed = $false

    DiskRescueWorkerSession([string]$enginePath) { $this.Init($enginePath, $null, 15000) }
    DiskRescueWorkerSession([string]$enginePath, [object]$onWedge) { $this.Init($enginePath, $onWedge, 15000) }
    DiskRescueWorkerSession([string]$enginePath, [object]$onWedge, [int]$graceMs) { $this.Init($enginePath, $onWedge, $graceMs) }

    hidden [void] Init([string]$enginePath, [object]$onWedge, [int]$graceMs) {
        $this._enginePath = $enginePath
        $this._onWedge = $onWedge
        $this._graceMs = $graceMs
        $this.Spawn()
    }

    hidden [void] Spawn() {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.Arguments = ('-NoProfile -ExecutionPolicy Bypass -Command ". ''{0}''; Enter-DiskRescueWorkerLoop"' -f $this._enginePath)
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $proc = [System.Diagnostics.Process]::Start($psi)
        $this._proc = $proc
        $this._stdin = New-Object System.IO.StreamWriter(
            $proc.StandardInput.BaseStream, (New-Object System.Text.UTF8Encoding($false)))
        $this._stdin.AutoFlush = $true
        $this._stdout = $proc.StandardOutput
        $this._stderrTask = $proc.StandardError.ReadToEndAsync()
        # Handshake: the worker pays powershell startup + Add-Type compile.
        $ping = $this.Transport('PING', 60000)
        if ($ping.Status -ne 'Good' -or $ping.Response -ne 'PONG') {
            $this.KillWorker()
            throw ('Probe worker did not start: ' + $ping.Message)
        }
    }

    hidden [object] Transport([string]$line, [int]$watchdogMs) {
        # One command line -> one response line, or Timeout when the worker
        # stalls past the watchdog. No retries here; callers decide.
        if ($null -eq $this._stdin -or $null -eq $this._stdout) {
            return @{ Status = 'Timeout'; Response = ''; Message = 'worker not running' }
        }
        try { $this._stdin.WriteLine($line) } catch {
            return @{ Status = 'Timeout'; Response = ''; Message = 'worker stdin broken' }
        }
        $task = $this._stdout.ReadLineAsync()
        if (-not $task.Wait($watchdogMs)) {
            return @{ Status = 'Timeout'; Response = ''; Message = ('no response within {0} ms' -f $watchdogMs) }
        }
        $resp = $task.Result
        if ($null -eq $resp) {
            return @{ Status = 'Timeout'; Response = ''; Message = 'worker process exited unexpectedly' }
        }
        return @{ Status = 'Good'; Response = $resp; Message = '' }
    }

    hidden [void] KillWorker() {
        $proc = $this._proc
        $this._proc = $null
        if ($null -ne $this._stdin) { try { $this._stdin.Dispose() } catch { } }
        $this._stdin = $null
        if ($null -ne $proc -and -not $proc.HasExited) {
            try { & taskkill /T /F /PID $proc.Id 2>$null | Out-Null } catch { }
            try { if (-not $proc.WaitForExit(3000)) { $proc.Kill() } } catch { }
        }
        if ($null -ne $this._stdout) { try { $this._stdout.Dispose() } catch { } }
        $this._stdout = $null
        if ($null -ne $proc) { try { $proc.Dispose() } catch { } }
    }

    hidden [void] ReopenHandles() {
        foreach ($key in @($this._handles.Keys)) {
            $h = $this._handles[$key]
            if ($h.Kind -eq 'Disk') {
                $r = $this.Transport(('OPENDISK {0} {1}' -f $h.Target, $key), 20000)
            } else {
                $r = $this.Transport(('OPENFILE {0} {1}' -f $h.Target, $key), 20000)
            }
            if ($r.Status -ne 'Good' -or $r.Response -notmatch ('^OK {0}\b' -f $key)) {
                # The disk may still be hard-stalled - drop the handle; the
                # next read reports an error and the caller's recovery logic
                # (ready-wait gate, abort) takes over.
                $this._handles.Remove($key)
                if ($key -eq $this._diskId) { $this._diskId = -1 }
            }
        }
    }

    [int] GetWorkerPid() {
        if ($null -ne $this._proc) { return $this._proc.Id }
        return -1
    }

    [object] SendCommand([string]$line, [int]$watchdogMs) {
        # Returns @{ Status='Good'|'Timeout'; Response; Message }. Status is
        # transport-level: 'Timeout' means the worker was killed and respawned.
        $r = $this.Transport($line, $watchdogMs)
        if ($r.Status -eq 'Good') {
            $this._consecutiveWedges = 0
            return $r
        }
        $this._consecutiveWedges = $this._consecutiveWedges + 1
        $msg = ('[WEDGE] Read worker stalled past the {0} ms watchdog - killed and respawned.' -f $watchdogMs)
        if ($null -ne $this._onWedge) {
            try { $this._onWedge.Invoke($msg) } catch { }
        }
        $this.KillWorker()
        $this.Spawn()
        $this.ReopenHandles()
        if ($this._consecutiveWedges -ge 20) {
            throw ('Probe worker wedged {0} times in a row - giving up.' -f $this._consecutiveWedges)
        }
        return @{ Status = 'Timeout'; Response = ''; Message = $msg }
    }

    [void] OpenDisk([int]$diskNumber) {
        $id = $this._nextHandleId
        $r = $this.SendCommand(('OPENDISK {0} {1}' -f $diskNumber, $id), $this._graceMs + 20000)
        if ($r.Status -ne 'Good' -or $r.Response -notmatch ('^OK {0}\b' -f $id)) {
            throw ('Cannot open disk {0} in the probe worker: {1}' -f $diskNumber, $r.Response)
        }
        $this._handles[$id] = @{ Kind = 'Disk'; Target = $diskNumber }
        $this._diskId = $id
        $this._nextHandleId = $this._nextHandleId + 1
    }

    [object] OpenFile([string]$path) {
        $id = $this._nextHandleId
        $r = $this.SendCommand(('OPENFILE {0} {1}' -f $path, $id), $this._graceMs + 20000)
        if ($r.Status -ne 'Good' -or $r.Response -notmatch ('^OK {0}\b' -f $id)) {
            throw ('Cannot open file in the probe worker: ' + $r.Response)
        }
        $this._handles[$id] = @{ Kind = 'File'; Target = $path }
        $this._nextHandleId = $this._nextHandleId + 1
        return [DiskRescueWorkerFileReader]::new($this, $id)
    }

    [void] CloseHandle([int]$id) {
        if (-not $this._handles.ContainsKey($id)) { return }
        $this._handles.Remove($id)
        if ($id -eq $this._diskId) { $this._diskId = -1 }
        try { $this.Transport(('CLOSE {0}' -f $id), 5000) | Out-Null } catch { }
    }

    [object] ReadAt([long]$offset, [int]$length, [int]$timeoutMs, [int]$cancelWaitMs) {
        return $this.ReadHandleAt($this._diskId, $offset, $length, $timeoutMs, $cancelWaitMs, 0)
    }

    [object] ReadAt([long]$offset, [int]$length, [int]$timeoutMs, [int]$cancelWaitMs, [int]$wantData) {
        return $this.ReadHandleAt($this._diskId, $offset, $length, $timeoutMs, $cancelWaitMs, $wantData)
    }

    [object] ReadHandleAt([int]$handleId, [long]$offset, [int]$length, [int]$timeoutMs, [int]$cancelWaitMs, [int]$wantData) {
        if ($handleId -lt 0) {
            return @{ Status = 'Error'; BytesRead = 0; Win32Error = 0; DurationMs = 0;
                      Message = 'no handle open in worker'; Data = $null }
        }
        $wd = $timeoutMs + $cancelWaitMs + $this._graceMs
        $r = $this.SendCommand(('READ {0} {1} {2} {3} {4} {5}' -f $handleId, $offset, $length, $timeoutMs, $cancelWaitMs, $wantData), $wd)
        if ($r.Status -eq 'Timeout') {
            return @{ Status = 'Timeout'; BytesRead = 0; Win32Error = 1460; DurationMs = $wd;
                      Message = $r.Message; Data = $null }
        }
        $parts = $r.Response -split ' '
        if ($parts.Count -lt 6 -or $parts[0] -ne 'OK') {
            return @{ Status = 'Error'; BytesRead = 0; Win32Error = 0; DurationMs = 0;
                      Message = ('worker protocol error: {0}' -f $r.Response); Data = $null }
        }
        $data = $null
        if ($wantData -eq 1 -and $parts.Count -ge 7 -and $parts[6]) {
            $data = [Convert]::FromBase64String($parts[6])
        }
        # Optional trailing message (multi-word, may be empty).
        $msg = ''
        if ($parts.Count -ge 8) { $msg = ($parts[7..($parts.Count - 1)] -join ' ') }
        return @{ Status = [string]$parts[2]; BytesRead = [int]$parts[3]; Win32Error = [int]$parts[4];
                  DurationMs = [int64]$parts[5]; Message = $msg; Data = $data }
    }

    [void] Dispose() {
        if ($this._disposed) { return }
        $this._disposed = $true
        $proc = $this._proc
        if ($null -ne $this._stdin) {
            try { $this._stdin.WriteLine('QUIT') } catch { }
        }
        if ($null -ne $proc -and -not $proc.HasExited) {
            try { if (-not $proc.WaitForExit(2000)) { & taskkill /T /F /PID $proc.Id 2>$null | Out-Null } } catch { }
        }
        if ($null -ne $this._stdin) { try { $this._stdin.Dispose() } catch { } }
        if ($null -ne $this._stdout) { try { $this._stdout.Dispose() } catch { } }
        if ($null -ne $proc) { try { $proc.Dispose() } catch { } }
        $this._proc = $null
    }
}

class DiskRescueWorkerFileReader : IDisposable {
    # Per-file reader bound to a worker handle. ReadAt mirrors the native
    # ReadReport shape; Dispose closes the worker-side file handle.
    hidden [DiskRescueWorkerSession]$_ses
    hidden [int]$_id

    DiskRescueWorkerFileReader([DiskRescueWorkerSession]$ses, [int]$id) {
        $this._ses = $ses
        $this._id = $id
    }

    [object] ReadAt([long]$offset, [int]$length, [int]$timeoutMs, [int]$cancelWaitMs) {
        return $this._ses.ReadHandleAt($this._id, $offset, $length, $timeoutMs, $cancelWaitMs, 1)
    }

    [void] Dispose() {
        $this._ses.CloseHandle($this._id)
    }
}

function New-DiskRescueWorkerSession {
    param(
        [string]$EnginePath = $PSCommandPath,
        [object]$OnWedge = $null,
        [int]$GraceMs = 15000
    )
    return [DiskRescueWorkerSession]::new($EnginePath, $OnWedge, $GraceMs)
}

# ---------------------------------------------------------------------------
# SCAN - hierarchical GOOD-first mapper (read-only)
# ---------------------------------------------------------------------------

function Invoke-DiskRescueScan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$Disk,
        [Parameter(Mandatory = $true)][string]$Map,
        [switch]$Restart,
        [int]$TimeoutMs = 5000,
        [int]$CancelWaitMs = 2000,
        [ValidateRange(1, 64)][int]$ProbeMiB = 1,
        [ValidateRange(1, 1024)][int]$MinStepMiB = 8,
        [int64]$MinStepBytes = 0,
        [int]$ProbeLimit = 0
    )
    if ($MinStepBytes -le 0) { $MinStepBytes = [int64]$MinStepMiB * $script:MiB }
    if (-not (Test-DiskRescueAdmin)) {
        throw 'Administrator privileges are required for raw disk access.'
    }
    try {
        $diskObj = Get-Disk -Number $Disk -ErrorAction Stop
    } catch {
        throw ("Disk {0} was not found. Run the 'List Disks' mode to see valid disk numbers." -f $Disk)
    }

    # The map must not live on the disk being scanned.
    $mapFull = [System.IO.Path]::GetFullPath($Map)
    $mapOnSource = $false
    try {
        $mapLetter = [System.IO.Path]::GetPathRoot($mapFull).TrimEnd('\').TrimEnd(':')
        if ($mapLetter.Length -eq 1) {
            try {
                $mapDisk = [int](Get-Partition -DriveLetter $mapLetter -ErrorAction Stop).DiskNumber
                if ($mapDisk -eq $Disk) { $mapOnSource = $true }
            } catch { }
        }
    } catch { }
    if ($mapOnSource) {
        throw ("The map file would live on disk {0} (the disk being scanned). Choose a location on a different physical disk, e.g. -Map 'D:\somewhere\map.json'." -f $Disk)
    }

    Write-Output '============================================================'
    Write-Output (' Disk Rescue - SCAN disk {0} ({1})' -f $Disk, ([string]$diskObj.FriendlyName).Trim())
    Write-Output (' Size: {0}  |  Map: {1}' -f (Format-DiskRescueBytes ([int64]$diskObj.Size)), $mapFull)
    Write-Output ' The scan is strictly read-only. Progress streams below.'
    Write-Output '============================================================'
    Write-Output ''

    $mapData = $null
    if (-not $Restart) {
        $existing = Load-DiskRescueMap -Path $mapFull
        if ($null -ne $existing -and (Test-DiskRescueMapMatchesDisk -Map $existing -DiskObject $diskObj)) {
            $mapData = $existing
            Write-Output '[RESUME] Existing map for this disk found - continuing where it stopped.'
        } elseif ($null -ne $existing) {
            Write-Output '[WARN] Existing map belongs to a different disk - starting a fresh map.'
        }
    }
    if ($null -eq $mapData) {
        $session0 = New-Object DiskRescueIo.DriveProbe($Disk)
        try { $geom = $session0.GetGeometry() } finally { $session0.Dispose() }
        $mapData = New-DiskRescueMap -DiskObject $diskObj -BytesPerSector $geom.SectorSize
        $mapData.TimeoutMs = $TimeoutMs
        $mapData.CancelWaitMs = $CancelWaitMs
    }
    $mapData.ProbeMiB = $ProbeMiB
    $mapData.MinStepMiB = $MinStepMiB
    $bps = [int]$mapData.BytesPerSector
    $diskSize = [int64]$mapData.DiskSizeBytes
    $badRanges = New-Object System.Collections.Generic.List[object]
    $goodRanges = New-Object System.Collections.Generic.List[object]
    Populate-DiskRescueRangeList -Ranges $mapData.BadRanges -Target $badRanges
    Populate-DiskRescueRangeList -Ranges $mapData.GoodRanges -Target $goodRanges

    # Coarse step: aim for ~512 first-pass probes, clamped. Aligned down to
    # the sector size - NO_BUFFERING reads require sector-aligned offsets,
    # and every later level derives from halving this step.
    [int64]$coarse = [int64]($diskSize / 512)
    if ($coarse -lt 64 * $script:MiB) { $coarse = 64 * $script:MiB }
    if ($coarse -gt 1 * $script:GiB) { $coarse = 1 * $script:GiB }
    $coarse = [int64]([Math]::Floor($coarse / $bps) * $bps)
    if ($coarse -lt $bps) { $coarse = $bps }
    if ($MinStepBytes -lt $bps) { $MinStepBytes = $bps }
    $MinStepBytes = [int64]([Math]::Floor($MinStepBytes / $bps) * $bps)
    if ($MinStepBytes -lt $bps) { $MinStepBytes = $bps }
    $probeLen = [int64]$ProbeMiB * $script:MiB   # per-probe sample read (sector-aligned: MiB multiples)

    [double]$samplePct = 100.0 * $probeLen / [Math]::Max(1, $coarse)
    Write-Output ('Probe plan: coarse step {0}, refine floor {1} MiB, sample {2} MiB ({3:N2}% first-pass coverage), timeout {4} ms.' -f `
        (Format-DiskRescueBytes $coarse), $MinStepMiB, $ProbeMiB, $samplePct, $TimeoutMs)
    Write-Output ''

    $session = $null
    try {
        $session = New-DiskRescueWorkerSession -EnginePath $PSCommandPath -OnWedge { param($m) Write-Output $m }
        $session.OpenDisk($Disk)
    } catch {
        Write-Output ('[ERROR] Probe worker could not open disk {0}: {1}' -f $Disk, $_.Exception.Message)
        throw
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $probesDone = 0
    $probesGood = 0
    $probesBad = 0
    $sinceSave = 0
    $lastPulse = $sw.Elapsed.TotalSeconds
    $anchor = [int64]-1
    $abort = $false
    $maxProbes = if ($ProbeLimit -gt 0) { $ProbeLimit } else { [int]::MaxValue }

    function Save-Checkpoint {
        # Assign the List directly: wrapping in @() breaks property assignment
        # on pwsh 7.6 ("Argument types do not match"); both serialize the same.
        $mapData.BadRanges = $badRanges
        $mapData.GoodRanges = $goodRanges
        $mapData.ProbeCount = $probesDone
        Save-DiskRescueMap -Map $mapData -Path $mapFull
    }

    function Invoke-DiskRescueProbeVerified {
        # Probe with one verification retry: a single timeout on an otherwise
        # responsive drive (e.g. a cold cache hiccup) must not mark a region
        # BAD. Waits for the known-good anchor between attempts. The read is
        # clamped to the disk end - probing the last <1 MiB with a full-size
        # read would fail with error 87 and never mean damage.
        param(
            [int64]$Offset,
            [int64]$Anchor
        )
        [int64]$len = [Math]::Min([int64]$probeLen, $diskSize - $Offset)
        if ($len -lt $bps) { $len = $bps }
        $r = $session.ReadAt($Offset, [int]$len, $TimeoutMs, $CancelWaitMs)
        if ($r.Status -eq 'Good') { return $r }
        if (-not (Wait-DiskRescueDriveReady -Session $session -AnchorOffset $Anchor -TimeoutMs $TimeoutMs -CancelWaitMs $CancelWaitMs)) {
            return $r
        }
        return $session.ReadAt($Offset, [int]$len, $TimeoutMs, $CancelWaitMs)
    }

    try {
        # Level-by-level hierarchical scan. Each level halves the step; probes
        # are only issued for locations that are still unknown (i.e. not
        # inside a classified range and not yet probed at a finer level).
        [int64]$step = $coarse
        $depth = 0
        $maxDepth = 0
        while ($step -ge $MinStepBytes) { $maxDepth++; $step = [int64]($step / 2) }
        $step = $coarse

        while ($step -ge $MinStepBytes -and -not $abort) {
            $depth++
            # Re-align the step to the sector size: halving an aligned step
            # can produce a non-multiple of the sector size (e.g. 512 x odd),
            # and NO_BUFFERING reads reject misaligned offsets with error 87
            # ("The parameter is incorrect") - which must never be mistaken
            # for a BAD region.
            $step = [int64]([Math]::Floor($step / $bps) * $bps)
            if ($step -lt $bps) { $step = $bps }
            $offsets = New-Object System.Collections.Generic.List[int64]
            for ([int64]$o = 0; $o -lt $diskSize; $o += $step) {
                if (Test-DiskRescueOverlap -Ranges $badRanges -S $o -E ($o + $step)) { continue }
                if (Test-DiskRescueOverlap -Ranges $goodRanges -S $o -E ($o + $probeLen)) { continue }
                [void]$offsets.Add($o)
            }
            $total = $offsets.Count
            Write-Output ('--- Depth {0}/{1}: step {2} - {3} location(s) to probe ---' -f `
                $depth, $maxDepth, (Format-DiskRescueBytes $step), $total)
            if ($total -eq 0) {
                $step = [int64]($step / 2)
                continue
            }
            $idx = 0
            $i = 0
            while ($i -lt $offsets.Count) {
                $o = [int64]$offsets[$i]
                if ($probesDone -ge $maxProbes) { $abort = $true; break }
                $res = Invoke-DiskRescueProbeVerified -Offset $o -Anchor $anchor
                $probesDone++
                $sinceSave++

                if ($res.Status -eq 'Good') {
                    $probesGood++
                    Add-DiskRescueRange -Ranges $goodRanges -S $o -E ([Math]::Min($diskSize, $o + $probeLen))
                    $anchor = [int64]$o
                } else {
                    $probesBad++
                    Write-Output ("[BAD ] {0} - {1}" -f (Format-DiskRescueBytes $o), $res.Message)
                    # Mark the probe span bad, then jump forward to find the edge
                    # of the damaged region using exponential steps.
                    Add-DiskRescueRange -Ranges $badRanges -S $o -E ([Math]::Min($diskSize, $o + $probeLen))
                    if (-not (Wait-DiskRescueDriveReady -Session $session -AnchorOffset $anchor -TimeoutMs $TimeoutMs -CancelWaitMs $CancelWaitMs)) {
                        $abort = $true
                        break
                    }
                    [int64]$jump = 64 * $script:MiB
                    [int64]$edge = -1
                    while ($true) {
                        $t = $o + $jump
                        $t = [int64]([Math]::Floor($t / $bps) * $bps)
                        if ($t -ge $diskSize) { $edge = $diskSize; break }
                        $res2 = Invoke-DiskRescueProbeVerified -Offset $t -Anchor $anchor
                        $probesDone++
                        if ($res2.Status -eq 'Good') {
                            $edge = $t
                            Add-DiskRescueRange -Ranges $goodRanges -S $t -E ([Math]::Min($diskSize, $t + $probeLen))
                            $anchor = [int64]$t
                            break
                        }
                        Add-DiskRescueRange -Ranges $badRanges -S $t -E ([Math]::Min($diskSize, $t + $probeLen))
                        Write-Output ("[BAD ] {0} (edge search) - {1}" -f (Format-DiskRescueBytes $t), $res2.Message)
                        if (-not (Wait-DiskRescueDriveReady -Session $session -AnchorOffset $anchor -TimeoutMs $TimeoutMs -CancelWaitMs $CancelWaitMs)) {
                            $abort = $true
                            break
                        }
                        $jump = $jump * 2
                    }
                    if ($abort) { break }
                    # Refine the boundary between the last BAD probe and the
                    # GOOD edge by bisection down to MinStepBytes.
                    [int64]$badEdge = [Math]::Min($diskSize, $o + $probeLen)
                    [int64]$goodEdge = $edge
                    while (($goodEdge - $badEdge) -gt $MinStepBytes) {
                        [int64]$mid = $badEdge + [int64](($goodEdge - $badEdge) / 2)
                        $mid = [int64]([Math]::Floor($mid / $bps) * $bps)
                        $resm = Invoke-DiskRescueProbeVerified -Offset $mid -Anchor $anchor
                        $probesDone++
                        if ($resm.Status -eq 'Good') {
                            $goodEdge = $mid
                            Add-DiskRescueRange -Ranges $goodRanges -S $mid -E ([Math]::Min($diskSize, $mid + $probeLen))
                            $anchor = [int64]$mid
                        } else {
                            $badEdge = [Math]::Min($diskSize, $mid + $probeLen)
                            Add-DiskRescueRange -Ranges $badRanges -S $mid -E ($mid + $probeLen)
                            Write-Output ("[BAD ] {0} (refine) - {1}" -f (Format-DiskRescueBytes $mid), $resm.Message)
                            if (-not (Wait-DiskRescueDriveReady -Session $session -AnchorOffset $anchor -TimeoutMs $TimeoutMs -CancelWaitMs $CancelWaitMs)) {
                                $abort = $true
                                break
                            }
                        }
                    }
                    if ($abort) { break }
                    # Skip the probe list ahead of the found edge.
                    while ($i -lt $offsets.Count -and [int64]$offsets[$i] -lt $goodEdge) { $i++ }
                    continue
                }

                $i++
                $idx++
                [double]$now = $sw.Elapsed.TotalSeconds
                if (($now - $lastPulse) -ge 2.0) {
                    $lastPulse = $now
                    $rate = $idx / [Math]::Max(0.001, $now)
                    $remaining = [Math]::Max(0, $total - $idx)
                    Write-Output ('  depth {0}: {1}/{2} probed | GOOD {3} BAD {4} | elapsed {5} | ETA {6}' -f `
                        $depth, $idx, $total, $probesGood, $probesBad,
                        (Format-DiskRescueDuration $now), (Format-DiskRescueDuration ($remaining / [Math]::Max(0.001, $rate))))
                }
                if ($sinceSave -ge 50) { $sinceSave = 0; Save-Checkpoint }
            }
            Save-Checkpoint
            $step = [int64]($step / 2)
        }

        $mapData.BadRanges = $badRanges
        $mapData.GoodRanges = $goodRanges
        $mapData.ProbeCount = $probesDone
        $mapData.Completed = -not $abort
        Save-DiskRescueMap -Map $mapData -Path $mapFull
    } finally {
        if ($null -ne $session) { try { $session.Dispose() } catch { } }
        $sw.Stop()
    }

    Write-Output ''
    if ($abort) {
        Write-Output '[STOPPED] Scan stopped early - the map has been saved and a later run will resume.'
    } else {
        Write-Output '[SUCCESS] Scan completed - map saved.'
    }
    Write-Output ('Probes: {0} (GOOD {1}, BAD {2}) in {3}.' -f `
        $probesDone, $probesGood, $probesBad, (Format-DiskRescueDuration $sw.Elapsed.TotalSeconds))
    Write-Output ('Mapped so far: BAD {0} in {1} range(s) | GOOD {2} in {3} range(s).' -f `
        (Format-DiskRescueBytes (Get-DiskRescueRangeTotal $badRanges)), (Get-DiskRescueRangeCount $badRanges),
        (Format-DiskRescueBytes (Get-DiskRescueRangeTotal $goodRanges)), (Get-DiskRescueRangeCount $goodRanges))
    Write-Output ("Next step: run 'Show Map Report' to inspect the map, then 'Copy Files (Bad-Aware)'.")
}

# ---------------------------------------------------------------------------
# REPORT - human-readable map summary
# ---------------------------------------------------------------------------

function Show-DiskRescueReport {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Map)
    $mapData = Load-DiskRescueMap -Path $Map
    if ($null -eq $mapData) {
        throw ("No usable map at '{0}'. Run 'Scan Disk (Build Map)' first." -f $Map)
    }
    $diskSize = [int64]$mapData.DiskSizeBytes
    $badRanges = New-Object System.Collections.Generic.List[object]
    $goodRanges = New-Object System.Collections.Generic.List[object]
    Populate-DiskRescueRangeList -Ranges $mapData.BadRanges -Target $badRanges
    Populate-DiskRescueRangeList -Ranges $mapData.GoodRanges -Target $goodRanges
    $badTotal = Get-DiskRescueRangeTotal $badRanges
    $goodTotal = Get-DiskRescueRangeTotal $goodRanges
    Write-Output '============================================================'
    Write-Output (' Disk Rescue - MAP REPORT: {0}' -f $Map)
    Write-Output '============================================================'
    Write-Output ('Disk      : #{0} {1} (S/N {2})' -f $mapData.DiskNumber, ([string]$mapData.Model).Trim(), ([string]$mapData.Serial).Trim())
    Write-Output ('Size      : {0}' -f (Format-DiskRescueBytes $diskSize))
    $upd = if ($mapData.UpdatedUtc -is [datetime]) { $mapData.UpdatedUtc.ToString('yyyy-MM-dd HH:mm:ss') } else { [string]$mapData.UpdatedUtc }
    Write-Output ('Updated   : {0}  |  Completed: {1}  |  Probes: {2}' -f $upd, $mapData.Completed, $mapData.ProbeCount)
    Write-Output ('BAD       : {0} in {1} range(s)' -f (Format-DiskRescueBytes $badTotal), $badRanges.Count)
    Write-Output ('GOOD      : {0} in {1} range(s)' -f (Format-DiskRescueBytes $goodTotal), $goodRanges.Count)
    Write-Output ('Unmapped  : {0}' -f (Format-DiskRescueBytes ([int64]($diskSize - $badTotal - $goodTotal))))
    [double]$sampledPct = 100.0 * [double]($goodTotal + $badTotal) / [Math]::Max(1, [double]$diskSize)
    Write-Output ('Sampled   : {0:N1}% of the disk was actually read (GOOD-first sampling - unprobed area is not a problem, just not read).' -f $sampledPct)
    Write-Output ''
    if ($badRanges.Count -gt 0) {
        Write-Output 'BAD ranges (first 40):'
        $n = 0
        foreach ($r in $badRanges) {
            if ($n -ge 40) { Write-Output ('  ... and {0} more' -f ($badRanges.Count - 40)); break }
            Write-Output ('  {0}  ->  {1}' -f (Format-DiskRescueBytes ([int64]$r.s)), (Format-DiskRescueBytes ([int64]$r.e)))
            $n++
        }
        Write-Output ''
    }
    # ASCII map, 100 cells.
    $width = 100
    $cell = [Math]::Max(1, [int64]([Math]::Ceiling($diskSize / $width)))
    $sb = New-Object System.Text.StringBuilder
    for ($c = 0; $c -lt $width; $c++) {
        $cs = [int64]($c * $cell)
        $ce = [int64][Math]::Min($diskSize, $cs + $cell)
        $badFrac = 0.0
        $goodFrac = 0.0
        foreach ($r in $badRanges) {
            $rs = [int64]$r.s; $re = [int64]$r.e
            if ($re -le $cs) { continue }
            if ($rs -ge $ce) { break }
            $ov = [Math]::Min($re, $ce) - [Math]::Max($rs, $cs)
            $badFrac += [Math]::Max(0.0, [double]$ov / [double]($ce - $cs))
        }
        foreach ($r in $goodRanges) {
            $rs = [int64]$r.s; $re = [int64]$r.e
            if ($re -le $cs) { continue }
            if ($rs -ge $ce) { break }
            $ov = [Math]::Min($re, $ce) - [Math]::Max($rs, $cs)
            $goodFrac += [Math]::Max(0.0, [double]$ov / [double]($ce - $cs))
        }
        if ($badFrac -gt 0) { [void]$sb.Append('X') }
        elseif ($goodFrac -gt 0) { [void]$sb.Append('.') }
        else { [void]$sb.Append('?') }
    }
    Write-Output ('Disk map ({0} cells):' -f $width)
    Write-Output $sb.ToString()
    Write-Output '  . = readable samples found   X = BAD found   ? = never sampled'
    Write-Output ''
    if (-not $mapData.Completed) {
        Write-Output "Recommended: re-run 'Scan Disk (Build Map)' to finish mapping (it resumes)."
    } elseif ($badTotal -gt 0) {
        Write-Output "Recommended: run 'Copy Files (Bad-Aware)' - readable files are copied fast, damaged regions are skipped and zero-filled."
    } else {
        Write-Output "Recommended: no BAD ranges found in the sampled areas - a straight copy may be sufficient, but 'Copy Files (Bad-Aware)' still protects against undiscovered damage."
    }
}

# ---------------------------------------------------------------------------
# COPY - bad-aware, watchdog-protected file copier
# ---------------------------------------------------------------------------

function Invoke-DiskRescueCopy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $false)][string]$Map = '',
        [int]$ChunkMiB = 4,
        [int]$TimeoutMs = 5000,
        [int]$CancelWaitMs = 2000,
        [switch]$AllowSameDisk
    )
    if (-not (Test-DiskRescueAdmin)) {
        throw 'Administrator privileges are required to read file extents.'
    }
    $srcRoot = $Source.TrimEnd('\') + '\'
    if (-not (Test-Path -LiteralPath $srcRoot)) {
        throw ("Source drive '{0}' does not exist." -f $srcRoot)
    }
    $destRoot = $Destination.TrimEnd('\') + '\'

    # --- safety guards -----------------------------------------------------
    $srcLetter = $srcRoot.Substring(0, 1)
    $destLetter = ''
    if ($destRoot.Length -ge 2 -and $destRoot.Substring(1, 1) -eq ':') { $destLetter = $destRoot.Substring(0, 1) }
    if ($destLetter -eq '') { throw 'The destination must be a local drive path.' }
    if ($srcLetter -ieq $destLetter -and -not $AllowSameDisk) { throw 'The destination must be on a different drive than the source.' }
    function Get-DiskRescuePartitionDisk {
        # Physical disk number for a drive letter, or -1 when unresolvable.
        param([string]$Letter)
        try { return [int](Get-Partition -DriveLetter $Letter -ErrorAction Stop).DiskNumber } catch { return -1 }
    }
    $srcDisk = Get-DiskRescuePartitionDisk -Letter $srcLetter
    $destDisk = Get-DiskRescuePartitionDisk -Letter $destLetter
    if ($srcDisk -ge 0 -and $destDisk -ge 0 -and $srcDisk -eq $destDisk -and -not $AllowSameDisk) {
        throw ("Destination '{0}:' and source '{1}:' are partitions of the SAME physical disk {2}. Use a different physical disk - copying to the same failing disk risks losing everything." -f $destLetter, $srcLetter, $srcDisk)
    }
    if ($destRoot.ToLower().StartsWith($srcRoot.ToLower())) {
        throw 'The destination cannot be inside the source tree.'
    }

    # --- map (optional) ----------------------------------------------------
    $badRanges = New-Object System.Collections.Generic.List[object]
    $mapData = $null
    $mapPathUsed = ''
    if (-not [string]::IsNullOrWhiteSpace($Map)) {
        $mapData = Load-DiskRescueMap -Path $Map
        if ($null -eq $mapData) { throw ("Map '{0}' could not be loaded." -f $Map) }
        Populate-DiskRescueRangeList -Ranges $mapData.BadRanges -Target $badRanges
        $mapPathUsed = $Map
        Write-Output ("[MAP ] Loaded {0} BAD range(s) from {1}" -f $badRanges.Count, $Map)
    } else {
        Write-Output '[MAP ] No map supplied - copying with per-chunk watchdog protection only (runtime discoveries will not be persisted).'
    }

    # --- source geometry ---------------------------------------------------
    $clusterSize = [DiskRescueIo.NtfsLayout]::BytesPerCluster(($srcLetter + ':\'))
    $bps = if ($null -ne $mapData) { [int]$mapData.BytesPerSector } else { 512 }
    $partOffset = [int64]0
    try {
        $part = Get-Partition -DriveLetter $srcLetter -ErrorAction Stop
        $partOffset = [int64]$part.Offset
    } catch { }
    Write-Output ("[INFO] Source {0}: cluster size {1}, partition offset {2}." -f $srcLetter, $clusterSize, (Format-DiskRescueBytes $partOffset))

    Write-Output '============================================================'
    Write-Output (' Disk Rescue - COPY from {0} to {1}' -f $srcRoot, $destRoot)
    Write-Output '============================================================'
    if (-not (Test-Path -LiteralPath $destRoot)) {
        New-Item -ItemType Directory -Path $destRoot -Force | Out-Null
    }

    # --- inventory ---------------------------------------------------------
    # Manual stack walk instead of EnumerateFiles(AllDirectories): a failing
    # disk often has unreadable folders, and the .NET recursive enumerator
    # aborts the whole traversal on the first such failure.
    Write-Output '[INFO] Building file inventory (this can take a while on large trees)...'
    $files = New-Object System.Collections.Generic.List[object]
    $dirs = New-Object System.Collections.Generic.List[string]
    $skippedLinks = 0
    $dirStack = New-Object System.Collections.Generic.Stack[string]
    $dirStack.Push($srcRoot)
    while ($dirStack.Count -gt 0) {
        $dir = $dirStack.Pop()
        try {
            foreach ($d in [System.IO.Directory]::EnumerateDirectories($dir)) {
                try {
                    $attr = [System.IO.File]::GetAttributes($d)
                    if (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { $skippedLinks++; continue }
                    [void]$dirs.Add($d)
                    $dirStack.Push($d)
                } catch { }
            }
        } catch {
            Write-Output ("[WARN] Cannot list folder (skipping its sub-tree): {0}" -f $dir)
        }
        try {
            foreach ($f in [System.IO.Directory]::EnumerateFiles($dir)) {
                try {
                    $attr = [System.IO.File]::GetAttributes($f)
                    if (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { $skippedLinks++; continue }
                    [void]$files.Add($f)
                } catch { }
            }
        } catch { }
    }
    foreach ($d in $dirs) {
        $rel = $d.Substring($srcRoot.Length)
        $target = Join-Path $destRoot $rel
        if (-not (Test-Path -LiteralPath $target)) {
            try { New-Item -ItemType Directory -Path $target -Force | Out-Null } catch { }
        }
    }
    Write-Output ('[INFO] {0} file(s), {1} folder(s), {2} link(s) skipped.' -f $files.Count, $dirs.Count, $skippedLinks)
    if ($files.Count -eq 0) {
        Write-Output '[INFO] Nothing to copy.'
        return
    }

    # Extent lookup up-front so files can be ordered physically (minimises
    # head movement on a mechanical drive).
    Write-Output '[INFO] Resolving physical extents...'
    $extents = @{ }
    $extentFail = 0
    $n = 0
    foreach ($f in $files) {
        $n++
        if ($n % 500 -eq 0) {
            Write-Output ('  extents {0}/{1}...' -f $n, $files.Count)
        }
        try {
            $runs = [DiskRescueIo.NtfsLayout]::PhysicalRuns($f, $clusterSize)
            $extents[$f] = $runs
        } catch { $extentFail++ }
    }
    if ($extentFail -gt 0) {
        Write-Output ("[WARN] Extents unavailable for {0} file(s) (non-NTFS or inaccessible) - those use watchdog-protected reads only." -f $extentFail)
    }

    # Sort: known physical position first (by lowest disk LBA), rest at the end.
    function Get-FileOrderKey {
        param([string]$Path)
        $runs = $extents[$Path]
        if ($null -eq $runs -or $runs.Count -eq 0) { return [int64]::MaxValue }
        foreach ($r in $runs) {
            if ([int64]$r[1] -ge 0) { return ([int64]$r[1] + $partOffset) }
        }
        return [int64]::MaxValue
    }
    $sorted = $files | Sort-Object { Get-FileOrderKey $_ }
    $totalBytes = [int64]0
    foreach ($f in $sorted) {
        try { $totalBytes += [int64]((Get-Item -LiteralPath $f -Force).Length) } catch { }
    }
    Write-Output ('[INFO] Total to copy: {0}. Ordering files by physical location.' -f (Format-DiskRescueBytes $totalBytes))
    Write-Output ''

    # --- copy --------------------------------------------------------------
    $chunk = $ChunkMiB * $script:MiB
    $zeroChunk = New-Object byte[] $chunk
    # Canonical report lives in the DiskRescue data folder (next to the map,
    # so 'Show Lost Files' finds it by disk number); a convenience copy is
    # placed next to the recovered files. Without a resolvable source disk
    # number the report goes to the destination only.
    $reportPath = Join-Path $destRoot 'copy-report.txt'
    $canonicalReport = ''
    $srcDiskNum = Get-DiskRescuePartitionDisk -Letter $srcLetter
    if ($srcDiskNum -ge 0) {
        try {
            $canonicalReport = Get-DiskRescueReportPath -DiskNumber $srcDiskNum
            $cdir = Split-Path -Parent $canonicalReport
            if (-not (Test-Path -LiteralPath $cdir)) { New-Item -ItemType Directory -Path $cdir -Force | Out-Null }
            $reportPath = $canonicalReport
        } catch { }
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $lastPulse = $sw.Elapsed.TotalSeconds
    $doneBytes = [int64]0
    $cntOk = 0; $cntPartial = 0; $cntLost = 0; $cntSkip = 0; $cntErr = 0
    $bytesRecovered = [int64]0
    $bytesLost = [int64]0
    $runtimeBad = 0
    $newBadRanges = 0
    $session = $null
    try {
        # Worker session hosts both the raw confirm-probe handle (when a map
        # exists) and every per-file reader, so a driver-level wedge during
        # copying is contained by the same watchdog as during scanning.
        $session = New-DiskRescueWorkerSession -EnginePath $PSCommandPath -OnWedge { param($m) Write-Output $m }
        if ($null -ne $mapData) {
            $session.OpenDisk([int]$mapData.DiskNumber)
        }
    } catch {
        Write-Output '[WARN] Probe worker unavailable - reads fall back to in-process watchdog only.'
        if ($null -ne $session) { try { $session.Dispose() } catch { } }
        $session = $null
    }

    function Test-VolRangeBad {
        param([int64]$VolOff, [int64]$Len)
        if ($badRanges.Count -eq 0) { return $false }
        return (Test-DiskRescueOverlap -Ranges $badRanges -S ($VolOff + $partOffset) -E ($VolOff + $partOffset + $Len))
    }

    $report = New-Object System.Text.StringBuilder
    foreach ($f in $sorted) {
        $rel = $f.Substring($srcRoot.Length)
        $target = Join-Path $destRoot $rel
        $fileLen = [int64]0
        try { $fileLen = [int64]((Get-Item -LiteralPath $f -Force).Length) } catch { }

        # Resume: same size + nearly same timestamp -> already copied.
        if (Test-Path -LiteralPath $target) {
            try {
                $dItem = Get-Item -LiteralPath $target -Force
                $sItem = Get-Item -LiteralPath $f -Force
                if ([int64]$dItem.Length -eq $fileLen -and
                    [Math]::Abs(($dItem.LastWriteTimeUtc - $sItem.LastWriteTimeUtc).TotalSeconds) -le 2) {
                    $cntSkip++
                    $doneBytes += $fileLen
                    [void]$report.AppendLine(("SKIP`t{0}`t{1}" -f $fileLen, $rel))
                    continue
                }
            } catch { }
        }

        # Pulse progress during long copies.
        [double]$now = $sw.Elapsed.TotalSeconds
        if (($now - $lastPulse) -ge 2.0) {
            $lastPulse = $now
            $rate = if ($doneBytes -gt 0 -and $now -gt 0) { $doneBytes / $now } else { 0 }
            Write-Output ('  ... {0} files done (OK {1} PARTIAL {2} LOST {3}) | {4} of {5} | {6}/s' -f `
                ($cntOk + $cntPartial + $cntLost + $cntSkip), $cntOk, $cntPartial, $cntLost,
                (Format-DiskRescueBytes $doneBytes), (Format-DiskRescueBytes $totalBytes), (Format-DiskRescueBytes ([int64]$rate)))
        }

        if ($fileLen -eq 0) {
            try {
                $tdir = Split-Path -Parent $target
                if (-not (Test-Path -LiteralPath $tdir)) { New-Item -ItemType Directory -Path $tdir -Force | Out-Null }
                [System.IO.File]::WriteAllBytes($target, @())
                $cntOk++
                [void]$report.AppendLine(("OK`t0`t{0}" -f $rel))
            } catch {
                $cntErr++
                [void]$report.AppendLine(("LOST`t0`t{0}" -f $rel))
            }
            continue
        }

        $runs = $extents[$f]
        $chunkBad = @()
        if ($null -ne $runs) {
            foreach ($r in $runs) {
                $fileOff = [int64]$r[0]
                $volOff = [int64]$r[1]
                $runLen = [int64]$r[2]
                if ($volOff -lt 0) { continue }
                $c = $fileOff
                while ($c -lt ($fileOff + $runLen)) {
                    $cLen = [Math]::Min($chunk, $fileOff + $runLen - $c)
                    if (Test-VolRangeBad -VolOff ($volOff + ($c - $fileOff)) -Len $cLen) {
                        $chunkBad += , @($c, ($c + $cLen))
                    }
                    $c += $cLen
                }
            }
        }

        $reader = $null
        $out = $null
        $copied = [int64]0
        $zeroed = [int64]0
        $unreadable = New-Object System.Collections.Generic.List[object]
        $fileLost = $false
        try {
            $tdir = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $tdir)) { New-Item -ItemType Directory -Path $tdir -Force | Out-Null }
            if ($null -ne $session) {
                $reader = $session.OpenFile($f)
            } else {
                $reader = New-Object DiskRescueIo.FileChunkReader($f)
            }
            $out = [System.IO.File]::Create($target, 1 * $script:MiB, [System.IO.FileOptions]::SequentialScan)
            $c = [int64]0
            while ($c -lt $fileLen) {
                $cLen = [int]([Math]::Min([int64]$chunk, $fileLen - $c))
                $isBadChunk = $false
                foreach ($br in $chunkBad) {
                    if ([int64]$br[0] -lt ($c + $cLen) -and [int64]$br[1] -gt $c) { $isBadChunk = $true; break }
                }
                if ($isBadChunk) {
                    if ($cLen -eq $chunk) { $out.Write($zeroChunk, 0, $cLen) } else { $out.Write((New-Object byte[] $cLen), 0, $cLen) }
                    $zeroed += $cLen
                    $c += $cLen
                    continue
                }
                $res = $reader.ReadAt($c, $cLen, $TimeoutMs, $CancelWaitMs)
                if ($res.Status -eq 'Good') {
                    $out.Write($res.Data, 0, $res.BytesRead)
                    $copied += $res.BytesRead
                    $c += $cLen
                    continue
                }
                # Unexpected failure in a supposedly readable area. Raw-confirm
                # against the disk (if the extent is known) before recording.
                $confirmed = $false
                if ($null -ne $runs -and $null -ne $session) {
                    $volChunk = -1
                    foreach ($r in $runs) {
                        $fo = [int64]$r[0]; $vo = [int64]$r[1]; $rl = [int64]$r[2]
                        if ($vo -ge 0 -and $c -ge $fo -and $c -lt ($fo + $rl)) {
                            $volChunk = $vo + ($c - $fo)
                            break
                        }
                    }
                    if ($volChunk -ge 0) {
                        $probeOff = [int64]([Math]::Floor(($partOffset + $volChunk) / $bps) * $bps)
                        if ($probeOff -lt [int64]0) { $probeOff = 0 }
                        $pres = $session.ReadAt($probeOff, [Math]::Min(1 * $script:MiB, $cLen), $TimeoutMs, $CancelWaitMs)
                        if ($pres.Status -ne 'Good') {
                            $confirmed = $true
                            Add-DiskRescueRange -Ranges $badRanges -S $probeOff -E ($probeOff + [int64]$cLen)
                            $newBadRanges++
                            $runtimeBad++
                        }
                    }
                }
                if (-not $confirmed) {
                    # One retry - occasional false timeouts happen on busy drives.
                    Start-Sleep -Milliseconds 250
                    $res2 = $reader.ReadAt($c, $cLen, $TimeoutMs, $CancelWaitMs)
                    if ($res2.Status -eq 'Good') {
                        $out.Write($res2.Data, 0, $res2.BytesRead)
                        $copied += $res2.BytesRead
                        $c += $cLen
                        continue
                    }
                }
                # Give up on this chunk: zero-fill and continue with the rest.
                if ($cLen -eq $chunk) { $out.Write($zeroChunk, 0, $cLen) } else { $out.Write((New-Object byte[] $cLen), 0, $cLen) }
                $zeroed += $cLen
                [void]$unreadable.Add([pscustomobject]@{ s = $c; e = ($c + $cLen) })
                $c += $cLen
            }
        } catch {
            $fileLost = $true
            Write-Output ("[ERR ] {0} - {1}" -f $rel, $_.Exception.Message)
        } finally {
            if ($null -ne $out) { try { $out.Dispose() } catch { } }
            if ($null -ne $reader) { try { $reader.Dispose() } catch { } }
        }

        if ($fileLost) {
            $cntLost++
            $bytesLost += $fileLen
            $doneBytes += $fileLen
            [void]$report.AppendLine(("LOST`t{0}`t{1}" -f $fileLen, $rel))
            continue
        }

        $recovered = $copied + $zeroed
        if ($copied -eq 0 -and $zeroed -gt 0) {
            # Nothing readable at all - do not leave a fake file behind.
            try { Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue } catch { }
            $cntLost++
            $bytesLost += $fileLen
            Write-Output ("[LOST] {0} - entirely inside BAD region ({1})." -f $rel, (Format-DiskRescueBytes $fileLen))
            [void]$report.AppendLine(("LOST`t{0}`t{1}" -f $fileLen, $rel))
        } elseif ($zeroed -gt 0) {
            $cntPartial++
            $bytesRecovered += $copied
            $pct = [int][Math]::Round(100.0 * $copied / [Math]::Max(1, $fileLen))
            Write-Output ("[PART] {0} - {1}% recovered ({2} readable, {3} unreadable)." -f $rel, $pct, (Format-DiskRescueBytes $copied), (Format-DiskRescueBytes $zeroed))
            try {
                $side = "$target.rescue-partial.txt"
                $lines = New-Object System.Text.StringBuilder
                [void]$lines.AppendLine(("Original size : {0}" -f (Format-DiskRescueBytes $fileLen)))
                [void]$lines.AppendLine(("Recovered     : {0} ({1}%)" -f (Format-DiskRescueBytes $copied), $pct))
                [void]$lines.AppendLine(("Unreadable    : {0} (zero-filled)" -f (Format-DiskRescueBytes $zeroed)))
                [void]$lines.AppendLine('Unreadable file ranges:')
                foreach ($u in $unreadable) {
                    [void]$lines.AppendLine(('  {0} - {1}' -f (Format-DiskRescueBytes ([int64]$u.s)), (Format-DiskRescueBytes ([int64]$u.e))))
                }
                [System.IO.File]::WriteAllText($side, $lines.ToString(), [System.Text.Encoding]::UTF8)
            } catch { }
            [void]$report.AppendLine(("PARTIAL`t{0}`t{1}" -f $fileLen, $rel))
        } else {
            $cntOk++
            $bytesRecovered += $copied
            [void]$report.AppendLine(("OK`t{0}`t{1}" -f $fileLen, $rel))
        }
        # Preserve the source timestamp so a later run recognises this file
        # as already copied (resume check compares size + LastWriteTime).
        if (-not $fileLost) {
            try {
                (Get-Item -LiteralPath $target -Force).LastWriteTimeUtc = (Get-Item -LiteralPath $f -Force).LastWriteTimeUtc
            } catch { }
        }
        $doneBytes += $fileLen
    }

    if ($null -ne $session) { try { $session.Dispose() } catch { } }
    [System.IO.File]::WriteAllText($reportPath, $report.ToString(), [System.Text.Encoding]::UTF8)
    $reportNote = ''
    if ($canonicalReport -and (Test-Path -LiteralPath $reportPath)) {
        try {
            Copy-Item -LiteralPath $reportPath -Destination (Join-Path $destRoot 'copy-report.txt') -Force
            $reportNote = ' (copy saved next to the recovered files)'
        } catch { }
    }
    if ($null -ne $mapData -and $newBadRanges -gt 0) {
        $mapData.BadRanges = $badRanges
        try { Save-DiskRescueMap -Map $mapData -Path $mapPathUsed } catch { }
        Write-Output ("[MAP ] {0} new BAD region(s) discovered during copying and written to the map." -f $newBadRanges)
    }

    Write-Output ''
    Write-Output '============================================================'
    Write-Output '[SUCCESS] Copy phase finished.'
    Write-Output ('Files: OK {0} | PARTIAL {1} | LOST {2} | SKIPPED {3} | ERRORS {4}' -f `
        $cntOk, $cntPartial, $cntLost, $cntSkip, $cntErr)
    Write-Output ('Recovered {0} | lost {1} | elapsed {2}.' -f `
        (Format-DiskRescueBytes $bytesRecovered), (Format-DiskRescueBytes $bytesLost), (Format-DiskRescueDuration $sw.Elapsed.TotalSeconds))
    Write-Output ("Report: {0}{1}" -f $reportPath, $reportNote)
    Write-Output "Use 'Show Lost Files' to list everything that did not fully recover."
}

# ---------------------------------------------------------------------------
# LOST - list files that did not fully recover
# ---------------------------------------------------------------------------

function Show-DiskRescueLost {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Report)
    if (-not (Test-Path -LiteralPath $Report)) {
        throw ("Copy report not found: {0}. Run 'Copy Files (Bad-Aware)' first." -f $Report)
    }
    $lines = [System.IO.File]::ReadAllLines($Report)
    $lost = @(); $partial = @(); $ok = 0; $skip = 0
    $lostBytes = [int64]0; $partialBytes = [int64]0
    foreach ($line in $lines) {
        $parts = $line.Split("`t")
        if ($parts.Count -lt 3) { continue }
        [int64]$size = 0
        try { [int64]$size = [int64]$parts[1] } catch { }
        switch ($parts[0]) {
            'LOST'    { $lost += , @($size, $parts[2]); $lostBytes += $size }
            'PARTIAL' { $partial += , @($size, $parts[2]); $partialBytes += $size }
            'OK'      { $ok++ }
            'SKIP'    { $skip++ }
        }
    }
    Write-Output '============================================================'
    Write-Output (' Disk Rescue - LOST FILES: {0}' -f $Report)
    Write-Output '============================================================'
    Write-Output ('OK {0} | SKIPPED {1} | PARTIAL {2} | LOST {3}' -f $ok, $skip, $partial.Count, $lost.Count)
    Write-Output ('Readable-but-damaged bytes: {0} | completely lost bytes: {1}' -f `
        (Format-DiskRescueBytes $partialBytes), (Format-DiskRescueBytes $lostBytes))
    Write-Output ''
    if ($partial.Count -gt 0) {
        Write-Output ('PARTIAL files (readable portion recovered, unreadable parts zero-filled) - first 60:')
        $n = 0
        foreach ($p in $partial) {
            if ($n -ge 60) { Write-Output ('  ... and {0} more' -f ($partial.Count - 60)); break }
            Write-Output ('  {0}  {1}' -f (Format-DiskRescueBytes ([int64]$p[0])), $p[1])
            $n++
        }
        Write-Output ''
    }
    if ($lost.Count -gt 0) {
        Write-Output ('LOST files (nothing or almost nothing recovered) - first 60:')
        $n = 0
        foreach ($p in $lost) {
            if ($n -ge 60) { Write-Output ('  ... and {0} more' -f ($lost.Count - 60)); break }
            Write-Output ('  {0}  {1}' -f (Format-DiskRescueBytes ([int64]$p[0])), $p[1])
            $n++
        }
    }
    if ($lost.Count -eq 0 -and $partial.Count -eq 0) {
        Write-Output 'Nothing was lost - every file was recovered in full.'
    }
}
