---
name: image-generation
description: Generates and edits images using Google Gemini and OpenAI GPT Image APIs via shell scripts. This skill should be used when the user asks to "generate an image", "create an image", "edit an image", "modify an image", "make a picture", "draw me a", "text to image", "generate with gemini", "generate with openai", "gpt image", or "gemini image".
version: 2026.2.0
---

# Image Generation with Gemini and OpenAI

Generate and edit images using Google Gemini and OpenAI GPT Image 1.5 APIs via shell scripts.

## Available Providers

### Google Gemini
- **Model**: `gemini-3-pro-image-preview` (default), `gemini-2.5-flash-image` (faster)
- **Strengths**: Multi-turn editing, aspect ratio control, Google Search grounding for factual imagery, up to 4K resolution
- **Aspect ratios**: 1:1, 16:9, 9:16, 4:3, 3:4, 3:2, 2:3, 4:5, 5:4, 21:9
- **Env var**: `GEMINI_API_KEY`

### OpenAI GPT Image 1.5
- **Model**: `gpt-image-1.5`
- **Strengths**: Superior text rendering, transparent backgrounds, up to 16 input images for editing, quality tiers
- **Sizes**: 1024x1024, 1536x1024 (landscape), 1024x1536 (portrait)
- **Quality**: low (fast/cheap), medium, high (best fidelity)
- **Env var**: `OPENAI_API_KEY`

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
```

### Parallel Generation

To generate with both providers simultaneously, use the Task tool to launch two Bash agents in parallel, each calling one script. Present both results to the user.

## Prompting Tips

### General
- Be specific and descriptive: "a golden retriever puppy playing in autumn leaves, soft afternoon light" beats "dog in park"
- Specify style explicitly: "watercolor painting", "photorealistic", "flat vector illustration"
- Include composition details: "close-up", "aerial view", "centered", "rule of thirds"

### Text in Images
- OpenAI GPT Image 1.5 is significantly better at rendering text
- Put text in quotes or ALL CAPS in the prompt: `a sign that reads "OPEN 24 HOURS"`
- Specify typography details: font style, size, color, placement

### Editing
- Describe what to change, not the whole image
- Be specific about which elements to preserve vs modify
- For Gemini: supports iterative multi-turn refinement
- For OpenAI: can accept up to 16 reference images

## Error Handling

- Scripts exit with code 1 on failure and print error details to stderr
- If an API key is missing, the script exits immediately with a clear message
- HTTP errors include the status code and API error message
- If both providers are used in parallel and one fails, report the error and present the successful result
- Rate limit errors (HTTP 429) mean the provider's quota is exhausted - try again later or use the other provider

## Script Options Reference

### gemini.sh
| Flag | Values | Default |
|------|--------|---------|
| `--mode` | generate, edit | (required) |
| `--prompt` | text | (required) |
| `--output` | file path | (required) |
| `--input-image` | file path | (edit only) |
| `--aspect-ratio` | 1:1, 16:9, etc. | 1:1 |
| `--model` | gemini model name | gemini-3-pro-image-preview |

### openai.sh
| Flag | Values | Default |
|------|--------|---------|
| `--mode` | generate, edit | (required) |
| `--prompt` | text | (required) |
| `--output` | file path | (required) |
| `--input-image` | file path | (edit only) |
| `--size` | 1024x1024, 1536x1024, 1024x1536 | 1024x1024 |
| `--quality` | low, medium, high | high |
| `--background` | transparent, opaque, auto | auto |
| `--model` | OpenAI model name | gpt-image-1.5 |
