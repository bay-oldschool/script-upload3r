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
echo  3) ✏  Enter path manually
echo  4) 💾 Choose from saved paths
echo  5) 🗑  Clear saved paths
echo  6) 🚪 Exit
echo.
set "choice="
set /p "choice=Select (1-6): "

if "%choice%"=="1" goto use_last
if "%choice%"=="2" goto browse_folder
if "%choice%"=="3" goto enter_manual
if "%choice%"=="4" goto choose_saved
if "%choice%"=="5" goto clear_saved
if "%choice%"=="6" goto end
echo %RED%Invalid choice!%RESET%
timeout /t 2 > nul
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

for /f "usebackq delims=" %%I in (`powershell -Command "Add-Type -AssemblyName System.Windows.Forms; $f = New-Object System.Windows.Forms.FolderBrowserDialog; $f.Description = 'Select the content directory:'; $f.ShowNewFolderButton = $false; $f.RootFolder = [System.Environment+SpecialFolder]::MyComputer; $f.ShowDialog() | Out-Null; if ($f.SelectedPath) { $f.SelectedPath } else { '' }"`) do set "USER_PATH=%%I"

if not "!USER_PATH!"=="" goto save_and_continue
echo.
echo %RED%No folder selected!%RESET%
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
echo  Folder: %CYAN%!UP_FOLDER!%RESET%
echo  Path:   !USER_PATH!
echo.
set "AUTO_CHOICE="
set /p "AUTO_CHOICE=Use auto mode (skip prompts)? (y/n) [n]: "

if /i "!AUTO_CHOICE!"=="y" set "AUTO_FLAG=-auto" & goto run_upload
set "AUTO_FLAG="

:run_upload
cls
echo %BLUE%========================================%RESET%
echo %BLUE%   UPLOADING TO TRACKER%RESET%
echo %BLUE%========================================%RESET%
echo.

powershell -ExecutionPolicy Bypass -File "%~dp0ps\upload.ps1" !AUTO_FLAG! "!USER_PATH!"
set "UP_EXIT=!errorlevel!"

echo.
if not !UP_EXIT! equ 0 goto upload_failed
echo %GREEN%========================================%RESET%
echo %GREEN%   ✅ UPLOAD COMPLETED SUCCESSFULLY%RESET%
echo %GREEN%========================================%RESET%
goto after_upload

:upload_failed
echo %RED%========================================%RESET%
echo %RED%   ❌ UPLOAD FAILED - code: !UP_EXIT!%RESET%
echo %RED%========================================%RESET%

:after_upload
echo.
echo  1) 🔄 New upload
echo  2) 🚪 Exit
echo.
set "after_choice="
set /p "after_choice=Select (1-2): "
if "!after_choice!"=="1" goto menu
if "!after_choice!"=="2" goto end
echo %RED%Invalid choice!%RESET%
goto after_upload

:end
echo.
echo %GREEN%Thank you for using UPLOAD3R!%RESET%
echo.
chcp %OLDCP% > nul
exit /b 0
