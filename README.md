# claude-image-generation

Claude Code plugin for generating and editing images using Google Gemini, OpenAI GPT Image, and xAI Grok Image APIs.

## Features

- **Text-to-image generation** with Google Gemini, OpenAI GPT Image 1.5, or xAI Grok Image
- **Image editing** with text instructions (all providers)
- **Parallel generation** using multiple providers simultaneously via Task tool
- **Interactive provider selection** via AskUserQuestion at runtime
- **Session start check** that reports which API keys are configured
- **Inline image preview** -- generated images display directly in the terminal (iTerm2, Kitty, Ghostty, WezTerm, Sixel terminals)
- **Tmux pane display** -- opens a split pane for image preview when running inside tmux (works with Claude Code)
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
| `GEMINI_IMAGE_MODEL` | `gemini-2.5-flash-image` | Gemini model used for generation and editing |
| `OPENAI_IMAGE_MODEL` | `gpt-image-1.5` | OpenAI model used for generation and editing |
| `XAI_IMAGE_MODEL` | `grok-imagine-image` | xAI model used for generation and editing |

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
| `gemini-2.5-flash-image` | Fast generation, good for iteration (default) |

### Available OpenAI Models

| Model | Characteristics |
|-------|-----------------|
| `gpt-image-1.5` | Superior text rendering, transparent backgrounds, quality tiers |

### Available xAI Models

| Model | Characteristics |
|-------|-----------------|
| `grok-imagine-image` | Editing via `image_url`, aspect ratio support (default) |
| `grok-2-image` | Basic generation, no editing or aspect ratio support |

## Usage

### Slash Command

```
/generate-image a golden retriever in a field of sunflowers
/generate-image --edit ./photo.png remove the background and make it transparent
```

The command prompts you to select a provider (Gemini, OpenAI, or both in parallel) and an output path.

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

# Use a specific model
bash scripts/gemini.sh \
  --mode generate \
  --prompt "quick sketch" \
  --output ./sketch.png \
  --model gemini-2.5-flash-preview-image-generation
```

**Flags:**

| Flag | Values | Default | Required |
|------|--------|---------|----------|
| `--mode` | `generate`, `edit` | -- | Yes |
| `--prompt` | text | -- | Yes |
| `--output` | file path | -- | Yes |
| `--input-image` | file path | -- | Edit mode only |
| `--aspect-ratio` | `1:1`, `16:9`, `9:16`, `4:3`, `3:4`, `3:2`, `2:3`, `4:5`, `5:4`, `21:9` | `1:1` | No |
| `--model` | Gemini model name | `gemini-2.5-flash-image` | No |

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
| `--size` | `1024x1024`, `1536x1024`, `1024x1536` | `1024x1024` | No |
| `--quality` | `low`, `medium`, `high` | `high` | No |
| `--background` | `transparent`, `opaque`, `auto` | `auto` | No |
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

# Use a different model
bash scripts/xai.sh \
  --mode generate \
  --prompt "a cat in a tree" \
  --output ./cat.png \
  --model grok-imagine-image
```

**Flags:**

| Flag | Values | Default | Required |
|------|--------|---------|----------|
| `--mode` | `generate`, `edit` | -- | Yes |
| `--prompt` | text | -- | Yes |
| `--output` | file path | -- | Yes |
| `--input-image` | file path | -- | Edit mode only |
| `--aspect-ratio` | `1:1`, `16:9`, `9:16`, `4:3`, `3:4`, `3:2`, `2:3`, `2:1`, `1:2`, etc. | (none) | No |
| `--model` | xAI model name | `grok-imagine-image` | No |

## Provider Comparison

| Feature | Gemini | OpenAI | xAI |
|---------|--------|--------|-----|
| Default model | gemini-2.5-flash-image | gpt-image-1.5 | grok-imagine-image |
| Text rendering | Good | Excellent | Good |
| Transparent BG | No | Yes | No |
| Aspect ratios | 10 options (1:1 to 21:9) | 3 fixed sizes | 14 options (1:1 to 20:9) |
| Image editing | Multi-turn refinement | Up to 16 input images | Same endpoint, via image_url |
| Quality tiers | N/A | low / medium / high | N/A |
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
| Display utility | `scripts/display.sh` | Multi-protocol terminal image display (iTerm2, Kitty, Sixel, tmux pane) |
| API reference | `skills/image-generation/references/api-details.md` | Endpoint and payload documentation |

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
hooks/                         -- Lifecycle hooks (SessionStart)
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

When running inside **tmux** (including Claude Code sessions), images are displayed in a split pane targeting the originating pane (via `$TMUX_PANE`). The pane uses `imgcat` (iTerm2), `kitten icat` (Kitty), or a Sixel tool depending on the outer terminal. Press **f** to reveal in Finder, **p** to open in Preview, or **Esc**/**Ctrl+D** to close.

For parallel generation, use `SKIP_DISPLAY=1` per provider script, then call `display_images` to show all results stacked in a vertical side pane.

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
