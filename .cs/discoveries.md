# Discoveries & Notes

## Google Gemini Image Generation API Research (2026-02-09)

### Model Landscape
- Google now refers to their image generation models as "Nano Banana"
- Imagen 3 has been discontinued/shut down
- Two primary models available:
  - `gemini-2.5-flash-image` (Nano Banana) - optimized for speed/high-volume
  - `gemini-3-pro-image-preview` (Nano Banana Pro) - professional asset production with advanced reasoning
- Imagen 4 models also available (`imagen-4.0-generate-001`, `imagen-4.0-ultra-generate-001`, `imagen-4.0-fast-generate-001`)

### Key API Characteristics
- Base64-encoded image input/output (no direct URLs)
- All images automatically watermarked with SynthID
- C2PA metadata for provenance tracking
- Multi-turn conversational image generation and editing
- Supports both text-to-image and text-and-image-to-image (editing)

### Rate Limiting Structure
- Free tier: 0 IPM (no image generation access)
- Tier 1 (paid): 10 IPM
- Tier 2: 20 IPM
- Tier 3 (enterprise): 100+ IPM
- Recent quota changes in December 2025 caught developers off-guard

### Technical Constraints
- Max input image: 7 MB
- Max total request: 20 MB
- Input images scaled to max 3072x3072
- Output resolutions: 1K, 2K, 4K (model-dependent)
- Max 14 reference images per prompt (Gemini 3 Pro)
- Each 1024x1024 image consumes ~1,290 tokens

## OpenAI GPT Image 1.5 Research (2026-02-09)

### Key Documentation Sources
- Official API Reference: https://platform.openai.com/docs/api-reference/images
- Model Documentation: https://platform.openai.com/docs/models/gpt-image-1.5
- Image Generation Guide: https://platform.openai.com/docs/guides/image-generation
- Prompting Guide: https://cookbook.openai.com/examples/multimodal/image-gen-1.5-prompting_guide

### Model Identity
- Model name: `gpt-image-1.5`
- Latest snapshot: `gpt-image-1.5-2025-12-16`
- Position: State-of-the-art image generation model (flagship)
- Released: December 2025 (part of "Little Shipmas")

### Key Capabilities
1. Natively multimodal language model (accepts text + images, outputs images + text)
2. Superior instruction following and prompt adherence
3. Enhanced text rendering (especially dense, small text)
4. Better preservation of logos, faces, and identities during editing
5. High-fidelity photorealism with natural lighting
6. Strong real-world knowledge and reasoning
7. Supports transparent backgrounds
8. Streaming support with partial images
9. Multi-image editing (up to 16 input images)

### API Endpoints
- Image Generation: `POST https://api.openai.com/v1/images/generations`
- Image Editing: `POST https://api.openai.com/v1/images/edits`
- Also available via Responses API with multi-turn capabilities

### Authentication
- Standard Bearer token authentication
- Header: `Authorization: Bearer $OPENAI_API_KEY`
- Organization verification required before using GPT Image models

### Output Formats
**GPT Image models (1.5, 1, 1-mini):**
- Always return base64-encoded images
- Formats: png (default), jpeg, webp
- Compression control: 0-100% (for jpeg/webp)
- No URL option (unlike DALL-E models)

**DALL-E 2/3 (deprecated):**
- Can return either URL or b64_json
- URLs valid for 60 minutes

### Rate Limits (by Tier)
- Free Tier: Not supported
- Tier 1: 100K TPM, 5 IPM (images per minute)
- Tier 2: 250K TPM, 20 IPM
- Tier 3: 800K TPM, 50 IPM
- Tier 4: 3M TPM, 150 IPM
- Tier 5: 8M TPM, 250 IPM

### Pricing Structure
**Per Image (Generation):**
- Low quality: $0.009 (1024x1024), $0.013 (portrait/landscape)
- Medium quality: $0.034 (1024x1024), $0.05 (portrait/landscape)
- High quality: $0.133 (1024x1024), $0.20 (portrait/landscape)

**Token-based pricing (for editing with images):**
- Text Input: $5.00 per 1M tokens
- Text Cached Input: $1.25 per 1M tokens
- Text Output: $10.00 per 1M tokens
- Image Input: $8.00 per 1M tokens
- Image Cached Input: $2.00 per 1M tokens
- Image Output: $32.00 per 1M tokens

**Output token counts:**
- Low: 272 (square), 408 (portrait), 400 (landscape)
- Medium: 1056 (square), 1584 (portrait), 1568 (landscape)
- High: 4160 (square), 6240 (portrait), 6208 (landscape)

### Differences from DALL-E 3
1. **Multimodal**: GPT Image 1.5 is a language model that can see and generate images; DALL-E 3 is image-only
2. **Editing**: GPT Image 1.5 supports advanced image editing; DALL-E 3 only generates
3. **Output format**: GPT Image always returns base64; DALL-E can return URLs
4. **Text rendering**: GPT Image 1.5 significantly better at rendering text in images
5. **Real-world knowledge**: GPT Image leverages LLM knowledge for more accurate depictions
6. **Multi-image input**: GPT Image supports up to 16 input images; DALL-E 3 doesn't support editing
7. **Transparent backgrounds**: GPT Image supports this; DALL-E 3 doesn't
8. **Streaming**: GPT Image supports streaming; DALL-E doesn't
9. **Style**: Community reports GPT Image produces more "honest, unposed" results vs DALL-E 3's more "dramatic" style
10. **Deprecation**: DALL-E 2 and 3 will be deprecated on May 12, 2026

### Constraints & Limitations
- Prompt length: Up to 32,000 characters (vs 4,000 for DALL-E 3, 1,000 for DALL-E 2)
- Image variations: Only DALL-E 2 supports this endpoint (not GPT Image models)
- Streaming: Only supported for GPT Image models
- Can generate 1-10 images per request (n parameter)
- Text rendering: "Significantly improved" but can still struggle with precise placement

## Claude Code Plugin Development Discoveries (2026-02-09)

### Plugin hooks.json Format
- Plugin `hooks/hooks.json` uses a wrapper format: `{"hooks": {"EventName": [...]}}`
- This differs from settings `.claude/settings.json` which uses a flat format
- The plugin-validator agent incorrectly flagged this as non-standard - it's actually correct for plugins

### Base64 Decoding Cross-Platform
- macOS uses `base64 -D` (capital D) to decode
- Linux uses `base64 -d` (lowercase d)
- Both scripts handle this with a `uname` check

### Both APIs Return Base64 Only
- Neither Gemini nor OpenAI GPT Image 1.5 returns URLs for generated images
- Everything is base64-encoded inline in the response body
- This means responses can be large (several MB for high-quality images)
- `jq` is needed to extract the base64 data from nested JSON responses

### Gemini Uses Unified Endpoint
- Gemini's image generation uses the same `generateContent` endpoint as text chat
- Images are passed as `inlineData` parts alongside text parts
- The `responseModalities: ["TEXT", "IMAGE"]` config tells the API to include image output
- This means editing is natural: send image + text instruction in same request

### OpenAI Uses Separate Endpoints
- Generation: `POST /v1/images/generations` (JSON body)
- Editing: `POST /v1/images/edits` (multipart/form-data)
- Different content types for different operations adds complexity to the script

