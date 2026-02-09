# image-generation

Claude Code plugin for generating and editing images using Google Gemini and OpenAI GPT Image APIs.

## Features

- **Text-to-image generation** with Google Gemini or OpenAI GPT Image 1.5
- **Image editing** with text instructions (both providers)
- **Parallel generation** using both providers simultaneously via Task tool
- **Interactive provider selection** via AskUserQuestion at runtime
- **Session start check** that reports which API keys are configured

## Prerequisites

- `jq` installed (used for JSON construction/parsing in scripts)
- `curl` installed
- One or both API keys set as environment variables:
  - `GEMINI_API_KEY` - Google AI API key ([get one](https://aistudio.google.com/apikey))
  - `OPENAI_API_KEY` - OpenAI API key ([get one](https://platform.openai.com/api-keys))

## Installation

```bash
# Use as a plugin directory
claude --plugin-dir /path/to/image-generation
```

## Usage

### Slash Command

```
/generate-image a golden retriever in a field of sunflowers
/generate-image --edit ./photo.png remove the background and make it transparent
```

### Agent (Automatic)

The `image-generator` agent triggers automatically when conversation context involves image creation. It generates with both providers in parallel and presents both results.

### Direct Script Usage

```bash
# Generate with Gemini
bash scripts/gemini.sh --mode generate --prompt "a mountain at sunset" --output ./mountain.png

# Generate with OpenAI
bash scripts/openai.sh --mode generate --prompt "a mountain at sunset" --output ./mountain.png

# Edit with Gemini
bash scripts/gemini.sh --mode edit --prompt "add snow to the peaks" --input-image ./mountain.png --output ./snowy.png

# Edit with OpenAI
bash scripts/openai.sh --mode edit --prompt "add snow to the peaks" --input-image ./mountain.png --output ./snowy.png
```

## Plugin Components

| Component | File | Purpose |
|-----------|------|---------|
| Skill | `skills/image-generation/SKILL.md` | API knowledge, prompting tips, script reference |
| Command | `commands/generate-image.md` | `/generate-image` slash command |
| Agent | `agents/image-generator.md` | Autonomous image generation |
| Hook | `hooks/hooks.json` | SessionStart API key check |
| Scripts | `scripts/gemini.sh`, `scripts/openai.sh` | API call execution |

## Provider Comparison

| Feature | Gemini | OpenAI |
|---------|--------|--------|
| Default model | gemini-3-pro-image-preview | gpt-image-1.5 |
| Text rendering | Good | Excellent |
| Transparent BG | No | Yes |
| Aspect ratios | 10 options (1:1 to 21:9) | 3 fixed sizes |
| Image editing | Multi-turn refinement | Up to 16 input images |
| Quality tiers | N/A | low / medium / high |
