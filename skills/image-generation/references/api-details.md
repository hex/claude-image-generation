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
| `imageConfig.imageSize` | `512`, `1K`, `2K`, `4K` | **UPPERCASE required** — lowercase is a hard API rejection. Default `1K`. `512` exclusive to `gemini-3.1-flash-image-preview`; Pro supports `1K`/`2K`/`4K`. |
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
- `gemini-3-pro-image-preview` (default): "Nano Banana Pro". Premium tier, professional asset production, 10 aspect ratios, up to 14 reference images.
- `gemini-3.1-flash-image-preview`: "Nano Banana 2". 4K output, 14 aspect ratios (incl. extreme 1:4, 4:1, 1:8, 8:1), thinking, search grounding. Also supports `512` resolution.
- `gemini-2.5-flash-image`: Previous generation, 1K only. **Scheduled shutdown 2026-10-02** — replacement is `gemini-3.1-flash-image-preview`.

### Pricing (gemini-3.1-flash-image-preview, Standard tier)
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
- `gpt-image-1.5`: Previous flagship. Snapshot: `gpt-image-1.5-2025-12-16`
- `gpt-image-1-mini`: 3-4x cheaper, same API surface, only first image gets high fidelity on edits
- `gpt-image-1`: Older generation
- `chatgpt-image-latest`: GA alias — current target unverified post-2.0 launch; see OpenAI docs for live mapping

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

The plugin posts generation to `/v1/images/generations` and editing to `/v1/images/edits` (edit mode previously went through the generations endpoint with a single `image_url` — that legacy form still works). The edit endpoint supports multi-image editing (up to 5 images; the plugin's scripts cap at 3).

### Authentication
Header: `Authorization: Bearer YOUR_API_KEY`

### Generation Request
```json
{
  "model": "grok-imagine-image-pro",
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
  "model": "grok-imagine-image-pro",
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
  "model": "grok-imagine-image-pro",
  "prompt": "edit instruction",
  "image": {"type": "image_url", "url": "https://..."}
}
```

Multi-image (up to 5):
```json
{
  "model": "grok-imagine-image-pro",
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
| `aspect_ratio` | `1:1`, `16:9`, `9:16`, `4:3`, `3:4`, `3:2`, `2:3`, `2:1`, `1:2`, `19.5:9`, `9:19.5`, `20:9`, `9:20`, `auto` | `auto` lets model pick |
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
- `grok-imagine-image-pro` (default): Premium tier. Higher quality output, 30 RPM. Same endpoint and parameters as standard.
- `grok-imagine-image`: Standard tier. Versioned as `grok-imagine-image-2026-03-02`. 1K/2K resolution, 14 aspect ratios, 300 RPM.
- `grok-2-image-1212` (aka `grok-2-image`): **Deprecated 2026-02-28**. Migration target is `grok-imagine-image`.

### Pricing
| Model | Output (1K or 2K) | Image input | RPM |
|-------|-------------------|-------------|-----|
| `grok-imagine-image` | $0.02 | $0.002 | 300 |
| `grok-imagine-image-pro` | $0.07 | $0.002 | 30 |

Multi-image edit example: 5 images on pro = `5 × $0.002 + $0.07 = $0.08`.

### Rate Limits
- **Free tier removed 2026-03-19** — API requires billing
- `grok-imagine-image`: 300 RPM
- `grok-imagine-image-pro`: 30 RPM
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
