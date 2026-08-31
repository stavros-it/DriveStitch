# Tests for the DiskRescueLib probe worker (protocol + wedge watchdog).
# Must run elevated (raw disk reads on the SanDisk test disk 5).
# Exit code = number of failed tests.
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$engine = 'C:\Users\Stavros\OneDrive\My AI Apps\SA DiskFileDigger\engine\DiskRescueLib.ps1'
. $engine
$ErrorActionPreference = 'Continue'

$script:failures = 0
function Assert-True($Condition, $Name, $Detail = '') {
    if ($Condition) {
        Write-Output ("PASS  {0}" -f $Name)
    } else {
        $script:failures++
        Write-Output ("FAIL  {0}  {1}" -f $Name, $Detail)
    }
}

# --- data file for OPENFILE tests ------------------------------------------
$tmpFile = Join-Path $env:TEMP ('dfd_wtest_{0}.bin' -f (Get-Random))
$payload = New-Object byte[] (1 * $script:MiB)
(New-Object Random(1234)).NextBytes($payload)
[IO.File]::WriteAllBytes($tmpFile, $payload)

Write-Output '===== PART A: in-process command handler ====='
$state = New-DiskRescueWorkerState

# T1: PING
$r = Invoke-DiskRescueWorkerCommand -Command 'PING' -State $state
Assert-True ($r -eq 'PONG') 'T1 PING answers PONG' ("got: " + $r)

# T2: OPENDISK 5
$r = Invoke-DiskRescueWorkerCommand -Command 'OPENDISK 5' -State $state
$diskId = -1
if ($r -match '^OK (\d+)$') { $diskId = [int]$Matches[1] }
Assert-True ($diskId -gt 0) 'T2 OPENDISK returns handle id' ("got: " + $r)

# T3: READ offset 0, 64 KiB, no data
$r = Invoke-DiskRescueWorkerCommand -Command ('READ {0} 0 65536 5000 2000 0' -f $diskId) -State $state
$ok = ($r -match ('^OK {0} Good (\d+) 0 \d+' -f $diskId)) -and ([int]$Matches[1] -eq 65536)
Assert-True $ok 'T3 disk READ offset 0 returns Good 64KiB' ("got: " + $r)

# T4: READ beyond disk end -> Error, non-zero win32 error
$r = Invoke-DiskRescueWorkerCommand -Command ('READ {0} 68719476736 512 5000 2000 0' -f $diskId) -State $state
$ok = ($r -match ('^OK {0} Error 0 [1-9]\d* \d+' -f $diskId))
Assert-True $ok 'T4 disk READ beyond end returns Error with win32 code' ("got: " + $r)

# T5: OPENFILE + READ with data
$r = Invoke-DiskRescueWorkerCommand -Command ('OPENFILE {0}' -f $tmpFile) -State $state
$fileId = -1
if ($r -match '^OK (\d+)$') { $fileId = [int]$Matches[1] }
Assert-True ($fileId -gt 0) 'T5a OPENFILE returns handle id' ("got: " + $r)
$r = Invoke-DiskRescueWorkerCommand -Command ('READ {0} 4096 4096 5000 2000 1' -f $fileId) -State $state
$ok = $false
if ($r -match ('^OK {0} Good (\d+) 0 \d+ ([A-Za-z0-9+/=]+)(?: .*)?$' -f $fileId)) {
    $got = [Convert]::FromBase64String($Matches[2])
    $want = New-Object byte[] 4096
    [Array]::Copy($payload, 4096, $want, 0, 4096)
    $ok = ([int]$Matches[1] -eq 4096) -and ([Convert]::ToBase64String($got) -eq [Convert]::ToBase64String($want))
}
Assert-True $ok 'T5b file READ returns exact bytes via base64' ("got prefix: " + $r.Substring(0, [Math]::Min(80, $r.Length)))

# T6: CLOSE then READ on closed id
$r = Invoke-DiskRescueWorkerCommand -Command ('CLOSE {0}' -f $fileId) -State $state
Assert-True ($r -eq ('OK {0}' -f $fileId)) 'T6a CLOSE answers OK' ("got: " + $r)
$r = Invoke-DiskRescueWorkerCommand -Command ('READ {0} 0 512 5000 2000 0' -f $fileId) -State $state
Assert-True ($r -like 'ERR*') 'T6b READ on closed id errors' ("got: " + $r)

# T7: unknown command
$r = Invoke-DiskRescueWorkerCommand -Command 'FLY 2 THE MOON' -State $state
Assert-True ($r -like 'ERR*') 'T7 unknown command errors' ("got: " + $r)

# T12: native message text is carried in the READ response (multi-word)
$r = Invoke-DiskRescueWorkerCommand -Command ('READ {0} 68719476736 512 5000 2000 0' -f $diskId) -State $state
$ok = $false
if ($r -match ('^OK {0} Error 0 [1-9]\d* \d+  (.+)$' -f $diskId)) {
    $ok = ($Matches[1].Trim().Length -gt 3)
}
Assert-True $ok 'T12 READ response carries native message text' ("got: " + $r)

Write-Output '===== PART B: worker process + wedge watchdog ====='

# T8: wrapper session, disk read through child process
$ses = [DiskRescueWorkerSession]::new($engine)
$ses.OpenDisk(5)
$r = $ses.ReadAt(0, 65536, 5000, 2000)
Assert-True ($r.Status -eq 'Good' -and $r.BytesRead -eq 65536) 'T8 wrapper ReadAt via child process' ("got: $($r.Status) $($r.BytesRead) $($r.Message)")

# T9: wedged command is killed by the watchdog, worker respawns, disk still usable
$sw = [Diagnostics.Stopwatch]::StartNew()
$r = $ses.SendCommand('SLEEP 60000', 4000)
$sw.Stop()
$ok = ($r.Status -eq 'Timeout') -and ($r.Message -like '*wedge*') -and ($sw.Elapsed.TotalSeconds -lt 25)
Assert-True $ok 'T9 SLEEP wedge killed by watchdog, Timeout returned' ("got: $($r.Status) $($r.Message) in $([int]$sw.Elapsed.TotalSeconds)s")
$r = $ses.ReadAt(1048576, 65536, 5000, 2000)
Assert-True ($r.Status -eq 'Good') 'T9b disk readable on respawned worker' ("got: $($r.Status)")

# T10: file read through wrapper after respawn
$fr = $ses.OpenFile($tmpFile)
$r = $fr.ReadAt(0, 4096, 5000, 2000)
$ok = $false
if ($r.Status -eq 'Good') {
    $want = New-Object byte[] 4096
    [Array]::Copy($payload, 0, $want, 0, 4096)
    $ok = ([Convert]::ToBase64String($r.Data) -eq [Convert]::ToBase64String($want))
}
Assert-True $ok 'T10 file reader ReadAt returns exact bytes' ("got: $($r.Status) $($r.BytesRead) $($r.Message)")
$fr.Dispose()

# T11: Dispose stops the worker process
$pidBefore = $ses.GetWorkerPid()
$ses.Dispose()
Start-Sleep -Milliseconds 800
$alive = Get-Process -Id $pidBefore -ErrorAction SilentlyContinue
Assert-True ($null -eq $alive) 'T11 Dispose terminates worker process' ("pid $pidBefore still alive")

Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue
Write-Output ''
if ($script:failures -eq 0) { Write-Output 'ALL WORKER TESTS PASSED' } else { Write-Output ("{0} TEST(S) FAILED" -f $script:failures) }
exit $script:failures
