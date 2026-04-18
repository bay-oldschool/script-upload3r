# Changelog

## v5.2.0 — 2026-04-18

### New Features
- **2FA (TOTP) web login**: pure PS5.1 RFC 6238 TOTP generator (`shared/totp.ps1`) and centralized login helper (`shared/web_login.ps1`) — all web-session scripts (edit, delete, upload, subtitle, fetch_categories, list_uploads_web) now support 2FA, with rate-limit detection (429 auto-retry) and per-host session cookie caching (90-minute TTL in `output/.web_cookie_<host>`)
- **Windows 10 (build 14393) compatibility**: install script auto-downloads `curl.exe` on systems that ship without it; downloads chafa/ImageMagick directly when winget is unavailable; OS-build-aware ffmpeg picker (BtbN for Win10 1809+, Gyan 4.4 for older Windows) with `.ffmpeg_target` marker and auto-reinstall on mismatch; `run.bat` emoji icons degrade to ASCII on legacy conhost, sixel logo falls back to text
- **TLS 1.2 fix script** (`ps/fix_tls.ps1`): diagnose and repair TLS 1.2 for SChannel and .NET (`SchUseStrongCrypto`) on legacy Windows; skipped automatically on modern builds where `SystemDefault` already includes TLS 1.2; added to the maintenance menu
- **Default NFO for games/software**: `description.ps1` now auto-generates a CP437 NFO for game and software uploads with a filesystem-derived summary (primary file, format, size, file count, heuristic type label, IGDB link for games)
- **Parametric logo generator** (`shared/make_logo.ps1`): GDI+ text-to-PNG renderer with flat/linear/radial gradient fills, optional soft glow, hex color parsing, and auto-padding to glyph bounds — used to produce custom `logo.png` images
- **Edit config menu item**: `run.bat` maintenance menu now includes an **Edit config** option that opens `config.jsonc` in Notepad; **Edit categories** entry opens the most recent `output/categories_*.jsonc`
- **Renderer parameter** for `render_image.ps1`: `-Renderer` flag chooses between `chafa`, `magick`, or `auto` (default)

### Improvements
- **Web session cache** moved from `shared/` to `output/` alongside other pipeline artifacts; `Get-CachedCookieJar` returns a disposable temp copy so `curl -c` calls no longer corrupt the cached session
- **`cat_type` hint in upload request**: `description.ps1` now writes `cat_type=<software|game|music|tv|movie>` so upload/edit prefer the explicit hint over deriving type from `category_id` — fixes software/game/music category filter on trackers whose category list has no matching type entry; upload falls back to showing every category when the filter yields an empty list
- **Music provider fallbacks** (`music.ps1`): when an override query finds nothing on a provider, retry the same provider with the cleaned auto-detected query before moving on; short-album retry (strip parenthesized subtitles) added to MusicBrainz, AudioDB, Last.fm, and iTunes (previously only Deezer/Discogs); skip artist-only fallback while auto-detect is pending so cleaned album name is tried first
- **Query override with spaces**: `run.bat` now passes query/poster to PowerShell via env vars (`PS_QUERY`, `PS_POSTER`) with splatting to avoid nested-quote breakage in `-Command`
- **Image preview sixel-first**: `logo_display` config now only affects the logo; all other image previews (bbcode, screenshots, cover/banner) always try chafa sixel first, then magick sixel, falling back to block art only when neither is available — no more `WT_SESSION` gating
- **Cover/poster previews at 40 columns, banners at full width**: `render_image.ps1` accepts `-Width`; `run.bat`, `upload.bat`, `change_image.ps1`, and `preview_bbcode.ps1` pass 40 for covers and full terminal width for banners
- **Winget-installed chafa detection**: searches `%LOCALAPPDATA%\Microsoft\WinGet\Packages` and adds chafa to PATH when winget did not
- **Torrent file list from .torrent metadata**: BBCode description file-list spoiler now parses the actual `.torrent` file instead of scanning the directory, so it reflects real torrent contents (falls back to directory scan if the torrent hasn't been created yet)
- **Configurable logo paths**: `logo_image_path` (logo PNG) and `nfo_logo_path` (ASCII logo injected into generated NFOs via `{{LOGO}}` placeholder in `shared/default.nfo`) — both resolve relative paths from project root
- **fetch_categories hardening**: BG/RU label detection (Филми, Сериали, Игри, Музика, Софтуер, Аниме, Порно) via `\uXXXX` regex escapes (keeps the script ASCII for PS5.1); auto-guessed `type` field flagged with a visible warning in the JSONC header and console; categories file written to `output/categories_<host>.jsonc` and auto-detected by the pipeline
- **Login error handling**: all web-session scripts show a clear error and wait for a keypress on login failure; `finally` blocks safely handle null cookie jars

### Bug Fixes
- **categories_file relative path**: `upload.ps1` and `edit.ps1` were resolving relative `categories_file` overrides against the parent of the repo root (two-level `Split-Path -Parent` at top of file), so the override silently fell back to `shared/categories.jsonc`
- **LOGO_DISPLAY JSON quotes**: the batch config parser preserves JSON quotes, so `LOGO_DISPLAY` arrived in PowerShell as `"direct"` (with quotes) — PS scripts now strip them before comparing
- **logo_display=direct ignored without WT_SESSION**: the Windows Terminal guard was silently downgrading direct (sixel) mode to ansi; when the user explicitly sets `logo_display=direct`, sixel output is used regardless
- **Null ffprobe output** (`screens.ps1`): guarded `InvokeMethodOnNull` crash when ffprobe returns nothing; duration warning now surfaces stderr
- **Missing `curl.exe`**: `run.bat` MISSING check now flags absent curl so first-run installer triggers on Windows builds that ship without it
- **PS5.1 compatibility**: replaced `[WildcardPattern]::Escape` (not always available on older PS 5.1 builds) with regex across `run*.ps1`; fixed `$script:` scoping for `$noArtistOnly` and single-element array unwrapping in `music.ps1`
- **Tracker host suffix**: the final `.tld` is stripped from tracker host when computing `categories_<host>.jsonc` filename (5 call sites kept consistent)

### New Config Keys
- `two_factor_secret` — Base32 TOTP secret for 2FA web login (leave empty if 2FA is disabled)
- `logo_image_path` — path to logo PNG for image logo source (relative to project root or absolute; defaults to `shared/logo.png`)
- `nfo_logo_path` — ASCII logo injected into generated NFOs via `{{LOGO}}` placeholder (defaults to `shared/logo_ascii.txt`)

---

## v5.1.0 — 2026-04-12

### New Features
- **Music pipeline** (`run_music.ps1`): full pipeline for music torrents — 6 metadata providers (Deezer, MusicBrainz, Discogs, Last.fm, TheAudioDB, iTunes) with configurable priority order, AI description with music-specific prompt, track durations, and music categories
- **Customizable BBCode description templates**: layout templates (`templates/`) for poster, no-poster, fallback, and screenshots sections — uses `{{VAR}}` variables and `{{#VAR}}...{{/VAR}}` conditional blocks; paths configurable in `config.jsonc`
- **Staff-only upload fields**: `internal`, `featured`, `free`, `fl_until`, `doubleup`, `du_until`, `sticky`, `mod_queue_opt_in` — set to `0`, `1`, or `"ask"` to prompt on upload
- **Default NFO generation**: auto-generated CP437 NFO with title row, TMDB/IMDB/IGDB links, release group separator, and ASCII logo (`shared/default.nfo`)
- **BDInfo subtitle notes**: language-specific subtitle notes injected into description from `shared/bdinfo_strings.txt`
- **NFO preview** (`preview_nfo.ps1`): preview NFO files in the terminal
- **Cover/banner image picker** (`change_image.ps1`): choose from top-10 TMDB posters/backdrops with terminal preview; change cover/banner from preview menus in `run.bat` and `upload.bat`
- **Torrent contents viewer** (`torrent_contents.ps1`): view torrent file list with sizes and remove individual files from the torrent
- **Fetch categories** (`fetch_categories.ps1`): scrape the tracker's live category list from the upload form and save as a JSONC file for the pipeline
- **View categories** (`view_categories.ps1`): print the active category list (honoring `categories_file` override)
- **Edit form: cover, banner, keywords, BDInfo**: edit script now prompts for cover image, banner image, keywords, and BDInfo fields; "Enter URL" option added to cover/banner image pickers
- **Prefer Bulgarian TMDB images**: TMDB image fetching now prefers Bulgarian-language posters and banners via the TMDB images API
- **Trailer skipping in torrent creation**: `mktorrent.ps1` skips trailer/featurette subdirectories when creating torrent files

### Improvements
- **Music metadata consolidation** (`music.ps1`): merged all music provider logic (Deezer, MusicBrainz, Discogs, Last.fm, TheAudioDB, iTunes) into a single script; Discogs short-album detection; `discogs_id` support in upload and edit flows
- **Track durations**: music descriptions now include individual track durations
- **Categories override**: music uploads can override the category using real category names from the active category list
- **Upload diagnostics**: upload script now shows detailed diagnostic info when upload fails
- **Top-10 TMDB images**: `tmdb.ps1` now fetches top-10 posters and backdrops (up from 1) for image selection
- **Preview menus enhanced**: both `run.bat` and `upload.bat` menus now include cover/banner/keywords change options and BDInfo/NFO preview
- **Menu consolidation**: BDInfo and keywords merged into a single preview/edit flow in the menus
- **Render image utility** (`render_image.ps1`): shared script for terminal image rendering (Sixel/ANSI) used across preview menus
- **Build logo ASCII** (`build_logo_ascii.ps1`): generate ASCII logo from `shared/logo_ascii.txt` with configurable colors
- **Audio language normalization**: `parse.ps1` normalizes unknown/undefined audio languages to English
- **Image/Other section recognition**: MediaInfo parser now recognizes Image and Other sections, ensuring Audio blocks are flushed correctly

### Bug Fixes
- **Staff field 'ask' crash**: fixed `"ask"` string values in staff fields (internal, featured, etc.) crashing upload with `[int]` cast error
- **IGDB game name cleaning**: improved stripping of repack/scene/platform tags from game names
- **BBCode preview rendering**: fixed rendering issues in `preview_bbcode.ps1`
- **Category override**: fixed music category override using real category names instead of IDs
- **Empty file path guards**: `edit.ps1` now guards `Test-Path` against empty upload request file paths
- **change_image variable parsing**: fixed variable parsing in `change_image.ps1`

### New Config Keys
- `categories_file` — custom categories JSONC file path (populated via `fetch_categories.ps1`)
- `internal` / `featured` / `free` / `fl_until` / `doubleup` / `du_until` / `sticky` / `mod_queue_opt_in` — staff-only upload fields (0/1/"ask")
- `music_providers` — comma-separated provider priority: `deezer,musicbrainz,discogs,lastfm,audiodb,itunes`
- `discogs_token` — [Discogs](https://www.discogs.com/settings/developers) personal access token
- `lastfm_api_key` — [Last.fm](https://www.last.fm/api/account/create) API key
- `audiodb_api_key` — [TheAudioDB](https://www.theaudiodb.com/) API key (free key: `523532`)
- `template_layout_poster` / `template_layout_no_poster` / `template_fallback_movie` / `template_screenshots` — BBCode template file paths

---

## v5.0.0 — 2026-04-05

### New Features
- **Game pipeline** (`run_game.ps1`): full pipeline for game torrents — IGDB search, AI description, screenshots, torrent creation, and upload with game-specific categories (18–23)
- **Software pipeline** (`run_software.ps1`): full pipeline for software torrents — AI description, screenshots, torrent creation, and upload with software categories (24–26)
- **IGDB search script** (`igdb.ps1`): search IGDB via Twitch OAuth for game metadata — trailers, cover art, interactive result selection, PC platform prioritization, and IGDB link in descriptions
- **Game/software AI descriptions**: dedicated system prompts (`ai_system_prompt_game.txt`, `ai_system_prompt_software.txt`) with genre-appropriate templates
- **Multi-provider AI support**: added Groq, Grok, Cerebras, SambaNova, OpenRouter, and HuggingFace as AI providers alongside Gemini and Ollama
- **Poster support**: prompt for poster (file path or URL) before game/software pipeline; upload local posters to onlyimage.org; pass as torrent cover in UNIT3D upload API; AI provides fallback poster/screenshot URLs when IGDB data is missing
- **Torrent cover upload**: upload torrent cover image via web session after API upload (for categories that don't auto-pull from TMDB/IGDB)
- **Torrent progress bar**: colored ANSI progress bar with Unicode block characters during torrent piece hashing
- **Auto piece size**: automatically calculate optimal piece size (~1500 pieces, 16 KiB–32 MiB cap), matching GG Bot Upload Assistant conventions
- **Configurable ASCII logo**: main menu header loaded from `shared/logo.txt` with 3 configurable colors (letters, dark, light) via 256-color codes
- **Image logo modes**: render `shared/logo.png` as ANSI half-blocks, shade blocks (░▒▓█), ASCII characters, or Sixel direct output via chafa or ImageMagick
- **Interactive install/uninstall**: install and uninstall scripts show menu with single-keypress selection — Enter=all, number=single tool, 0=exit; shows disk space per tool
- **Uninstall script** (`uninstall.ps1` / `uninstall.bat`): interactive tool removal with same UI as install
- **View README**: option 8 in maintenance menu to preview `README.bbcode` in terminal
- **Upload request file picker in edit flow**: select from output dir / browse / skip before prompting for fields; auto-detect and apply description + mediainfo files
- **Torrent list actions**: clickable edit/delete/subtitle icons via OSC 8 links in torrent listings; pagination with load-more for both API and web listings
- **Upload logs viewer**: view upload logs from upload submenu
- **Edit-in-notepad**: option to open description in Notepad from description preview

### Improvements
- **Config restructured**: organized into labeled sections (Tracker, Upload Defaults, Subtitle, TMDB, AI Providers, Ratings, IGDB, Screenshots, UI)
- **Smarter search queries**: strip resolution (`1080p`, `720p`, etc.), source (`WEBRip`, `BluRay`, etc.), and codec tags from TMDB/IMDB search queries across all scripts — applied consistently via cross-script rule
- **Skip poster download**: movie, TV, and game torrents skip poster download/upload since the site pulls covers automatically from TMDB/IGDB
- **PNG screenshots**: switched from JPG to PNG format for lossless quality
- **Randomized screenshot timestamps**: spread to 10/35/65% to avoid duplicates near scene boundaries
- **AI description word limit**: reduced from 200–400 to 150–250 words for more concise descriptions
- **Poster skip-on-enter**: instant single-keypress selection for poster image choice, 0 to skip
- **PATH refresh**: run.bat refreshes PATH from registry after install/uninstall; expands registry variables (`%SystemRoot%`) to prevent losing system32
- **Chafa support**: added chafa as primary image renderer with ImageMagick fallback for logo display
- **Cache tool availability**: cache chafa/magick detection to avoid slow `where` lookups on every menu loop
- **BBCode preview**: added `[list]`/`[*]` rendering with bullet/numbered items and `[code]` block rendering with dim indented content
- **Post-process AI output**: convert `**text**` to `[b]text[/b]`, strip markdown list markers from AI responses
- **Clean game/software header**: strip repack/scene/platform tags, restore version dots in torrent names
- **Consolidated ai_call.ps1**: manual JSON escaping for all providers to preserve emoji surrogate pairs
- **Validate image URLs**: HEAD request check before including poster/screenshot URLs in descriptions
- **OMDB poster fallback**: fetch poster from OMDB when TMDB has no results
- **Torrent name override**: prompt to override torrent name before category selection in upload flow
- **Skip type/resolution pickers**: game and software uploads skip irrelevant type/resolution selection
- **Cancel support extended**: cancel (`c`) added to subtitle, delete, and edit scripts
- **Emoji strings externalized**: install/uninstall emoji strings stored in external UTF-8 files (PS5.1 safe)
- **ffmpeg source switched**: install now downloads ffmpeg from GitHub CDN (BtbN) for faster downloads
- **Config reloads after install**: logo settings reload when returning to menu after install/uninstall

### Bug Fixes
- **PATH refresh losing system32**: expanding registry `%SystemRoot%` variables prevents losing system32 from PATH after install
- **`-steps` parameter**: accept unquoted comma-separated values by using `[string[]]` parameter type
- **techPart extraction**: fallback regex when torrent name has no year or season tag (extract from resolution/source tag)
- **EnTitle in description.ps1**: keep full release info (resolution, codec, source, group) — only replace dots/underscores with spaces
- **Cyrillic/emoji in upload request preview**: read files as UTF-8 and set console encoding to UTF-8
- **Year in query override**: strip year from `-query` override in tmdb.ps1, imdb.ps1, and describe.ps1 to avoid duplicate year in search
- **Interactive description file pick**: track override with flag to prevent Livewire re-fetch from overwriting user selection
- **CMD delayed expansion**: fix `!` characters in paths being corrupted by delayed expansion
- **Delete.ps1 404 fallback**: fall back to web scraping when API returns 404
- **$PSScriptRoot scoping**: renamed to `$RootDir` in list scripts to fix variable scoping issue
- **Apostrophe in filenames**: use `$env:` variables instead of direct interpolation in PowerShell commands
- **Bracketed tags**: strip `[SKIDROW]` and similar scene tags from game/software names

### New Config Keys
- `twitch_client_id` / `twitch_client_secret` — IGDB access via Twitch OAuth ([dev.twitch.tv/console](https://dev.twitch.tv/console))
- `groq_api_key` / `groq_model` — [Groq](https://console.groq.com/) AI provider
- `grok_api_key` / `grok_model` — [Grok](https://x.ai/) AI provider
- `cerebras_api_key` / `cerebras_model` — [Cerebras](https://cloud.cerebras.ai/) AI provider
- `sambanova_api_key` / `sambanova_model` — [SambaNova](https://cloud.sambanova.ai/) AI provider
- `openrouter_api_key` / `openrouter_model` — [OpenRouter](https://openrouter.ai/) AI provider
- `huggingface_api_key` / `huggingface_model` — [HuggingFace](https://huggingface.co/) AI provider
- `show_logo` — show/hide ASCII logo in main menu (1/0)
- `logo_source` — `"text"` (colored ASCII) or `"image"` (render logo.png)
- `logo_display` — image display mode: `"ansi"`, `"block"`, `"ascii"`, or `"direct"` (Sixel)
- `logo_width` — logo width in characters for image modes
- `logo_color_letters` / `logo_color_dark` / `logo_color_light` — 256-color codes for text logo

---

## v4.2.0 — 2026-03-27

### New Features
- **Sixel image preview** in BBCode preview: renders banner, poster, and screenshots as inline terminal images via ImageMagick (requires Windows Terminal 1.22+)
  - Banner rendered at full terminal pixel width (auto-detected via Win32 API)
  - Poster rendered above metadata table (150px)
  - Screenshots merged side by side with `+append` into a single row
  - Two-step flow: text-only preview first, then optional "Render with images" if ImageMagick is available
  - All `[IMG]` link placeholders remain clickable in the text
- **ImageMagick optional install**: install script now asks whether to install ImageMagick (default: yes) instead of installing automatically
- **Colored install output**: install script messages color-coded — DarkGray for "already present", Cyan for progress, Green for success

### Improvements
- **Shared preview logic**: both `run.bat` and `upload.bat` use exit code from `preview_bbcode.ps1` to detect ImageMagick availability (no duplicated detection)

---

## v4.2.0-rc1 — 2026-03-26

### New Features
- **Subtitle upload script** (`subtitle.ps1` / `subtitle.bat`): upload subtitle files to torrents by ID via web session with language selection, note field, and anonymous toggle
  - Interactive language picker with config default (`subtitle_language_id`)
  - Required note field
  - Anonymous default read from config
  - Graphical file browser or drag-and-drop path entry
- **List last uploads** (`list_uploads.ps1`): fetch and display last N uploads by current user from tracker API with table output (ID, name, category, date)
- **BBCode preview** (`preview_bbcode.ps1`): renders BBCode files with ANSI terminal colors — bold, italic, underline, colored text, URL links, image placeholders, spoiler/quote/code blocks
- **Upload submenu** in main menu: new option 6 with sub-options for uploading torrents, uploading subtitles, and listing last 10 uploads
- **Maintenance submenu** in main menu: option 9 with list saved paths, list output folder, clear saved paths, clear output folder, and run install
- **File preview in upload flow**: preview upload request, description (rendered BBCode), and mediainfo before uploading — available in both `upload.bat` options screen and `run.bat` post-pipeline menu
- **Upload file override**: when not using auto mode, option to change upload request, torrent, or description files via graphical browser or manual path entry
- **Upload file status display**: shows OK/missing status for each upload file (request, torrent, description) in the upload options screen

### Improvements
- **Colors in upload prompts**: category, type, resolution headings in cyan; selected answers in green; invalid choices in yellow
- **Colors in edit prompts**: current values displayed in green with cyan headings; selected answers in green
- **Cancel with 'c'**: type `c` at any interactive prompt in upload or edit to cancel and exit cleanly (exit code 2 for upload, 0 for edit)
- **Cancel suppresses banners**: cancelling upload no longer shows success/failure banners
- **Config defaults for subtitle upload**: `subtitle_language_id` (default: 15 for Bulgarian) and `anonymous` read from config
- **Interactive description/name in edit**: option to load name or description from file via graphical browser (`f` at prompt) during interactive edit
- **Description prompt moved**: description prompt now appears right after name in edit flow
- **Navigation improvements**: `0` goes back (not exit) in content type, steps, DHT, and confirmation screens
- **File/folder detection**: uses PowerShell `Test-Path -PathType Leaf` instead of batch extension check — fixes false "File" label on folders with dots in name (e.g. `H.265-GROUP`)
- **Run.ps1 usage**: updated to say "directory or file" instead of just "directory"
- **Upload.ps1 help flag**: added `-h` / `-help` parameter
- **Upload.ps1 override params**: added `-r`, `-t`, `-d` params to override request, torrent, and description files

### Bug Fixes
- **CRLF in subtitle.bat**: fixed LF-only line endings causing cmd.exe parse failures
- **Torrent name detection in upload.bat**: fixed folder names with dots (e.g. `DDP.5.1.H.265-GROUP`) being truncated by batch `%%~nF` extension stripping — now uses PowerShell for reliable detection

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
