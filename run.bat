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
echo  6) 🗑  Clear saved paths
echo  7) 📝 Edit torrent
echo  8) 🗑  Delete torrent
echo  9) ❓ Help
echo  0) 🚪 Exit
echo.
set "CHOICE="
set /p "CHOICE=Select (0-9): "

if "%CHOICE%"=="0" goto end
if "%CHOICE%"=="1" goto browse_folder
if "%CHOICE%"=="2" goto browse_file
if "%CHOICE%"=="3" goto manual_path
if "%CHOICE%"=="4" goto use_last
if "%CHOICE%"=="5" goto choose_saved
if "%CHOICE%"=="6" goto clear_saved
if "%CHOICE%"=="7" goto edit_torrent
if "%CHOICE%"=="8" goto delete_torrent
if "%CHOICE%"=="9" goto show_help
echo %RED%Invalid choice!%RESET%
timeout /t 2 > nul
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
for /f "usebackq delims=" %%I in (`powershell -Command "Add-Type -AssemblyName System.Windows.Forms; $f = New-Object System.Windows.Forms.FolderBrowserDialog; $f.Description = 'Select media folder:'; $f.ShowNewFolderButton = $false; $f.RootFolder = [System.Environment+SpecialFolder]::MyComputer; $f.ShowDialog() | Out-Null; if ($f.SelectedPath) { $f.SelectedPath } else { '' }"`) do set "MEDIA_PATH=%%I"

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
for /f "usebackq delims=" %%I in (`powershell -Command "Add-Type -AssemblyName System.Windows.Forms; $f = New-Object System.Windows.Forms.OpenFileDialog; $f.Title = 'Select media file:'; $f.Filter = 'Video files (*.mkv;*.mp4;*.avi)|*.mkv;*.mp4;*.avi|All files (*.*)|*.*'; $f.ShowDialog() | Out-Null; if ($f.FileName) { $f.FileName } else { '' }"`) do set "MEDIA_PATH=%%I"

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
for %%F in ("!MEDIA_PATH!") do if not "%%~xF"=="" set "PATH_LABEL=File"
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
if exist "%LAST_PATH_FILE%" echo  3) 🚀 Upload to tracker (last path)
echo  0) 🚪 Exit
echo.
set "TYPE_CHOICE="
set /p "TYPE_CHOICE=Select [1]: "

if "!TYPE_CHOICE!"=="0" goto end
if "!TYPE_CHOICE!"=="" set "TV_OPTION=" & set "TYPE_LABEL=MOVIE" & goto select_steps
if "!TYPE_CHOICE!"=="1" set "TV_OPTION=" & set "TYPE_LABEL=MOVIE" & goto select_steps
if "!TYPE_CHOICE!"=="2" set "TV_OPTION=-tv" & set "TYPE_LABEL=TV SERIES" & goto select_steps
if "!TYPE_CHOICE!"=="3" goto select_type_upload
echo %RED%Invalid choice!%RESET%
timeout /t 1 > nul
goto select_type

:select_type_upload
if not exist "%LAST_PATH_FILE%" goto select_type
set /p "UPLOAD_PATH="<"%LAST_PATH_FILE%"
echo.
echo %CYAN%Starting upload for: !UPLOAD_PATH!%RESET%
echo.
call "%~dp0upload.bat" "!UPLOAD_PATH!"
goto menu

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
echo  Type 0 to exit.
echo.
set "STEPS_INPUT="
set /p "STEPS_INPUT=Steps: "

if "!STEPS_INPUT!"=="0" goto end
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
echo  0) 🚪 Exit
echo.
set "DHT_CHOICE="
set /p "DHT_CHOICE=Enable DHT? (y/n/0) [n]: "

if "!DHT_CHOICE!"=="0" goto end
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
echo  DHT:    %CYAN%!DHT_LABEL!%RESET%
echo  Steps:  %CYAN%!STEPS_LABEL!%RESET%
echo.
echo  0) 🚪 Exit
echo.
set "CONFIRM="
set /p "CONFIRM=Proceed? (y/n/0) [y]: "
if "!CONFIRM!"=="0" goto end
if "!CONFIRM!"=="" set "CONFIRM=y"
if /i "!CONFIRM!"=="n" goto menu
if /i not "!CONFIRM!"=="y" goto confirm

:execute
cls
echo %BLUE%========================================%RESET%
echo %BLUE%   RUNNING PIPELINE%RESET%
echo %BLUE%========================================%RESET%
echo.

powershell -ExecutionPolicy Bypass -File "%~dp0ps\run.ps1" !TV_OPTION! !DHT_OPTION! !STEPS_OPTION! "!MEDIA_PATH!"
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
echo  1) 🚀 Upload to tracker (using processed path)
echo  2) 🔄 Run another media folder
echo  3) 🚪 Exit
echo.
set "FINAL_CHOICE="
set /p "FINAL_CHOICE=Select (1-3): "

if "!FINAL_CHOICE!"=="1" goto do_upload
if "!FINAL_CHOICE!"=="2" goto menu
if "!FINAL_CHOICE!"=="3" goto end
echo %RED%Invalid choice!%RESET%
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

:clear_saved
if not exist "%SAVED_PATHS_FILE%" goto clear_saved_empty
del "%SAVED_PATHS_FILE%"
echo %GREEN%Saved paths cleared.%RESET%
goto clear_saved_done

:clear_saved_empty
echo %YELLOW%No saved paths found.%RESET%

:clear_saved_done
if exist "%LAST_PATH_FILE%" del "%LAST_PATH_FILE%"
timeout /t 2 > nul
goto menu

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
goto menu

:delete_force
echo.
powershell -ExecutionPolicy Bypass -File "%~dp0ps\delete.ps1" -force "!TORRENT_ID!"
echo.
echo  Press any key to return to menu...
pause > nul
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
set "WELCOME_CHOICE="
set /p "WELCOME_CHOICE=Select (0-1): "

if "!WELCOME_CHOICE!"=="0" goto end
if "!WELCOME_CHOICE!"=="1" goto run_install
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
goto menu

:install_fail
echo %RED%Installation incomplete. Still missing:!MISSING!%RESET%
echo  Press any key to return...
pause > nul
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
echo   6   Clear saved paths
echo   7   Edit an existing torrent by ID
echo   8   Delete a torrent by ID
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
goto menu
