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

set "LAST_PATH_FILE=%~dp0output\.last_path.txt"
set "SAVED_PATHS_FILE=%~dp0output\.saved_paths.txt"

:: If arguments provided, pass directly to upload.ps1 (no menu)
if not "%~1"=="" (
    powershell -ExecutionPolicy Bypass -File "%~dp0ps\upload.ps1" %*
    chcp %OLDCP% > nul
    exit /b !errorlevel!
)

:menu
cls
echo %BLUE%========================================%RESET%
echo %BLUE%   UPLOAD TO TRACKER - PATH SELECTION%RESET%
echo %BLUE%========================================%RESET%
echo.
echo  1) 🕐 Use last path
echo  2) 📂 Browse for folder (graphical)
echo  3) 🎞  Browse for file (graphical)
echo  4) ✏  Enter path manually
echo  5) 💾 Choose from saved paths
echo  6) 🗑  Clear saved paths
echo  0) 🚪 Exit
echo.
choice /c 1234560 /n /m "Select (0-6): "
if errorlevel 7 goto end
if errorlevel 6 goto clear_saved
if errorlevel 5 goto choose_saved
if errorlevel 4 goto enter_manual
if errorlevel 3 goto browse_file
if errorlevel 2 goto browse_folder
if errorlevel 1 goto use_last
goto menu

:use_last
if not exist "%LAST_PATH_FILE%" goto use_last_empty
set /p USER_PATH=<"%LAST_PATH_FILE%"
echo.
echo  Using: %CYAN%!USER_PATH!%RESET%
goto save_and_continue

:use_last_empty
echo.
echo %RED%No last path saved!%RESET%
timeout /t 2 > nul
goto menu

:browse_folder
echo.
echo Opening folder browser...
echo.

for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ps\browse_folder.ps1" -title "Select the content directory"`) do set "USER_PATH=%%I"

if not "!USER_PATH!"=="" goto save_and_continue
echo.
echo %RED%No folder selected!%RESET%
timeout /t 2 > nul
goto menu

:browse_file
echo.
echo Opening file browser...
echo.

set "USER_PATH="
for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "Add-Type -AssemblyName System.Windows.Forms; $f = New-Object System.Windows.Forms.OpenFileDialog; $f.Title = 'Select media file'; $f.Filter = 'Video files (*.mkv;*.mp4;*.avi;*.ts)|*.mkv;*.mp4;*.avi;*.ts|All files (*.*)|*.*'; if ($f.ShowDialog() -eq 'OK') { $f.FileName }"`) do set "USER_PATH=%%I"

if not "!USER_PATH!"=="" goto save_and_continue
echo.
echo %RED%No file selected!%RESET%
timeout /t 2 > nul
goto menu

:enter_manual
echo.
echo Enter path to content directory:
echo (you can drag and drop the folder here)
echo.
set "USER_PATH="
set /p "USER_PATH=Path: "
set "USER_PATH=!USER_PATH:"=!"

if not "!USER_PATH!"=="" goto save_and_continue
echo %RED%Error: Path cannot be empty!%RESET%
timeout /t 2 > nul
goto menu

:save_and_continue
if not exist "!USER_PATH!" goto path_not_exist

:: Save to last_path
> "%LAST_PATH_FILE%" <nul set /p ="!USER_PATH!"

:: Save to saved paths list (if not already there)
if not exist "%SAVED_PATHS_FILE%" goto save_new_path
findstr /x /C:"!USER_PATH!" "%SAVED_PATHS_FILE%" >nul 2>&1
if errorlevel 1 >> "%SAVED_PATHS_FILE%" echo !USER_PATH!
goto ask_auto

:save_new_path
> "%SAVED_PATHS_FILE%" echo !USER_PATH!
goto ask_auto

:path_not_exist
echo.
echo %RED%ERROR: Path does not exist!%RESET%
echo "!USER_PATH!"
echo.
timeout /t 2 > nul
goto menu

:choose_saved
if not exist "%SAVED_PATHS_FILE%" goto no_saved_paths

cls
echo %BLUE%========================================%RESET%
echo %BLUE%   SAVED PATHS%RESET%
echo %BLUE%========================================%RESET%
echo.
set index=1
for /f "usebackq delims=" %%a in ("%SAVED_PATHS_FILE%") do (
    echo  !index!^) %%a
    set "path!index!=%%a"
    set /a index+=1
)
echo.
set "path_choice="
set /p "path_choice=Choose number (or 0 for back): "

if "!path_choice!"=="0" goto menu
set "USER_PATH=!path%path_choice%!"
if "!USER_PATH!"=="" goto invalid_saved_choice
> "%LAST_PATH_FILE%" <nul set /p ="!USER_PATH!"
goto ask_auto

:invalid_saved_choice
echo %RED%Invalid choice!%RESET%
timeout /t 2 > nul
goto choose_saved

:no_saved_paths
echo.
echo %RED%No saved paths found!%RESET%
timeout /t 2 > nul
goto menu

:clear_saved
if not exist "%SAVED_PATHS_FILE%" goto clear_saved_empty
del "%SAVED_PATHS_FILE%"
echo %GREEN%Saved paths cleared.%RESET%
goto clear_saved_last

:clear_saved_empty
echo %YELLOW%No saved paths found.%RESET%

:clear_saved_last
if exist "%LAST_PATH_FILE%" del "%LAST_PATH_FILE%"
timeout /t 2 > nul
goto menu

:ask_auto
cls
echo %BLUE%========================================%RESET%
echo %BLUE%   UPLOAD OPTIONS%RESET%
echo %BLUE%========================================%RESET%
echo.
for %%F in ("!USER_PATH!") do set "UP_FOLDER=%%~nxF"
rem Detect if file or folder, and get torrent name
for /f "usebackq delims=" %%L in (`powershell -NoProfile -Command "if (Test-Path -LiteralPath '!USER_PATH!' -PathType Leaf) { 'File' } else { 'Folder' }"`) do set "PATH_LABEL=%%L"
for /f "usebackq delims=" %%N in (`powershell -NoProfile -Command "if (Test-Path -LiteralPath '!USER_PATH!' -PathType Leaf) { [System.IO.Path]::GetFileNameWithoutExtension('!USER_PATH!') } else { Split-Path -Leaf '!USER_PATH!' }"`) do set "TORRENT_NAME=%%N"
echo  !PATH_LABEL!: %CYAN%!UP_FOLDER!%RESET%
echo  Path:   !USER_PATH!
echo.

set "OUT_DIR=%~dp0output"
set "REQ_FILE=!OUT_DIR!\!TORRENT_NAME!_upload_request.txt"
set "TOR_FILE=!OUT_DIR!\!TORRENT_NAME!.torrent"
set "DESC_FILE=!OUT_DIR!\!TORRENT_NAME!_torrent_description.bbcode"

echo  %CYAN%Upload files:%RESET%
if exist "!REQ_FILE!" (echo   %GREEN%OK%RESET%  !TORRENT_NAME!_upload_request.txt) else (echo   %RED%--  !TORRENT_NAME!_upload_request.txt%RESET%)
if exist "!TOR_FILE!" (echo   %GREEN%OK%RESET%  !TORRENT_NAME!.torrent) else (echo   %RED%--  !TORRENT_NAME!.torrent%RESET%)
if exist "!DESC_FILE!" (echo   %GREEN%OK%RESET%  !TORRENT_NAME!_torrent_description.bbcode) else (echo   %RED%--  !TORRENT_NAME!_torrent_description.bbcode%RESET%)
echo.

set "MEDIA_FILE=!OUT_DIR!\!TORRENT_NAME!_mediainfo.txt"

echo  %CYAN%Preview:%RESET%
echo  1) 📋 Preview upload request
echo  2) 📝 Preview description
echo  3) ℹ  Preview mediainfo
echo  0) 🚪 Back
echo.

:upload_action
choice /c yn1230 /n /m "Use auto mode (skip prompts)? (y/n/1/2/3/0) [n]: "
if errorlevel 6 goto menu
if errorlevel 5 goto upl_preview_media
if errorlevel 4 goto upl_preview_desc
if errorlevel 3 goto upl_preview_req
if errorlevel 2 set "AUTO_FLAG=" & goto show_override
if errorlevel 1 set "AUTO_FLAG=-auto" & goto run_upload

:show_override
echo.
set "OVR_REQ="
set "OVR_TOR="
set "OVR_DESC="
echo  Override upload files?
echo  1) 📋 Change upload request file
echo  2) 🧲 Change torrent file
echo  3) 📝 Change description file
echo  4) ▶  Continue with current files
echo.
:override_loop
set "OVR_CHOICE="
set /p "OVR_CHOICE=Select (1-4) [4]: "
if "!OVR_CHOICE!"=="" goto run_upload
if "!OVR_CHOICE!"=="4" goto run_upload
if "!OVR_CHOICE!"=="1" goto ovr_request
if "!OVR_CHOICE!"=="2" goto ovr_torrent
if "!OVR_CHOICE!"=="3" goto ovr_desc
echo %RED%Invalid choice!%RESET%
goto override_loop

:ovr_request
echo.
echo  Select upload request file:
echo  1) 📂 Browse (graphical)
echo  2) ✏  Enter path manually
echo.
choice /c 12 /n /m "Select (1-2): "
if errorlevel 2 (
    set /p "REQ_FILE=Path: "
    set "REQ_FILE=!REQ_FILE:"=!"
) else (
    for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "Add-Type -AssemblyName System.Windows.Forms; $f = New-Object System.Windows.Forms.OpenFileDialog; $f.Title = 'Select upload request file'; $f.InitialDirectory = '!OUT_DIR!'; $f.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'; if ($f.ShowDialog() -eq 'OK') { $f.FileName }"`) do set "REQ_FILE=%%I"
)
set "OVR_REQ=1"
echo   Updated: %CYAN%!REQ_FILE!%RESET%
echo.
goto override_loop

:ovr_torrent
echo.
echo  Select torrent file:
echo  1) 📂 Browse (graphical)
echo  2) ✏  Enter path manually
echo.
choice /c 12 /n /m "Select (1-2): "
if errorlevel 2 (
    set /p "TOR_FILE=Path: "
    set "TOR_FILE=!TOR_FILE:"=!"
) else (
    for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "Add-Type -AssemblyName System.Windows.Forms; $f = New-Object System.Windows.Forms.OpenFileDialog; $f.Title = 'Select torrent file'; $f.InitialDirectory = '!OUT_DIR!'; $f.Filter = 'Torrent files (*.torrent)|*.torrent|All files (*.*)|*.*'; if ($f.ShowDialog() -eq 'OK') { $f.FileName }"`) do set "TOR_FILE=%%I"
)
set "OVR_TOR=1"
echo   Updated: %CYAN%!TOR_FILE!%RESET%
echo.
goto override_loop

:ovr_desc
echo.
echo  Select description file:
echo  1) 📂 Browse (graphical)
echo  2) ✏  Enter path manually
echo.
choice /c 12 /n /m "Select (1-2): "
if errorlevel 2 (
    set /p "DESC_FILE=Path: "
    set "DESC_FILE=!DESC_FILE:"=!"
) else (
    for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "Add-Type -AssemblyName System.Windows.Forms; $f = New-Object System.Windows.Forms.OpenFileDialog; $f.Title = 'Select description file'; $f.InitialDirectory = '!OUT_DIR!'; $f.Filter = 'BBCode files (*.bbcode)|*.bbcode|Text files (*.txt)|*.txt|All files (*.*)|*.*'; if ($f.ShowDialog() -eq 'OK') { $f.FileName }"`) do set "DESC_FILE=%%I"
)
set "OVR_DESC=1"
echo   Updated: %CYAN%!DESC_FILE!%RESET%
echo.
goto override_loop

:upl_preview_req
cls
if not exist "!REQ_FILE!" (
    echo %RED%File not found: !REQ_FILE!%RESET%
) else (
    echo %CYAN%=== Upload Request ===%RESET%
    echo.
    type "!REQ_FILE!"
)
echo.
echo  Press any key to return...
pause > nul
rem Flush any extra buffered input
choice /c yn1230 /n /t 0 /d n > nul 2>&1
goto ask_auto

:upl_preview_desc
cls
if not exist "!DESC_FILE!" (
    echo %RED%File not found: !DESC_FILE!%RESET%
    echo.
    echo  Press any key to return...
    pause > nul
    choice /c yn1230 /n /t 0 /d n > nul 2>&1
    goto ask_auto
)
powershell -ExecutionPolicy Bypass -File "%~dp0ps\preview_bbcode.ps1" "!DESC_FILE!"
if not !errorlevel! equ 2 goto upl_preview_desc_done
echo.
echo  1) 🖼  Render with images
echo  0) 🔙 Back
choice /c 10 /n /m "Select (0-1): "
if errorlevel 2 goto upl_preview_desc_done
cls
powershell -ExecutionPolicy Bypass -File "%~dp0ps\preview_bbcode.ps1" "!DESC_FILE!" -images
:upl_preview_desc_done
echo.
echo  Press any key to return...
pause > nul
rem Flush any extra buffered input
choice /c yn1230 /n /t 0 /d n > nul 2>&1
goto ask_auto

:upl_preview_media
cls
if not exist "!MEDIA_FILE!" (
    echo %RED%File not found: !MEDIA_FILE!%RESET%
) else (
    echo %CYAN%=== MediaInfo ===%RESET%
    echo.
    type "!MEDIA_FILE!"
)
echo.
echo  Press any key to return...
pause > nul
rem Flush any extra buffered input
choice /c yn1230 /n /t 0 /d n > nul 2>&1
goto ask_auto

:run_upload
cls
echo %BLUE%========================================%RESET%
echo %BLUE%   UPLOADING TO TRACKER%RESET%
echo %BLUE%========================================%RESET%
echo.

set "OVR_ARGS="
if "!OVR_REQ!"=="1" set "OVR_ARGS=!OVR_ARGS! -r "!REQ_FILE!""
if "!OVR_TOR!"=="1" set "OVR_ARGS=!OVR_ARGS! -t "!TOR_FILE!""
if "!OVR_DESC!"=="1" set "OVR_ARGS=!OVR_ARGS! -d "!DESC_FILE!""
powershell -ExecutionPolicy Bypass -File "%~dp0ps\upload.ps1" !AUTO_FLAG! !OVR_ARGS! "!USER_PATH!"
set "UP_EXIT=!errorlevel!"

echo.
if !UP_EXIT! equ 2 goto upload_cancelled
if not !UP_EXIT! equ 0 goto upload_failed
echo %GREEN%========================================%RESET%
echo %GREEN%   UPLOAD COMPLETED SUCCESSFULLY%RESET%
echo %GREEN%========================================%RESET%
goto after_upload

:upload_cancelled
goto after_upload

:upload_failed
echo %RED%========================================%RESET%
echo %RED%   UPLOAD FAILED - code: !UP_EXIT!%RESET%
echo %RED%========================================%RESET%

:after_upload
echo.
echo  1) 🔄 New upload
echo  2) 🚪 Exit
echo.
choice /c 12 /n /m "Select (1-2): "
if errorlevel 2 goto end
if errorlevel 1 goto menu
goto after_upload

:end
chcp %OLDCP% > nul
exit /b 99
