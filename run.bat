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

:: If arguments provided, pass directly to run.ps1 (no menu)
if not "%~1"=="" (
    powershell -ExecutionPolicy Bypass -File "%~dp0ps\run.ps1" %*
    chcp %OLDCP% > nul
    exit /b !errorlevel!
)

:: Check if installation is needed
set "MISSING="
if not exist "%~dp0config.jsonc" set "MISSING=!MISSING! config.jsonc"
if not exist "%~dp0tools\ffmpeg.exe" set "MISSING=!MISSING! ffmpeg.exe"
if not exist "%~dp0tools\ffprobe.exe" set "MISSING=!MISSING! ffprobe.exe"
if not exist "%~dp0tools\MediaInfo.exe" set "MISSING=!MISSING! MediaInfo.exe"
if not "!MISSING!"=="" goto welcome

:menu
cls
echo %BLUE%========================================%RESET%
echo %BLUE%   UPLOAD3R - MAIN MENU%RESET%
echo %BLUE%========================================%RESET%
echo.
echo  1) 📂 Browse for folder (graphical)
echo  2) 🎞  Browse for file (graphical)
echo  3) ✏  Enter path manually
echo  4) 🕐 Use last path
echo  5) 💾 Choose from saved paths
echo  6) 🚀 Upload
echo  7) 📝 Edit torrent
echo  8) 🗑  Delete torrent
echo  9) 🔧 Maintenance
echo  0) 🚪 Exit
echo.
choice /c 1234567890 /n /m "Select (0-9): "
if errorlevel 10 goto end
if errorlevel 9 goto maintenance
if errorlevel 8 goto delete_torrent
if errorlevel 7 goto edit_torrent
if errorlevel 6 goto upload_menu
if errorlevel 5 goto choose_saved
if errorlevel 4 goto use_last
if errorlevel 3 goto manual_path
if errorlevel 2 goto browse_file
if errorlevel 1 goto browse_folder
goto menu

:use_last
if not exist "%LAST_PATH_FILE%" goto use_last_empty
set /p MEDIA_PATH=<"%LAST_PATH_FILE%"
echo.
echo  Using: %CYAN%!MEDIA_PATH!%RESET%
goto validate_path

:use_last_empty
echo.
echo %RED%No last path saved!%RESET%
timeout /t 2 > nul
goto menu

:browse_folder
echo.
echo Opening folder browser...
echo.

set "MEDIA_PATH="
for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ps\browse_folder.ps1" -title "Select media folder"`) do set "MEDIA_PATH=%%I"

if not "!MEDIA_PATH!"=="" goto validate_path
echo.
echo %RED%No folder selected!%RESET%
timeout /t 2 > nul
goto menu

:browse_file
echo.
echo Opening file browser...
echo.

set "MEDIA_PATH="
for /f "usebackq delims=" %%I in (`powershell -Command "Add-Type -AssemblyName System.Windows.Forms; $f = New-Object System.Windows.Forms.OpenFileDialog; $f.Title = 'Select media file:'; $f.Filter = 'Video files (*.mkv;*.mp4;*.avi;*.ts)|*.mkv;*.mp4;*.avi;*.ts|All files (*.*)|*.*'; $f.ShowDialog() | Out-Null; if ($f.FileName) { $f.FileName } else { '' }"`) do set "MEDIA_PATH=%%I"

if not "!MEDIA_PATH!"=="" goto validate_path
echo.
echo %RED%No file selected!%RESET%
timeout /t 2 > nul
goto menu

:manual_path
echo.
echo Enter path to media folder:
echo (you can drag and drop the folder here)
echo.
set "MEDIA_PATH="
set /p "MEDIA_PATH=Path: "
set "MEDIA_PATH=!MEDIA_PATH:"=!"

if not "!MEDIA_PATH!"=="" goto validate_path
echo %RED%Error: Path cannot be empty!%RESET%
timeout /t 2 > nul
goto manual_path

:validate_path
if not exist "!MEDIA_PATH!" goto path_not_exist

:: Save to last path
> "%LAST_PATH_FILE%" <nul set /p ="!MEDIA_PATH!"

:: Save to saved paths (if not already there)
if not exist "%SAVED_PATHS_FILE%" goto save_new_run_path
findstr /x /C:"!MEDIA_PATH!" "%SAVED_PATHS_FILE%" >nul 2>&1
if errorlevel 1 >> "%SAVED_PATHS_FILE%" echo !MEDIA_PATH!
goto done_save_path

:save_new_run_path
> "%SAVED_PATHS_FILE%" echo !MEDIA_PATH!

:done_save_path
for %%F in ("!MEDIA_PATH!") do set "ITEM_NAME=%%~nxF"
:: Detect if path is a file or folder
set "PATH_LABEL=Folder"
for /f "usebackq delims=" %%L in (`powershell -NoProfile -Command "if (Test-Path -LiteralPath '!MEDIA_PATH!' -PathType Leaf) { 'File' } else { 'Folder' }"`) do set "PATH_LABEL=%%L"

:: Compute clean query name (same logic as tmdb.ps1)
for /f "delims=" %%Q in ('powershell -NoProfile -Command "$n='!ITEM_NAME!'; $n=$n -replace '[._]',' ' -replace '(?i)\bSEASON\s+\d+\b','' -replace ' - [Ss]\d{2}.*','' -replace '\b[Ss]\d{2}.*','' -replace '\b(19|20)\d{2}\b.*','' -replace ' - WEBDL.*','' -replace ' - WEB-DL.*','' -replace '[\s([]+$',''; Write-Output $n.Trim()"') do set "CLEAN_QUERY=%%Q"

:: Auto-detect year from filename
set "DETECTED_YEAR="
for /f "delims=" %%Y in ('powershell -NoProfile -Command "if ('!ITEM_NAME!' -match '\b(19|20)\d{2}\b') { $matches[0] } else { '' }"') do set "DETECTED_YEAR=%%Y"

:: Auto-detect season number from filename
set "SEASON_NUM="
for /f "delims=" %%S in ('powershell -NoProfile -Command "if ('!ITEM_NAME!' -match '(?i)S(\d+)') { [int]$matches[1] } else { '' }"') do set "SEASON_NUM=%%S"

goto select_type

:path_not_exist
echo.
echo %RED%ERROR: Path does not exist!%RESET%
echo "!MEDIA_PATH!"
echo.
timeout /t 2 > nul
goto menu

:select_type
cls
echo %BLUE%========================================%RESET%
echo %BLUE%   SELECT CONTENT TYPE%RESET%
echo %BLUE%========================================%RESET%
echo.
echo  !PATH_LABEL!: %CYAN%!ITEM_NAME!%RESET%
echo.
echo  1) 🎬 MOVIE
echo  2) 📺 TV SERIES
echo  0) 🚪 Back to main menu
echo.
set "TYPE_CHOICE="
set /p "TYPE_CHOICE=Select [1]: "

if "!TYPE_CHOICE!"=="0" goto menu
if "!TYPE_CHOICE!"=="" set "TV_OPTION=" & set "TYPE_LABEL=MOVIE" & goto select_steps
if "!TYPE_CHOICE!"=="1" set "TV_OPTION=" & set "TYPE_LABEL=MOVIE" & goto select_steps
if "!TYPE_CHOICE!"=="2" set "TV_OPTION=-tv" & set "TYPE_LABEL=TV SERIES" & goto select_steps
echo %RED%Invalid choice!%RESET%
timeout /t 1 > nul
goto select_type

:select_steps
cls
echo %BLUE%========================================%RESET%
echo %BLUE%   STEPS SELECTION%RESET%
echo %BLUE%========================================%RESET%
echo.
echo  Available steps:
echo    1) 📋 parse       - Extract MediaInfo
echo    2) 🧲 create      - Create .torrent file
echo    3) 📸 screens     - Take screenshots
echo    4) 🔍 tmdb        - Search TMDB for metadata
echo    5) ⭐ imdb        - Fetch IMDB details
echo    6) 🤖 describe    - Generate AI description
echo    7) ☁  upload      - Upload screenshots
echo    8) 📝 description - Build final BBCode description
echo.
echo  Enter comma-separated step numbers (e.g. 4,5,8)
echo  or press Enter to run ALL steps.
echo  Type 0 to go back.
echo.
set "STEPS_INPUT="
set /p "STEPS_INPUT=Steps: "

if "!STEPS_INPUT!"=="0" goto select_type
if "!STEPS_INPUT!"=="" set "STEPS_OPTION=" & set "STEPS_LABEL=ALL" & goto select_dht
set "STEPS_OPTION=-steps !STEPS_INPUT!" & set "STEPS_LABEL=!STEPS_INPUT!"

:: Check if step 2 (create torrent) is in the selected steps
echo !STEPS_INPUT! | findstr /C:"2" >nul 2>&1
if not errorlevel 1 goto select_dht
set "DHT_OPTION=" & set "DHT_LABEL=DISABLED" & goto confirm

:select_dht
cls
echo %BLUE%========================================%RESET%
echo %BLUE%   DHT OPTION%RESET%
echo %BLUE%========================================%RESET%
echo.
echo  DHT (Distributed Hash Table) - speeds up distribution
echo  but may cause issues with private trackers.
echo.
echo  0) 🚪 Back
echo.
set "DHT_CHOICE="
set /p "DHT_CHOICE=Enable DHT? (y/n/0) [n]: "

if "!DHT_CHOICE!"=="0" goto select_steps
if "!DHT_CHOICE!"=="" set "DHT_CHOICE=n"

if /i "!DHT_CHOICE!"=="y" set "DHT_OPTION=-dht" & set "DHT_LABEL=ENABLED" & goto confirm
set "DHT_OPTION=" & set "DHT_LABEL=DISABLED"

:confirm
cls
echo %BLUE%========================================%RESET%
echo %BLUE%   CONFIRMATION%RESET%
echo %BLUE%========================================%RESET%
echo.
echo  !PATH_LABEL!: %CYAN%!ITEM_NAME!%RESET%
echo  Path:   !MEDIA_PATH!
echo  Type:   %CYAN%!TYPE_LABEL!%RESET%
:: Check if query/season steps are selected (4=tmdb, 5=imdb, 6=describe)
set "NEED_QUERY="
set "NEED_SEASON="
if "!STEPS_LABEL!"=="ALL" set "NEED_QUERY=1" & set "NEED_SEASON=1"
if not "!NEED_QUERY!"=="1" (
    echo !STEPS_LABEL! | findstr /r "[456]" >nul 2>&1 && set "NEED_QUERY=1"
)
if not "!NEED_SEASON!"=="1" (
    echo !STEPS_LABEL! | findstr /r "[46]" >nul 2>&1 && set "NEED_SEASON=1"
)
if "!NEED_QUERY!"=="1" echo  Query:  %CYAN%!CLEAN_QUERY!%RESET%
if "!NEED_QUERY!"=="1" if not "!DETECTED_YEAR!"=="" echo  Year:   %CYAN%!DETECTED_YEAR!%RESET%
if "!TYPE_LABEL!"=="TV SERIES" if "!NEED_SEASON!"=="1" (
    if "!SEASON_NUM!"=="" (echo  Season: %CYAN%ALL%RESET%) else if "!SEASON_NUM!"=="0" (echo  Season: %CYAN%ALL%RESET%) else (echo  Season: %CYAN%!SEASON_NUM!%RESET%)
)
set "NEED_DHT="
if "!STEPS_LABEL!"=="ALL" set "NEED_DHT=1"
if not "!NEED_DHT!"=="1" echo !STEPS_LABEL! | findstr /C:"2" >nul 2>&1 && set "NEED_DHT=1"
if "!NEED_DHT!"=="1" echo  DHT:    %CYAN%!DHT_LABEL!%RESET%
echo  Steps:  %CYAN%!STEPS_LABEL!%RESET%
echo.
set "QUERY_CHANGED="
set "YEAR_CHANGED="
set "SEASON_CHANGED="
if "!NEED_QUERY!"=="1" (
    set "QUERY_INPUT="
    set /p "QUERY_INPUT=Query [!CLEAN_QUERY!]: "
    if not "!QUERY_INPUT!"=="" set "CLEAN_QUERY=!QUERY_INPUT!" & set "QUERY_CHANGED=1"
)
if "!NEED_QUERY!"=="1" (
    set "YEAR_INPUT="
    if "!DETECTED_YEAR!"=="" (set /p "YEAR_INPUT=Year [auto]: ") else (set /p "YEAR_INPUT=Year [!DETECTED_YEAR!]: ")
    if not "!YEAR_INPUT!"=="" set "DETECTED_YEAR=!YEAR_INPUT!" & set "YEAR_CHANGED=1"
)
if "!TYPE_LABEL!"=="TV SERIES" if "!NEED_SEASON!"=="1" (
    set "SEASON_INPUT="
    if "!SEASON_NUM!"=="" (set /p "SEASON_INPUT=Season [ALL]: ") else if "!SEASON_NUM!"=="0" (set /p "SEASON_INPUT=Season [ALL]: ") else (set /p "SEASON_INPUT=Season [!SEASON_NUM!]: ")
    if not "!SEASON_INPUT!"=="" set "SEASON_NUM=!SEASON_INPUT!" & set "SEASON_CHANGED=1"
)
echo.
echo  0) 🚪 Back to main menu
echo.
set "CONFIRM="
set /p "CONFIRM=Proceed? (y/n/0) [y]: "
if "!CONFIRM!"=="0" goto menu
if "!CONFIRM!"=="" set "CONFIRM=y"
if /i "!CONFIRM!"=="n" goto menu
if /i not "!CONFIRM!"=="y" goto confirm

:execute
cls
echo %BLUE%========================================%RESET%
echo %BLUE%   RUNNING PIPELINE%RESET%
echo %BLUE%========================================%RESET%
echo.

:: Only pass -query/-season if user overrode the defaults
set "QUERY_OPTION="
if "!QUERY_CHANGED!"=="1" if not "!DETECTED_YEAR!"=="" (set "QUERY_OPTION=-query "!CLEAN_QUERY! !DETECTED_YEAR!"") else (set "QUERY_OPTION=-query "!CLEAN_QUERY!"")
if "!YEAR_CHANGED!"=="1" if not "!QUERY_CHANGED!"=="1" if not "!DETECTED_YEAR!"=="" set "QUERY_OPTION=-query "!CLEAN_QUERY! !DETECTED_YEAR!""
set "SEASON_OPTION="
if "!SEASON_CHANGED!"=="1" set "SEASON_OPTION=-season !SEASON_NUM!"

powershell -ExecutionPolicy Bypass -File "%~dp0ps\run.ps1" !TV_OPTION! !DHT_OPTION! !STEPS_OPTION! !QUERY_OPTION! !SEASON_OPTION! "!MEDIA_PATH!"
set "EXIT_CODE=!errorlevel!"

echo.
if not !EXIT_CODE! equ 0 goto execute_failed
echo %GREEN%========================================%RESET%
echo %GREEN%   ✅ PROCESS COMPLETED SUCCESSFULLY%RESET%
echo %GREEN%========================================%RESET%
goto final_menu

:execute_failed
echo %RED%========================================%RESET%
echo %RED%   ❌ PROCESS FAILED - code: !EXIT_CODE!%RESET%
echo %RED%========================================%RESET%

:final_menu
echo.
echo %BLUE%========================================%RESET%
echo %BLUE%   WHAT NEXT?%RESET%
echo %BLUE%========================================%RESET%
echo.
rem Detect torrent name for preview
for /f "usebackq delims=" %%N in (`powershell -NoProfile -Command "if (Test-Path -LiteralPath '!MEDIA_PATH!' -PathType Leaf) { [System.IO.Path]::GetFileNameWithoutExtension('!MEDIA_PATH!') } else { Split-Path -Leaf '!MEDIA_PATH!' }"`) do set "FIN_TORRENT=%%N"
set "FIN_OUT=%~dp0output"
echo  1) 📋 Preview upload request
echo  2) 📝 Preview description
echo  3) ℹ  Preview mediainfo
echo  4) 🚀 Upload to tracker
echo  5) 🔄 Run another media folder
echo  0) 🚪 Exit
echo.
choice /c 123450 /n /m "Select (0-5): "
if errorlevel 6 goto end
if errorlevel 5 goto menu
if errorlevel 4 goto do_upload
if errorlevel 3 goto preview_mediainfo
if errorlevel 2 goto preview_desc
if errorlevel 1 goto preview_request
goto final_menu

:preview_request
cls
set "PRV_FILE=!FIN_OUT!\!FIN_TORRENT!_upload_request.txt"
if not exist "!PRV_FILE!" (
    echo %RED%File not found: !PRV_FILE!%RESET%
) else (
    echo %CYAN%=== Upload Request ===%RESET%
    echo.
    type "!PRV_FILE!"
)
echo.
echo  Press any key to return...
pause > nul
choice /c yn /n /t 0 /d n > nul 2>&1
goto final_menu

:preview_desc
cls
set "PRV_FILE=!FIN_OUT!\!FIN_TORRENT!_torrent_description.bbcode"
if not exist "!PRV_FILE!" (
    echo %RED%File not found: !PRV_FILE!%RESET%
    echo.
    echo  Press any key to return...
    pause > nul
    choice /c yn /n /t 0 /d n > nul 2>&1
    goto final_menu
)
powershell -ExecutionPolicy Bypass -File "%~dp0ps\preview_bbcode.ps1" "!PRV_FILE!"
if not !errorlevel! equ 2 goto preview_desc_done
echo.
echo  1) 🖼  Render with images
echo  0) 🔙 Back
choice /c 10 /n /m "Select (0-1): "
if errorlevel 2 goto preview_desc_done
cls
powershell -ExecutionPolicy Bypass -File "%~dp0ps\preview_bbcode.ps1" "!PRV_FILE!" -images
:preview_desc_done
echo.
echo  Press any key to return...
pause > nul
choice /c yn /n /t 0 /d n > nul 2>&1
goto final_menu

:preview_mediainfo
cls
set "PRV_FILE=!FIN_OUT!\!FIN_TORRENT!_mediainfo.txt"
if not exist "!PRV_FILE!" (
    echo %RED%File not found: !PRV_FILE!%RESET%
) else (
    echo %CYAN%=== MediaInfo ===%RESET%
    echo.
    type "!PRV_FILE!"
)
echo.
echo  Press any key to return...
pause > nul
choice /c yn /n /t 0 /d n > nul 2>&1
goto final_menu

:do_upload
echo.
echo %CYAN%Starting upload for: !MEDIA_PATH!%RESET%
echo.
call "%~dp0upload.bat" "!MEDIA_PATH!"
goto final_menu

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
    set "spath!index!=%%a"
    set /a index+=1
)
echo.
set "path_choice="
set /p "path_choice=Choose number (0 to cancel): "

if "!path_choice!"=="0" goto menu
set "MEDIA_PATH=!spath%path_choice%!"
if "!MEDIA_PATH!"=="" goto invalid_saved
goto validate_path

:invalid_saved
echo %RED%Invalid choice!%RESET%
timeout /t 2 > nul
goto choose_saved

:no_saved_paths
echo.
echo %RED%No saved paths found!%RESET%
timeout /t 2 > nul
goto menu

:upload_menu
cls
echo %BLUE%========================================%RESET%
echo %BLUE%   🚀 UPLOAD%RESET%
echo %BLUE%========================================%RESET%
echo.
echo  1) 🧲 Upload torrent
echo  2) 🔤 Upload subtitle
echo  3) 📋 List last 10 uploads (API)
echo  4) 🌐 List last 10 uploads (Web)
echo  0) 🚪 Back to main menu
echo.
choice /c 12340 /n /m "Select (0-4): "
if errorlevel 5 goto menu
if errorlevel 4 goto list_uploads_web
if errorlevel 3 goto list_uploads
if errorlevel 2 goto subtitle_upload
if errorlevel 1 goto upload_torrent
goto upload_menu

:upload_torrent
echo.
call "%~dp0upload.bat"
if !errorlevel! equ 99 goto upload_menu
echo.
echo  Press any key to return to upload menu...
pause > nul
choice /c yn /n /t 0 /d n > nul 2>&1
goto upload_menu

:list_uploads
echo.
powershell -ExecutionPolicy Bypass -File "%~dp0ps\list_uploads.ps1" 10
echo.
echo  Press any key to return to upload menu...
pause > nul
choice /c yn /n /t 0 /d n > nul 2>&1
goto upload_menu

:list_uploads_web
echo.
powershell -ExecutionPolicy Bypass -File "%~dp0ps\list_uploads_web.ps1" 10
echo.
echo  Press any key to return to upload menu...
pause > nul
choice /c yn /n /t 0 /d n > nul 2>&1
goto upload_menu

:subtitle_upload
cls
echo %BLUE%========================================%RESET%
echo %BLUE%   🔤 UPLOAD SUBTITLE%RESET%
echo %BLUE%========================================%RESET%
echo.
set "TORRENT_ID="
set /p "TORRENT_ID=Enter torrent ID (0 to cancel): "
if "!TORRENT_ID!"=="0" goto upload_menu
if "!TORRENT_ID!"=="" goto subtitle_upload

rem Fetch torrent name from API
set "TOR_NAME="
for /f "usebackq delims=" %%N in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$tid='%TORRENT_ID%'; $cfg = (Get-Content -LiteralPath '%~dp0config.jsonc' | Where-Object { $_ -notmatch '^\s*//' }) -join [char]10 | ConvertFrom-Json; $r = curl.exe -s ($cfg.tracker_url + '/api/torrents/' + $tid + '?api_token=' + $cfg.api_key); try { $d = $r | ConvertFrom-Json; if ($d.attributes.name) { $d.attributes.name } else { '' } } catch { '' }"`) do set "TOR_NAME=%%N"
echo.
if not "!TOR_NAME!"=="" (
    echo  Torrent: %CYAN%!TOR_NAME!%RESET%
    echo.
) else (
    echo  %YELLOW%Could not fetch torrent name from API.%RESET%
    echo.
)
:sub_select_file
echo  1) 📂 Browse for file (graphical)
echo  2) ✏  Enter path manually / drag and drop
echo  0) 🚪 Cancel
echo.
choice /c 120 /n /m "Select (0-2): "
if errorlevel 3 goto upload_menu
if errorlevel 2 goto sub_manual
if errorlevel 1 goto sub_browse
goto sub_select_file

:sub_browse
echo.
echo Opening file browser...
set "SUB_FILE="
for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "Add-Type -AssemblyName System.Windows.Forms; $f = New-Object System.Windows.Forms.OpenFileDialog; $f.Title = 'Select subtitle file'; $f.Filter = 'Subtitle files (*.srt;*.ass;*.ssa;*.sub;*.zip)|*.srt;*.ass;*.ssa;*.sub;*.zip|All files (*.*)|*.*'; if ($f.ShowDialog() -eq 'OK') { $f.FileName }"`) do set "SUB_FILE=%%I"
if "!SUB_FILE!"=="" (
    echo %RED%No file selected!%RESET%
    timeout /t 2 > nul
    goto sub_select_file
)
goto sub_confirm

:sub_manual
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
    goto sub_select_file
)
if not exist "!SUB_FILE!" (
    echo %RED%Error: File not found!%RESET%
    timeout /t 2 > nul
    goto sub_select_file
)

:sub_confirm
echo.
for %%F in ("!SUB_FILE!") do set "SUB_NAME=%%~nxF"
echo  Torrent ID: %CYAN%!TORRENT_ID!%RESET%
echo  File:       %CYAN%!SUB_NAME!%RESET%
echo.
set "SUB_NOTE="
:sub_ask_note
set /p "SUB_NOTE=Note: "
if "!SUB_NOTE!"=="" (
    echo %RED%Error: Note is required!%RESET%
    goto sub_ask_note
)
echo.
powershell -ExecutionPolicy Bypass -File "%~dp0ps\subtitle.ps1" !TORRENT_ID! "!SUB_FILE!" -n "!SUB_NOTE!"
echo.
echo  Press any key to return to upload menu...
pause > nul
choice /c yn /n /t 0 /d n > nul 2>&1
goto upload_menu

:maintenance
cls
echo %BLUE%========================================%RESET%
echo %BLUE%   🔧 MAINTENANCE%RESET%
echo %BLUE%========================================%RESET%
echo.
echo  1) 💾 List saved paths
echo  2) 📂 List output folder
echo  3) 🗑  Clear saved paths
echo  4) 🧹 Clear output folder
echo  5) 📝 Rename _description.txt to .bbcode
echo  6) 🔧 Run install
echo  7) ❓ Help
echo  0) 🚪 Back to main menu
echo.
choice /c 12345670 /n /m "Select (0-7): "
if errorlevel 8 goto menu
if errorlevel 7 goto maint_help
if errorlevel 6 goto maint_install
if errorlevel 5 goto maint_rename_desc
if errorlevel 4 goto maint_clear_output
if errorlevel 3 goto maint_clear_paths
if errorlevel 2 goto maint_list_output
if errorlevel 1 goto maint_list_saved
goto maintenance

:maint_list_saved
echo.
if not exist "%SAVED_PATHS_FILE%" (
    echo %YELLOW%No saved paths found.%RESET%
) else (
    echo %CYAN%Saved paths:%RESET%
    set "idx=1"
    for /f "usebackq delims=" %%a in ("%SAVED_PATHS_FILE%") do (
        echo   !idx!^) %%a
        set /a idx+=1
    )
)
if exist "%LAST_PATH_FILE%" (
    set /p "LAST_P="<"%LAST_PATH_FILE%"
    echo.
    echo %CYAN%Last path:%RESET% !LAST_P!
)
echo.
echo  Press any key to return to maintenance...
pause > nul
choice /c yn /n /t 0 /d n > nul 2>&1
goto maintenance

:maint_list_output
echo.
set "OUTPUT_DIR=%~dp0output"
if not exist "!OUTPUT_DIR!" (
    echo %YELLOW%Output folder does not exist.%RESET%
) else (
    echo %CYAN%Output folder contents:%RESET%
    for %%F in ("!OUTPUT_DIR!\*") do (
        if /i not "%%~nxF"==".last_path.txt" if /i not "%%~nxF"==".saved_paths.txt" if /i not "%%~nxF"==".gitkeep" echo   %%~nxF
    )
    for /d %%D in ("!OUTPUT_DIR!\*") do echo   %%~nxD\
)
echo.
echo  Press any key to return to maintenance...
pause > nul
choice /c yn /n /t 0 /d n > nul 2>&1
goto maintenance

:maint_clear_paths
if not exist "%SAVED_PATHS_FILE%" goto maint_clear_paths_empty
del "%SAVED_PATHS_FILE%"
echo %GREEN%Saved paths cleared.%RESET%
goto maint_clear_paths_done

:maint_clear_paths_empty
echo %YELLOW%No saved paths found.%RESET%

:maint_clear_paths_done
if exist "%LAST_PATH_FILE%" del "%LAST_PATH_FILE%"
timeout /t 2 > nul
goto maintenance

:maint_clear_output
set "OUTPUT_DIR=%~dp0output"
if not exist "!OUTPUT_DIR!" (
    echo %YELLOW%Output folder does not exist.%RESET%
    timeout /t 2 > nul
    goto maintenance
)
echo.
set "CLEAR_CONFIRM="
set /p "CLEAR_CONFIRM=Delete all files in output folder? (y/n) [n]: "
if /i not "!CLEAR_CONFIRM!"=="y" goto maintenance
for %%F in ("!OUTPUT_DIR!\*") do (
    if /i not "%%~nxF"==".last_path.txt" if /i not "%%~nxF"==".saved_paths.txt" if /i not "%%~nxF"==".gitkeep" del /q "%%F" 2>nul
)
for /d %%D in ("!OUTPUT_DIR!\*") do rmdir /s /q "%%D" 2>nul
echo %GREEN%Output folder cleared.%RESET%
timeout /t 2 > nul
goto maintenance

:maint_rename_desc
powershell -ExecutionPolicy Bypass -File "%~dp0ps\rename_desc.ps1"
echo.
echo  Press any key to return to maintenance...
pause > nul
choice /c yn /n /t 0 /d n > nul 2>&1
goto maintenance

:maint_help
cls
powershell -ExecutionPolicy Bypass -File "%~dp0ps\help.ps1"
echo  Press any key to return to maintenance...
pause > nul
choice /c yn /n /t 0 /d n > nul 2>&1
goto maintenance

:maint_install
echo.
call "%~dp0install.bat"
echo.
echo  Press any key to return to maintenance...
pause > nul
choice /c yn /n /t 0 /d n > nul 2>&1
goto maintenance

:edit_torrent
cls
echo %BLUE%========================================%RESET%
echo %BLUE%   📝 EDIT TORRENT%RESET%
echo %BLUE%========================================%RESET%
echo.
set "TORRENT_ID="
set /p "TORRENT_ID=Enter torrent ID (0 to cancel): "
if "!TORRENT_ID!"=="0" goto menu
if "!TORRENT_ID!"=="" goto edit_torrent
echo.
powershell -ExecutionPolicy Bypass -File "%~dp0ps\edit.ps1" "!TORRENT_ID!"
echo.
echo  Press any key to return to menu...
pause > nul
choice /c yn /n /t 0 /d n > nul 2>&1
goto menu

:delete_torrent
cls
echo %BLUE%========================================%RESET%
echo %BLUE%   🗑️  DELETE TORRENT%RESET%
echo %BLUE%========================================%RESET%
echo.
set "TORRENT_ID="
set /p "TORRENT_ID=Enter torrent ID (0 to cancel): "
if "!TORRENT_ID!"=="0" goto menu
if "!TORRENT_ID!"=="" goto delete_torrent
echo.
powershell -ExecutionPolicy Bypass -File "%~dp0ps\delete.ps1" "!TORRENT_ID!"
if not !errorlevel! equ 0 goto delete_ask_force
echo.
echo  Press any key to return to menu...
pause > nul
choice /c yn /n /t 0 /d n > nul 2>&1
goto menu

:delete_ask_force
echo.
set "FORCE_CHOICE="
set /p "FORCE_CHOICE=Try force delete (skip API lookup)? (y/n) [y]: "
if "!FORCE_CHOICE!"=="" goto delete_force
if /i "!FORCE_CHOICE!"=="y" goto delete_force
echo.
echo  Press any key to return to menu...
pause > nul
choice /c yn /n /t 0 /d n > nul 2>&1
goto menu

:delete_force
echo.
powershell -ExecutionPolicy Bypass -File "%~dp0ps\delete.ps1" -force "!TORRENT_ID!"
echo.
echo  Press any key to return to menu...
pause > nul
choice /c yn /n /t 0 /d n > nul 2>&1
goto menu

:welcome
cls
echo %BLUE%========================================%RESET%
echo %BLUE%   WELCOME TO UPLOAD3R%RESET%
echo %BLUE%========================================%RESET%
echo.
echo  It looks like this is your first time
echo  running UPLOAD3R, or the installation
echo  is incomplete.
echo.
echo  Missing:!MISSING!
echo.
echo  The installer will download required
echo  tools and create the config file.
echo.
echo  1) 🔧 Run install
echo  0) 🚪 Exit
echo.
choice /c 10 /n /m "Select (0-1): "
if errorlevel 2 goto end
if errorlevel 1 goto run_install
goto welcome

:run_install
echo.
call "%~dp0install.bat"
echo.
set "MISSING="
if not exist "%~dp0config.jsonc" set "MISSING=!MISSING! config.jsonc"
if not exist "%~dp0tools\ffmpeg.exe" set "MISSING=!MISSING! ffmpeg.exe"
if not exist "%~dp0tools\ffprobe.exe" set "MISSING=!MISSING! ffprobe.exe"
if not exist "%~dp0tools\MediaInfo.exe" set "MISSING=!MISSING! MediaInfo.exe"
if not "!MISSING!"=="" goto install_fail
echo %GREEN%Installation complete!%RESET%
echo  Press any key to continue to menu...
pause > nul
choice /c yn /n /t 0 /d n > nul 2>&1
goto menu

:install_fail
echo %RED%Installation incomplete. Still missing:!MISSING!%RESET%
echo  Press any key to return...
pause > nul
choice /c yn /n /t 0 /d n > nul 2>&1
goto welcome

:end
echo.
echo %GREEN%Thank you for using UPLOAD3R!%RESET%
echo.
chcp %OLDCP% > nul
exit /b 0

:show_help
cls
echo %BLUE%========================================%RESET%
echo %BLUE%   HELP%RESET%
echo %BLUE%========================================%RESET%
echo.
echo  UPLOAD3R automates the full media upload
echo  pipeline: from MediaInfo extraction to
echo  torrent creation and tracker upload.
echo.
echo  %CYAN%MENU OPTIONS:%RESET%
echo  1-3  Select media (folder, file, or manual path)
echo   4   Reuse last path
echo   5   Pick from saved paths
echo   6   Upload (torrent or subtitle)
echo   7   Edit an existing torrent by ID
echo   8   Delete a torrent by ID
echo   9   Maintenance (clear paths, output, install)
echo.
echo  %CYAN%PIPELINE STEPS:%RESET%
echo  1. Choose content type (Movie / TV Series)
echo  2. Choose which steps to run (or all)
echo  3. Enable DHT (only if torrent create step)
echo  4. Confirm and run
echo  5. Optionally upload to tracker after processing
echo.
echo  %CYAN%PIPELINE STAGES:%RESET%
echo  1) parse       - Extract MediaInfo
echo  2) create      - Create .torrent file
echo  3) screens     - Take screenshots
echo  4) tmdb        - Search TMDB for metadata
echo  5) imdb        - Fetch IMDB details
echo  6) describe    - Generate AI description
echo  7) upload      - Upload screenshots
echo  8) description - Build final BBCode description
echo.
echo  %CYAN%CLI USAGE:%RESET%
echo  run.bat [options] "path"
echo  Options: -tv -dht -steps 1,2,3 -query "name"
echo.
echo  %CYAN%REQUIREMENTS:%RESET%
echo  - config.jsonc (run install if missing)
echo  - tools: ffmpeg, ffprobe, MediaInfo
echo.
echo  Press any key to return to menu...
pause > nul
choice /c yn /n /t 0 /d n > nul 2>&1
goto menu
