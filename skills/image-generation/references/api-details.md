# API Technical Details

## Google Gemini Image Generation

### Endpoint
```
POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent
```

### Authentication
Header: `x-goog-api-key: YOUR_API_KEY`

### Request Format
The Gemini API uses a unified `generateContent` endpoint. Images are passed as `inlineData` parts alongside text parts.

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
    "imageGenerationConfig": {
      "aspectRatio": "16:9"
    }
  }
}
```

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
- `gemini-2.5-flash-image`: Fast generation, good for iteration (default)

### Constraints
- Max input image: 7 MB per image
- Max request size: 20 MB
- Input images auto-scaled to max 3072x3072
- All outputs include SynthID watermark
- Rate limits: 10 IPM (Tier 1), 20 IPM (Tier 2), 100+ IPM (Tier 3)

---

## OpenAI GPT Image 1.5

### Endpoints
- Generation: `POST https://api.openai.com/v1/images/generations`
- Editing: `POST https://api.openai.com/v1/images/edits`

### Authentication
Header: `Authorization: Bearer YOUR_API_KEY`

### Generation Request
```json
{
  "model": "gpt-image-1.5",
  "prompt": "description",
  "n": 1,
  "size": "1024x1024",
  "quality": "high",
  "output_format": "png",
  "background": "auto"
}
```

### Edit Request (multipart/form-data)
```
model=gpt-image-1.5
prompt=edit instruction
image=@path/to/image.png
size=1024x1024
```

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

### Quality Tiers and Token Costs
| Quality | 1024x1024 tokens | Cost estimate |
|---------|-------------------|---------------|
| low     | 272               | ~$0.009       |
| medium  | 1,056             | ~$0.034       |
| high    | 4,160             | ~$0.133       |

### Constraints
- Prompt max: 32,000 characters
- Up to 10 images per generation request
- Up to 16 input images for editing
- Organization verification required
- Rate limits: 5 IPM (Tier 1) to 250 IPM (Tier 5)

---

## xAI Grok Image

### Endpoint
```
POST https://api.x.ai/v1/images/generations
```

Both generation and editing use the same endpoint. Editing passes the source image via `image_url`.

### Authentication
Header: `Authorization: Bearer YOUR_API_KEY`

### Generation Request
```json
{
  "model": "grok-2-image",
  "prompt": "description",
  "n": 1,
  "response_format": "b64_json"
}
```

### Edit Request (same endpoint, JSON body)
```json
{
  "model": "grok-2-image",
  "prompt": "edit instruction",
  "n": 1,
  "response_format": "b64_json",
  "image_url": "data:image/png;base64,<base64-encoded-image>"
}
```

The `image_url` field accepts either a public URL or a base64 data URI. The OpenAI SDK's `images.edit()` method is not compatible because it uses multipart/form-data.

### Optional Parameters
| Parameter | Values | Notes |
|-----------|--------|-------|
| `aspect_ratio` | 1:1, 16:9, 9:16, 4:3, 3:4, 3:2, 2:3, 2:1, 1:2, 19.5:9, 9:19.5, 20:9, 9:20, auto | Model-dependent |
| `n` | 1-10 | Images per request |
| `response_format` | url, b64_json | Default: url |

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
- `grok-imagine-image`: Supports editing via `image_url` and `aspect_ratio` (default)
- `grok-2-image`: Basic generation, no editing or aspect ratio support

### Constraints
- Max 10 images per request
- Generated URLs are temporary (download promptly)
- Flat per-image pricing (not token-based)
- Prompts are revised by a chat model before generation
- `quality`, `size`, and `style` parameters are not supported
