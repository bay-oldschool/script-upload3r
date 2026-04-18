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

:: Detect Windows build number (used for emoji support + PATH refresh)
set "WINBUILD=0"
for /f "tokens=2 delims=[]" %%v in ('ver') do for /f "tokens=3 delims=." %%b in ("%%v") do set "WINBUILD=%%b"

:: On Win10 1803+ (build 17763, where winget exists), refresh PATH from registry
:: so winget-installed tools are found without restarting the terminal.
:: Skip on older builds where reg query is slow and winget doesn't exist anyway.
if !WINBUILD! GEQ 17763 (
    for /f "tokens=2*" %%A in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" /v Path 2^>nul') do set "SYS_PATH=%%B"
    for /f "tokens=2*" %%A in ('reg query "HKCU\Environment" /v Path 2^>nul') do set "USR_PATH=%%B"
    set "PATH=%~dp0tools;!SYS_PATH!;!USR_PATH!;%LOCALAPPDATA%\Microsoft\WindowsApps"
    call set "PATH=!PATH!"
) else (
    set "PATH=%~dp0tools;%PATH%"
)
if defined WT_SESSION goto emoji_icons
if !WINBUILD! GEQ 22000 goto emoji_icons
goto ascii_icons

:emoji_icons
set "I_FOLDER=📂" & set "I_FILM=🎞 " & set "I_PENCIL=✏ " & set "I_CLOCK=🕐" & set "I_SAVE=💾"
set "I_ROCKET=🚀" & set "I_MEMO=📝" & set "I_TRASH=🗑 " & set "I_WRENCH=🔧" & set "I_DOOR=🚪"
set "I_MOVIE=🎬" & set "I_TV=📺" & set "I_GAME=🎮" & set "I_PC=💻" & set "I_MUSIC=🎸"
set "I_MAGNET=🧲" & set "I_SEARCH=🔍" & set "I_AI=🤖" & set "I_LIST=📋" & set "I_CAMERA=📸"
set "I_STAR=⭐" & set "I_CLOUD=☁ " & set "I_PAGE=📄" & set "I_DISC=💿" & set "I_IMAGE=🖼 "
set "I_LAND=🏞 " & set "I_BACK=🔙" & set "I_TEXT=🔤" & set "I_WEB=🌐" & set "I_BOOK=📖"
set "I_TAG=🏷 " & set "I_EYE=👁 " & set "I_LOCK=🔒" & set "I_OK=✅" & set "I_FAIL=❌"
set "I_HELP=❓" & set "I_BROOM=🧹" & set "I_SKIP=⏭ " & set "I_INFO=ℹ "
goto icons_done

:ascii_icons
set "I_FOLDER=-" & set "I_FILM=-" & set "I_PENCIL=-" & set "I_CLOCK=-" & set "I_SAVE=-"
set "I_ROCKET=-" & set "I_MEMO=-" & set "I_TRASH=-" & set "I_WRENCH=-" & set "I_DOOR=-"
set "I_MAGNET=-" & set "I_SEARCH=-" & set "I_AI=-" & set "I_LIST=-" & set "I_CAMERA=-"
set "I_STAR=-" & set "I_CLOUD=-" & set "I_PAGE=-" & set "I_DISC=-" & set "I_IMAGE=-"
set "I_LAND=-" & set "I_BACK=-" & set "I_TEXT=-" & set "I_WEB=-" & set "I_BOOK=-"
set "I_TAG=-" & set "I_EYE=-" & set "I_LOCK=-" & set "I_HELP=-" & set "I_BROOM=-"
set "I_SKIP=-" & set "I_INFO=-"
set "I_MOVIE=[M]" & set "I_TV=[T]" & set "I_GAME=[G]" & set "I_PC=[S]" & set "I_MUSIC=[~]"
set "I_OK=[OK]" & set "I_FAIL=[XX]"

:icons_done

set "LAST_PATH_FILE=%~dp0output\.last_path.txt"
set "SAVED_PATHS_FILE=%~dp0output\.saved_paths.txt"
set "TMPPATH=%TEMP%\_media_path.tmp"

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
:: curl is built into Windows 1803+; otherwise install.ps1 drops it into tools/
where curl.exe >nul 2>&1 || set "MISSING=!MISSING! curl.exe"
if not "!MISSING!"=="" goto welcome

:read_config
:: Read logo settings from config (defaults: show=1, source=text, width=80, letters=160, dark=210, light=95)
set "SHOW_LOGO=1"
set "LOGO_SOURCE=text"
set "LOGO_DISPLAY=ansi"
set "LOGO_WIDTH=80"
set "LOGO_CLR_R=160"
set "LOGO_CLR_D=210"
set "LOGO_CLR_L=95"
set "LOGO_IMG_CFG="
for /f "usebackq delims=" %%L in ("%~dp0config.jsonc") do (
    set "LINE=%%L"
    if not "!LINE:show_logo=!"=="!LINE!" for /f "tokens=2 delims=:" %%V in ("!LINE!") do set "TMPVAL=%%V" & set "TMPVAL=!TMPVAL: =!" & set "SHOW_LOGO=!TMPVAL:,=!"
    if not "!LINE:logo_source=!"=="!LINE!" for /f "tokens=2 delims=:" %%V in ("!LINE!") do set "TMPVAL=%%V" & set "TMPVAL=!TMPVAL: =!" & set "LOGO_SOURCE=!TMPVAL:,=!"
    if not "!LINE:logo_display=!"=="!LINE!" for /f "tokens=2 delims=:" %%V in ("!LINE!") do set "TMPVAL=%%V" & set "TMPVAL=!TMPVAL: =!" & set "LOGO_DISPLAY=!TMPVAL:,=!"
    if not "!LINE:logo_width=!"=="!LINE!" for /f "tokens=2 delims=:" %%V in ("!LINE!") do set "TMPVAL=%%V" & set "TMPVAL=!TMPVAL: =!" & set "LOGO_WIDTH=!TMPVAL:,=!"
    if not "!LINE:logo_color_letters=!"=="!LINE!" for /f "tokens=2 delims=:" %%V in ("!LINE!") do set "TMPVAL=%%V" & set "TMPVAL=!TMPVAL: =!" & set "LOGO_CLR_R=!TMPVAL:,=!"
    if not "!LINE:logo_color_dark=!"=="!LINE!" for /f "tokens=2 delims=:" %%V in ("!LINE!") do set "TMPVAL=%%V" & set "TMPVAL=!TMPVAL: =!" & set "LOGO_CLR_D=!TMPVAL:,=!"
    if not "!LINE:logo_color_light=!"=="!LINE!" for /f "tokens=2 delims=:" %%V in ("!LINE!") do set "TMPVAL=%%V" & set "TMPVAL=!TMPVAL: =!" & set "LOGO_CLR_L=!TMPVAL:,=!"
)
:: Parse logo_image_path separately (value may contain colons / slashes). Skip commented lines.
for /f "usebackq tokens=* delims=" %%L in (`findstr /r /c:"^[ 	]*\"logo_image_path\"" "%~dp0config.jsonc"`) do set "_LIP_LINE=%%L"
if defined _LIP_LINE (
    set _LIP=!_LIP_LINE:*": "=!
    set _LIP=!_LIP:",=!
    set _LIP=!_LIP:"=!
    set "LOGO_IMG_CFG=!_LIP!"
)
:: Resolve LOGO_IMG: absolute if contains drive letter, else relative to script dir. Fallback to shared\logo.png.
set "LOGO_IMG=%~dp0shared\logo.png"
if defined LOGO_IMG_CFG (
    set "_LIP_RESOLVED=!LOGO_IMG_CFG:/=\!"
    echo !_LIP_RESOLVED! | findstr /r /c:"^[A-Za-z]:" >nul
    if errorlevel 1 (
        set "_LIP_RESOLVED=%~dp0!_LIP_RESOLVED!"
    )
    if exist "!_LIP_RESOLVED!" set "LOGO_IMG=!_LIP_RESOLVED!"
)
set "CLR_R=%ESC%[38;5;!LOGO_CLR_R!m"
set "CLR_D=%ESC%[38;5;!LOGO_CLR_D!m"
set "CLR_L=%ESC%[38;5;!LOGO_CLR_L!m"
:: Check image tools once, fall back to text if neither found
:: Fast file checks first, slow 'where' (PATH search) only as fallback
set "HAS_CHAFA=0"
set "HAS_MAGICK=0"
if exist "%~dp0tools\chafa.exe" (set "HAS_CHAFA=1" & set "PATH=%~dp0tools;!PATH!") else (where chafa.exe >nul 2>&1 && set "HAS_CHAFA=1")
if "!HAS_CHAFA!"=="0" for /d %%D in ("%LOCALAPPDATA%\Microsoft\WinGet\Packages\hpjansson.Chafa_*") do for /d %%S in ("%%D\chafa-*") do if exist "%%S\Chafa.exe" set "HAS_CHAFA=1" & set "PATH=%%S;!PATH!"
for /d %%D in ("C:\Program Files\ImageMagick-*") do if exist "%%D\magick.exe" set "HAS_MAGICK=1" & set "PATH=%%D;!PATH!"
if "!HAS_MAGICK!"=="0" where magick.exe >nul 2>&1 && set "HAS_MAGICK=1"
if /i !LOGO_SOURCE!=="image" if "!HAS_CHAFA!"=="0" if "!HAS_MAGICK!"=="0" set "LOGO_SOURCE=text"
:: Win10 conhost (build < 22000, no WT_SESSION) has limited ANSI support — image logo can freeze
if /i !LOGO_SOURCE!=="image" if !WINBUILD! LSS 22000 if not defined WT_SESSION set "LOGO_SOURCE=text"
if "!_GOTO_AFTER_CONFIG!"=="maintenance" set "_GOTO_AFTER_CONFIG=" & goto maintenance

:menu
cls
if "!SHOW_LOGO!"=="0" goto skip_logo
echo.
if /i not !LOGO_SOURCE!=="image" goto logo_text
if /i !LOGO_DISPLAY!=="direct" goto logo_direct
if /i !LOGO_DISPLAY!=="ansi" goto logo_ansi
if /i !LOGO_DISPLAY!=="block" goto logo_block
if /i !LOGO_DISPLAY!=="ascii" goto logo_ascii
goto logo_ansi
:logo_direct
if "!HAS_CHAFA!"=="0" goto logo_direct_magick
chafa --format sixel -s !LOGO_WIDTH!x --fg-only "!LOGO_IMG!"
goto skip_logo_text
:logo_direct_magick
if "!HAS_MAGICK!"=="0" goto logo_text
set /a LOGO_PX=!LOGO_WIDTH! * 8
magick "!LOGO_IMG!" -fuzz 10%% -transparent white -resize !LOGO_PX!x sixel:-
echo.
goto skip_logo_text
:logo_ansi
if "!HAS_CHAFA!"=="0" goto logo_ansi_magick
chafa --format symbols -s !LOGO_WIDTH!x --symbols block+border+space --color-space din99d "!LOGO_IMG!"
goto skip_logo_text
:logo_ansi_magick
if "!HAS_MAGICK!"=="0" goto logo_text
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ps\logo_image.ps1" -Width !LOGO_WIDTH! -Path "!LOGO_IMG!"
goto skip_logo_text
:logo_block
if "!HAS_CHAFA!"=="0" goto logo_text
chafa --format symbols -s !LOGO_WIDTH!x --symbols block+space --fg-only "!LOGO_IMG!"
goto skip_logo_text
:logo_ascii
if "!HAS_CHAFA!"=="0" goto logo_text
chafa --format symbols -s !LOGO_WIDTH!x --symbols ascii --fg-only "!LOGO_IMG!"
goto skip_logo_text
:logo_text
for /f "usebackq delims=" %%L in ("%~dp0shared\logo.txt") do (
    set "LINE=%%L"
    set "LINE=!LINE:{R}=%CLR_R%!"
    set "LINE=!LINE:{D}=%CLR_D%!"
    set "LINE=!LINE:{L}=%CLR_L%!"
    set "LINE=!LINE:{0}=%RESET%!"
    echo !LINE!
)
:skip_logo_text
echo.
:skip_logo
echo %BLUE%========================================%RESET%
echo %BLUE%   SCRIPT UPLOAD3R - MAIN MENU%RESET%
echo %BLUE%========================================%RESET%
echo.
echo  1) !I_FOLDER! Browse for folder (graphical)
echo  2) !I_FILM! Browse for file (graphical)
echo  3) !I_PENCIL! Enter path manually
echo  4) !I_CLOCK! Use last path
echo  5) !I_SAVE! Choose from saved paths
echo  6) !I_ROCKET! Upload
echo  7) !I_MEMO! Edit torrent
echo  8) !I_TRASH! Delete torrent
echo  9) !I_WRENCH! Maintenance
echo  0) !I_DOOR! Exit
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
powershell -NoProfile -Command "Write-Host ('  Using: ' + $env:MEDIA_PATH) -ForegroundColor Cyan"
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
setlocal disabledelayedexpansion
for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ps\browse_folder.ps1" -title "Select media folder"`) do >"%TMPPATH%" echo %%I
endlocal
if exist "%TMPPATH%" (set /p MEDIA_PATH=<"%TMPPATH%" & del "%TMPPATH%")
powershell -NoProfile -Command "if ($env:MEDIA_PATH) { exit 0 } else { exit 1 }" && goto validate_path
echo.
echo %RED%No folder selected!%RESET%
timeout /t 2 > nul
goto menu

:browse_file
echo.
echo Opening file browser...
echo.

set "MEDIA_PATH="
setlocal disabledelayedexpansion
for /f "usebackq delims=" %%I in (`powershell -Command "Add-Type -AssemblyName System.Windows.Forms; $f = New-Object System.Windows.Forms.OpenFileDialog; $f.Title = 'Select media file:'; $f.Filter = 'Video files (*.mkv;*.mp4;*.avi;*.ts)|*.mkv;*.mp4;*.avi;*.ts|All files (*.*)|*.*'; $f.ShowDialog() | Out-Null; if ($f.FileName) { $f.FileName } else { '' }"`) do >"%TMPPATH%" echo %%I
endlocal
if exist "%TMPPATH%" (set /p MEDIA_PATH=<"%TMPPATH%" & del "%TMPPATH%")
powershell -NoProfile -Command "if ($env:MEDIA_PATH) { exit 0 } else { exit 1 }" && goto validate_path
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
:: Strip quotes and preserve ! via PowerShell temp file
powershell -NoProfile -Command "$p = $env:MEDIA_PATH.Trim('""', ' '); if ($p) { [IO.File]::WriteAllText('%TMPPATH%', $p); exit 0 } else { exit 1 }"
if errorlevel 1 goto manual_path_empty
set /p MEDIA_PATH=<"%TMPPATH%"
del "%TMPPATH%" 2>nul
goto validate_path
:manual_path_empty
echo %RED%Error: Path cannot be empty!%RESET%
timeout /t 2 > nul
goto manual_path

:validate_path
:: Single PowerShell call: validate path, save paths, get item name, path type, and clean query
for /f "usebackq tokens=1,2,* delims=|" %%A in (`powershell -NoProfile -Command "$p=$env:MEDIA_PATH; if (-not (Test-Path -LiteralPath $p)) { exit 1 }; [IO.File]::WriteAllText('%LAST_PATH_FILE%',$p); $sf='%SAVED_PATHS_FILE%'; if (Test-Path $sf) { $lines=[IO.File]::ReadAllLines($sf); if ($lines -notcontains $p) { [IO.File]::AppendAllText($sf,$p+[Environment]::NewLine) } } else { [IO.File]::WriteAllText($sf,$p+[Environment]::NewLine) }; $leaf=Split-Path -Leaf $p; $pt=if(Test-Path -LiteralPath $p -PathType Leaf){'File'}else{'Folder'}; $n=$leaf -replace '[._]',' ' -replace '(?i)\bSEASON\s+\d+\b','' -replace ' - [Ss]\d{2}.*','' -replace '\b[Ss]\d{2}.*','' -replace '\b(19|20)\d{2}\b.*','' -replace '(?i)\b(2160|1080|720|480|360)[pi]\b.*','' -replace '(?i)\b(WEBRip|WEB-DL|WEBDL|BluRay|BDRip|BRRip|HDRip|HDTV|DVDRip|REMUX|WEB)\b.*','' -replace '[\s([]+$',''; Write-Output ($leaf+'|'+$pt+'|'+$n.Trim())"`) do (
    set "ITEM_NAME=%%A"
    set "PATH_LABEL=%%B"
    set "CLEAN_QUERY=%%C"
)
if not defined ITEM_NAME goto path_not_exist

:: Auto-detect year from filename
set "DETECTED_YEAR="
for /f "usebackq delims=" %%Y in (`powershell -NoProfile -Command "if ($env:ITEM_NAME -match '\b(19|20)\d{2}\b') { $matches[0] } else { '' }"`) do set "DETECTED_YEAR=%%Y"

:: Auto-detect season number from filename
set "SEASON_NUM="
for /f "usebackq delims=" %%S in (`powershell -NoProfile -Command "if ($env:ITEM_NAME -match '(?i)S(\d+)') { [int]$matches[1] } else { '' }"`) do set "SEASON_NUM=%%S"

goto select_type

:path_not_exist
echo.
echo %RED%ERROR: Path does not exist!%RESET%
powershell -NoProfile -Command "Write-Host $env:MEDIA_PATH"
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
echo  1) !I_MOVIE! MOVIE
echo  2) !I_TV! TV SERIES
echo  3) !I_GAME! GAME
echo  4) !I_PC! SOFTWARE
echo  5) !I_MUSIC! MUSIC
echo  0) !I_DOOR! Back to main menu
echo.
choice /c 123450 /n /m "Select (0-5): "
if errorlevel 6 goto menu
if errorlevel 5 goto select_steps_music
if errorlevel 4 goto select_steps_software
if errorlevel 3 goto select_steps_game
if errorlevel 2 set "TV_OPTION=-tv" & set "TYPE_LABEL=TV SERIES" & goto select_steps
if errorlevel 1 set "TV_OPTION=" & set "TYPE_LABEL=MOVIE" & goto select_steps
goto select_type

:select_steps_game
set "TYPE_LABEL=GAME"
set "POSTER_VALUE="
set "PIPELINE_SCRIPT=run_game.ps1"
set "CREATE_STEP=1"
set "STEPS_BACK=select_steps_game"
set "CONFIRM_TARGET=simple_confirm"
cls
echo %BLUE%========================================%RESET%
echo %BLUE%   GAME STEPS SELECTION%RESET%
echo %BLUE%========================================%RESET%
echo.
echo  Available steps:
echo    1) !I_MAGNET! create      - Create .torrent file
echo    2) !I_SEARCH! igdb        - Search IGDB for metadata
echo    3) !I_AI! describe    - Generate AI description
echo    4) !I_MEMO! description - Build final BBCode description
echo.
echo  Enter comma-separated step numbers (e.g. 2,3,4)
echo  or press Enter to run ALL steps.
echo  Type 0 to go back.
echo.
set "STEPS_INPUT="
set /p "STEPS_INPUT=Steps: "
if "!STEPS_INPUT!"=="0" goto select_type
if "!STEPS_INPUT!"=="" set "STEPS_OPTION=" & set "STEPS_LABEL=ALL" & goto select_dht
set "STEPS_OPTION=-steps !STEPS_INPUT!" & set "STEPS_LABEL=!STEPS_INPUT!"
echo !STEPS_INPUT! | findstr /C:"!CREATE_STEP!" >nul 2>&1
if not errorlevel 1 goto select_dht
set "DHT_OPTION=" & set "DHT_LABEL=DISABLED" & goto simple_confirm

:select_steps_software
set "TYPE_LABEL=SOFTWARE"
set "POSTER_VALUE="
set "PIPELINE_SCRIPT=run_software.ps1"
set "CREATE_STEP=1"
set "STEPS_BACK=select_steps_software"
set "CONFIRM_TARGET=simple_confirm"
cls
echo %BLUE%========================================%RESET%
echo %BLUE%   SOFTWARE STEPS SELECTION%RESET%
echo %BLUE%========================================%RESET%
echo.
echo  Available steps:
echo    1) !I_MAGNET! create      - Create .torrent file
echo    2) !I_AI! describe    - Generate AI description
echo    3) !I_MEMO! description - Build final BBCode description
echo.
echo  Enter comma-separated step numbers (e.g. 2,3)
echo  or press Enter to run ALL steps.
echo  Type 0 to go back.
echo.
set "STEPS_INPUT="
set /p "STEPS_INPUT=Steps: "
if "!STEPS_INPUT!"=="0" goto select_type
if "!STEPS_INPUT!"=="" set "STEPS_OPTION=" & set "STEPS_LABEL=ALL" & goto select_dht
set "STEPS_OPTION=-steps !STEPS_INPUT!" & set "STEPS_LABEL=!STEPS_INPUT!"
echo !STEPS_INPUT! | findstr /C:"!CREATE_STEP!" >nul 2>&1
if not errorlevel 1 goto select_dht
set "DHT_OPTION=" & set "DHT_LABEL=DISABLED" & goto simple_confirm

:select_steps_music
set "TYPE_LABEL=MUSIC"
set "POSTER_VALUE="
set "PIPELINE_SCRIPT=run_music.ps1"
set "CREATE_STEP=2"
set "STEPS_BACK=select_steps_music"
set "CONFIRM_TARGET=simple_confirm"
cls
echo %BLUE%========================================%RESET%
echo %BLUE%   MUSIC STEPS SELECTION%RESET%
echo %BLUE%========================================%RESET%
echo.
echo  Available steps:
echo    1) !I_LIST! parse       - Extract MediaInfo
echo    2) !I_MAGNET! create      - Create .torrent file
echo    3) !I_SEARCH! metadata    - Search Deezer/MusicBrainz for metadata
echo    4) !I_AI! describe    - Generate AI description
echo    5) !I_MEMO! description - Build final BBCode description
echo.
echo  Enter comma-separated step numbers (e.g. 3,4,5)
echo  or press Enter to run ALL steps.
echo  Type 0 to go back.
echo.
set "STEPS_INPUT="
set /p "STEPS_INPUT=Steps: "
if "!STEPS_INPUT!"=="0" goto select_type
if "!STEPS_INPUT!"=="" set "STEPS_OPTION=" & set "STEPS_LABEL=ALL" & goto select_dht
set "STEPS_OPTION=-steps !STEPS_INPUT!" & set "STEPS_LABEL=!STEPS_INPUT!"
echo !STEPS_INPUT! | findstr /C:"!CREATE_STEP!" >nul 2>&1
if not errorlevel 1 goto select_dht
set "DHT_OPTION=" & set "DHT_LABEL=DISABLED" & goto simple_confirm

:: Shared confirm + execute for game/software/music pipelines
:simple_confirm
cls
echo %BLUE%========================================%RESET%
echo %BLUE%   CONFIRMATION%RESET%
echo %BLUE%========================================%RESET%
echo.
echo  !PATH_LABEL!: %CYAN%!ITEM_NAME!%RESET%
powershell -NoProfile -Command "Write-Host ('  Path:   ' + $env:MEDIA_PATH)"
echo  Type:   %CYAN%!TYPE_LABEL!%RESET%
echo  Steps:  %CYAN%!STEPS_LABEL!%RESET%
echo  DHT:    %CYAN%!DHT_LABEL!%RESET%
if not "!POSTER_VALUE!"=="" echo  Poster: %CYAN%!POSTER_VALUE!%RESET%
echo.
set "QUERY_INPUT="
set /p "QUERY_INPUT=Search title [auto]: "
set "PS_QUERY=!QUERY_INPUT!"
:: Ask for year override (music only)
set "YEAR_OPTION="
if "!TYPE_LABEL!"=="MUSIC" (
    echo.
    set "YEAR_INPUT="
    set /p "YEAR_INPUT=Release year [auto]: "
    if not "!YEAR_INPUT!"=="" set "YEAR_OPTION=-year !YEAR_INPUT!"
)
:: Ask for poster image (file path, URL, or browse)
echo.
echo  Poster image:
echo   1) !I_FOLDER! Browse for file
echo   2) !I_PENCIL! Enter path or URL
echo   0) !I_SKIP! Skip
if not "!POSTER_VALUE!"=="" echo   Current: %CYAN%!POSTER_VALUE!%RESET%
echo.
choice /c 120 /n /m "Select (0-2): "
if errorlevel 3 goto poster_done
if errorlevel 2 goto poster_manual
if errorlevel 1 goto poster_browse
goto poster_done
:poster_browse
:: Browse for poster file
set "POSTER_VALUE="
setlocal disabledelayedexpansion
for /f "usebackq delims=" %%I in (`powershell -Command "Add-Type -AssemblyName System.Windows.Forms; $f = New-Object System.Windows.Forms.OpenFileDialog; $f.Title = 'Select poster image'; $f.Filter = 'Image files (*.jpg;*.jpeg;*.png;*.webp)|*.jpg;*.jpeg;*.png;*.webp|All files (*.*)|*.*'; $f.ShowDialog() | Out-Null; if ($f.FileName) { $f.FileName } else { '' }"`) do >"%TMPPATH%" echo %%I
endlocal
if exist "%TMPPATH%" (set /p POSTER_VALUE=<"%TMPPATH%" & del "%TMPPATH%")
if not "!POSTER_VALUE!"=="" echo   Selected: %CYAN%!POSTER_VALUE!%RESET%
goto poster_done
:poster_manual
set "POSTER_INPUT="
set /p "POSTER_INPUT=Path or URL: "
if not "!POSTER_INPUT!"=="" set "POSTER_VALUE=!POSTER_INPUT!"
:poster_done
set "PS_POSTER=!POSTER_VALUE!"
echo.
set "SC_CONFIRM="
set /p "SC_CONFIRM=Proceed? (y/n) [y]: "
if "!SC_CONFIRM!"=="" set "SC_CONFIRM=y"
if /i "!SC_CONFIRM!"=="n" goto menu
if /i not "!SC_CONFIRM!"=="y" goto simple_confirm

cls
echo %BLUE%========================================%RESET%
echo %BLUE%   RUNNING !TYPE_LABEL! PIPELINE%RESET%
echo %BLUE%========================================%RESET%
echo.
powershell -ExecutionPolicy Bypass -Command "$a=@{}; if($env:PS_QUERY){$a['query']=$env:PS_QUERY}; if($env:PS_POSTER){$a['poster']=$env:PS_POSTER}; & '%~dp0ps\!PIPELINE_SCRIPT!' !DHT_OPTION! !STEPS_OPTION! !YEAR_OPTION! @a $env:MEDIA_PATH"
set "EXIT_CODE=!errorlevel!"
echo.
if not !EXIT_CODE! equ 0 goto execute_failed
echo %GREEN%========================================%RESET%
echo %GREEN%   !I_OK! PROCESS COMPLETED SUCCESSFULLY%RESET%
echo %GREEN%========================================%RESET%
goto final_menu

:select_steps
set "STEPS_BACK=select_steps"
set "CREATE_STEP=2"
set "CONFIRM_TARGET=confirm"
cls
echo %BLUE%========================================%RESET%
echo %BLUE%   STEPS SELECTION%RESET%
echo %BLUE%========================================%RESET%
echo.
echo  Available steps:
echo    1) !I_LIST! parse       - Extract MediaInfo
echo    2) !I_MAGNET! create      - Create .torrent file
echo    3) !I_CAMERA! screens     - Take screenshots
echo    4) !I_SEARCH! tmdb        - Search TMDB for metadata
echo    5) !I_STAR! imdb        - Fetch IMDB details
echo    6) !I_AI! describe    - Generate AI description
echo    7) !I_CLOUD! upload      - Upload screenshots
echo    8) !I_MEMO! description - Build final BBCode description
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
echo !STEPS_INPUT! | findstr /C:"!CREATE_STEP!" >nul 2>&1
if not errorlevel 1 goto select_dht
set "DHT_OPTION=" & set "DHT_LABEL=DISABLED" & goto !CONFIRM_TARGET!

:select_dht
cls
echo %BLUE%========================================%RESET%
echo %BLUE%   DHT OPTION%RESET%
echo %BLUE%========================================%RESET%
echo.
echo  DHT (Distributed Hash Table) - speeds up distribution
echo  but may cause issues with private trackers.
echo.
echo  0) !I_DOOR! Back
echo.
set "DHT_CHOICE="
set /p "DHT_CHOICE=Enable DHT? (y/n/0) [n]: "

if "!DHT_CHOICE!"=="0" goto !STEPS_BACK!
if "!DHT_CHOICE!"=="" set "DHT_CHOICE=n"

if /i "!DHT_CHOICE!"=="y" set "DHT_OPTION=-dht" & set "DHT_LABEL=ENABLED" & goto !CONFIRM_TARGET!
set "DHT_OPTION=" & set "DHT_LABEL=DISABLED" & goto !CONFIRM_TARGET!

:confirm
cls
echo %BLUE%========================================%RESET%
echo %BLUE%   CONFIRMATION%RESET%
echo %BLUE%========================================%RESET%
echo.
echo  !PATH_LABEL!: %CYAN%!ITEM_NAME!%RESET%
powershell -NoProfile -Command "Write-Host ('  Path:   ' + $env:MEDIA_PATH)"
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
echo  0) !I_DOOR! Back to main menu
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
set "PS_QUERY="
if "!QUERY_CHANGED!"=="1" if not "!DETECTED_YEAR!"=="" (set "PS_QUERY=!CLEAN_QUERY! !DETECTED_YEAR!") else (set "PS_QUERY=!CLEAN_QUERY!")
if "!YEAR_CHANGED!"=="1" if not "!QUERY_CHANGED!"=="1" if not "!DETECTED_YEAR!"=="" set "PS_QUERY=!CLEAN_QUERY! !DETECTED_YEAR!"
set "SEASON_OPTION="
if "!SEASON_CHANGED!"=="1" set "SEASON_OPTION=-season !SEASON_NUM!"

powershell -ExecutionPolicy Bypass -Command "$a=@{}; if($env:PS_QUERY){$a['query']=$env:PS_QUERY}; & '%~dp0ps\run.ps1' !TV_OPTION! !DHT_OPTION! !STEPS_OPTION! !SEASON_OPTION! @a $env:MEDIA_PATH"
set "EXIT_CODE=!errorlevel!"

echo.
if not !EXIT_CODE! equ 0 goto execute_failed
echo %GREEN%========================================%RESET%
echo %GREEN%   !I_OK! PROCESS COMPLETED SUCCESSFULLY%RESET%
echo %GREEN%========================================%RESET%
goto final_menu

:execute_failed
echo %RED%========================================%RESET%
echo %RED%   !I_FAIL! PROCESS FAILED - code: !EXIT_CODE!%RESET%
echo %RED%========================================%RESET%

:final_menu
echo.
echo %BLUE%========================================%RESET%
echo %BLUE%   WHAT NEXT?%RESET%
echo %BLUE%========================================%RESET%
echo.
rem Detect torrent name for preview
powershell -NoProfile -Command "$p=$env:MEDIA_PATH; $n=if(Test-Path -LiteralPath $p -PathType Leaf){[IO.Path]::GetFileNameWithoutExtension($p)}else{Split-Path -Leaf $p}; [IO.File]::WriteAllText('%TMPPATH%',$n)"
set /p FIN_TORRENT=<"%TMPPATH%"
del "%TMPPATH%" 2>nul
set "FIN_OUT=%~dp0output"
rem Detect file/url fields from the upload request file (if generated)
set "FIN_NFO_FILE="
set "FIN_BDINFO_FILE="
set "FIN_KEYWORDS_FILE="
set "FIN_POSTER_URL="
set "FIN_BANNER_URL="
set "FIN_REQ_FILE=!FIN_OUT!\!FIN_TORRENT!_upload_request.txt"
if exist "!FIN_REQ_FILE!" (
    for /f "usebackq tokens=1,* delims==" %%A in ("!FIN_REQ_FILE!") do (
        if /i "%%A"=="nfo_file"      set "FIN_NFO_FILE=%%B"
        if /i "%%A"=="bdinfo_file"   set "FIN_BDINFO_FILE=%%B"
        if /i "%%A"=="keywords_file" set "FIN_KEYWORDS_FILE=%%B"
        if /i "%%A"=="poster"        set "FIN_POSTER_URL=%%B"
        if /i "%%A"=="banner"        set "FIN_BANNER_URL=%%B"
    )
)
echo  1) !I_LIST! Preview upload request
echo  2) !I_MEMO! Preview description
echo  3) !I_INFO! Preview mediainfo
echo  4) !I_PAGE! Preview NFO
echo  5) !I_DISC! Preview BDInfo ^& keywords
echo  6) !I_IMAGE! Preview cover
echo  7) !I_LAND! Preview banner
echo  8) !I_MAGNET! Torrent contents
echo  9) !I_ROCKET! Upload to tracker
echo  0) !I_BACK! Back to main menu
echo.
choice /c 1234567890 /n /m "Select: "
if errorlevel 10 goto menu
if errorlevel 9 goto do_upload
if errorlevel 8 goto preview_torrent_contents
if errorlevel 7 goto preview_banner
if errorlevel 6 goto preview_cover
if errorlevel 5 goto preview_bdinfo_keywords
if errorlevel 4 goto preview_nfo
if errorlevel 3 goto preview_mediainfo
if errorlevel 2 goto preview_desc
if errorlevel 1 goto preview_request
goto final_menu

:preview_request
cls
set "PRV_SUFFIX=_upload_request.txt"
powershell -NoProfile -Command "$f=Join-Path $env:FIN_OUT ($env:FIN_TORRENT+$env:PRV_SUFFIX); if(-not(Test-Path -LiteralPath $f)){Write-Host ('File not found: '+$f) -ForegroundColor Red; exit 1}; Write-Host '=== Upload Request ===' -ForegroundColor Cyan; Write-Host ''; [Console]::OutputEncoding=[System.Text.Encoding]::UTF8; Get-Content -LiteralPath $f -Encoding UTF8"
echo.
echo  Press any key to return...
pause > nul
choice /c yn /n /t 0 /d n > nul 2>&1
goto final_menu

:preview_desc
cls
set "PRV_SUFFIX=_torrent_description.bbcode"
powershell -NoProfile -Command "$f=Join-Path $env:FIN_OUT ($env:FIN_TORRENT+$env:PRV_SUFFIX); if(-not(Test-Path -LiteralPath $f)){Write-Host ('File not found: '+$f) -ForegroundColor Red; exit 1}" && goto preview_desc_ok
echo.
echo  Press any key to return...
pause > nul
choice /c yn /n /t 0 /d n > nul 2>&1
goto final_menu
:preview_desc_ok
powershell -ExecutionPolicy Bypass -Command "& '%~dp0ps\preview_bbcode.ps1' (Join-Path $env:FIN_OUT ($env:FIN_TORRENT+$env:PRV_SUFFIX)); exit $LASTEXITCODE"
if not !errorlevel! equ 2 goto preview_desc_done
echo.
echo  1) !I_IMAGE! Render with images
echo  2) !I_MEMO! Edit in Notepad
echo  0) !I_BACK! Back
choice /c 120 /n /m "Select (0-2): "
if errorlevel 3 goto final_menu
if errorlevel 2 goto preview_desc_edit
cls
powershell -ExecutionPolicy Bypass -Command "& '%~dp0ps\preview_bbcode.ps1' (Join-Path $env:FIN_OUT ($env:FIN_TORRENT+$env:PRV_SUFFIX)) -images"
goto preview_desc_done
:preview_desc_edit
powershell -NoProfile -Command "Start-Process notepad.exe -ArgumentList (Join-Path $env:FIN_OUT ($env:FIN_TORRENT+$env:PRV_SUFFIX)) -Wait"
:preview_desc_done
echo.
echo  Press any key to return...
pause > nul
choice /c yn /n /t 0 /d n > nul 2>&1
goto final_menu

:preview_mediainfo
cls
set "PRV_SUFFIX=_mediainfo.txt"
powershell -NoProfile -Command "$f=Join-Path $env:FIN_OUT ($env:FIN_TORRENT+$env:PRV_SUFFIX); if(-not(Test-Path -LiteralPath $f)){Write-Host ('File not found: '+$f) -ForegroundColor Red}else{Write-Host '=== MediaInfo ===' -ForegroundColor Cyan; Write-Host ''; Get-Content -LiteralPath $f}"
echo.
echo  Press any key to return...
pause > nul
choice /c yn /n /t 0 /d n > nul 2>&1
goto final_menu

:preview_nfo
cls
if not defined FIN_NFO_FILE (
    echo  %RED%No NFO file recorded in the upload request.%RESET%
) else if not exist "!FIN_NFO_FILE!" (
    echo  %RED%File not found: !FIN_NFO_FILE!%RESET%
) else (
    powershell -ExecutionPolicy Bypass -File "%~dp0ps\preview_nfo.ps1" "!FIN_NFO_FILE!"
)
echo.
echo  Press any key to return...
pause > nul
choice /c yn /n /t 0 /d n > nul 2>&1
goto final_menu

:preview_cover
cls
if not defined FIN_POSTER_URL (
    echo  %RED%No cover/poster URL recorded in the upload request.%RESET%
    echo.
    echo  Press any key to return...
    pause > nul
    choice /c yn /n /t 0 /d n > nul 2>&1
    goto final_menu
)
:preview_cover_menu
cls
echo  %CYAN%Cover URL:%RESET% !FIN_POSTER_URL!
echo.
echo  1) !I_IMAGE! Render in terminal
echo  2) !I_PENCIL! Change from TMDB listing
echo  0) !I_BACK! Back
echo.
choice /c 120 /n /m "Select: "
if errorlevel 3 goto final_menu
if errorlevel 2 goto preview_cover_change
set "PRV_IMG_URL=!FIN_POSTER_URL!"
set "PRV_IMG_WIDTH=40"
call :render_image
goto final_menu
:preview_cover_change
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ps\change_image.ps1" -TorrentName "!FIN_TORRENT!" -OutDir "!FIN_OUT!" -Type poster
echo.
echo  Press any key to return...
pause > nul
choice /c yn /n /t 0 /d n > nul 2>&1
goto final_menu

:preview_banner
cls
if not defined FIN_BANNER_URL (
    echo  %RED%No banner URL recorded in the upload request.%RESET%
    echo.
    echo  Press any key to return...
    pause > nul
    choice /c yn /n /t 0 /d n > nul 2>&1
    goto final_menu
)
:preview_banner_menu
cls
echo  %CYAN%Banner URL:%RESET% !FIN_BANNER_URL!
echo.
echo  1) !I_IMAGE! Render in terminal
echo  2) !I_PENCIL! Change from TMDB listing
echo  0) !I_BACK! Back
echo.
choice /c 120 /n /m "Select: "
if errorlevel 3 goto final_menu
if errorlevel 2 goto preview_banner_change
set "PRV_IMG_URL=!FIN_BANNER_URL!"
set "PRV_IMG_WIDTH=0"
call :render_image
goto final_menu
:preview_banner_change
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ps\change_image.ps1" -TorrentName "!FIN_TORRENT!" -OutDir "!FIN_OUT!" -Type banner
echo.
echo  Press any key to return...
pause > nul
choice /c yn /n /t 0 /d n > nul 2>&1
goto final_menu

:render_image
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ps\render_image.ps1" -Url "!PRV_IMG_URL!" -Width !PRV_IMG_WIDTH!
echo.
echo  Press any key to return...
pause > nul
choice /c yn /n /t 0 /d n > nul 2>&1
exit /b 0

:preview_bdinfo_keywords
cls
powershell -NoProfile -Command "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; $bf=$env:FIN_BDINFO_FILE; $kf=$env:FIN_KEYWORDS_FILE; $any=$false; if($bf -and (Test-Path -LiteralPath $bf)){Write-Host '=== BDInfo ===' -ForegroundColor Cyan; Write-Host ''; Get-Content -LiteralPath $bf -Encoding UTF8; Write-Host ''; $any=$true}; if($kf -and (Test-Path -LiteralPath $kf)){Write-Host '=== Keywords ===' -ForegroundColor Cyan; Write-Host ''; Get-Content -LiteralPath $kf -Encoding UTF8; Write-Host ''; $any=$true}; if(-not $any){Write-Host 'No BDInfo or keywords files found.' -ForegroundColor Red}"
echo.
echo  Press any key to return...
pause > nul
choice /c yn /n /t 0 /d n > nul 2>&1
goto final_menu

:preview_torrent_contents
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ps\torrent_contents.ps1" -torrentfile "!FIN_OUT!\!FIN_TORRENT!.torrent" -mediapath "!MEDIA_PATH!"
goto final_menu

:do_upload
echo.
powershell -NoProfile -Command "Write-Host $env:MEDIA_PATH -ForegroundColor Cyan"
echo.
powershell -ExecutionPolicy Bypass -Command "& '%~dp0ps\upload.ps1' $env:MEDIA_PATH"
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
:: Read selected saved path via PowerShell to preserve ! in paths
powershell -NoProfile -Command "$f = '%SAVED_PATHS_FILE%'; $n = [int]$env:path_choice; $lines = [IO.File]::ReadAllLines($f); if ($n -ge 1 -and $n -le $lines.Count) { [IO.File]::WriteAllText('%TMPPATH%', $lines[$n-1]) } else { exit 1 }" || goto invalid_saved
set /p MEDIA_PATH=<"%TMPPATH%"
del "%TMPPATH%" 2>nul
powershell -NoProfile -Command "if ($env:MEDIA_PATH) { exit 0 } else { exit 1 }" && goto validate_path
goto invalid_saved

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
echo %BLUE%   !I_ROCKET! UPLOAD%RESET%
echo %BLUE%========================================%RESET%
echo.
echo  1) !I_MAGNET! Upload torrent
echo  2) !I_TEXT! Upload subtitle
echo  3) !I_LIST! List my uploads (API)
echo  4) !I_WEB! List my uploads (Web)
echo  5) !I_PAGE! View upload logs
echo  0) !I_DOOR! Back to main menu
echo.
choice /c 123450 /n /m "Select (0-5): "
if errorlevel 6 goto menu
if errorlevel 5 goto view_upload_logs
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
powershell -ExecutionPolicy Bypass -File "%~dp0ps\list_uploads.ps1"
goto upload_menu

:list_uploads_web
echo.
powershell -ExecutionPolicy Bypass -File "%~dp0ps\list_uploads_web.ps1"
goto upload_menu

:view_upload_logs
cls
echo %BLUE%========================================%RESET%
echo %BLUE%   !I_PAGE! UPLOAD LOGS%RESET%
echo %BLUE%========================================%RESET%
echo.
set "LOG_COUNT=0"
for %%f in ("%~dp0output\*_upload.log") do (
    set /a LOG_COUNT+=1
    set "LOG_!LOG_COUNT!=%%f"
    set "LOG_NAME_!LOG_COUNT!=%%~nf"
    echo  !LOG_COUNT!^) %%~nf
)
if !LOG_COUNT! equ 0 (
    echo  %YELLOW%No upload logs found.%RESET%
    echo.
    echo  Press any key to return...
    pause > nul
    choice /c yn /n /t 0 /d n > nul 2>&1
    goto upload_menu
)
echo.
echo  0) !I_DOOR! Back
echo.
set "LOG_CHOICE="
set /p "LOG_CHOICE=Select log: "
if "!LOG_CHOICE!"=="0" goto upload_menu
if "!LOG_CHOICE!"=="" goto upload_menu
set /a LOG_IDX=LOG_CHOICE 2>nul
if !LOG_IDX! lss 1 goto view_upload_logs
if !LOG_IDX! gtr !LOG_COUNT! goto view_upload_logs
set "SELECTED_LOG=!LOG_%LOG_IDX%!"
cls
echo %CYAN%=== !LOG_NAME_%LOG_IDX%! ===%RESET%
echo.
type "!SELECTED_LOG!"
echo.
echo  Press any key to return...
pause > nul
choice /c yn /n /t 0 /d n > nul 2>&1
goto view_upload_logs

:subtitle_upload
cls
echo %BLUE%========================================%RESET%
echo %BLUE%   !I_TEXT! UPLOAD SUBTITLE%RESET%
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
echo  1) !I_FOLDER! Browse for file (graphical)
echo  2) !I_PENCIL! Enter path manually / drag and drop
echo  0) !I_DOOR! Cancel
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
echo %BLUE%   !I_WRENCH! MAINTENANCE%RESET%
echo %BLUE%========================================%RESET%
echo.
echo  1) !I_WRENCH! Run install
echo  2) !I_PENCIL! Edit config
echo  3) !I_LOCK! Fix TLS 1.2 (older Windows)
echo  4) !I_TAG! Fetch tracker categories
echo  5) !I_PENCIL! Edit categories
echo  6) !I_SAVE! List saved paths
echo  7) !I_FOLDER! List output folder
echo  8) !I_TRASH! Clear saved paths
echo  9) !I_BROOM! Clear output folder
echo  r) !I_BOOK! View README
echo  h) !I_HELP! Help
echo  u) !I_TRASH! Run uninstall
echo  0) !I_DOOR! Back to main menu
echo.
choice /c 123456789rhu0 /n /m "Select (0-9, r, h, u): "
if errorlevel 13 goto menu
if errorlevel 12 goto maint_uninstall
if errorlevel 11 goto maint_help
if errorlevel 10 goto maint_readme
if errorlevel 9 goto maint_clear_output
if errorlevel 8 goto maint_clear_paths
if errorlevel 7 goto maint_list_output
if errorlevel 6 goto maint_list_saved
if errorlevel 5 goto maint_edit_categories
if errorlevel 4 goto maint_fetch_categories
if errorlevel 3 goto maint_fix_tls
if errorlevel 2 goto maint_edit_config
if errorlevel 1 goto maint_install
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
powershell -NoProfile -Command "Get-ChildItem -LiteralPath '%~dp0output' -File | Where-Object { $_.Name -notin '.last_path.txt','.saved_paths.txt','.gitkeep' } | Remove-Item -Force; Get-ChildItem -LiteralPath '%~dp0output' -Directory | Remove-Item -Recurse -Force"
echo %GREEN%Output folder cleared.%RESET%
timeout /t 2 > nul
goto maintenance

:maint_fetch_categories
cls
echo %BLUE%========================================%RESET%
echo %BLUE%   !I_TAG! FETCH TRACKER CATEGORIES%RESET%
echo %BLUE%========================================%RESET%
echo.
echo  Logs in to the configured tracker, scrapes the upload form, and writes
echo  output\categories_^<host^>.jsonc. The pipeline will automatically use
echo  the fetched list for uploads.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ps\fetch_categories.ps1"
echo.
echo  Press any key to return to maintenance...
pause > nul
choice /c yn /n /t 0 /d n > nul 2>&1
goto maintenance

:maint_edit_categories
cls
echo %BLUE%========================================%RESET%
echo %BLUE%   !I_PENCIL! EDIT CATEGORIES%RESET%
echo %BLUE%========================================%RESET%
echo.
set "CAT_FILE="
for /f "usebackq delims=" %%F in (`powershell -NoProfile -Command "$f = Get-ChildItem -LiteralPath '%~dp0output' -Filter 'categories_*.jsonc' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1; if ($f) { $f.FullName }"`) do set "CAT_FILE=%%F"
if "!CAT_FILE!"=="" (
    echo %YELLOW%No categories file found in output\.%RESET%
    echo  Run option 4 ^(Fetch tracker categories^) first.
    echo.
    echo  Press any key to return to maintenance...
    pause > nul
    choice /c yn /n /t 0 /d n > nul 2>&1
    goto maintenance
)
echo  Opening !CAT_FILE! in editor...
echo.
powershell -NoProfile -Command "Start-Process notepad.exe -ArgumentList '!CAT_FILE!' -Wait"
echo  Categories saved.
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

:maint_readme
cls
powershell -ExecutionPolicy Bypass -File "%~dp0ps\preview_bbcode.ps1" "%~dp0README.bbcode"
if !errorlevel! equ 2 (
    echo.
    set "IMG_CHOICE="
    set /p "IMG_CHOICE=Render with images? (y/n) [n]: "
    if /i "!IMG_CHOICE!"=="y" (
        cls
        powershell -ExecutionPolicy Bypass -File "%~dp0ps\preview_bbcode.ps1" -images "%~dp0README.bbcode"
    )
)
echo.
echo  Press any key to return to maintenance...
pause > nul
choice /c yn /n /t 0 /d n > nul 2>&1
goto maintenance

:maint_install
echo.
call "%~dp0install.bat"
:: Refresh PATH so newly installed tools (chafa, magick) are found without restarting
for /f "tokens=2*" %%A in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" /v Path 2^>nul') do set "SYS_PATH=%%B"
for /f "tokens=2*" %%A in ('reg query "HKCU\Environment" /v Path 2^>nul') do set "USR_PATH=%%B"
set "PATH=%~dp0tools;!SYS_PATH!;!USR_PATH!;%LOCALAPPDATA%\Microsoft\WindowsApps"
call set "PATH=!PATH!"
echo.
echo  Press any key to return to maintenance...
pause > nul
choice /c yn /n /t 0 /d n > nul 2>&1
set "_GOTO_AFTER_CONFIG=maintenance" & goto read_config

:maint_uninstall
echo.
call "%~dp0uninstall.bat"
:: Refresh PATH after uninstall
for /f "tokens=2*" %%A in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" /v Path 2^>nul') do set "SYS_PATH=%%B"
for /f "tokens=2*" %%A in ('reg query "HKCU\Environment" /v Path 2^>nul') do set "USR_PATH=%%B"
set "PATH=%~dp0tools;!SYS_PATH!;!USR_PATH!;%LOCALAPPDATA%\Microsoft\WindowsApps"
call set "PATH=!PATH!"
echo.
echo  Press any key to return to maintenance...
pause > nul
choice /c yn /n /t 0 /d n > nul 2>&1
set "_GOTO_AFTER_CONFIG=maintenance" & goto read_config

:maint_fix_tls
cls
echo %BLUE%========================================%RESET%
echo %BLUE%   !I_LOCK! FIX TLS 1.2%RESET%
echo %BLUE%========================================%RESET%
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ps\fix_tls.ps1"
echo.
echo  Press any key to return to maintenance...
pause > nul
choice /c yn /n /t 0 /d n > nul 2>&1
goto maintenance

:maint_edit_config
cls
echo %BLUE%========================================%RESET%
echo %BLUE%   !I_PENCIL! EDIT CONFIG%RESET%
echo %BLUE%========================================%RESET%
echo.
echo  Opening config.jsonc in editor...
echo.
powershell -NoProfile -Command "Start-Process notepad.exe -ArgumentList '%~dp0config.jsonc' -Wait"
echo  Config saved. Reloading...
set "_GOTO_AFTER_CONFIG=maintenance" & goto read_config

:edit_torrent
cls
echo %BLUE%========================================%RESET%
echo %BLUE%   !I_MEMO! EDIT TORRENT%RESET%
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
echo %BLUE%   !I_TRASH! DELETE TORRENT%RESET%
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
echo  1) !I_WRENCH! Run install
echo  0) !I_DOOR! Exit
echo.
choice /c 10 /n /m "Select (0-1): "
if errorlevel 2 goto end
if errorlevel 1 goto run_install
goto welcome

:run_install
echo.
call "%~dp0install.bat"
:: Refresh PATH so newly installed tools (chafa, magick) are found without restarting
for /f "tokens=2*" %%A in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" /v Path 2^>nul') do set "SYS_PATH=%%B"
for /f "tokens=2*" %%A in ('reg query "HKCU\Environment" /v Path 2^>nul') do set "USR_PATH=%%B"
set "PATH=%~dp0tools;!SYS_PATH!;!USR_PATH!;%LOCALAPPDATA%\Microsoft\WindowsApps"
call set "PATH=!PATH!"
echo.
set "MISSING="
if not exist "%~dp0config.jsonc" set "MISSING=!MISSING! config.jsonc"
if not exist "%~dp0tools\ffmpeg.exe" set "MISSING=!MISSING! ffmpeg.exe"
if not exist "%~dp0tools\ffprobe.exe" set "MISSING=!MISSING! ffprobe.exe"
if not exist "%~dp0tools\MediaInfo.exe" set "MISSING=!MISSING! MediaInfo.exe"
where curl.exe >nul 2>&1 || set "MISSING=!MISSING! curl.exe"
if not "!MISSING!"=="" goto install_fail
echo %GREEN%Installation complete!%RESET%
echo  Press any key to continue to menu...
pause > nul
choice /c yn /n /t 0 /d n > nul 2>&1
goto read_config

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
