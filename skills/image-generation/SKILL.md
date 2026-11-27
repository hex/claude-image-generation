---
name: image-generation
description: Generates and edits images using Google Gemini, OpenAI GPT Image, xAI Grok Image, and OpenRouter APIs via shell scripts. This skill should be used when the user asks to "generate an image", "create an image", "edit an image", "modify an image", "make a picture", "draw me a", "text to image", "generate with gemini", "generate with openai", "generate with xai", "generate with grok", "generate with openrouter", "gpt image", "gemini image", "grok image", or "openrouter image".
version: 2026.11.3
---

# Image Generation with Gemini, OpenAI, xAI, and OpenRouter

Generate and edit images using Google Gemini, OpenAI GPT Image 2, xAI Grok Image, and OpenRouter APIs via shell scripts.

## Available Providers

### Google Gemini
- **Model**: `gemini-3-pro-image` (default, "Nano Banana Pro"). Alt: `gemini-3.1-flash-image` (Flash, 14 ratios), `gemini-nano-banana-2.1` (Flash, "Nano Banana 2.1", Google's replacement for `gemini-3.1-flash-image` and the plugin's fallback), `gemini-3.1-flash-lite-image` (cheapest). The `-preview` IDs are past their shutdown date.
- **Strengths**: Premium quality, up to 4K output, thinking mode, Google Search grounding, multi-turn editing with up to 14 reference images
- **Aspect ratios**: 10 on Pro (1:1, 16:9, 9:16, 4:3, 3:4, 3:2, 2:3, 4:5, 5:4, 21:9); Flash adds 4 extreme ratios (1:4, 4:1, 1:8, 8:1)
- **Resolution**: `--image-size` takes `1K`, `2K`, `4K` on both Pro and Flash; Flash additionally supports `512` (UPPERCASE required)
- **Env var**: `GEMINI_API_KEY`

### OpenAI GPT Image 2
- **Model**: `gpt-image-2.6-sunburst` (default); `gpt-image-2.6-flare` (faster), `gpt-image-2.5-sunburst`, `gpt-image-2` (snapshot `gpt-image-2-2026-04-21`) and `gpt-image-1.5` (previous flagship, shuts down 2026-12-01) available via `--model`
- **Strengths**: Superior text rendering, transparent backgrounds, up to 16 input images for editing, quality tiers
- **Sizes**: on `gpt-image-2` and the `gpt-image-2.5` models, any `WxH` with both edges multiples of 16, longest edge up to 3840 and ratio at most 3:1 (such as `2048x1152`, `3840x2160`). OpenAI's guide gives the 2.6 models (Sunburst and Flare) the same rules. Older models take `1024x1024`, `1536x1024` (landscape), `1024x1536` (portrait)
- **Quality**: low (fast/cheap), medium, high; xhigh and max on the `gpt-image-2.5` and `2.6` models
- **Env var**: `OPENAI_API_KEY`

### xAI Grok Image
- **Model**: `grok-imagine-image-2.0` (default, flagship since 2026-08-07), `grok-imagine-image` (standard, 300 RPM). xAI has retired `grok-imagine-image-quality`, the May 2026 quality mode: the API answered HTTP 404 for it on 2026-11-26
- **Strengths**: Prompt revision by chat model, flat per-image pricing, diverse style range, many aspect ratios
- **Aspect ratios**: 1:1, 16:9, 9:16, 4:3, 3:4, 3:2, 2:3, 2:1, 1:2, 19.5:9, 9:19.5, 20:9, 9:20, 21:9, 5:2, auto
- **Resolution**: `--resolution` takes `1k`, `2k` (LOWERCASE required, opposite of Gemini)
- **Quality**: `--quality` takes `low`, `medium`, `auto` on `grok-imagine-image-2.0`; unset means auto (low for generation, medium for edits), billed as served
- **Editing**: Dedicated `/v1/images/edits` endpoint; up to 5 input images passed as data URIs in an `images` array
- **Env var**: `XAI_API_KEY` or `GROK_API_KEY`

### OpenRouter (gateway)
- **Model**: any OpenRouter model slug that supports image output; default `google/gemini-nano-banana-2.1`. Others: `google/gemini-3.1-flash-image`, `google/gemini-3-pro-image`, `x-ai/grok-imagine-image-2.0`, `openai/gpt-image-2`, and more at [openrouter.ai/models](https://openrouter.ai/models?fmt=cards&output_modalities=image)
- **Strengths**: One key reaches many providers' image models; useful for access, fallback, and comparison without separate accounts
- **API shape**: Every request goes to chat completions (`/api/v1/chat/completions`) with `modalities: ["image","text"]`, and the image comes back as a base64 data URL in `message.images[]`. When chat completions answers HTTP 404 because OpenRouter serves the model only on its images endpoint (`openai/gpt-image-2`, `x-ai/grok-imagine-image-2.0`), the script sends the same request once to `/api/v1/images`, and the image comes back as base64 in `data[].b64_json`
- **Editing**: Input images are `image_url` parts holding base64 data URLs: content parts of the user message on chat completions, `input_references` on the images endpoint
- **Controls**: `--aspect-ratio` and `--size-tier` go to chat completions as `image_config` and to the images endpoint as `aspect_ratio` and `resolution`; quality is model-dependent
- **Env var**: `OPENROUTER_API_KEY` (optional `OPENROUTER_SITE_URL` / `OPENROUTER_SITE_NAME` for attribution)

## Usage

### Generate Tool

When `mcp__claude-image-generation__generate` is available (Claude Code builds with function
hooks), prefer it over the scripts below. It takes `prompt`, and optionally `providers`,
`outputBase` (a path without extension), `inputImages` (switches to edit mode) and
`aspectRatio` (`W:H`) and `size` (`1K`, `2K` or `4K`), each for every provider. Leave `providers` and `outputBase` out unless the request
gives them: the tool uses the person's `/config` defaults. It runs `run-all.sh`, so the gallery
or pane and the retry offer behave as described under Parallel Generation, and it answers with each
expected file marked `saved` or `missing`. It never overwrites: when any
`<outputBase>-<provider>.png` already exists it refuses the call and names each path, so pick
an unused `outputBase` (add `-2`, `-3`) rather than deleting the old files. Use the scripts instead when the request needs an
option the tool does not take, such as `--quality`, `--background`, `--model`.

A provider whose model does not draw the ratio you ask for, or takes no size when you give one,
fails before its request, with an error that names the ratios it draws; the others still run.
openrouter checks only `google/` and `x-ai/` models, and sends any other model the ratio and size
unchecked. xai keeps the input image's shape on a single-image edit, and draws `2k` for `4K`, and
says so both times. openai
draws the ratio and tier as one `WxH` (16:9 at 2K is `2736x1536`; ratios past 3:1 are not in
its table).

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

# OpenRouter (any image model via --model; default google/gemini-nano-banana-2.1)
bash "${CLAUDE_PLUGIN_ROOT}/scripts/openrouter.sh" \
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

# OpenRouter
bash "${CLAUDE_PLUGIN_ROOT}/scripts/openrouter.sh" \
  --mode edit \
  --prompt "change the sky to a starry night" \
  --input-image ./original.png \
  --output ./edited.png
```

### Parallel Generation

Use `scripts/run-all.sh` — a single Bash call that forks all providers in parallel as one run.
By default (`IMAGE_DISPLAY=gallery`) the run shows on the browser gallery page every session
shares: a section with one frame per provider, filled in as each finishes, with nothing drawn in the terminal.
The page can also delete a finished run, one image of it, or every finished run of a project, with the image files
they saved, after a dialog that lists each file. Its Edit prompt button sends a run-all.sh run's prompt again, edited,
with an aspect ratio and size, to the providers the person picks, and once a run has ended each failed frame has a
Retry that runs that provider again and saves to `<base>-<provider>.png`; the server starts run-all.sh for both and
the results show only on the page, never reaching Claude.
With `IMAGE_DISPLAY=pane` it streams into one shared tmux pane instead, whose watcher renders per-provider colored banners (gemini
blue / openai gray / xai red / openrouter indigo) with model + timing, plus a bottom `waiting on`
line naming the pending providers. It animates until the first image renders; after that it is
written once under each new block and never rewritten, so the inline images accumulate (a
repeated redraw would erase them in tmux control mode).

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-all.sh" \
  --mode generate \
  --prompt "<prompt>" \
  --output-base "<base>"
```

Each provider produces `<base>-<provider>.png` (e.g. `<base>-gemini.png`, `<base>-openai.png`,
`<base>-xai.png`). The default set is `gemini,openai,xai`; OpenRouter is opt-in. No script
overwrites a file: a provider whose output path already exists, as a file or a symlink, exits 1
before calling its API while the others run, so choose a base whose files do not exist yet.

Optional flags:
- `--input-image <path>` — required for `--mode edit`; repeatable, every image is forwarded to each provider. Forwarding happens in edit mode only — for Gemini's generate-mode reference images, call gemini.sh directly. Each path must be a PNG, JPEG, WebP or GIF file; the type is read from its bytes, and anything else is refused before any API call
- `--providers gemini,openai` — comma-separated subset; add `openrouter` to include it (e.g. `--providers gemini,openai,xai,openrouter`)
- `--aspect-ratio 16:9` and `--size 2K` (`1K`, `2K`, `4K`) — one shape for every provider; a provider's own flag in its extra args (`--image-size`, `--resolution`, `--size`) wins
- `--gemini-extra "--image-size 4K --aspect-ratio 16:9"` — pass-through args to gemini.sh
- `--openai-extra "--quality high"` — pass-through args to openai.sh
- `--xai-extra "--resolution 2k"` — pass-through args to xai.sh
- `--openrouter-extra "--model openai/gpt-image-2"` — pass-through args to openrouter.sh

In pane mode, providers share a pane only while they overlap in time: each finds this tmux window's pane
through a registry entry and joins it, and the pane closes once the last provider sharing it
has finished. Running the provider scripts as separate sequential Bash calls therefore gives a
pane (or a gallery run) per call, which is why `run-all.sh` is the way to reach more than one provider at once.

In pane mode, run-all.sh captures each provider's stderr/stdout under
`$DISPLAY_PANE_DIR/logs/<provider>.{out,err}` while the pane is open, and errors render as a
red error banner inline. In the gallery, provider output stays on run-all.sh's own output and
errors show in the provider's frame of the run. After all providers finish, run-all.sh closes the pane (or
marks the gallery run finished) and exits with status 0 if every provider succeeded, 1
otherwise.

If any provider failed, the pane offers a retry (`[r] retry failed (xai) · [esc/ctrl-d] close 45s`)
before run-all.sh exits; pressing `r` re-runs just the failed providers in the same call, and
letting the offer expire or pressing Esc closes the pane and returns the run's existing result.
The offer counts down until the first image is on the pane; after that it shows the time budget
once (`close (up to 45s)`), because a rewritten line erases the pane's images. In the gallery
the offer is the run's Retry failed button, and run-all.sh makes it only while a gallery page is open;
with none open, a failed run returns at once.

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
- `--input-image` is repeatable on all providers, but the modes differ: Gemini accepts up to 14 images in both `--mode generate` (references for a fresh composition) and `--mode edit`; OpenAI (up to 16) and xAI (up to 5) accept input images in `--mode edit` only — their generation endpoints take no images
- For Gemini: supports iterative multi-turn refinement; compose the flat 14-image budget as up to 6 object + 5 character-consistency + 3 style-reference images. There is no API field to tag an image's role — the model infers it from the prompt, so state which images are objects, characters, or style references
- For xAI: prompts are revised by a chat model before generation

## Error Handling

- Scripts exit with code 1 on failure and print error details to stderr
- If an API key is missing, the script exits immediately with a clear message
- `Error: --output already exists, refusing to overwrite it: <path>` means a file or a symlink holds the path, and the script sent no request. Rerun with a new path rather than deleting the file
- `Could not save the image to <path>: <reason>` means the API answered but the script did not write the image: `File exists` when something appeared at the path during the request, the system's error (`Operation not supported` on macOS) when the folder's filesystem has no hard links (FAT, for one), or the decoder's error when the image data did not decode. The script leaves no partial file behind and touches nothing at the path
- HTTP errors include the status code and API error message
- If multiple providers are used in parallel and one fails, report the error and present the successful results
- Rate limit errors (HTTP 429) mean the provider's quota is exhausted. The script retries a 429 up to three times first; if it still fails, try again later or use another provider
- The script automatically retries HTTP 429, 500, 502, 503 or 504, or a network failure, up to three times with a doubling delay before giving up
- When the default model is unavailable to the key (HTTP 404, a 403 outside OpenRouter, or a 400 saying the model does not exist), the script sends the request once more with the provider's fallback and says so on stderr: gemini `gemini-nano-banana-2.1`, openai `gpt-image-2.5-sunburst`, xai `grok-imagine-image`, openrouter `google/gemini-3.1-flash-image`. Report which model drew the image. A model named with `--model` or `*_IMAGE_MODEL` never falls back. Once the fallback answers HTTP 200, even with no image in it, the script records the verdict and later runs send the fallback first until it expires: the default's own unavailable answer is the evidence, and the fallback's 200 shows the account and endpoint work

| Env var | Default | Purpose |
|---------|---------|---------|
| `IMAGE_MAX_RETRIES` | 3 | Retry attempts for a transient API failure before the script gives up |
| `IMAGE_RETRY_DELAY` | 1 | Starting retry delay in seconds; doubles on each attempt |
| `IMAGE_AVAILABILITY_TTL` | 86400 | Seconds a remembered "default model unavailable" verdict holds; 0 tries the default every run |
| `DISPLAY_PANE_RETRY_WAIT` | 45 | Seconds the retry offer (the pane's, or the gallery's Retry failed button) stays open after a run-all.sh failure; 0 disables the offer |
| `IMAGE_DISPLAY` | gallery | Where images show: `gallery` (browser page), `pane` (tmux pane, or inline outside tmux), `none` |

## Script Options Reference

### gemini.sh
| Flag | Values | Default |
|------|--------|---------|
| `--mode` | generate, edit | (required) |
| `--prompt` | text | (required) |
| `--output` | file path | (required) |
| `--input-image` | file path, repeatable (max 14) | (required for edit; optional refs in generate) |
| `--aspect-ratio` | 10 on the default Pro model (1:1, 16:9, 9:16, 4:3, 3:4, 3:2, 2:3, 4:5, 5:4, 21:9); the Nano Banana 2 models add 1:4, 4:1, 1:8, 8:1; the script refuses any other before the request | 1:1 |
| `--image-size` | 512, 1K, 2K, 4K (UPPERCASE) | (API default 1K) |
| `--size-tier` | 1K, 2K, 4K; sent as `--image-size`; `--image-size` wins | (none) |
| `--thinking-level` | minimal, High | unset (API `minimal`) |
| `--image-only` | (flag) | off |
| `--search-grounding` | (flag) | off |
| `--model` | gemini model name | gemini-3-pro-image |

### openai.sh
| Flag | Values | Default |
|------|--------|---------|
| `--mode` | generate, edit | (required) |
| `--prompt` | text | (required) |
| `--output` | file path | (required) |
| `--input-image` | file path, repeatable (max 16) | (edit only) |
| `--size` | auto or WxH (gpt-image-2, the 2.5 and the 2.6 models: edges multiples of 16, max edge 3840, ratio up to 3:1, 655,360 to 8,294,400 pixels; above `2560x1440` is experimental on the 2.5 models); older models: `1024x1024`, `1536x1024`, `1024x1536` | `1024x1024` |
| `--aspect-ratio` | a ratio from the README's table, drawn as its `WxH`; `--size` wins; refused on models that take only three sizes | (none) |
| `--size-tier` | 1K, 2K, 4K, drawn as the table's `WxH` (1:1 when no ratio); `--size` wins | (none) |
| `--quality` | auto, low, medium, high; xhigh and max on the 2.5 and 2.6 models | high |
| `--background` | auto, transparent, opaque; transparent needs png or webp output | auto |
| `--output-format` | png, jpeg, webp | png |
| `--output-compression` | 0-100 (jpeg/webp only) | -- |
| `--moderation` | auto, low | auto |
| `--input-fidelity` | low, high (edit only); not accepted with gpt-image-2 (that model always uses high fidelity) or gpt-image-2.6-sunburst, and openai.sh refuses the flag for both | unset (API `low`) |
| `--model` | OpenAI model name | gpt-image-2.6-sunburst |

### xai.sh
| Flag | Values | Default |
|------|--------|---------|
| `--mode` | generate, edit | (required) |
| `--prompt` | text | (required) |
| `--output` | file path | (required) |
| `--input-image` | file path, repeatable (max 5) | (edit only) |
| `--aspect-ratio` | 16 ratios (1:1, 16:9, 21:9, 5:2, 20:9, auto, etc.) | (none) |
| `--resolution` | 1k, 2k (LOWERCASE) | (API default) |
| `--size-tier` | 1K, 2K, 4K; sent as `--resolution`, `4K` as `2k` with a line that says so; `--resolution` wins | (none) |
| `--quality` | low, medium, auto (grok-imagine-image-2.0 only) | unset (API `auto`) |
| `--model` | xAI model name | grok-imagine-image-2.0 |

### openrouter.sh
| Flag | Values | Default |
|------|--------|---------|
| `--mode` | generate, edit | (required) |
| `--prompt` | text | (required) |
| `--output` | file path | (required) |
| `--input-image` | file path, repeatable | (required for edit; also sent in generate) |
| `--model` | any OpenRouter image model slug | google/gemini-nano-banana-2.1 |
| `--aspect-ratio` | W:H; checked for `google/` and `x-ai/` models, unchecked for others | (none) |
| `--size-tier` | 1K, 2K, 4K; `2K` for `4K` on `x-ai/` models; refused for `google/gemini-2.5-flash-image` | (none) |
| `--site-url` | URL (sent as `HTTP-Referer`) | (from `OPENROUTER_SITE_URL`) |
| `--site-name` | text (sent as `X-Title`) | (from `OPENROUTER_SITE_NAME`) |
