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

