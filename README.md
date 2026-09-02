# claude-image-generation

Claude Code plugin for generating and editing images using Google Gemini, OpenAI GPT Image, xAI Grok Image, and OpenRouter APIs.

## Features

- **Text-to-image generation** with Google Gemini, OpenAI GPT Image 2, xAI Grok Image, or any image model on OpenRouter
- **OpenRouter gateway** — reach any OpenRouter image model (Gemini, GPT Image, and more) through one key via the chat-completions API
- **Image editing** with text instructions (all providers)
- **Multi-image input** — repeatable `--input-image` for multi-image edits (all providers) and Gemini reference-based generation
- **Parallel generation** across all providers via `scripts/run-all.sh` — one shared streaming pane, council-style colored banners, and a pending-provider spinner shown until the first image renders
- **Interactive provider selection** via AskUserQuestion at runtime
- **Inline image preview** -- generated images display directly in the terminal (iTerm2, Kitty, Ghostty, WezTerm, Sixel terminals)
- **Tmux pane display** -- opens a split pane for image preview when running inside tmux (works with Claude Code). Providers running at the same time share one pane, however they were launched
- **Streaming display** -- images appear progressively in a shared pane during parallel generation, accumulating as each provider finishes
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
| `OPENROUTER_API_KEY` | OpenRouter | [OpenRouter Keys](https://openrouter.ai/keys) |

At least one key is required.

### Model Selection

Override the default model per provider via environment variables:

| Variable | Default | Purpose |
|----------|---------|---------|
| `GEMINI_IMAGE_MODEL` | `gemini-3-pro-image-preview` | Gemini model used for generation and editing |
| `OPENAI_IMAGE_MODEL` | `gpt-image-2` | OpenAI model used for generation and editing |
| `XAI_IMAGE_MODEL` | `grok-imagine-image-pro` | xAI model used for generation and editing |
| `OPENROUTER_IMAGE_MODEL` | `google/gemini-3.1-flash-image` | OpenRouter model slug used for generation and editing |

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
| `gpt-image-2` | Latest flagship, snapshot `gpt-image-2-2026-04-21` (default) |
| `gpt-image-1.5` | Previous flagship, superior text rendering, transparent backgrounds, quality tiers |
| `gpt-image-1-mini` | 3-4x cheaper, cost-efficient for drafts and previews |
| `gpt-image-1` | Older generation |

### Available xAI Models

| Model | Characteristics |
|-------|-----------------|
| `grok-imagine-image-pro` | Premium tier, higher quality, 30 RPM (default) |
| `grok-imagine-image` | Standard tier, 1K/2K resolution, 300 RPM, same endpoint and parameters |

### Available OpenRouter Models

OpenRouter is a gateway, so `--model` (or `OPENROUTER_IMAGE_MODEL`) accepts any OpenRouter slug that supports image output. A few:

| Model | Characteristics |
|-------|-----------------|
| `google/gemini-3.1-flash-image` | Fast Gemini image model, generation + editing (default) |
| `google/gemini-3-pro-image-preview` | Pro-tier Gemini image model, premium quality |
| `openai/gpt-5-image` | OpenAI GPT image model via OpenRouter (also `openai/gpt-5-image-mini`) |

Browse the full list at [openrouter.ai/models](https://openrouter.ai/models?fmt=cards&output_modalities=image).

## Usage

### Slash Command

```
/generate-image a golden retriever in a field of sunflowers
/generate-image --edit ./photo.png remove the background and make it transparent
```

The command prompts you to select a provider (Gemini, OpenAI, xAI, OpenRouter, or all in parallel) and an output path.

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
| `--input-image` | file path, repeatable (max 14) | -- | Edit mode; optional in generate mode as references |
| `--aspect-ratio` | `1:1`, `16:9`, `9:16`, `4:3`, `3:4`, `3:2`, `2:3`, `4:5`, `5:4`, `21:9` on Pro (default); add `1:4`, `4:1`, `1:8`, `8:1` on `gemini-3.1-flash-image-preview` | `1:1` | No |
| `--image-size` | `512`, `1K`, `2K`, `4K` (UPPERCASE); `512` requires `gemini-3.1-flash-image-preview` | (API default `1K`) | No |
| `--thinking-level` | `minimal`, `High` | unset (API default `minimal`) | No |
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
| `--input-image` | file path, repeatable (max 16; `dall-e-2` allows 1) | -- | Edit mode only |
| `--size` | `auto`, `1024x1024`, `1536x1024`, `1024x1536` | `1024x1024` | No |
| `--quality` | `auto`, `low`, `medium`, `high` | `high` | No |
| `--background` | `auto`, `transparent`, `opaque` | `auto` | No |
| `--output-format` | `png`, `jpeg`, `webp` | `png` | No |
| `--output-compression` | integer 0-100 (jpeg/webp only) | -- | No |
| `--moderation` | `auto`, `low` | `auto` | No |
| `--input-fidelity` | `low`, `high` (edit only) | unset (API default `low`) | No |
| `--model` | OpenAI model name | `gpt-image-2` | No |

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
| `--input-image` | file path, repeatable (max 3) | -- | Edit mode only |
| `--aspect-ratio` | `1:1`, `16:9`, `9:16`, `4:3`, `3:4`, `3:2`, `2:3`, `2:1`, `1:2`, `19.5:9`, `9:19.5`, `20:9`, `9:20`, `auto` | (none) | No |
| `--resolution` | `1k`, `2k` (LOWERCASE) | (API default) | No |
| `--model` | xAI model name | `grok-imagine-image-pro` | No |

**Note**: For single-image edits, xAI ignores `--aspect-ratio` and uses the input image's ratio. Multi-image edits allow aspect ratio override (the script accepts up to 3 images; the API itself supports up to 5).

#### openrouter.sh

OpenRouter is a gateway to many image models through a single key. It uses the chat-completions API, so `--model` accepts any OpenRouter model slug that supports image output.

```bash
# Generate (default model: google/gemini-3.1-flash-image)
bash scripts/openrouter.sh \
  --mode generate \
  --prompt "a mountain at sunset" \
  --output ./mountain.png

# Generate with a specific model
bash scripts/openrouter.sh \
  --mode generate \
  --prompt "a cat in a tree" \
  --output ./cat.png \
  --model openai/gpt-5-image

# Edit (single or multiple --input-image)
bash scripts/openrouter.sh \
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
| `--input-image` | file path, repeatable | -- | Edit mode only |
| `--model` | any OpenRouter image model slug | `google/gemini-3.1-flash-image` | No |
| `--site-url` | URL | (none) | No (sent as `HTTP-Referer` for OpenRouter attribution) |
| `--site-name` | text | (none) | No (sent as `X-Title` for OpenRouter attribution) |

`--site-url` / `--site-name` also default from `OPENROUTER_SITE_URL` / `OPENROUTER_SITE_NAME`.

#### Reference Images and Multi-Image Composition

`--input-image` is repeatable on all four scripts. Passing more images than a provider supports exits with code 1 before any API call:

| Provider | Max images | Modes |
|----------|------------|-------|
| Gemini | 14 | `generate` (references for a fresh composition) and `edit` |
| OpenAI | 16 | `edit` only (its generation endpoint takes no images) |
| xAI | 3 | `edit` only |
| OpenRouter | model-dependent | `edit` only (input images attached as chat image parts) |

```bash
# Gemini: compose a new image from reference images (generate mode)
bash scripts/gemini.sh \
  --mode generate \
  --prompt "a product shot combining the chair from the first image with the fabric of the second" \
  --input-image ./chair.png \
  --input-image ./fabric.png \
  --output ./composite.png

# OpenAI: multi-image edit
bash scripts/openai.sh \
  --mode edit \
  --prompt "place the logo from the second image onto the mug in the first" \
  --input-image ./mug.png \
  --input-image ./logo.png \
  --output ./branded.png

# xAI: multi-image edit
bash scripts/xai.sh \
  --mode edit \
  --prompt "blend both scenes into one panorama" \
  --input-image ./left.png \
  --input-image ./right.png \
  --output ./panorama.png

# All providers in parallel (edit mode only)
bash scripts/run-all.sh \
  --mode edit \
  --prompt "combine these" \
  --input-image ./ref-a.png \
  --input-image ./ref-b.png \
  --output-base ./combined
```

Gemini's flat 14-image budget is best composed as up to 6 object + 5 character-consistency + 3 style-reference images. There is no API field to tag an image's role — the model infers it from the prompt, so state which images are objects, characters, or style references.

**Notes:**

- `run-all.sh` forwards every `--input-image` to each selected provider, but only in `--mode edit`. Gemini's generate-mode reference images are not forwarded through run-all — call `scripts/gemini.sh` directly for generate-with-references.
- `dall-e-2` edits are a known limitation: the script rejects multiple images for `dall-e-2`, but single-image `dall-e-2` edits also do not work — the script sends form fields only the gpt-image models accept.

### Retries

Each provider script retries a transient API error (429 or a 5xx status, or a network failure) up to three times, with a delay that doubles each attempt (1 second, 2 seconds, 4 seconds). `IMAGE_MAX_RETRIES` and `IMAGE_RETRY_DELAY` tune the count and the starting delay. Inside a streaming pane, a retry shows on the spinner line as `(retry 2/3)`.

## Provider Comparison

| Feature | Gemini | OpenAI | xAI | OpenRouter |
|---------|--------|--------|-----|------------|
| Default model | gemini-3-pro-image-preview | gpt-image-2 | grok-imagine-image-pro | google/gemini-3.1-flash-image |
| Max resolution | 4K (via `--image-size`) | 1536x1024 | 2K (via `--resolution`) | Model-dependent |
| Text rendering | Very good (under 25 chars) | Excellent | Good | Model-dependent |
| Transparent BG | No | Yes | No | Model-dependent |
| Aspect ratios | 10 on Pro / 14 on 3.1 Flash | 3 fixed sizes | 14 options (incl. 20:9, auto) | Prompt-driven |
| Image editing | Multi-turn, up to 14 refs (generate + edit) | Up to 16 input images | `/v1/images/edits`, up to 3 images | Chat image parts (edit) |
| Quality tiers | N/A | auto / low / medium / high | N/A | Model-dependent |
| Thinking mode | Yes (`--thinking-level`) | No | No | Model-dependent |
| Search grounding | Yes (Google Search) | No | No | Model-dependent |
| Pricing | Token-based | Token-based | Flat per-image | Per OpenRouter model |
| Prompt revision | No | No | Yes (by chat model) | No |

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
| OpenRouter script | `scripts/openrouter.sh` | OpenRouter chat-completions image call execution |
| Retry helper | `scripts/retry.sh` | `curl_with_retry` for transient API failures |
| Parallel runner | `scripts/run-all.sh` | Forks all providers in parallel under one streaming pane; holds a pane token for the batch |
| Display utility | `scripts/display.sh` | Multi-protocol terminal image display (iTerm2, Kitty, Sixel, tmux pane, shared streaming pane with colored banners + pending-provider spinner) |
| API reference | `skills/image-generation/references/api-details.md` | Endpoint and payload documentation |
| Automated tests | `tests/` | bats test suite for all scripts |

## Development

### Versioning

This plugin uses calendar versioning in `YYYY.M.PATCH` format (e.g., `2026.7.1`). The version is tracked in both `.claude-plugin/plugin.json` and `skills/image-generation/SKILL.md`.

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

The scripts (`gemini.sh`, `openai.sh`, `xai.sh`, `openrouter.sh`) are standalone bash programs that handle API communication, base64 encoding/decoding, and error reporting. They are invoked by the command, agent, and skill layers. All of them source `display.sh` which auto-detects the terminal and displays generated images using the best available method.

### Terminal Image Display

| Terminal | Protocol | Detection |
|----------|----------|-----------|
| iTerm2 | OSC 1337 | `TERM_PROGRAM`, `LC_TERMINAL` |
| Kitty | Kitty graphics | `TERM=xterm-kitty` |
| Ghostty | Kitty graphics | `TERM_PROGRAM=ghostty` |
| WezTerm | Kitty graphics | `TERM_PROGRAM=WezTerm` |
| Sixel terminals | Sixel (via img2sixel/chafa/magick) | Tool + terminal detection |

When running inside **tmux** (including Claude Code sessions), provider images stream into a shared pane taking 30% of the terminal's longer axis, targeting the originating pane (via `$TMUX_PANE`). Every provider generating at that moment renders into that one pane. Direct calls to `display_image` / `display_images` outside a provider run still open a pane of their own: a bottom pane (`-v` split) for a single image, a vertical side pane (`-h` split, 30% width) for several. Panes use `imgcat` (iTerm2), `kitten icat` (Kitty), or a Sixel tool depending on the outer terminal. Press **f** to reveal in Finder, **p** to open in Preview, or **Esc**/**Ctrl+D** to close.

For parallel generation, use `scripts/run-all.sh` — a single shell that joins the streaming pane, exports `DISPLAY_PANE_DIR`, forks all providers with `&`, waits, and releases the pane.

Providers find that pane through a registry entry under `$TMPDIR` keyed by tmux session and window, so a provider launched on its own joins whatever is already streaming instead of splitting a pane of its own. The entry is a directory, making `mkdir` the atomic create-once lock: the winner opens the pane and publishes it, and callers that lose the claim wait briefly for that publication. Each participant holds a token under `active/`, and whoever drops the last one retires the entry and writes `.done`, so the pane closes once — after the last provider sharing it has finished. Sequential runs each get a fresh pane; concurrency is what makes providers share one. The watcher renders per-provider colored banners (blue/gray/red/indigo) with model + timing, plus an animated bottom spinner of pending providers shown until the first image renders (after which it stays silent, since further redraws would erase the accumulated inline images in tmux control mode). Provider scripts emit status events (`querying` / `complete` / `error`) via `display_pane_status` when running under `DISPLAY_PANE_DIR`; otherwise they fall back to `display_image` for direct terminal rendering.

## Requirements

- `curl` -- HTTP requests to provider APIs
- `jq` -- JSON construction and parsing
- `base64` -- Image data encoding/decoding (included in macOS and most Linux distributions)
- At least one API key: `GEMINI_API_KEY`, `OPENAI_API_KEY`, `XAI_API_KEY`, `GROK_API_KEY`, or `OPENROUTER_API_KEY`

**Optional (for Sixel image display):**
- `img2sixel` (from libsixel), `chafa`, or `magick` (ImageMagick 7) -- any one of these enables Sixel terminal display
- Install via: `brew install libsixel`, `brew install chafa`, or `brew install imagemagick`

## License

[MIT](LICENSE)
