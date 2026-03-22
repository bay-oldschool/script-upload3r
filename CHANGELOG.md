# Changelog

## v4.1.0 — 2026-03-22

### New Features
- **Torrent file list spoiler**: adds a `[spoiler=Torrent files]` section inside the metadata table column with a Name/Size table and summary (total count, count by type, total size in KB/MB/GB)
- **Multi-season pack detection**: patterns like `S01-S05` are detected; uses the show poster and total show runtime instead of season-specific ones
- **Season-specific trailers**: fetches trailers from TMDB season endpoint; falls back to show-level trailers sorted oldest-first
- **Season year for AI description**: when a season's air date year differs from the show's premiere year, passes the correct season year to the AI prompt

## v4.0.0 — 2026-03-21

### Breaking Changes
- **Removed Bash support**: all `.sh` scripts and `bash/` directory removed; project is now PowerShell/Cmd only
- **Moved root PS1 scripts to `ps/`**: `run.ps1`, `upload.ps1`, `edit.ps1`, `delete.ps1`, `install.ps1` now live in `ps/` alongside pipeline scripts; `.bat` wrappers updated accordingly

### New Features
- **Interactive menu** (`run.bat`): full interactive menu when run without arguments — browse folder/file, enter path manually, use last/saved paths, edit/delete torrents by ID, step selection, DHT toggle, upload after processing
- **Interactive upload menu** (`upload.bat`): path selection with last/saved paths, auto mode prompt
- **Welcome screen**: auto-detects missing components (config, tools) and offers to run installer
- **File browser**: graphical file picker for single video files (`.mkv`, `.mp4`, `.avi`)
- **Saved paths**: both menus save/recall paths via `output/.last_path.txt` and `output/.saved_paths.txt` (shared between run and upload)
- **Screenshot upload script renamed**: `ps/upload.ps1` (screenshot uploader) renamed to `ps/screens_upload.ps1` to avoid collision with tracker upload script
- **ANSI colored menus**: blue headers, green success, red errors, cyan highlights in `.bat` menus
- **Emoji menu items**: contextual emojis for all menu options

### Improvements
- **CLI passthrough**: `run.bat` and `upload.bat` pass arguments directly to PS1 scripts when called with args (no menu shown)
- **Path trimming**: all PS1 scripts now `.Trim()` the directory path to prevent trailing-space issues causing broken output filenames
- **Better upload errors**: `upload.ps1` now shows the `data` field from API validation errors
- **DHT conditional**: DHT option only shown when torrent create step (step 2) is selected
- **File/Folder label**: confirmation screen shows "File:" or "Folder:" based on selection type
- **AI prompt emojis**: updated to unique, contextually relevant emojis for each description section

### Bug Fixes
- **Trailing space in path**: fixed paths with trailing whitespace producing broken output filenames (e.g. `Movie .torrent`)
- **BOM in .bat files**: removed UTF-8 BOM that broke `@echo off` on first line
- **CRLF line endings**: ensured all `.bat` files use CRLF (required by cmd.exe)
- **ANSI in if/else blocks**: replaced parenthesized `if/else` blocks containing ANSI escape codes with `goto`-based branching (cmd.exe parser limitation)
- **File path execution**: fixed multi-line `set /p` in `upload.bat` that caused video file paths to be executed as commands (opening media player)

## v3.5.0 — 2026-03-20

### Changes
- **OMDB fallback for RT ratings**: when MDBList has no Rotten Tomatoes data for a title, falls back to OMDB API for RT Critics score
- Added `omdb_api_key` to `config.example.jsonc`

## v3.4.0 — 2026-03-19

### Changes
- **Rotten Tomatoes via MDBList**: replaced OMDB API with [MDBList API](https://mdblist.com/) for Rotten Tomatoes ratings — now shows both Critics Score (🍅) and Audience Score (🍿) in torrent descriptions
- Config key renamed: `omdb_api_key` → `mdblist_api_key` (free key from mdblist.com)
- **Google Translate subtitle indicator**: when external BG subtitle filename contains `.GT`, prepends 🤖 before 🇧🇬🔤 in upload title (e.g. `🤖🇧🇬🔤`)

### Bug Fixes
- Fixed file listing at end of `run.ps1` failing when name contains `[]` characters (escaped with `[WildcardPattern]::Escape()`)

## v3.3.0 — 2026-03-12

### New Features
- **Install script** (`install.ps1` / `install.bat`): automatically downloads ffmpeg, ffprobe, and MediaInfo if not present in `tools/`; copies `config.example.jsonc` to `config.jsonc` if missing
- **Example config** (`config.example.jsonc`): template config with placeholder values — real `config.jsonc` is now gitignored to protect secrets
- **Edit torrent script** (`edit.ps1` / `edit.bat`): interactively edit torrent metadata (name, category, type, resolution, TMDB/IMDB IDs, season/episode, description, mediainfo, personal release, anonymous) via web session with CSRF handling
  - API fetch with automatic web page fallback when API returns 404
  - `-u <file>` flag to load all fields from `_upload_request.txt` (skips all interactive prompts)
  - `-n <file>` flag to set torrent name from file (preserves emoji that break on terminal paste)
  - `-d <file>` flag to replace description from file
  - `-m <file>` flag to replace mediainfo from file
  - Season/episode prompts for TV categories, extracted from API or edit page
  - Extracts current values from API response or HTML edit page (Livewire data for description, same-tag regex for TMDB/IMDB)
  - Personal release and anonymous prompts with current values as defaults
- **Delete torrent script** (`delete.ps1` / `delete.bat`): delete a torrent by ID via web session with confirmation prompt
  - Fetches torrent info via API for confirmation before deleting
  - `-f` / `--force` flag to skip API fetch and delete without confirmation
  - Detailed error reporting (HTTP status, redirect location, HTML error extraction)
- **Livewire description extractor** (`shared/extract_livewire_desc.pl`): extracts BBCode description from UNIT3D edit page Livewire component data with full unicode/emoji decoding
- **JSON field extractor** (`shared/json_field.pl`): Perl helper for extracting string or numeric (`-n`) JSON field values with unicode surrogate pair decoding

### Improvements
- **`-q` / `--query` flag**: manually override the TMDB/IMDB search query instead of extracting from filename/directory name (useful for non-Latin titles like Cyrillic)
- **Multi-level search fallback chain**: when the initial TMDB search fails, automatically retries without year filter → tries opposite media type (movie↔tv) → tries parent directory name (for single file paths)
- **Year-aware title similarity scoring**: picks the best TMDB result using `score = titleScore × 2 + yearBonus`, correctly preferring e.g. Lion King 2019 over 1994 when year is in the directory name
- **UTF-8 encoding fixes**: added `-Encoding UTF8` to all `Get-Content -Raw` calls and `[Console]::OutputEncoding`, fixing Cyrillic mojibake in IMDB/TMDB output files
- **Type auto-detection**: automatically detects torrent type (Remux, WEB-DL, WEBRip, HDTV, Full Disc) from filename/directory name — falls back to config default (Encode) if no pattern matches
- **Colored console output**: all messages are now color-coded in the PowerShell pipeline
  - Red for errors, yellow for warnings/skipping/failures, green for success messages, blue for pipeline step headers
- **Friendly error messages**: replaced all PowerShell `Write-Error` stack traces with clean `Write-Host` messages
- **Smart upload response**: shows friendly error when tracker returns HTML page instead of API response, with config hint
- **Upload URL**: shows actual tracker URL in upload progress instead of hardcoded name
- **Encoding settings filtering**: mediainfo submitted via edit script automatically strips `Encoding settings` lines (matching upload script behavior)
- **Web session login**: reusable login function with anti-bot field handling (CSRF token, captcha, honeypot, random timestamp field)
- **UTF-8 console encoding** in edit scripts for emoji support (`[Console]::InputEncoding/OutputEncoding`)
- **HTML entity decoding** for torrent name in web fallback path

### Bug Fixes
- Fixed TMDB ID extraction from edit page matching wrong value from hidden input (`[\s\S]*?` crossed element boundaries → `[^>]*` stays within same tag)
- Fixed season/episode hardcoded to 0 when editing TV torrents — now extracted from API/web page and prompted interactively

## v3.2.0 — 2026-03-09

### New Features
- **Linkable hashtags**: hashtags in AI-generated descriptions are now clickable BBCode links to tracker search (e.g. `#action` → `[url=.../torrents?description=action]#action[/url]`), with proper URL-encoding for Cyrillic tags
- **Linkable signature**: "Uploaded using SCRIPT UPLOAD3R" line now links to tracker search for all SCRIPT UPLOAD3R uploads

### Bug Fixes
- Fixed MediaInfo Cyrillic filename mojibake in PS upload (`upload.ps1`) — UTF-8 output now captured via `System.Diagnostics.Process` instead of PS pipeline
- Fixed MediaInfo Cyrillic filename mojibake in PS parse (`parse.ps1`) — same `Process`-based UTF-8 fix

## v3.1.0 — 2026-03-08

### New Features
- **Personal/anonymous upload prompts**: interactive prompts for `personal` (0/1) and `anonymous` (0/1) fields during upload, with defaults read from `config.jsonc`
- **`personal` config option**: added `personal` field to `config.jsonc` (default: 0), sent as `personal_release` in tracker API
- **Filtered output listing**: `run.ps1` now lists only files related to the current input path instead of the entire output directory

### Bug Fixes
- Fixed torrent missing first letter of filename when path had trailing backslash (`mktorrent.ps1` `Resolve-Path` trimming)
- Fixed curl hanging on filenames with parentheses, spaces, or Cyrillic characters — all file paths now copied to temp files before curl upload (screenshot upload + tracker upload)

## v3.0.0 — 2026-03-05

### New Features
- **Rotten Tomatoes rating**: fetched in IMDB step and displayed in torrent description (originally via OMDB, later replaced with MDBList in v3.4.0)
- **Interactive upload prompts**: category, type, resolution pickers with default preselection; season/episode confirmation for TV uploads
- **`-auto` / `-a` flag** for upload scripts: skips all interactive prompts and uses defaults from config/output files
- **External subtitle detection**: detects Bulgarian `.srt` files in torrent directory (by filename pattern: `.bg.`, `.bul.`, `bulgarian`) and adds `🇧🇬🔤` to upload name even when no embedded subs in MediaInfo
- **Genre and rating in AI description**: AI prompt now includes IMDB genres, rating, RT rating, cast, and directors for more accurate descriptions
- **BG title in AI prompt**: passes TMDB Bulgarian title to AI to prevent hallucinated translations

### Reorganization
- **Moved config files to `shared/`**: `categories.jsonc`, `types.jsonc`, `resolutions.jsonc` now live in `shared/` alongside other shared resources
- **Lowercase parameters**: all PowerShell script parameters renamed to lowercase (`-directory`, `-configfile`, `-tv`, `-dht`, `-steps`, etc.)

### Improvements
- **BOM-free UTF-8 output**: all PowerShell scripts now write output files without UTF-8 BOM (`UTF8Encoding($false)`), fixing corrupted URLs and characters in output files
- **Robust RT rating insertion**: RT rating line injected after IMDB rating using pattern matching that works regardless of AI translation language
- **IMDB rating rounding**: ratings now rounded to 1 decimal place (e.g. `6.8/10` instead of `6.767/10`)
- **Banner URL fix**: picks banner from best-matched TMDB result instead of first result
- **AI prompt enrichment**: sends cast, directors, genres, rating, and BG title to AI for better descriptions
- **`-steps` flag**: accepts step numbers or names (e.g. `-steps 4,5,8` or `-steps tmdb,imdb,description`)

### Bug Fixes
- Fixed BOM (`﻿`) appearing in screenshot URLs in torrent description
- Fixed AI hallucinating wrong Bulgarian titles by passing actual TMDB BG title
- Fixed AI writing wrong actor names by passing IMDB cast data
- Fixed PS 5.1 `[char]` overflow for emoji above U+FFFF (tomato emoji) — now uses `ConvertFromUtf32`
- Fixed PS 5.1 trailing comma in array literal causing parse error
- Fixed `upload.bat` / `run.bat` showing PS parameter prompt when run with no arguments
- Fixed AI adding unwanted "Кратко въведение" prefix to description intro

## v2.0.0 — 2026-03-04

### New Features
- **Custom steps** (`-s`/`--steps` / `-Steps`): run only specific pipeline steps by number or name (e.g. `-s 4,5,8` or `-s tmdb,imdb,description`)
- **Help option** (`-h`/`--help` / `-Help`): lists all available options, steps, and usage examples
- **TV show support** for upload (`-t` / `-Tv`): sets `category_id=12`, sends `season_number` and `episode_number` extracted from directory name (e.g. `S01E05`)
- **Bulgarian audio detection**: appends `🇧🇬🔊` to upload title when Bulgarian audio track is found in MediaInfo
- **Bulgarian subtitle detection**: appends `🇧🇬🔤` to upload title when Bulgarian subtitle track is found in MediaInfo
- **Upload log**: saves full request fields and API response to `<name>_upload.log` in the output directory
- **API key links** in README config table for all services (TMDB, Gemini, Google Cloud, onlyimage.org)
- **BBCode README** (`README.bbcode`) — Bulgarian localized version for forum posting

### Reorganization
- **New directory structure**: flat `scripts/` folder split into `ps/`, `tools/`, and `shared/` for clarity
  - `ps/` — PowerShell pipeline scripts (`.ps1`)
  - `tools/` — Binary tools (`MediaInfo.exe`, `ffmpeg.exe`, `ffprobe.exe`)
  - `shared/` — Shared resources (`ai_call.ps1`, `ai_system_prompt.txt`, `mktorrent.ps1`)
- **Renamed** `gemini_call.ps1` → `ai_call.ps1` to reflect support for multiple AI providers (Gemini + Ollama)
- **JSONC config**: renamed `config.json` → `config.jsonc` with `//` line comments for inline documentation
- All path references updated across orchestrators, pipeline scripts, and root upload scripts

### Improvements
- **Width-based resolution detection**: uses video width instead of height for reliable detection (handles non-standard heights like 1920x960, 1920x800)
- **3-level resolution fallback**: directory name → MediaInfo file → MediaInfo.exe direct scan
- **Year fallback for TV shows**: when directory name has no year (e.g. `Dexter.Original.Sin.S01`), extracts year from IMDB or TMDB output files
- **Season marker stripping** (`S01`, `S02E05`, etc.): all search scripts now strip season/episode markers from TMDB/IMDB queries for cleaner results
- **Hashtable splatting** in `run.ps1`: fixed `-Tv` and `-Dht` switches not being passed to sub-scripts
- **Step counter** adapts to selected steps (shows `1/3` instead of `1/8` when running 3 steps)

### Bug Fixes
- Fixed `run.ps1` failing with "positional parameter cannot be found" when passing `-Tv` flag
- Fixed TMDB returning no results for TV shows with season markers in name
- Fixed resolution detection returning wrong ID for non-standard heights (960p, 800p encoded as 1080p)
- Fixed upload title showing `(????)` year for TV shows without year in directory name

## v1.0.0 — 2026-03-02

### Initial Features
- 8-step pipeline: MediaInfo, torrent creation, screenshots, TMDB, IMDB, AI description, screenshot upload, description builder
- PowerShell pipeline with .bat wrappers for every step
- PowerShell bencoder (`mktorrent.ps1`) for .torrent creation
- Gemini AI description generation in Bulgarian BBCode
- TMDB best-match selection with BG title fetch
- Screenshot upload to onlyimage.org
- UNIT3D tracker upload with auto-detected resolution
- BG title appended to upload name with UTF-8 temp file encoding
- Graceful skipping when API keys are not configured
- Trailer/featurette subdirectory filtering
