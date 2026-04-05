# SCRIPT UPLOAD3R

A set of scripts for preparing and uploading media to Unit3D-based torrent trackers. Runs on Windows via **PowerShell** / **Cmd**. Features an interactive menu (`run.bat`) or full CLI support. Supports **movies**, **TV shows**, **games**, and **software**.

## What It Does

### Movie / TV Pipeline (8 steps)

1. **MediaInfo** — parses all video files and saves a formatted text report
2. **Create Torrent** — creates a private `.torrent` file with auto-calculated piece size and progress bar
3. **Screenshots** — captures 3 PNG screenshots at randomized timestamps
4. **TMDB Search** — fetches title, poster/banner URLs, and Bulgarian title
5. **IMDB Lookup** — fetches IMDB ID, rating, genres, runtime, director, and cast
6. **AI Description** — generates a rich Bulgarian BBCode description via 8 supported AI providers
7. **Upload Screenshots** — uploads screenshots to onlyimage.org and saves direct URLs
8. **Build Description** — assembles the final BBCode torrent description file

### Game Pipeline

Uses **IGDB** (via Twitch API) for game metadata, trailers, and cover art, with a game-specific AI description prompt.

### Software Pipeline

AI-generated description with a software-specific prompt. Manual poster support.

All output files are saved to the `output/` directory.

## Directory Structure

```
torrent-upload/
├── ps/          # PowerShell pipeline scripts (.ps1)
├── tools/       # Binaries: MediaInfo.exe, ffmpeg.exe, ffprobe.exe (auto-downloaded by install script)
├── shared/      # Shared resources: ai_call.ps1, ai_system_prompt.txt, mktorrent.ps1
├── output/      # Generated output files
├── run.bat      # Interactive menu / cmd wrapper for ps/run.ps1
├── upload.bat   # Interactive menu / cmd wrapper for ps/upload.ps1
├── subtitle.bat # Interactive menu / cmd wrapper for ps/subtitle.ps1
├── edit.bat     # Cmd wrapper for ps/edit.ps1
├── delete.bat   # Cmd wrapper for ps/delete.ps1
├── install.bat  # Cmd wrapper for ps/install.ps1
├── config.example.jsonc  # Example config template (tracked in git)
└── config.jsonc # API keys and settings — gitignored (copy from example)
```

## Requirements

- **PowerShell** 5+ (`pwsh` or Windows PowerShell)
- **`curl`** — built into Windows 10+
- **API keys** — configured in `config.jsonc`

## Setup

Run the install script to download required tools and create your config:

```
install.bat
```

Or use the interactive menu — `run.bat` will detect missing components and offer to run the installer.

This will:
- Download `ffmpeg.exe`, `ffprobe.exe`, and `MediaInfo.exe` to `tools/` (if not already present)
- Copy `config.example.jsonc` to `config.jsonc` (if not already present)
- Optionally install **ImageMagick** via winget for sixel image preview in terminal (banner, poster, screenshots rendered inline in BBCode preview)

Then edit `config.jsonc` with your credentials. JSONC supports `//` line comments for documentation:

```jsonc
{
  "api_key": "YOUR_TRACKER_API_KEY",
  "announce_url": "https://yourtracker.cc/announce/YOUR_PASSKEY",
  "tracker_url": "https://yourtracker.cc",
  "username": "",
  "password": "",
  "name_convention": 1,
  "type_id": 3,
  "resolution_id": 2,
  "tmdb": 0,
  "imdb": 0,
  "personal": 0,
  "anonymous": 0,
  "subtitle_language_id": 15,
  "tmdb_api_key": "YOUR_TMDB_API_KEY",
  "google_api_key": "YOUR_GOOGLE_API_KEY",
  "translate_lang": "bg",
  "ai_provider": "gemini",
  "gemini_api_key": "YOUR_GEMINI_API_KEY",
  "gemini_model": "gemini-2.5-flash",
  "ollama_model": "gemma3:4b",
  "ollama_url": "",
  "groq_api_key": "YOUR_GROQ_API_KEY",
  "groq_model": "qwen/qwen3-32b",
  "grok_api_key": "YOUR_GROK_API_KEY",
  "grok_model": "grok-3-mini",
  "cerebras_api_key": "YOUR_CEREBRAS_API_KEY",
  "cerebras_model": "llama-3.3-70b",
  "sambanova_api_key": "YOUR_SAMBANOVA_API_KEY",
  "sambanova_model": "Meta-Llama-3.1-70B-Instruct",
  "openrouter_api_key": "YOUR_OPENROUTER_API_KEY",
  "openrouter_model": "qwen/qwen3-32b:free",
  "huggingface_api_key": "YOUR_HUGGINGFACE_API_KEY",
  "huggingface_model": "Qwen/Qwen2.5-72B-Instruct",
  "twitch_client_id": "YOUR_TWITCH_CLIENT_ID",
  "twitch_client_secret": "YOUR_TWITCH_CLIENT_SECRET",
  "omdb_api_key": "YOUR_OMDB_API_KEY",
  "mdblist_api_key": "YOUR_MDBLIST_API_KEY",
  "onlyimage_api_key": "YOUR_ONLYIMAGE_API_KEY",
  "show_logo": 1,
  "logo_source": "image",
  "logo_display": "direct",
  "logo_width": 40
}
```

| Key | Description |
|-----|-------------|
| `api_key` | Your tracker API key — find it in your tracker's account settings under **API** |
| `announce_url` | Full announce URL with your passkey — find it in your tracker's account **Upload** or **Passkey** page |
| `tracker_url` | Tracker base URL (e.g. `https://yourtracker.cc`) |
| `username` | Tracker login username — required for edit/delete/subtitle scripts |
| `password` | Tracker login password — required for edit/delete/subtitle scripts |
| `name_convention` | `1` = UNIT3D format (spaces, normalized titles), `0` = raw torrent name |
| `category_id` | Tracker category ID (1 = Movies, etc.) |
| `type_id` | Tracker type ID (e.g. 3 = Blu-ray) |
| `resolution_id` | Default resolution ID (auto-detected from directory name or MediaInfo) |
| `personal` | `1` to mark as personal release, `0` otherwise |
| `anonymous` | `1` to upload anonymously, `0` to show your username |
| `subtitle_language_id` | Default language ID for subtitle uploads (e.g. `15` for Bulgarian) |
| `tmdb_api_key` | [TMDB API key](https://www.themoviedb.org/settings/api) — free account required |
| `google_api_key` | [Google Cloud API key](https://console.cloud.google.com/apis/credentials) — needed only for TMDB description translation (enable **Cloud Translation API**) |
| `translate_lang` | Translation language code (e.g. `bg` for Bulgarian) |
| `gemini_api_key` | [Google Gemini API key](https://aistudio.google.com/app/apikey) — free via Google AI Studio |
| `gemini_model` | Gemini model to use (default: `gemini-2.5-flash`) |
| `ai_provider` | AI provider: `"gemini"`, `"ollama"`, `"groq"`, `"grok"`, `"cerebras"`, `"sambanova"`, `"openrouter"`, or `"huggingface"` |
| `ollama_model` | Ollama model name (e.g. `gemma3:4b`) — if set and no `ai_provider`, Ollama is used |
| `ollama_url` | Ollama API URL (default: `http://localhost:11434`) |
| `groq_api_key` | [Groq API key](https://console.groq.com/) — fast inference provider |
| `groq_model` | Groq model (default: `qwen/qwen3-32b`) |
| `grok_api_key` | [Grok API key](https://x.ai/) — xAI provider |
| `grok_model` | Grok model (default: `grok-3-mini`) |
| `cerebras_api_key` | [Cerebras API key](https://cloud.cerebras.ai/) — fast inference provider |
| `cerebras_model` | Cerebras model (default: `llama-3.3-70b`) |
| `sambanova_api_key` | [SambaNova API key](https://cloud.sambanova.ai/) — fast inference provider |
| `sambanova_model` | SambaNova model (default: `Meta-Llama-3.1-70B-Instruct`) |
| `openrouter_api_key` | [OpenRouter API key](https://openrouter.ai/) — multi-model router |
| `openrouter_model` | OpenRouter model (default: `qwen/qwen3-32b:free`) |
| `huggingface_api_key` | [HuggingFace API key](https://huggingface.co/) — inference API |
| `huggingface_model` | HuggingFace model (default: `Qwen/Qwen2.5-72B-Instruct`) |
| `twitch_client_id` | [Twitch Client ID](https://dev.twitch.tv/console) — required for IGDB game search |
| `twitch_client_secret` | Twitch Client Secret — required for IGDB game search |
| `mdblist_api_key` | [MDBList API key](https://mdblist.com/) — free tier, used for Rotten Tomatoes Critics and Audience scores |
| `omdb_api_key` | [OMDB API key](https://www.omdbapi.com/apikey.aspx) — free tier, used as fallback for RT Critics score when MDBList has no data |
| `onlyimage_api_key` | [onlyimage.org API key](https://onlyimage.org/user/settings/api) — register and find it in account settings |
| `show_logo` | Show ASCII/image logo in main menu (`1` = show, `0` = hide) |
| `logo_source` | Logo source: `"text"` (colored ASCII), `"image"` (render logo.png) |
| `logo_display` | Image display mode: `"ansi"`, `"block"`, `"ascii"`, or `"direct"` (Sixel) |
| `logo_width` | Logo width in characters for image display modes |
| `logo_color_letters` | 256-color code for logo letters (text source only) |
| `logo_color_dark` | 256-color code for dark shading (text source only) |
| `logo_color_light` | 256-color code for light shading (text source only) |

## Usage

### Interactive menu

Just run `run.bat` without arguments for the interactive menu:
- Browse for folder/file or enter path manually
- Choose content type (Movie / TV Series / Game / Software)
- Select pipeline steps
- Upload submenu: upload torrent, upload subtitle, list last 10 uploads, view upload logs
- Edit/delete torrents by ID
- Maintenance: list saved paths, list output, clear paths/output, run install/uninstall, view README
- Preview upload files (request, description with BBCode rendering, mediainfo)
- Configurable ASCII/image logo header

### Full pipeline (CLI)

```powershell
.\ps\run.ps1 [options] <directory> [config.jsonc]
# or from cmd:
run.bat [options] <directory> [config.jsonc]
```

**Options:**

| Flag | Description |
|------|-------------|
| `-tv` | Search for TV shows instead of movies |
| `-dht` | Enable DHT in the torrent (private by default) |
| `-steps` | Comma-separated list of steps to run |
| `-query`, `-q` | Override TMDB/IMDB search query (useful for non-Latin titles) |
| `-season`, `-sn` | Override season number (e.g. `-season 1`, `-season 0` for all seasons) |
| `-help`, `-h` | Show help with all options and examples |

**Available steps** (use with `-steps`):

| # | Name | Description |
|---|------|-------------|
| 1 | `parse` | Extract MediaInfo from video files |
| 2 | `create` | Create .torrent file |
| 3 | `screens` | Take PNG screenshots at randomized timestamps |
| 4 | `tmdb` | Search TMDB for metadata and BG title |
| 5 | `imdb` | Fetch IMDB details (rating, cast, etc.) |
| 6 | `describe` | Generate AI description (8 providers supported) |
| 7 | `upload` | Upload screenshots to onlyimage.org |
| 8 | `description` | Build final BBCode torrent description |

**Examples:**

```powershell
# Run all steps (default)
.\ps\run.ps1 "D:\media\Pacific.Rim.2013.1080p.BluRay"

# TV show
.\ps\run.ps1 -tv "D:\media\Breaking.Bad.S01.1080p"

# Run only specific steps
.\ps\run.ps1 -steps 4,5,8 "D:\media\Pacific.Rim.2013.1080p.BluRay"

# Run steps by name
.\ps\run.ps1 -steps tmdb,imdb,description "D:\media\Pacific.Rim.2013.1080p.BluRay"

# Override search query
.\ps\run.ps1 -query "Mamnik" -tv "D:\media\Mamnik.S01.1080p"

# From cmd
run.bat "D:\media\Pacific.Rim.2013.1080p.BluRay"
run.bat -steps 1,2,3 "D:\media\Pacific.Rim.2013.1080p.BluRay"
```

---

### Upload to tracker (after pipeline)

```powershell
.\ps\upload.ps1 [-auto] <directory> [config.jsonc]
# or from cmd:
upload.bat [-auto] <directory> [config.jsonc]
```

| Flag | Description |
|------|-------------|
| `-auto`, `-a` | Skip all interactive prompts, use defaults |
| `-r <file>` | Override upload request file |
| `-t <file>` | Override torrent file |
| `-d <file>` | Override description file |
| `-help`, `-h` | Show help message |

TV mode is auto-detected from the `_upload_request.txt` generated by the pipeline (step 8).

**Examples:**
```powershell
# Upload with interactive prompts
.\ps\upload.ps1 "D:\media\Pacific.Rim.2013.1080p.BluRay"

# Auto mode (skip prompts, use defaults)
.\ps\upload.ps1 -auto "D:\media\Pacific.Rim.2013.1080p.BluRay"

# From cmd
upload.bat "D:\media\Pacific.Rim.2013.1080p.BluRay"
```

---

### Edit torrent

Edit an existing torrent's metadata (name, category, type, resolution, TMDB/IMDB, season/episode, description, mediainfo, personal/anonymous). Fetches current values via API or web page, lets you change fields interactively, then submits via web session.

Requires `username` and `password` in `config.jsonc`.

```powershell
.\ps\edit.ps1 <torrent_id> [config.jsonc] [-u upload_request.txt] [-n name.txt] [-d description.txt] [-m mediainfo.txt]
edit.bat <torrent_id> [config.jsonc] [-u upload_request.txt] [-n name.txt] [-d description.txt] [-m mediainfo.txt]
```

| Flag | Description |
|------|-------------|
| `-u <file>` | Load all fields from `_upload_request.txt` (name, category, type, resolution, TMDB/IMDB, season/episode, personal, anonymous) |
| `-n <file>` | Use torrent name from file (preserves emoji from clipboard) |
| `-d <file>` | Use description from file instead of current one |
| `-m <file>` | Use mediainfo from file instead of current one |

**Examples:**
```powershell
# Edit torrent #2770 interactively
.\ps\edit.ps1 2770

# Load all fields from pipeline output
.\ps\edit.ps1 2770 -u output/Movie_upload_request.txt -d output/Movie_torrent_description.txt

# Edit with replacement description and mediainfo
.\ps\edit.ps1 2770 -d new_desc.txt -m mediainfo.txt
```

---

### Delete torrent

Delete a torrent by ID. Fetches torrent info for confirmation, then deletes via web session.

Requires `username` and `password` in `config.jsonc`.

```powershell
.\ps\delete.ps1 [-f] <torrent_id> [config.jsonc]
delete.bat [-f] <torrent_id> [config.jsonc]
```

| Flag | Description |
|------|-------------|
| `-f` | Skip API fetch and delete without confirmation |

**Examples:**
```powershell
# Delete with confirmation
.\ps\delete.ps1 2770

# Force delete (skip confirmation)
.\ps\delete.ps1 -f 2770
```

---

### Upload subtitle

Upload a subtitle file to an existing torrent. Logs in via web session, fetches the subtitle create form for language options, then uploads.

Requires `username` and `password` in `config.jsonc`.

```powershell
.\ps\subtitle.ps1 <torrent_id> <subtitle_file> [-l language_id] [-n note] [-a]
subtitle.bat <torrent_id> <subtitle_file> [-l language_id] [-n note] [-a]
```

| Flag | Description |
|------|-------------|
| `-l <id>` | Language ID (default from config `subtitle_language_id`) |
| `-n <text>` | Note (required) |
| `-a` | Upload anonymously |

**Config defaults:**
- `subtitle_language_id` — default language ID (e.g. `15` for Bulgarian)
- `anonymous` — default anonymous flag

**Examples:**
```powershell
# Interactive (prompts for language, note, anonymous)
.\ps\subtitle.ps1 3643 "movie.bg.srt"

# Pre-select language and note
.\ps\subtitle.ps1 3643 "movie.bg.srt" -l 15 -n "Google Translated" -a
```

---

### Individual scripts

Each pipeline step can be run standalone. Scripts are in `ps/`.

| Step | Command |
|------|---------|
| MediaInfo | `.\ps\parse.ps1 <dir>` |
| Create torrent | `.\ps\create.ps1 [-dht] <dir> [config]` |
| Screenshots | `.\ps\screens.ps1 <dir>` |
| TMDB search | `.\ps\tmdb.ps1 [-tv] [-query query] [-season N] <dir> [config]` |
| IMDB lookup | `.\ps\imdb.ps1 [-tv] [-query query] [-season N] <dir> [config]` |
| AI description | `.\ps\describe.ps1 [-tv] [-query query] [-season N] <dir> [config]` |
| Upload screenshots | `.\ps\screens_upload.ps1 <dir> [config]` |
| Build description | `.\ps\description.ps1 [-tv] <dir> [config]` |
| IGDB search | `.\ps\igdb.ps1 [-query query] <dir> [config]` |
| Game description | `.\ps\describe_game.ps1 <dir> [config]` |
| Software description | `.\ps\describe_software.ps1 <dir> [config]` |
| Game pipeline | `.\ps\run_game.ps1 <dir> [config]` |
| Software pipeline | `.\ps\run_software.ps1 <dir> [config]` |
| Upload subtitle | `.\ps\subtitle.ps1 <torrent_id> <file> [-l lang] [-n note] [-a]` |
| List uploads | `.\ps\list_uploads.ps1 [count] [config]` |
| Preview BBCode | `.\ps\preview_bbcode.ps1 [-images] <file.bbcode>` |

---

## Output

All files are written to `output/`:

| File | Description |
|------|-------------|
| `<name>.torrent` | Torrent file |
| `<name>_mediainfo.txt` | MediaInfo report |
| `<name>_screen01.png` | Screenshot 1 |
| `<name>_screen02.png` | Screenshot 2 |
| `<name>_screen03.png` | Screenshot 3 |
| `<name>_tmdb.txt` | TMDB search results (top 5 with BG title) |
| `<name>_imdb.txt` | IMDB details (ID, rating, cast, etc.) |
| `<name>_description.bbcode` | AI-generated BBCode description |
| `<name>_screens.txt` | Direct URLs of uploaded screenshots |
| `<name>_torrent_description.bbcode` | Final BBCode description ready for upload |
| `<name>_upload_request.txt` | Upload form fields (name, category, type, etc.) |
| `<name>_upload.log` | Upload request & response log |

## Type Auto-Detection

The torrent type is automatically detected from the directory/file name:

| Pattern | Type |
|---------|------|
| `Remux` | Remux (id=2) |
| `WEB-DL`, `WEBDL` | WEB-DL (id=4) |
| `WEBRip`, `WEB` | WEBRip (id=5) |
| `HDTV` | HDTV (id=6) |
| `BDMV`, `DISC`, `.iso` | Full Disc (id=1) |
| *(no match)* | Config default — Encode (id=3) |

The interactive picker in the upload script still lets you override the detected type.

## Resolution Auto-Detection

The resolution ID is automatically detected in this order:

1. **Directory name** — matches `1080p`, `2160p`, `4K`, `720p`, etc.
2. **MediaInfo file** — reads video width from `_mediainfo.txt`
3. **MediaInfo.exe** — runs directly on the video file as final fallback

Width-based detection handles non-standard heights (e.g. 1920x960 correctly maps to 1080p).

| Width | resolution_id |
|-------|---------------|
| >= 7000 | 1 (4320p) |
| >= 3000 | 2 (2160p) |
| >= 1800 | 3 (1080p) |
| >= 1200 | 5 (720p) |
| >= 700 | 6 (576p) / 8 (480p) |

## Upload Features

- **TV mode**: auto-detected from pipeline output — sets `category_id`, `season_number` and `episode_number` with interactive confirmation
- **Auto mode** (`-auto`): skips all interactive prompts (category, type, resolution, season/episode) and uses defaults
- **BG title**: appends Bulgarian title and year to upload name (e.g. `Movie.2013.1080p / Филм (2013)`)
- **BG audio/subtitle detection**: automatically appends `🇧🇬🔤` for Bulgarian subtitles (embedded or external `.srt`) and `🇧🇬🔊` for Bulgarian audio to the upload title; prepends `🤖` when external subtitle filename contains `.GT` (Google Translate)
- **Rotten Tomatoes ratings**: displays RT Critics (🍅) and Audience (🍿) scores in torrent description via MDBList API, with OMDB fallback
- **Interactive pickers**: category, type, and resolution selection with arrow-key navigation and default preselection
- **Upload log**: saves full request fields and response to `_upload.log`

## Screenshots

![1](https://img.onlyimage.org/Q4WN1g.png)
![2](https://img.onlyimage.org/Q4WYMj.png)
![3](https://img.onlyimage.org/Q4Wa6G.png)
![4](https://img.onlyimage.org/Q4WSxH.png)
![5](https://img.onlyimage.org/Q4WXxJ.png)
![6](https://img.onlyimage.org/Q4LrK6.png)