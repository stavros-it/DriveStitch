@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
set "TARGET=%SCRIPT_DIR%DriveStitch.pyw"
set "ICON=%SCRIPT_DIR%app.ico"
set "LNKNAME=DriveStitch.lnk"

if not exist "%TARGET%" (
    echo ERROR: DriveStitch.pyw was not found next to this script.
    pause
    exit /b 1
)
if not exist "%ICON%" (
    echo ERROR: app.ico was not found next to this script.
    pause
    exit /b 1
)

for /f "usebackq delims=" %%D in (`powershell -NoProfile -Command "[Environment]::GetFolderPath('Desktop')"`) do set "DESKTOP=%%D"

if not defined DESKTOP (
    echo ERROR: could not locate the desktop folder.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -Command "$ws = New-Object -ComObject WScript.Shell; $lnk = $ws.CreateShortcut((Join-Path $env:DESKTOP $env:LNKNAME)); $lnk.TargetPath = $env:TARGET; $lnk.WorkingDirectory = $env:SCRIPT_DIR; $lnk.IconLocation = ($env:ICON + ',0'); $lnk.Description = 'DriveStitch - Failing Disk Rescue'; $lnk.Save(); Write-Host ('Shortcut created: ' + (Join-Path $env:DESKTOP $env:LNKNAME))"

echo.
echo Done. Use the DriveStitch shortcut on your desktop to start the app.
echo The app will ask for Administrator rights through UAC when launched.
pause
