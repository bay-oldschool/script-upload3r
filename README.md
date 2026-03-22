# SCRIPT UPLOAD3R

A set of scripts for preparing and uploading media to Unit3D-based torrent trackers. Runs on Windows via **PowerShell** / **Cmd**. Features an interactive menu (`run.bat`) or full CLI support.

## What It Does

Runs 8 steps in sequence for a given media directory:

1. **MediaInfo** — parses all video files and saves a formatted text report
2. **Create Torrent** — creates a private `.torrent` file with your tracker's announce URL
3. **Screenshots** — captures 3 JPG screenshots at 15%, 50%, and 85% of playback
4. **TMDB Search** — fetches title, poster/banner URLs, and Bulgarian title
5. **IMDB Lookup** — fetches IMDB ID, rating, genres, runtime, director, and cast
6. **AI Description** — generates a rich Bulgarian BBCode description via Gemini AI or Ollama
7. **Upload Screenshots** — uploads screenshots to onlyimage.org and saves direct URLs
8. **Build Description** — assembles the final BBCode torrent description file

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

Then edit `config.jsonc` with your credentials. JSONC supports `//` line comments for documentation:

```jsonc
{
  "api_key": "YOUR_TRACKER_API_KEY",
  "announce_url": "https://yourtracker.cc/announce/YOUR_PASSKEY",
  "tracker_url": "https://yourtracker.cc",
  "category_id": 1,
  "type_id": 3,
  "resolution_id": 2,
  "tmdb": 0,
  "imdb": 0,
  "anonymous": 1,
  "tmdb_api_key": "YOUR_TMDB_API_KEY",
  "google_api_key": "YOUR_GOOGLE_API_KEY",
  "translate_lang": "bg",
  "ai_provider": "gemini",
  "gemini_api_key": "YOUR_GEMINI_API_KEY",
  "gemini_model": "gemini-2.5-flash-lite",
  "ollama_model": "gemma3:4b",
  "ollama_url": "",
  "omdb_api_key": "YOUR_OMDB_API_KEY",
  "mdblist_api_key": "YOUR_MDBLIST_API_KEY",
  "onlyimage_api_key": "YOUR_ONLYIMAGE_API_KEY"
}
```

| Key | Description |
|-----|-------------|
| `api_key` | Your tracker API key — find it in your tracker's account settings under **API** |
| `announce_url` | Full announce URL with your passkey — find it in your tracker's account **Upload** or **Passkey** page |
| `tracker_url` | Tracker base URL (e.g. `https://yourtracker.cc`) |
| `username` | Tracker login username — required for edit/delete scripts |
| `password` | Tracker login password — required for edit/delete scripts |
| `category_id` | Tracker category ID (1 = Movies, etc.) |
| `type_id` | Tracker type ID (e.g. 3 = Blu-ray) |
| `resolution_id` | Default resolution ID (auto-detected from directory name or MediaInfo) |
| `anonymous` | `1` to upload anonymously, `0` to show your username |
| `tmdb_api_key` | [TMDB API key](https://www.themoviedb.org/settings/api) — free account required |
| `google_api_key` | [Google Cloud API key](https://console.cloud.google.com/apis/credentials) — needed only for TMDB description translation (enable **Cloud Translation API**) |
| `translate_lang` | Translation language code (e.g. `bg` for Bulgarian) |
| `gemini_api_key` | [Google Gemini API key](https://aistudio.google.com/app/apikey) — free via Google AI Studio |
| `gemini_model` | Gemini model to use (default: `gemini-2.5-flash-lite`) |
| `ai_provider` | Force AI provider: `"gemini"` or `"ollama"` (auto-detected if omitted) |
| `ollama_model` | Ollama model name (e.g. `gemma3:4b`) — if set and no `ai_provider`, Ollama is used |
| `ollama_url` | Ollama API URL (default: `http://localhost:11434`) |
| `mdblist_api_key` | [MDBList API key](https://mdblist.com/) — free tier, used for Rotten Tomatoes Critics and Audience scores |
| `omdb_api_key` | [OMDB API key](https://www.omdbapi.com/apikey.aspx) — free tier, used as fallback for RT Critics score when MDBList has no data |
| `onlyimage_api_key` | [onlyimage.org API key](https://onlyimage.org/user/settings/api) — register and find it in account settings |

## Usage

### Interactive menu

Just run `run.bat` without arguments for the interactive menu:
- Browse for folder/file or enter path manually
- Choose content type (Movie / TV Series)
- Select pipeline steps
- Edit/delete torrents by ID
- Upload to tracker after processing

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
| `-query` | Override TMDB/IMDB search query (useful for non-Latin titles) |
| `-help` | Show help with all options and examples |

**Available steps** (use with `-steps`):

| # | Name | Description |
|---|------|-------------|
| 1 | `parse` | Extract MediaInfo from video files |
| 2 | `create` | Create .torrent file |
| 3 | `screens` | Take screenshots at 15%, 50%, 85% |
| 4 | `tmdb` | Search TMDB for metadata and BG title |
| 5 | `imdb` | Fetch IMDB details (rating, cast, etc.) |
| 6 | `describe` | Generate AI description via Gemini |
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
| `-auto` | Skip all interactive prompts, use defaults |

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

### Individual scripts

Each pipeline step can be run standalone. Scripts are in `ps/`.

| Step | Command |
|------|---------|
| MediaInfo | `.\ps\parse.ps1 <dir>` |
| Create torrent | `.\ps\create.ps1 [-dht] <dir> [config]` |
| Screenshots | `.\ps\screens.ps1 <dir>` |
| TMDB search | `.\ps\tmdb.ps1 [-tv] [-query query] <dir> [config]` |
| IMDB lookup | `.\ps\imdb.ps1 [-tv] [-query query] <dir> [config]` |
| AI description | `.\ps\describe.ps1 [-tv] [-query query] <dir> [config]` |
| Upload screenshots | `.\ps\screens_upload.ps1 <dir> [config]` |
| Build description | `.\ps\description.ps1 <dir>` |

---

## Output

All files are written to `output/`:

| File | Description |
|------|-------------|
| `<name>.torrent` | Torrent file |
| `<name>_mediainfo.txt` | MediaInfo report |
| `<name>_screen01.jpg` | Screenshot at 15% |
| `<name>_screen02.jpg` | Screenshot at 50% |
| `<name>_screen03.jpg` | Screenshot at 85% |
| `<name>_tmdb.txt` | TMDB search results (top 5 with BG title) |
| `<name>_imdb.txt` | IMDB details (ID, rating, cast, etc.) |
| `<name>_description.txt` | AI-generated BBCode description |
| `<name>_screens.txt` | Direct URLs of uploaded screenshots |
| `<name>_torrent_description.txt` | Final BBCode description ready for upload |
| `<name>_upload.log` | Upload request & response log |

## Type Auto-Detection

The torrent type is automatically detected from the directory/file name:

| Pattern | Type |
|---------|------|
| `Remux` | Remux (id=2) |
| `WEB-DL`, `WEBDL` | WEB-DL (id=4) |
| `WEBRip` | WEBRip (id=5) |
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