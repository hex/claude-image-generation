#!/usr/bin/env bash
# ABOUTME: Generates or edits images using Google Gemini API.
# ABOUTME: Supports text-to-image and image editing via generateContent endpoint.

set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") --mode <generate|edit> --prompt <text> --output <path> [options]

Options:
  --mode          generate or edit (required)
  --prompt        Text prompt describing the image (required)
  --output        Output file path (required)
  --input-image   Input image path for edit mode (required for edit)
  --aspect-ratio  Aspect ratio: 1:1, 16:9, 9:16, 4:3, 3:4 (default: 1:1)
  --model         Gemini model (default: gemini-3-pro-image-preview)

Environment:
  GEMINI_API_KEY  Google AI API key (required)
EOF
  exit 1
}

MODE=""
PROMPT=""
OUTPUT=""
INPUT_IMAGE=""
ASPECT_RATIO="1:1"
MODEL="gemini-3-pro-image-preview"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --input-image) INPUT_IMAGE="$2"; shift 2 ;;
    --aspect-ratio) ASPECT_RATIO="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

if [[ -z "$MODE" || -z "$PROMPT" || -z "$OUTPUT" ]]; then
  echo "Error: --mode, --prompt, and --output are required" >&2
  usage
fi

if [[ "$MODE" == "edit" && -z "$INPUT_IMAGE" ]]; then
  echo "Error: --input-image is required for edit mode" >&2
  usage
fi

if [[ -z "${GEMINI_API_KEY:-}" ]]; then
  echo "Error: GEMINI_API_KEY environment variable is not set" >&2
  exit 1
fi

API_URL="https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent"

build_request_body() {
  local parts="[]"

  if [[ "$MODE" == "edit" && -n "$INPUT_IMAGE" ]]; then
    local mime_type
    case "${INPUT_IMAGE##*.}" in
      png) mime_type="image/png" ;;
      jpg|jpeg) mime_type="image/jpeg" ;;
      webp) mime_type="image/webp" ;;
      *) mime_type="image/png" ;;
    esac
    local image_b64
    image_b64=$(base64 < "$INPUT_IMAGE" | tr -d '\n')
    parts=$(jq -n --arg mime "$mime_type" --arg data "$image_b64" \
      '[{"inlineData": {"mimeType": $mime, "data": $data}}]')
  fi

  parts=$(echo "$parts" | jq --arg prompt "$PROMPT" '. + [{"text": $prompt}]')

  jq -n \
    --argjson parts "$parts" \
    --arg aspect "$ASPECT_RATIO" \
    '{
      "contents": [{"parts": $parts}],
      "generationConfig": {
        "responseModalities": ["TEXT", "IMAGE"],
        "imageGenerationConfig": {
          "aspectRatio": $aspect
        }
      }
    }'
}

REQUEST_BODY=$(build_request_body)

echo "Calling Gemini API (model: ${MODEL}, mode: ${MODE})..." >&2

RESPONSE=$(curl -s -w "\n%{http_code}" \
  -X POST "${API_URL}" \
  -H "Content-Type: application/json" \
  -H "x-goog-api-key: ${GEMINI_API_KEY}" \
  -d "$REQUEST_BODY")

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "Error: Gemini API returned HTTP ${HTTP_CODE}" >&2
  echo "$BODY" | jq -r '.error.message // .' >&2
  exit 1
fi

IMAGE_DATA=$(echo "$BODY" | jq -r '
  .candidates[0].content.parts[]
  | select(.inlineData != null)
  | .inlineData.data' | head -1)

if [[ -z "$IMAGE_DATA" || "$IMAGE_DATA" == "null" ]]; then
  echo "Error: No image data in response" >&2
  TEXT_RESPONSE=$(echo "$BODY" | jq -r '.candidates[0].content.parts[] | select(.text != null) | .text' 2>/dev/null || true)
  if [[ -n "$TEXT_RESPONSE" ]]; then
    echo "Model response: ${TEXT_RESPONSE}" >&2
  fi
  exit 1
fi

MIME_TYPE=$(echo "$BODY" | jq -r '
  .candidates[0].content.parts[]
  | select(.inlineData != null)
  | .inlineData.mimeType' | head -1)

OUTPUT_DIR=$(dirname "$OUTPUT")
if [[ ! -d "$OUTPUT_DIR" ]]; then
  mkdir -p "$OUTPUT_DIR"
fi

if [[ "$(uname)" == "Darwin" ]]; then
  echo "$IMAGE_DATA" | base64 -D > "$OUTPUT"
else
  echo "$IMAGE_DATA" | base64 -d > "$OUTPUT"
fi

TEXT_RESPONSE=$(echo "$BODY" | jq -r '
  .candidates[0].content.parts[]
  | select(.text != null)
  | .text' 2>/dev/null | head -1 || true)

echo "Image saved to: ${OUTPUT}" >&2
echo "Format: ${MIME_TYPE}" >&2
if [[ -n "$TEXT_RESPONSE" && "$TEXT_RESPONSE" != "null" ]]; then
  echo "Description: ${TEXT_RESPONSE}" >&2
fi

echo "$OUTPUT"
