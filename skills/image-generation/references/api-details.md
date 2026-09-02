# API Technical Details

## Google Gemini Image Generation

### Endpoint
```
POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent
```

### Authentication
Header: `x-goog-api-key: YOUR_API_KEY`

### Request Format
The Gemini API uses a unified `generateContent` endpoint. Images are passed as `inlineData` parts alongside text parts. Multiple input images become multiple `inlineData` parts (up to 14) ahead of the text part; the same payload shape serves both editing and reference-based generation — there is no separate edit endpoint.

```json
{
  "contents": [
    {
      "parts": [
        {
          "inlineData": {
            "mimeType": "image/png",
            "data": "<base64-encoded-image>"
          }
        },
        {
          "text": "Edit instruction here"
        }
      ]
    }
  ],
  "generationConfig": {
    "responseModalities": ["TEXT", "IMAGE"],
    "imageConfig": {
      "aspectRatio": "16:9",
      "imageSize": "2K"
    },
    "thinkingConfig": {
      "thinkingLevel": "minimal"
    }
  }
}
```

### Optional Parameters (generationConfig)

| Parameter | Values | Notes |
|-----------|--------|-------|
| `responseModalities` | `["TEXT", "IMAGE"]` or `["IMAGE"]` | Default is both; `["IMAGE"]` suppresses text response |
| `imageConfig.aspectRatio` | 14 ratios (see below) | Default `1:1` |
| `imageConfig.imageSize` | `512`, `1K`, `2K`, `4K` | **UPPERCASE required** — lowercase is a hard API rejection. Default `1K`. `512` exclusive to `gemini-3.1-flash-image`; Pro supports `1K`/`2K`/`4K`. |
| `thinkingConfig.thinkingLevel` | `minimal` (default) or `High` | Capital H. Higher levels improve complex compositions, increase latency. |
| `thinkingConfig.includeThoughts` | boolean | Controls whether thought images/text appear in response |

**14 aspect ratios** (3.1 Flash): `1:1`, `16:9`, `9:16`, `4:3`, `3:4`, `3:2`, `2:3`, `4:5`, `5:4`, `21:9`, `1:4`, `4:1`, `1:8`, `8:1`. The 4 extreme ratios are 3.1 Flash only; the Pro image model supports only 10 ratios.

### Google Search Grounding (3.1 Flash)
Top-level `tools` field (REST uses `google_search`, SDKs use `googleSearch`):

```json
{
  "contents": [...],
  "generationConfig": {...},
  "tools": [{"google_search": {}}]
}
```

3.1 Flash also supports Image Search grounding:

```json
"tools": [{"googleSearch": {"searchTypes": {"webSearch": {}, "imageSearch": {}}}}]
```

Pricing: 5,000 grounding prompts/month free across Gemini 3 models, then $14 per 1,000 queries.

### Response Format
```json
{
  "candidates": [
    {
      "content": {
        "parts": [
          {"text": "Description of generated image"},
          {
            "inlineData": {
              "mimeType": "image/png",
              "data": "<base64-encoded-output>"
            }
          }
        ]
      }
    }
  ]
}
```

### Models
- `gemini-3-pro-image` (default): "Nano Banana Pro", GA 2026-05-28. Premium tier, professional asset production, 10 aspect ratios, up to 14 reference images.
- `gemini-3.1-flash-image`: "Nano Banana 2", GA 2026-05-28. 4K output, 14 aspect ratios (incl. extreme 1:4, 4:1, 1:8, 8:1), thinking, search grounding. Also supports `512` resolution.
- `gemini-3.1-flash-lite-image`: "Nano Banana 2 Lite". Cheapest tier, about $0.034 per 1K image.
- `gemini-3-pro-image-preview` and `gemini-3.1-flash-image-preview`: the pre-GA IDs. Still answer as of 2026-09-02 but passed their earliest shutdown date (2026-06-25) and are gone from the model tables.
- `gemini-2.5-flash-image`: Previous generation, 1K only. **Scheduled shutdown 2026-10-02** — replacement is `gemini-3.1-flash-image`.

### Pricing (gemini-3.1-flash-image, Standard tier)
| Resolution | Cost per image | Output tokens |
|------------|----------------|---------------|
| 512        | $0.045         | 747           |
| 1K         | $0.067         | 1,120         |
| 2K         | $0.101         | 1,680         |
| 4K         | $0.151         | 2,520         |

Token rates: input $0.50/MTok, output text+thinking $3.00/MTok, output images $60.00/MTok. Batch API: 50% discount.

### Rate Limits
- **Free tier: image generation not available** (IPM dropped to 0 in December 2025)
- Paid tier limits now dynamic — check AI Studio dashboard for current numbers
- Tier qualification: Tier 1 ($5 paid), Tier 2 ($100 + 3 days), Tier 3 ($1,000 + 30 days)

### Constraints
- Max input image: 7 MB per image
- Max request size: 20 MB
- Input images auto-scaled to max 3072x3072
- **SynthID watermark is mandatory** — embedded in every image, cannot be disabled
- ONE image per API call (use Batch API for bulk)
- Multi-image input: up to 14 refs (10 object + 4 character on 3.1 Flash; 6 object + 5 character + 3 style on Pro)
- No transparent backgrounds, no negative prompts, no function calling/structured outputs/caching
- Text rendering: keep under 25 characters for reliable output

### finishReason codes (response field)
- `STOP`: success
- `SAFETY`: output blocked — check `safetyRatings.blocked`, rephrase and retry
- `PROHIBITED_CONTENT`: topic blocked, do not retry
- `RECITATION`: copyright detected, rephrase

---

## OpenAI GPT Image 2

### Endpoints
- Generation: `POST https://api.openai.com/v1/images/generations`
- Editing: `POST https://api.openai.com/v1/images/edits`

### Authentication
Header: `Authorization: Bearer YOUR_API_KEY`

### Generation Request
```json
{
  "model": "gpt-image-2",
  "prompt": "description",
  "n": 1,
  "size": "1024x1024",
  "quality": "high",
  "output_format": "png",
  "background": "auto",
  "moderation": "auto",
  "output_compression": 80
}
```

### Edit Request (multipart/form-data)
```
model=gpt-image-2
prompt=edit instruction
image[]=@path/to/first.png
image[]=@path/to/second.png
size=1024x1024
output_format=png
moderation=auto
input_fidelity=high
```

Multiple input images are sent as repeated `image[]` fields (up to 16). The generation endpoint accepts no image parameters, so reference-based composition goes through `/v1/images/edits`.

### Edit Request (JSON body alternative, available since 2026-02-09)
```json
POST /v1/images/edits
Content-Type: application/json

{
  "model": "gpt-image-2",
  "prompt": "...",
  "images": [
    {"image_url": "https://example.com/source.png"},
    {"file_id": "file-abc123"}
  ],
  "input_fidelity": "high"
}
```
Accepts either `image_url` (URL or base64 data URL, max 20MB) or `file_id` (Files API upload). Multipart form format still supported in parallel.

### Optional Parameters

| Parameter | Values | Notes |
|-----------|--------|-------|
| `size` | `auto`, `1024x1024`, `1536x1024`, `1024x1536` | Default `1024x1024` |
| `quality` | `auto`, `low`, `medium`, `high` | Default `high` |
| `background` | `auto`, `transparent`, `opaque` | `transparent` supported on gpt-image-2 and gpt-image-1.5 |
| `output_format` | `png`, `jpeg`, `webp` | `jpeg` is faster than `png` |
| `output_compression` | integer 0-100 | Only applies to `jpeg`/`webp` |
| `moderation` | `auto` (default), `low` | Less restrictive filtering; gpt-image models only |
| `input_fidelity` | `low` (default), `high` | Edit only. `high` preserves faces/logos/textures. For 2/1.5: first 5 images get high fidelity. For 1/mini: first image only. |
| `partial_images` | integer 0-3 | SSE streaming, +100 output tokens per partial |

### Response Format
```json
{
  "data": [
    {
      "b64_json": "<base64-encoded-image>"
    }
  ],
  "usage": {
    "total_tokens": 100,
    "input_tokens": 50,
    "output_tokens": 50
  }
}
```

### Models
- `gpt-image-2` (default): Current flagship. Snapshot: `gpt-image-2-2026-04-21`
- `gpt-image-1.5`: Previous flagship. Snapshot: `gpt-image-1.5-2025-12-16`. **Shutdown 2026-12-01**
- `gpt-image-1-mini`: 3-4x cheaper, same API surface, only first image gets high fidelity on edits. **Shutdown 2026-12-01**
- `gpt-image-1`: Older generation. **Shutdown 2026-10-23**
- `chatgpt-image-latest`: GA alias. **Shutdown 2026-12-01**; replacement for all four is `gpt-image-2`

### Pricing

**gpt-image-2**: pricing not yet enumerated on the model reference page — see https://platform.openai.com/docs/pricing for current per-image rates.

**gpt-image-1.5** output per image (excludes input tokens):
| Quality | 1024x1024 | 1024x1536 | 1536x1024 |
|---------|-----------|-----------|-----------|
| low     | $0.009    | $0.013    | $0.013    |
| medium  | $0.034    | $0.050    | $0.050    |
| high    | $0.133    | $0.200    | $0.200    |

**gpt-image-1-mini** output per image:
| Quality | 1024x1024 | 1024x1536 | 1536x1024 |
|---------|-----------|-----------|-----------|
| low     | $0.005    | $0.006    | $0.006    |
| medium  | $0.011    | $0.015    | $0.015    |
| high    | $0.036    | $0.052    | $0.052    |

Token pricing (1.5): input text $5/MTok, input image $8/MTok, output text $10/MTok, output image $32/MTok.
Token pricing (mini): input text $2/MTok, input image $2.50/MTok, output image $8/MTok.

### Rate Limits (IPM/TPM, applies to all gpt-image models)
| Tier | Qualification | IPM | TPM |
|------|---------------|-----|-----|
| Free | — | Not supported | — |
| 1 | $5 paid | 5 | 100K |
| 2 | $50 + 7 days | 20 | 250K |
| 3 | $100 + 7 days | 50 | 800K |
| 4 | $250 + 14 days | 150 | 3M |
| 5 | $1,000 + 30 days | 250 | 8M |

Batch API (available since 2026-02-10) does NOT count against IPM limits.

### Constraints
- Prompt max: 32,000 characters
- Up to 10 images per generation request
- Up to 16 input images for editing (multipart: repeated `image[]` fields; JSON: `images` array)
- Organization verification required

---

## xAI Grok Image

### Endpoints
- Generation: `POST https://api.x.ai/v1/images/generations`
- Editing: `POST https://api.x.ai/v1/images/edits` (dedicated edit endpoint, added 2026-01-28)

The plugin posts generation to `/v1/images/generations` and editing to `/v1/images/edits` (edit mode previously went through the generations endpoint with a single `image_url` — that legacy form still works). The edit endpoint supports multi-image editing (up to 5 images on grok-imagine-image-2.0, which the plugin allows).

### Authentication
Header: `Authorization: Bearer YOUR_API_KEY`

### Generation Request
```json
{
  "model": "grok-imagine-image-2.0",
  "prompt": "description",
  "n": 1,
  "response_format": "b64_json",
  "resolution": "2k",
  "aspect_ratio": "16:9"
}
```

Substitute `grok-imagine-image` for the standard-tier model — parameter schema is identical.

### Edit Request — legacy `image_url` via generations endpoint
```json
{
  "model": "grok-imagine-image-2.0",
  "prompt": "edit instruction",
  "n": 1,
  "response_format": "b64_json",
  "image_url": "data:image/png;base64,<base64-encoded-image>"
}
```

### Edit Request — dedicated `/v1/images/edits` endpoint (used by the plugin)
Single image:
```json
{
  "model": "grok-imagine-image-2.0",
  "prompt": "edit instruction",
  "image": {"type": "image_url", "url": "https://..."}
}
```

Multi-image (up to 5):
```json
{
  "model": "grok-imagine-image-2.0",
  "prompt": "...",
  "images": [
    {"type": "image_url", "url": "..."},
    {"type": "image_url", "url": "..."}
  ],
  "aspect_ratio": "3:2"
}
```

The plugin always sends the `images` array form — even for a single input image — with each entry a base64 data URI: `{"type": "image_url", "url": "data:image/png;base64,..."}`.

**Important quirk**: For single-image edits, the output aspect ratio matches the input image's ratio. You cannot override `aspect_ratio` on single-image edits. Multi-image edits allow override (defaults to first image's ratio).

### Optional Parameters
| Parameter | Values | Notes |
|-----------|--------|-------|
| `aspect_ratio` | `1:1`, `16:9`, `9:16`, `4:3`, `3:4`, `3:2`, `2:3`, `2:1`, `1:2`, `19.5:9`, `9:19.5`, `20:9`, `9:20`, `21:9`, `5:2`, `auto` | `auto` lets model pick; `21:9` and `5:2` added 2026-08-28 |
| `resolution` | `1k`, `2k` | **LOWERCASE required** — opposite of Gemini! Same price at both resolutions. |
| `n` | 1-10 | Images per request |
| `response_format` | `url`, `b64_json` | Default: `url` |

### Response Format
```json
{
  "data": [
    {
      "b64_json": "<base64-encoded-image>",
      "revised_prompt": "chat-model-revised version of your prompt"
    }
  ]
}
```

When `response_format` is `"url"`, the response contains `url` instead of `b64_json`. URLs are temporary.

### Models
- `grok-imagine-image-2.0` (default): Flagship since 2026-08-07. Adds `quality` (`low`, `medium`, `auto`; omitted means `auto`, served as `low` for generation and `medium` for edits, billed as served), up to 5 reference images on edits (was 3), and the `21:9` and `5:2` ratios (2026-08-28 release notes).
- `grok-imagine-image-quality`: Quality mode launched 2026-05-06. Aliases `grok-imagine-image-quality-20260403`, `grok-imagine-image-quality-latest` and `grok-imagine-image-pro` (the pro slug was retired 2026-05-15 and redirects here).
- `grok-imagine-image`: Standard tier. Versioned as `grok-imagine-image-2026-03-02`. 1K/2K resolution, 300 RPM.
- `grok-2-image-1212` (aka `grok-2-image`): **Deprecated 2026-02-28**. Migration target is `grok-imagine-image`.

### Pricing
| Model | Output per image | Image input |
|-------|------------------|-------------|
| `grok-imagine-image-2.0` | $0.04 (1K, low) to $0.08 by resolution and quality | $0.01 |
| `grok-imagine-image-quality` | $0.05 (1K) | $0.01 |
| `grok-imagine-image` | $0.02 | $0.002 |

Multi-image edit example: 5 images on 2.0 at 1K low = `5 × $0.01 + $0.04 = $0.09`.

### Rate Limits
- **Free tier removed 2026-03-19** — API requires billing
- `grok-imagine-image`: 300 RPM
- `grok-imagine-image-2.0` and `grok-imagine-image-quality`: see the model pages on docs.x.ai for the current limits
- Increased limits available by request form

### Batch API (2026-03-15)
Image generation and editing supported via `/v1/batches`. Batch URLs expire after 1 hour.

### Constraints
- Max 10 images per generation request
- Multi-image editing: up to 5 images
- Generated URLs are temporary (download promptly)
- Flat per-image pricing (not token-based)
- Prompts are revised by a chat model before generation (returned as `revised_prompt`)
- `quality`, `size`, `style`, `seed`, `negative_prompt`, `guidance_scale`, `mask` — not supported
- **JPEG output quirk**: `response_format: "b64_json"` returns JPEG-encoded data regardless of filename. Files saved as `.png` contain JPEG content. Confirmed in official docs (examples save output with `.jpg` extension).
- **Content moderation tightened 2026-01**: two-layer guard (prompt + post-gen classifier). Expect `content_policy_violation` errors on prompts with real identifiable people in altered contexts.
- Quality/Speed generation modes are **consumer UI only** (grok.com/imagine), NOT API parameters

## OpenRouter (gateway)

OpenRouter is not a first-party image API — it is a gateway that fronts many providers' models behind one key and one endpoint. Image generation is exposed through the **chat-completions** API, not a dedicated images endpoint.

### Endpoint
- Generation and editing: `POST https://openrouter.ai/api/v1/chat/completions`

There is no separate edit endpoint; editing is generation with input images attached to the user message.

### Authentication
- Header: `Authorization: Bearer $OPENROUTER_API_KEY`
- Optional attribution headers: `HTTP-Referer: <site-url>` and `X-Title: <site-name>` (the plugin sends these from `--site-url` / `--site-name` or `OPENROUTER_SITE_URL` / `OPENROUTER_SITE_NAME`)

### Request Format
The prompt is a normal chat message; image output is opted into with `modalities`. In generate mode `content` is a plain string:
```json
{
  "model": "google/gemini-3.1-flash-image",
  "modalities": ["image", "text"],
  "messages": [{"role": "user", "content": "a serene mountain landscape at sunset"}]
}
```
In edit mode `content` is an array whose first part is the text prompt, followed by one `image_url` part per input image. Each image is a base64 data URL (the plugin streams these via `jq --rawfile` and posts with `curl --data-binary @-` to stay under ARG_MAX, mirroring gemini.sh):
```json
{
  "model": "google/gemini-3.1-flash-image",
  "modalities": ["image", "text"],
  "messages": [{
    "role": "user",
    "content": [
      {"type": "text", "text": "change the sky to a starry night"},
      {"type": "image_url", "image_url": {"url": "data:image/png;base64,<...>"}}
    ]
  }]
}
```

### Response Format
The generated image is returned as a base64 data URL inside the assistant message's `images` array (not the OpenAI `data[].b64_json` shape):
```json
{
  "choices": [{
    "message": {
      "role": "assistant",
      "content": "",
      "images": [{"type": "image_url", "image_url": {"url": "data:image/png;base64,<...>"}}]
    }
  }]
}
```
The plugin reads `.choices[0].message.images[0].image_url.url`, strips the `data:<mime>;base64,` prefix, and decodes the remainder. If no image is present it falls back to reporting `.choices[0].message.content` (a refusal or text-only reply). Errors come back as `.error.message`.

### Models
`--model` (or `OPENROUTER_IMAGE_MODEL`) accepts any OpenRouter slug that supports image output. Default: `google/gemini-3.1-flash-image`. Others include `google/gemini-3-pro-image`, `x-ai/grok-imagine-image-2.0` and `openai/gpt-image-2`. See [openrouter.ai/models](https://openrouter.ai/models?fmt=cards&output_modalities=image).

### Constraints
- Aspect ratio, resolution, and quality are model-dependent and driven by the prompt — there are no dedicated flags for them
- Per-image cost, rate limits, and max input images depend on the underlying model, not OpenRouter itself
- Pricing/billing is per OpenRouter account and the selected model
