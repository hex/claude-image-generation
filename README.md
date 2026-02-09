# claude-image-generation

Claude Code plugin for generating and editing images using Google Gemini and OpenAI GPT Image APIs.

## Features

- **Text-to-image generation** with Google Gemini or OpenAI GPT Image 1.5
- **Image editing** with text instructions (both providers)
- **Parallel generation** using both providers simultaneously via Task tool
- **Interactive provider selection** via AskUserQuestion at runtime
- **Session start check** that reports which API keys are configured

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

At least one key is required. The plugin reports available providers at session start.

### Model Selection

Override the default model per provider via environment variables:

| Variable | Default | Purpose |
|----------|---------|---------|
| `GEMINI_MODEL` | `gemini-3-pro-image-preview` | Gemini model used for generation and editing |
| `OPENAI_IMAGE_MODEL` | `gpt-image-1.5` | OpenAI model used for generation and editing |

Command-line `--model` flag on the scripts takes precedence over environment variables.

### Available Gemini Models

| Model | Characteristics |
|-------|-----------------|
| `gemini-3-pro-image-preview` | Pro quality, 4K support, Google Search grounding, up to 14 reference images |
| `gemini-2.5-flash-image` | Faster generation, good for iteration |

### Available OpenAI Models

| Model | Characteristics |
|-------|-----------------|
| `gpt-image-1.5` | Superior text rendering, transparent backgrounds, quality tiers |

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

# Use a different model
bash scripts/gemini.sh \
  --mode generate \
  --prompt "quick sketch" \
  --output ./sketch.png \
  --model gemini-2.5-flash-image
```

**Flags:**

| Flag | Values | Default | Required |
|------|--------|---------|----------|
| `--mode` | `generate`, `edit` | -- | Yes |
| `--prompt` | text | -- | Yes |
| `--output` | file path | -- | Yes |
| `--input-image` | file path | -- | Edit mode only |
| `--aspect-ratio` | `1:1`, `16:9`, `9:16`, `4:3`, `3:4`, `3:2`, `2:3`, `4:5`, `5:4`, `21:9` | `1:1` | No |
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
| `--size` | `1024x1024`, `1536x1024`, `1024x1536` | `1024x1024` | No |
| `--quality` | `low`, `medium`, `high` | `high` | No |
| `--background` | `transparent`, `opaque`, `auto` | `auto` | No |
| `--model` | OpenAI model name | `gpt-image-1.5` | No |

## Provider Comparison

| Feature | Gemini | OpenAI |
|---------|--------|--------|
| Default model | gemini-3-pro-image-preview | gpt-image-1.5 |
| Text rendering | Good | Excellent |
| Transparent BG | No | Yes |
| Aspect ratios | 10 options (1:1 to 21:9) | 3 fixed sizes |
| Image editing | Multi-turn refinement | Up to 16 input images |
| Quality tiers | N/A | low / medium / high |

## Plugin Components

| Component | File | Purpose |
|-----------|------|---------|
| Plugin manifest | `.claude-plugin/plugin.json` | Plugin metadata and version |
| Skill | `skills/image-generation/SKILL.md` | API knowledge, prompting tips, script reference |
| Command | `commands/generate-image.md` | `/generate-image` slash command |
| Agent | `agents/image-generator.md` | Autonomous image generation |
| Hook | `hooks/hooks.json` | SessionStart API key check |
| Key checker | `scripts/check-keys.sh` | Reports available providers |
| Gemini script | `scripts/gemini.sh` | Gemini API call execution |
| OpenAI script | `scripts/openai.sh` | OpenAI API call execution |
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

The scripts (`gemini.sh`, `openai.sh`) are standalone bash programs that handle API communication, base64 encoding/decoding, and error reporting. They are invoked by the command, agent, and skill layers.

## Requirements

- `curl` -- HTTP requests to provider APIs
- `jq` -- JSON construction and parsing
- `base64` -- Image data encoding/decoding (included in macOS and most Linux distributions)
- At least one API key: `GEMINI_API_KEY` or `OPENAI_API_KEY`

## License

[MIT](LICENSE)
