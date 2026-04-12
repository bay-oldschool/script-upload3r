# Description Templates

These BBCode templates control the final torrent description layout.
Edit them to rearrange sections, change formatting, or add custom text.

Paths are configured in `config.jsonc` under **Description Templates**.

## Syntax

| Syntax | Meaning |
|---|---|
| `{{VAR}}` | Replaced with the variable value |
| `{{#VAR}}...{{/VAR}}` | Conditional block — included only when VAR is non-empty |

Excessive blank lines (3+) are automatically collapsed to 2.

## Template files

### layout_poster.bbcode

Used when a poster image is available and metadata lines are detected.
The description is split into METADATA (top key:value lines) and CONTENT (everything below).

| Variable | Description |
|---|---|
| `{{BANNER_URL}}` | Raw banner image URL |
| `{{BANNER}}` | Non-empty when banner exists (use in conditionals) |
| `{{POSTER_URL}}` | Raw poster image URL |
| `{{HEADER}}` | Formatted title: `[size=26][b]Title (Year)[/b][/size]` |
| `{{METADATA}}` | Metadata lines (genre, rating, links, etc.) |
| `{{FILE_LIST}}` | Torrent file list spoiler (includes leading newlines) |
| `{{CONTENT}}` | Content block (plot, themes, narrative text) |
| `{{SCREENSHOTS}}` | Screenshot section BBCode |
| `{{HASHTAGS}}` | Keyword hashtags |
| `{{EN_TITLE}}` | English title text |
| `{{BG_TITLE}}` | Bulgarian title text (may be empty) |
| `{{YEAR}}` | Release year |
| `{{TRACKER_URL}}` | Tracker base URL |
| `{{TORRENT_NAME}}` | Raw torrent/directory name |
| `{{DESCRIPTION}}` | Full unsplit description (METADATA + CONTENT combined) |

### layout_no_poster.bbcode

Used when no poster image is available, or when metadata/content split fails.
Uses `{{DESCRIPTION}}` (the full description body) instead of separate METADATA/CONTENT.

Same variables as layout_poster — see table above.

### fallback_movie.bbcode

Used only for movie/TV uploads when no AI description exists (falls back to IMDB data).
Contains emoji characters directly (UTF-8 file, not .ps1).

| Variable | Description |
|---|---|
| `{{GENRES}}` | Genre list from IMDB |
| `{{RATING}}` | IMDB rating |
| `{{TITLE}}` | Movie/show title |
| `{{TAGLINE}}` | Tagline (may be empty) |
| `{{OVERVIEW}}` | Plot summary |
| `{{BG_DESCRIPTION}}` | Bulgarian description from TMDB |
| `{{DIRECTOR}}` | Director name(s) |
| `{{CAST}}` | Cast list |

### screenshots.bbcode

Two-part template separated by `---IMAGE---`:
1. **Wrapper** (above the separator) — wraps all screenshot images
2. **Per-image** (below the separator) — repeated for each valid screenshot URL

| Variable | Where | Description |
|---|---|---|
| `{{SCREENSHOT_IMAGES}}` | Wrapper | All per-image tags joined together |
| `{{URL}}` | Per-image | Individual screenshot URL |

## Signature

The signature block is always appended at the end and is not template-controlled.

## Examples

**Change poster size to 300px:**
In `layout_poster.bbcode`, change `[img=250]` to `[img=300]`.

**Remove the table layout:**
Replace the `[table]...[/table]` block with a simpler linear layout:
```
{{#BANNER}}[center][url={{BANNER_URL}}][img=1920]{{BANNER_URL}}[/img][/url][/center]

{{/BANNER}}[center][url={{POSTER_URL}}][img=300]{{POSTER_URL}}[/img][/url][/center]

{{HEADER}}

{{METADATA}}{{FILE_LIST}}

{{#CONTENT}}
{{CONTENT}}
{{/CONTENT}}

{{#SCREENSHOTS}}
{{SCREENSHOTS}}
{{/SCREENSHOTS}}

{{#HASHTAGS}}
{{HASHTAGS}}
{{/HASHTAGS}}
```

**Change screenshot thumbnail size:**
In `screenshots.bbcode`, change `[img=400]` to `[img=600]`.

**Add a custom notice to all uploads:**
Add a line anywhere in the layout templates:
```
[color=red][b]Please seed![/b][/color]
```
