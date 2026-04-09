# claude-image-generation

Claude Code plugin for generating and editing images using Google Gemini, OpenAI GPT Image, and xAI Grok Image APIs.

## Features

- **Text-to-image generation** with Google Gemini, OpenAI GPT Image 1.5, or xAI Grok Image
- **Image editing** with text instructions (all providers)
- **Parallel generation** using multiple providers simultaneously via Task tool
- **Interactive provider selection** via AskUserQuestion at runtime
- **Inline image preview** -- generated images display directly in the terminal (iTerm2, Kitty, Ghostty, WezTerm, Sixel terminals)
- **Tmux pane display** -- opens a split pane for image preview when running inside tmux (works with Claude Code)
- **Streaming display** -- images appear progressively in a shared pane during parallel generation
- **Grid view** -- compare multiple provider results stacked in a vertical side pane
- **Open in Finder/Preview** -- press 'f' for Finder or 'p' for Preview in the display pane

## Installation

### From marketplace (recommended)

```bash
# Add the hex-plugins marketplace (once)
/plugin marketplace add hex/claude-marketplace

# Install the plugin
/plugin install claude-image-generation
```

### From GitHub

```bash
/plugin install hex/claude-image-generation
```

### Manual

```bash
git clone https://github.com/hex/claude-image-generation.git
claude --plugin-dir /path/to/claude-image-generation
```

## Configuration

### API Keys

Set one or both as environment variables:

| Variable | Provider | Get a key |
|----------|----------|-----------|
| `GEMINI_API_KEY` | Google Gemini | [Google AI Studio](https://aistudio.google.com/apikey) |
| `OPENAI_API_KEY` | OpenAI | [OpenAI Platform](https://platform.openai.com/api-keys) |
| `XAI_API_KEY` or `GROK_API_KEY` | xAI | [xAI Console](https://console.x.ai) |

At least one key is required.

### Model Selection

Override the default model per provider via environment variables:

| Variable | Default | Purpose |
|----------|---------|---------|
| `GEMINI_IMAGE_MODEL` | `gemini-3-pro-image-preview` | Gemini model used for generation and editing |
| `OPENAI_IMAGE_MODEL` | `gpt-image-1.5` | OpenAI model used for generation and editing |
| `XAI_IMAGE_MODEL` | `grok-imagine-image-pro` | xAI model used for generation and editing |

Command-line `--model` flag on the scripts takes precedence over environment variables.

### Display Size

Control the terminal image display dimensions (in pixels):

| Variable | Default | Purpose |
|----------|---------|---------|
| `DISPLAY_IMAGE_WIDTH` | `512` | Max image width in pixels for terminal display |
| `DISPLAY_IMAGE_HEIGHT` | `512` | Max image height in pixels for iTerm2 display |

These apply to inline display (iTerm2, Sixel) and tmux pane display.

### Available Gemini Models

| Model | Characteristics |
|-------|-----------------|
| `gemini-3-pro-image-preview` | Pro tier, premium quality, 10 aspect ratios, up to 14 reference images (default, "Nano Banana Pro") |
| `gemini-3.1-flash-image-preview` | 14 aspect ratios (incl. extreme 1:4, 8:1), 512-4K resolution, thinking, Google Search grounding ("Nano Banana 2") |
| `gemini-2.5-flash-image` | Previous generation, 1K only (scheduled shutdown 2026-10-02) |

### Available OpenAI Models

| Model | Characteristics |
|-------|-----------------|
| `gpt-image-1.5` | Superior text rendering, transparent backgrounds, quality tiers (default) |
| `gpt-image-1-mini` | 3-4x cheaper, cost-efficient for drafts and previews |
| `gpt-image-1` | Previous generation |

### Available xAI Models

| Model | Characteristics |
|-------|-----------------|
| `grok-imagine-image-pro` | Premium tier, higher quality, 30 RPM (default) |
| `grok-imagine-image` | Standard tier, 1K/2K resolution, 300 RPM, same endpoint and parameters |

## Usage

### Slash Command

```
/generate-image a golden retriever in a field of sunflowers
/generate-image --edit ./photo.png remove the background and make it transparent
```

The command prompts you to select a provider (Gemini, OpenAI, xAI, or all in parallel) and an output path.

### Agent (Automatic)

The `image-generator` agent triggers automatically when conversation context involves image creation. It handles provider selection, parallel generation, and result delivery without requiring the slash command.

### Direct Script Usage

Scripts are located in `scripts/` and can be invoked directly.

#### gemini.sh

```bash
# Generate
bash scripts/gemini.sh \
  --mode generate \
  --prompt "a mountain at sunset" \
  --output ./mountain.png

# Generate with aspect ratio
bash scripts/gemini.sh \
  --mode generate \
  --prompt "a wide landscape" \
  --output ./landscape.png \
  --aspect-ratio 16:9

# Edit
bash scripts/gemini.sh \
  --mode edit \
  --prompt "add snow to the peaks" \
  --input-image ./mountain.png \
  --output ./snowy.png

# Generate at 4K with thinking mode
bash scripts/gemini.sh \
  --mode generate \
  --prompt "a detailed sci-fi cityscape" \
  --output ./city.png \
  --image-size 4K \
  --thinking-level High

# Generate with Google Search grounding
bash scripts/gemini.sh \
  --mode generate \
  --prompt "Search for the latest SpaceX Starship and draw it at sunset on the launch pad" \
  --output ./starship.png \
  --search-grounding

# Use a specific model
bash scripts/gemini.sh \
  --mode generate \
  --prompt "quick sketch" \
  --output ./sketch.png \
  --model gemini-3-pro-image-preview
```

**Flags:**

| Flag | Values | Default | Required |
|------|--------|---------|----------|
| `--mode` | `generate`, `edit` | -- | Yes |
| `--prompt` | text | -- | Yes |
| `--output` | file path | -- | Yes |
| `--input-image` | file path | -- | Edit mode only |
| `--aspect-ratio` | `1:1`, `16:9`, `9:16`, `4:3`, `3:4`, `3:2`, `2:3`, `4:5`, `5:4`, `21:9` on Pro (default); add `1:4`, `4:1`, `1:8`, `8:1` on `gemini-3.1-flash-image-preview` | `1:1` | No |
| `--image-size` | `512`, `1K`, `2K`, `4K` (UPPERCASE); `512` requires `gemini-3.1-flash-image-preview` | (API default `1K`) | No |
| `--thinking-level` | `minimal`, `High` | `minimal` | No |
| `--image-only` | (flag, no value) | off | No |
| `--search-grounding` | (flag, no value) | off | No |
| `--model` | Gemini model name | `gemini-3-pro-image-preview` | No |

#### openai.sh

```bash
# Generate
bash scripts/openai.sh \
  --mode generate \
  --prompt "a mountain at sunset" \
  --output ./mountain.png

# Generate with options
bash scripts/openai.sh \
  --mode generate \
  --prompt "company logo on transparent background" \
  --output ./logo.png \
  --size 1024x1024 \
  --quality high \
  --background transparent

# Edit
bash scripts/openai.sh \
  --mode edit \
  --prompt "add snow to the peaks" \
  --input-image ./mountain.png \
  --output ./snowy.png
```

**Flags:**

| Flag | Values | Default | Required |
|------|--------|---------|----------|
| `--mode` | `generate`, `edit` | -- | Yes |
| `--prompt` | text | -- | Yes |
| `--output` | file path | -- | Yes |
| `--input-image` | file path | -- | Edit mode only |
| `--size` | `auto`, `1024x1024`, `1536x1024`, `1024x1536` | `1024x1024` | No |
| `--quality` | `auto`, `low`, `medium`, `high` | `high` | No |
| `--background` | `auto`, `transparent`, `opaque` | `auto` | No |
| `--output-format` | `png`, `jpeg`, `webp` | `png` | No |
| `--output-compression` | integer 0-100 (jpeg/webp only) | -- | No |
| `--moderation` | `auto`, `low` | `auto` | No |
| `--input-fidelity` | `low`, `high` (edit only) | `low` | No |
| `--model` | OpenAI model name | `gpt-image-1.5` | No |

#### xai.sh

```bash
# Generate
bash scripts/xai.sh \
  --mode generate \
  --prompt "a mountain at sunset" \
  --output ./mountain.png

# Generate with aspect ratio
bash scripts/xai.sh \
  --mode generate \
  --prompt "a wide landscape" \
  --output ./landscape.png \
  --aspect-ratio 16:9

# Edit
bash scripts/xai.sh \
  --mode edit \
  --prompt "add snow to the peaks" \
  --input-image ./mountain.png \
  --output ./snowy.png

# Generate at 2K resolution
bash scripts/xai.sh \
  --mode generate \
  --prompt "a cat in a tree" \
  --output ./cat.png \
  --resolution 2k

# Use the pro model
bash scripts/xai.sh \
  --mode generate \
  --prompt "a cat in a tree" \
  --output ./cat.png \
  --model grok-imagine-image-pro
```

**Flags:**

| Flag | Values | Default | Required |
|------|--------|---------|----------|
| `--mode` | `generate`, `edit` | -- | Yes |
| `--prompt` | text | -- | Yes |
| `--output` | file path | -- | Yes |
| `--input-image` | file path | -- | Edit mode only |
| `--aspect-ratio` | `1:1`, `16:9`, `9:16`, `4:3`, `3:4`, `3:2`, `2:3`, `2:1`, `1:2`, `19.5:9`, `9:19.5`, `20:9`, `9:20`, `auto` | (none) | No |
| `--resolution` | `1k`, `2k` (LOWERCASE) | (API default) | No |
| `--model` | xAI model name | `grok-imagine-image-pro` | No |

**Note**: For single-image edits, xAI ignores `--aspect-ratio` and uses the input image's ratio. Multi-image edits (5 images max) allow aspect ratio override.

## Provider Comparison

| Feature | Gemini | OpenAI | xAI |
|---------|--------|--------|-----|
| Default model | gemini-3-pro-image-preview | gpt-image-1.5 | grok-imagine-image-pro |
| Max resolution | 4K (via `--image-size`) | 1536x1024 | 2K (via `--resolution`) |
| Text rendering | Very good (under 25 chars) | Excellent | Good |
| Transparent BG | No | Yes | No |
| Aspect ratios | 10 on Pro / 14 on 3.1 Flash | 3 fixed sizes | 14 options (incl. 20:9, auto) |
| Image editing | Multi-turn, up to 14 refs | Single image (API supports up to 16) | Same endpoint, via `image_url` |
| Quality tiers | N/A | auto / low / medium / high | N/A |
| Thinking mode | Yes (`--thinking-level`) | No | No |
| Search grounding | Yes (Google Search) | No | No |
| Pricing | Token-based | Token-based | Flat per-image |
| Prompt revision | No | No | Yes (by chat model) |

## Plugin Components

| Component | File | Purpose |
|-----------|------|---------|
| Plugin manifest | `.claude-plugin/plugin.json` | Plugin metadata and version |
| Skill | `skills/image-generation/SKILL.md` | API knowledge, prompting tips, script reference |
| Command | `commands/generate-image.md` | `/generate-image` slash command |
| Agent | `agents/image-generator.md` | Autonomous image generation |
| Gemini script | `scripts/gemini.sh` | Gemini API call execution |
| OpenAI script | `scripts/openai.sh` | OpenAI API call execution |
| xAI script | `scripts/xai.sh` | xAI API call execution |
| Display utility | `scripts/display.sh` | Multi-protocol terminal image display (iTerm2, Kitty, Sixel, tmux pane, streaming pane) |
| API reference | `skills/image-generation/references/api-details.md` | Endpoint and payload documentation |
| Automated tests | `tests/` | bats test suite for all scripts |

## Development

### Versioning

This plugin uses calendar versioning in `YYYY.M.PATCH` format (e.g., `2026.2.0`). The version is tracked in both `.claude-plugin/plugin.json` and `skills/image-generation/SKILL.md`.

### Testing

```bash
# Run all automated tests (requires bats)
./tests/run_tests.sh

# Or run bats directly
bats tests/
```

See [TESTING.md](TESTING.md) for the full testing guide, including manual test procedures.

### Architecture

The plugin is organized into Claude Code extension points:

```
.claude-plugin/plugin.json    -- Plugin identity and metadata
commands/                      -- Slash command definitions
agents/                        -- Autonomous agent definitions
skills/                        -- Skill knowledge and references
scripts/                       -- Shell scripts for API calls
tests/                         -- Automated tests (bats)
```

The scripts (`gemini.sh`, `openai.sh`, `xai.sh`) are standalone bash programs that handle API communication, base64 encoding/decoding, and error reporting. They are invoked by the command, agent, and skill layers. All three source `display.sh` which auto-detects the terminal and displays generated images using the best available method.

### Terminal Image Display

| Terminal | Protocol | Detection |
|----------|----------|-----------|
| iTerm2 | OSC 1337 | `TERM_PROGRAM`, `LC_TERMINAL` |
| Kitty | Kitty graphics | `TERM=xterm-kitty` |
| Ghostty | Kitty graphics | `TERM_PROGRAM=ghostty` |
| WezTerm | Kitty graphics | `TERM_PROGRAM=WezTerm` |
| Sixel terminals | Sixel (via img2sixel/chafa/magick) | Tool + terminal detection |

When running inside **tmux** (including Claude Code sessions), single images open in a bottom pane (`-v` split) and multiple images open in a vertical side pane (`-h` split, 30% width) targeting the originating pane (via `$TMUX_PANE`). The pane uses `imgcat` (iTerm2), `kitten icat` (Kitty), or a Sixel tool depending on the outer terminal. Press **f** to reveal in Finder, **p** to open in Preview, or **Esc**/**Ctrl+D** to close.

For parallel generation, the streaming display pane shows images progressively as each provider finishes. Call `display_pane_open` to create a shared pane, pass `DISPLAY_PANE_DIR` to each provider script, and call `display_pane_close` when all are done. Provider scripts require zero changes — `display_image()` transparently routes to the shared pane when `DISPLAY_PANE_DIR` is set.

## Requirements

- `curl` -- HTTP requests to provider APIs
- `jq` -- JSON construction and parsing
- `base64` -- Image data encoding/decoding (included in macOS and most Linux distributions)
- At least one API key: `GEMINI_API_KEY`, `OPENAI_API_KEY`, `XAI_API_KEY`, or `GROK_API_KEY`

**Optional (for Sixel image display):**
- `img2sixel` (from libsixel), `chafa`, or `magick` (ImageMagick 7) -- any one of these enables Sixel terminal display
- Install via: `brew install libsixel`, `brew install chafa`, or `brew install imagemagick`

## License

[MIT](LICENSE)
