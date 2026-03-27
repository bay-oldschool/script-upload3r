@echo off
setlocal enabledelayedexpansion

:: Save code page and set to UTF-8
for /f "tokens=2 delims=:" %%a in ('chcp') do set "OLDCP=%%a"
set "OLDCP=%OLDCP: =%"
chcp 65001 > nul

:: Enable ANSI escape codes
for /f %%a in ('echo prompt $E ^| cmd') do set "ESC=%%a"
set "BLUE=%ESC%[94m"
set "GREEN=%ESC%[92m"
set "RED=%ESC%[91m"
set "YELLOW=%ESC%[93m"
set "CYAN=%ESC%[96m"
set "RESET=%ESC%[0m"

:: If arguments provided, pass directly to subtitle.ps1 (no menu)
if not "%~1"=="" (
    powershell -ExecutionPolicy Bypass -File "%~dp0ps\subtitle.ps1" %*
    chcp %OLDCP% > nul
    exit /b !errorlevel!
)

:menu
cls
echo %BLUE%========================================%RESET%
echo %BLUE%   SUBTITLE UPLOAD%RESET%
echo %BLUE%========================================%RESET%
echo.

:: Ask for torrent ID
set "TORRENT_ID="
set /p "TORRENT_ID=Torrent ID: "
if "!TORRENT_ID!"=="" (
    echo %RED%Error: Torrent ID cannot be empty!%RESET%
    timeout /t 2 > nul
    goto menu
)

:: Validate numeric
echo !TORRENT_ID!| findstr /r "^[0-9][0-9]*$" > nul 2>&1
if errorlevel 1 (
    echo %RED%Error: Torrent ID must be a number!%RESET%
    timeout /t 2 > nul
    goto menu
)

:select_file
echo.
echo  1) 📂 Browse for file (graphical)
echo  2) ✏  Enter path manually / drag and drop
echo  3) 🚪 Exit
echo.
choice /c 123 /n /m "Select (1-3): "
if errorlevel 3 goto end
if errorlevel 2 goto enter_file
if errorlevel 1 goto browse_file
goto select_file

:browse_file
echo.
echo Opening file browser...
echo.

for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "Add-Type -AssemblyName System.Windows.Forms; $f = New-Object System.Windows.Forms.OpenFileDialog; $f.Title = 'Select subtitle file'; $f.Filter = 'Subtitle files (*.srt;*.ass;*.ssa;*.sub;*.zip)|*.srt;*.ass;*.ssa;*.sub;*.zip|All files (*.*)|*.*'; if ($f.ShowDialog() -eq 'OK') { $f.FileName }"`) do set "SUB_FILE=%%I"

if not "!SUB_FILE!"=="" goto confirm_upload
echo.
echo %RED%No file selected!%RESET%
timeout /t 2 > nul
goto select_file

:enter_file
echo.
echo Enter path to subtitle file:
echo (you can drag and drop the file here)
echo.
set "SUB_FILE="
set /p "SUB_FILE=Path: "
set "SUB_FILE=!SUB_FILE:"=!"

if "!SUB_FILE!"=="" (
    echo %RED%Error: Path cannot be empty!%RESET%
    timeout /t 2 > nul
    goto select_file
)

if not exist "!SUB_FILE!" (
    echo %RED%Error: File not found!%RESET%
    echo "!SUB_FILE!"
    timeout /t 2 > nul
    goto select_file
)

:confirm_upload
cls
echo %BLUE%========================================%RESET%
echo %BLUE%   SUBTITLE UPLOAD%RESET%
echo %BLUE%========================================%RESET%
echo.
for %%F in ("!SUB_FILE!") do set "SUB_NAME=%%~nxF"
echo  Torrent ID: %CYAN%!TORRENT_ID!%RESET%
echo  File:       %CYAN%!SUB_NAME!%RESET%
echo.

:ask_note
set "SUB_NOTE="
set /p "SUB_NOTE=Note: "
if "!SUB_NOTE!"=="" (
    echo %RED%Error: Note is required!%RESET%
    goto ask_note
)
set "NOTE_FLAG=-n "!SUB_NOTE!""

rem Anonymous prompt is handled by the PS1 script using config default

echo.
echo %BLUE%========================================%RESET%
echo %BLUE%   UPLOADING SUBTITLE%RESET%
echo %BLUE%========================================%RESET%
echo.

powershell -ExecutionPolicy Bypass -File "%~dp0ps\subtitle.ps1" !TORRENT_ID! "!SUB_FILE!" !NOTE_FLAG!
set "UP_EXIT=!errorlevel!"

echo.
if not !UP_EXIT! equ 0 goto upload_failed
echo %GREEN%========================================%RESET%
echo %GREEN%   SUBTITLE UPLOADED SUCCESSFULLY%RESET%
echo %GREEN%========================================%RESET%
goto after_upload

:upload_failed
echo %RED%========================================%RESET%
echo %RED%   SUBTITLE UPLOAD FAILED - code: !UP_EXIT!%RESET%
echo %RED%========================================%RESET%

:after_upload
echo.
echo  1) 🔄 Upload another subtitle
echo  2) 🚪 Exit
echo.
choice /c 12 /n /m "Select (1-2): "
if errorlevel 2 goto end
if errorlevel 1 goto menu
goto after_upload

:end
echo.
echo %GREEN%Done!%RESET%
echo.
chcp %OLDCP% > nul
exit /b 0
