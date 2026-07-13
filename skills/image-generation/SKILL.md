---
name: image-generation
description: Generates and edits images using Google Gemini, OpenAI GPT Image, and xAI Grok Image APIs via shell scripts. This skill should be used when the user asks to "generate an image", "create an image", "edit an image", "modify an image", "make a picture", "draw me a", "text to image", "generate with gemini", "generate with openai", "generate with xai", "generate with grok", "gpt image", "gemini image", or "grok image".
version: 2026.7.0
---

# Image Generation with Gemini, OpenAI, and xAI

Generate and edit images using Google Gemini, OpenAI GPT Image 2, and xAI Grok Image APIs via shell scripts.

## Available Providers

### Google Gemini
- **Model**: `gemini-3-pro-image-preview` (default, "Nano Banana Pro"). Alt: `gemini-3.1-flash-image-preview` (Flash, 14 ratios).
- **Strengths**: Premium quality, up to 4K output, thinking mode, Google Search grounding, multi-turn editing with up to 14 reference images
- **Aspect ratios**: 10 on Pro (1:1, 16:9, 9:16, 4:3, 3:4, 3:2, 2:3, 4:5, 5:4, 21:9); Flash adds 4 extreme ratios (1:4, 4:1, 1:8, 8:1)
- **Resolution**: `--image-size` takes `1K`, `2K`, `4K` on both Pro and Flash; Flash additionally supports `512` (UPPERCASE required)
- **Env var**: `GEMINI_API_KEY`

### OpenAI GPT Image 2
- **Model**: `gpt-image-2` (default, snapshot `gpt-image-2-2026-04-21`); `gpt-image-1.5` available as previous flagship via `--model`
- **Strengths**: Superior text rendering, transparent backgrounds, up to 16 input images for editing, quality tiers
- **Sizes**: 1024x1024, 1536x1024 (landscape), 1024x1536 (portrait)
- **Quality**: low (fast/cheap), medium, high (best fidelity)
- **Env var**: `OPENAI_API_KEY`

### xAI Grok Image
- **Model**: `grok-imagine-image-pro` (default, premium tier, 30 RPM), `grok-imagine-image` (standard, 300 RPM)
- **Strengths**: Prompt revision by chat model, flat per-image pricing, diverse style range, many aspect ratios
- **Aspect ratios**: 1:1, 16:9, 9:16, 4:3, 3:4, 3:2, 2:3, 2:1, 1:2, 19.5:9, 9:19.5, 20:9, 9:20, auto
- **Resolution**: `--resolution` takes `1k`, `2k` (LOWERCASE required, opposite of Gemini)
- **Editing**: Dedicated `/v1/images/edits` endpoint; up to 3 input images passed as data URIs in an `images` array
- **Env var**: `XAI_API_KEY` or `GROK_API_KEY`

## Usage

### Text-to-Image Generation

Use the scripts at `${CLAUDE_PLUGIN_ROOT}/scripts/`:

```bash
# Gemini
bash "${CLAUDE_PLUGIN_ROOT}/scripts/gemini.sh" \
  --mode generate \
  --prompt "a serene mountain landscape at sunset" \
  --output ./generated.png

# OpenAI
bash "${CLAUDE_PLUGIN_ROOT}/scripts/openai.sh" \
  --mode generate \
  --prompt "a serene mountain landscape at sunset" \
  --output ./generated.png

# xAI
bash "${CLAUDE_PLUGIN_ROOT}/scripts/xai.sh" \
  --mode generate \
  --prompt "a serene mountain landscape at sunset" \
  --output ./generated.png
```

### Image Editing

```bash
# Gemini
bash "${CLAUDE_PLUGIN_ROOT}/scripts/gemini.sh" \
  --mode edit \
  --prompt "change the sky to a starry night" \
  --input-image ./original.png \
  --output ./edited.png

# OpenAI
bash "${CLAUDE_PLUGIN_ROOT}/scripts/openai.sh" \
  --mode edit \
  --prompt "change the sky to a starry night" \
  --input-image ./original.png \
  --output ./edited.png

# xAI
bash "${CLAUDE_PLUGIN_ROOT}/scripts/xai.sh" \
  --mode edit \
  --prompt "change the sky to a starry night" \
  --input-image ./original.png \
  --output ./edited.png
```

### Parallel Generation

Use `scripts/run-all.sh` — a single Bash call that owns the streaming pane lifecycle and
forks all providers in parallel. The watcher renders per-provider colored banners (gemini
blue / openai gray / xai red) with model + timing, plus an animated bottom spinner of
pending providers shown until the first image renders. Once the first image appears the
spinner goes silent so the inline images accumulate (further redraws would erase them in
tmux control mode).

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-all.sh" \
  --mode generate \
  --prompt "<prompt>" \
  --output-base "<base>"
```

Each provider produces `<base>-gemini.png`, `<base>-openai.png`, `<base>-xai.png`.

Optional flags:
- `--input-image <path>` — required for `--mode edit`; repeatable, every image is forwarded to each provider. Forwarding happens in edit mode only — for Gemini's generate-mode reference images, call gemini.sh directly
- `--providers gemini,openai` — comma-separated subset
- `--gemini-extra "--image-size 4K --aspect-ratio 16:9"` — pass-through args to gemini.sh
- `--openai-extra "--quality high"` — pass-through args to openai.sh
- `--xai-extra "--resolution 2k"` — pass-through args to xai.sh

Per-provider stderr/stdout is captured under `$DISPLAY_PANE_DIR/logs/<provider>.{out,err}`
while the pane is open. Errors render as a red error banner inline. After all providers
finish, run-all.sh closes the pane and exits with status 0 if every provider succeeded, 1
otherwise.

## Prompting Tips

### General
- Be specific and descriptive: "a golden retriever puppy playing in autumn leaves, soft afternoon light" beats "dog in park"
- Specify style explicitly: "watercolor painting", "photorealistic", "flat vector illustration"
- Include composition details: "close-up", "aerial view", "centered", "rule of thirds"

### Text in Images
- OpenAI GPT Image 2 is significantly better at rendering text
- Put text in quotes or ALL CAPS in the prompt: `a sign that reads "OPEN 24 HOURS"`
- Specify typography details: font style, size, color, placement

### Editing
- Describe what to change, not the whole image
- Be specific about which elements to preserve vs modify
- `--input-image` is repeatable on all providers, but the modes differ: Gemini accepts up to 14 images in both `--mode generate` (references for a fresh composition) and `--mode edit`; OpenAI (up to 16) and xAI (up to 3) accept input images in `--mode edit` only — their generation endpoints take no images
- For Gemini: supports iterative multi-turn refinement; compose the flat 14-image budget as up to 6 object + 5 character-consistency + 3 style-reference images. There is no API field to tag an image's role — the model infers it from the prompt, so state which images are objects, characters, or style references
- For xAI: prompts are revised by a chat model before generation

## Error Handling

- Scripts exit with code 1 on failure and print error details to stderr
- If an API key is missing, the script exits immediately with a clear message
- HTTP errors include the status code and API error message
- If multiple providers are used in parallel and one fails, report the error and present the successful results
- Rate limit errors (HTTP 429) mean the provider's quota is exhausted - try again later or use the other provider

## Script Options Reference

### gemini.sh
| Flag | Values | Default |
|------|--------|---------|
| `--mode` | generate, edit | (required) |
| `--prompt` | text | (required) |
| `--output` | file path | (required) |
| `--input-image` | file path, repeatable (max 14) | (required for edit; optional refs in generate) |
| `--aspect-ratio` | 14 ratios (1:1, 16:9, 21:9, 1:4, 4:1, 1:8, 8:1, etc.) | 1:1 |
| `--image-size` | 512, 1K, 2K, 4K (UPPERCASE) | (API default 1K) |
| `--thinking-level` | minimal, High | unset (API `minimal`) |
| `--image-only` | (flag) | off |
| `--search-grounding` | (flag) | off |
| `--model` | gemini model name | gemini-3-pro-image-preview |

### openai.sh
| Flag | Values | Default |
|------|--------|---------|
| `--mode` | generate, edit | (required) |
| `--prompt` | text | (required) |
| `--output` | file path | (required) |
| `--input-image` | file path, repeatable (max 16) | (edit only) |
| `--size` | auto, 1024x1024, 1536x1024, 1024x1536 | 1024x1024 |
| `--quality` | auto, low, medium, high | high |
| `--background` | auto, transparent, opaque | auto |
| `--output-format` | png, jpeg, webp | png |
| `--output-compression` | 0-100 (jpeg/webp only) | -- |
| `--moderation` | auto, low | auto |
| `--input-fidelity` | low, high (edit only) | unset (API `low`) |
| `--model` | OpenAI model name | gpt-image-2 |

### xai.sh
| Flag | Values | Default |
|------|--------|---------|
| `--mode` | generate, edit | (required) |
| `--prompt` | text | (required) |
| `--output` | file path | (required) |
| `--input-image` | file path, repeatable (max 3) | (edit only) |
| `--aspect-ratio` | 14 ratios (1:1, 16:9, 19.5:9, 20:9, auto, etc.) | (none) |
| `--resolution` | 1k, 2k (LOWERCASE) | (API default) |
| `--model` | xAI model name | grok-imagine-image-pro |
