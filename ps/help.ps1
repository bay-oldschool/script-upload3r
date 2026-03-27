#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Display colored help about the project functionality, workflow, and usage.
#>
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$esc = [char]27
$b    = "$esc[1m"
$r    = "$esc[0m"
$cyan = "$esc[96m"
$grn  = "$esc[92m"
$ylw  = "$esc[93m"
$blue = "$esc[94m"
$mag  = "$esc[95m"
$dim  = "$esc[90m"
$dash = [char]0x2014

Write-Host ''
Write-Host ($b + $cyan + '========================================================' + $r)
Write-Host ($b + $cyan + '   SCRIPT UPLOAD3R ' + $dash + ' Help' + $r)
Write-Host ($b + $cyan + '========================================================' + $r)
Write-Host ''

Write-Host ($b + $blue + 'WHAT IT DOES' + $r)
Write-Host '  Prepares and uploads media to Unit3D-based torrent trackers.'
Write-Host '  Runs 8 pipeline steps, then uploads to tracker with one click.'
Write-Host ''

Write-Host ($b + $blue + 'PIPELINE STEPS' + $r)
Write-Host ('  ' + $grn + '1' + $r + ') parse       ' + $dash + ' Extract MediaInfo from video files')
Write-Host ('  ' + $grn + '2' + $r + ') create      ' + $dash + ' Create private .torrent file')
Write-Host ('  ' + $grn + '3' + $r + ') screens     ' + $dash + ' Capture 3 screenshots (15%, 50%, 85%)')
Write-Host ('  ' + $grn + '4' + $r + ') tmdb        ' + $dash + ' Search TMDB for title, poster, BG title')
Write-Host ('  ' + $grn + '5' + $r + ') imdb        ' + $dash + ' Fetch IMDB rating, cast, genres, RT scores')
Write-Host ('  ' + $grn + '6' + $r + ') describe    ' + $dash + ' Generate AI description (Gemini/Ollama)')
Write-Host ('  ' + $grn + '7' + $r + ') upload      ' + $dash + ' Upload screenshots to onlyimage.org')
Write-Host ('  ' + $grn + '8' + $r + ') description ' + $dash + ' Build final BBCode torrent description')
Write-Host ''

Write-Host ($b + $blue + 'TYPICAL WORKFLOW' + $r)
Write-Host ('  ' + $ylw + '1.' + $r + ' Run ' + $b + 'install.bat' + $r + ' to download tools and create config')
Write-Host ('  ' + $ylw + '2.' + $r + ' Edit ' + $b + 'config.jsonc' + $r + ' with your API keys and tracker settings')
Write-Host ('  ' + $ylw + '3.' + $r + ' Run ' + $b + 'run.bat' + $r + ' ' + $dash + ' select media folder, choose steps, process')
Write-Host ('  ' + $ylw + '4.' + $r + ' Preview the generated description (with optional image rendering)')
Write-Host ('  ' + $ylw + '5.' + $r + ' Upload to tracker from the post-pipeline menu')
Write-Host ''

Write-Host ($b + $blue + 'INTERACTIVE MENU (run.bat)' + $r)
Write-Host ('  Just run ' + $b + 'run.bat' + $r + ' without arguments for the interactive menu:')
Write-Host ('  ' + $dim + '- Browse for folder/file or enter path manually' + $r)
Write-Host ('  ' + $dim + '- Choose content type (Movie / TV Series)' + $r)
Write-Host ('  ' + $dim + '- Select pipeline steps to run' + $r)
Write-Host ('  ' + $dim + '- Preview upload request, description (BBCode), mediainfo' + $r)
Write-Host ('  ' + $dim + '- Upload torrent or subtitle to tracker' + $r)
Write-Host ('  ' + $dim + '- Edit/delete torrents by ID' + $r)
Write-Host ('  ' + $dim + '- Maintenance: paths, output, install, help' + $r)
Write-Host ''

Write-Host ($b + $blue + 'CLI USAGE' + $r)
Write-Host ''
Write-Host ('  ' + $b + 'Full pipeline:' + $r)
Write-Host ('  ' + $mag + 'run.bat [options] "path"' + $r)
Write-Host ('  ' + $mag + '.\ps\run.ps1 [options] "path" [config.jsonc]' + $r)
Write-Host ''
Write-Host ('  ' + $b + 'Options:' + $r)
Write-Host ('    ' + $grn + '-tv' + $r + '            Search for TV shows instead of movies')
Write-Host ('    ' + $grn + '-dht' + $r + '           Enable DHT in torrent (private by default)')
Write-Host ('    ' + $grn + '-steps 4,5,8' + $r + '   Run only specific steps (by number or name)')
Write-Host ('    ' + $grn + '-query "text"' + $r + '  Override TMDB/IMDB search query')
Write-Host ('    ' + $grn + '-season N' + $r + '      Override season number')
Write-Host ''

Write-Host ('  ' + $b + 'Upload to tracker:' + $r)
Write-Host ('  ' + $mag + 'upload.bat ["path"]' + $r)
Write-Host ('  ' + $mag + '.\ps\upload.ps1 [-auto] "path" [config.jsonc]' + $r)
Write-Host ''

Write-Host ('  ' + $b + 'Other scripts:' + $r)
Write-Host ('  ' + $mag + 'edit.bat {torrent_id}' + $r + '                   ' + $dash + ' Edit torrent metadata')
Write-Host ('  ' + $mag + 'delete.bat [-f] {torrent_id}' + $r + '            ' + $dash + ' Delete torrent')
Write-Host ('  ' + $mag + 'subtitle.bat {torrent_id} "file.srt"' + $r + '    ' + $dash + ' Upload subtitle')
Write-Host ''

Write-Host ($b + $blue + 'EXAMPLES' + $r)
Write-Host ''
Write-Host ('  ' + $dim + '# Run all steps on a movie' + $r)
Write-Host ('  ' + $cyan + 'run.bat "D:\media\Pacific.Rim.2013.1080p.BluRay"' + $r)
Write-Host ''
Write-Host ('  ' + $dim + '# TV show, all steps' + $r)
Write-Host ('  ' + $cyan + 'run.bat -tv "D:\media\Breaking.Bad.S01.1080p"' + $r)
Write-Host ''
Write-Host ('  ' + $dim + '# Only TMDB + IMDB + description' + $r)
Write-Host ('  ' + $cyan + 'run.bat -steps 4,5,8 "D:\media\Pacific.Rim.2013.1080p.BluRay"' + $r)
Write-Host ''
Write-Host ('  ' + $dim + '# Override search query (useful for non-Latin titles)' + $r)
Write-Host ('  ' + $cyan + 'run.bat -query "Mamnik" -tv "D:\media\Mamnik.S01.1080p"' + $r)
Write-Host ''
Write-Host ('  ' + $dim + '# Upload with auto mode (skip prompts)' + $r)
Write-Host ('  ' + $cyan + 'upload.bat -auto "D:\media\Pacific.Rim.2013.1080p.BluRay"' + $r)
Write-Host ''

Write-Host ($b + $blue + 'AUTO-DETECTION' + $r)
Write-Host ('  ' + $b + 'Type:' + $r + '       Remux, WEB-DL, WEBRip, HDTV, Full Disc, or Encode (default)')
Write-Host ('  ' + $b + 'Resolution:' + $r + ' From directory name, MediaInfo file, or MediaInfo.exe scan')
Write-Host ('  ' + $b + 'BG flags:' + $r + '   ' + $grn + 'BG audio' + $r + ' and ' + $grn + 'BG subtitles' + $r + ' detected automatically')
Write-Host ''

Write-Host ($b + $blue + 'REQUIREMENTS' + $r)
Write-Host ('  ' + $b + 'Required:' + $r + '  PowerShell 5+, curl (built-in Win10+), API keys in config.jsonc')
Write-Host ('  ' + $b + 'Tools:' + $r + '     ffmpeg, ffprobe, MediaInfo (auto-downloaded by install script)')
Write-Host ('  ' + $b + 'Optional:' + $r + '  ImageMagick (for sixel image preview in BBCode renderer)')
Write-Host ''
Write-Host ($dim + '  All output files are saved to the output/ directory.' + $r)
Write-Host ''
