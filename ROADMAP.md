# DriveStitch - Roadmap

Last updated: 2026-08-31

## Status

Working standalone failing-disk rescue tool (PySide6 GUI + PowerShell engine).

Validated in the field:

- SanDisk SDSSDP064G 64 GB (SATA): full scan (4200 probes, 0 bad) + bad-aware
  copy with SHA256-identical result. Clean bill of health.
- TOSHIBA External USB 3.0 700 GB (USB): scan found 4+ damaged regions
  (CRC errors around 180.9, 216.1, 314.6, 466.2, 518.1 GiB) and one sector
  class that hard-stalls the USB bridge (driver-level wedge, LED dead).
  The wedge-proof probe worker survived it and kept scanning (checkpointed).

## Done

- [x] GUI: disk table, scan/copy dialogs, streaming log panel, dark theme
- [x] Engine: GOOD-first hierarchical scan with watchdog-protected probes,
      resumable JSON maps, per-probe verified retries
- [x] Engine: bad-aware copy (extents, map-driven skip + zero-fill, per-chunk
      watchdog, resume, copy report + lost-files list)
- [x] Map report + lost-files viewers
- [x] Probe worker process isolation (2026-08-31): all timed reads run in a
      child process; a driver-level stall that ignores CancelIoEx is released
      by taskkill /F, the worker respawns with the same handles and the read
      reports Timeout. 20-consecutive-wedge guard aborts cleanly.
- [x] Worker test suite (tests/test-worker.ps1, 15 checks): protocol,
      base64 file reads, wedge simulation (SLEEP), respawn + reopen, dispose.
      Runs elevated; log via Tee-Object.
- [x] Clean-room rewrite of the native C# I/O block (2026-09-08): all Win32
      interop re-implemented independently from the Microsoft documentation
      (DriveProbe / FileChunkReader / NtfsLayout, namespace DiskRescueIo).
      Removes any structural overlap with the GPL-3.0 AdaptiveDisk concept
      inspiration; worker protocol, map format and behaviour unchanged.
      Verified: 0 non-boilerplate lines shared with AdaptiveDisk; 15/15
      worker tests + geometry check pass on the SanDisk 64 GB (disk 5).

## Next

- [ ] Finish the Toshiba 700 GB map (resume from DiskRescue\disk7-map.json;
      depths 7-8 were in progress, ~4 bad regions known)
- [ ] Copy-path field test on a disk with real bad sectors (verify zero-fill
      + partial-report behaviour against damage, not just the healthy path)
- [ ] Speed up worker respawn: cache the compiled native DLL so a respawn
      skips Add-Type compilation (~2-4 s today)
- [ ] GUI: surface [WEDGE] events as a status hint (auto-recovery is silent
      beyond the log lines)
- [ ] Test wedge behaviour on a failing internal SATA disk (AHCI path should
      cancel cleanly - confirm and document the difference)
- [ ] Optional: SMART health column in the disk table (Get-PhysicalDisk
      HealthStatus/OperationalStatus already available)
