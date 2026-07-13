#!/usr/bin/env bash
# ABOUTME: Generates or edits images using OpenAI GPT Image 2 API.
# ABOUTME: Supports text-to-image and image editing via separate endpoints.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/display.sh"

readonly PROVIDER_NAME="openai"

usage() {
  cat <<EOF
Usage: $(basename "$0") --mode <generate|edit> --prompt <text> --output <path> [options]

Options:
  --mode              generate or edit (required)
  --prompt            Text prompt describing the image (required)
  --output            Output file path (required)
  --input-image       Input image path for edit mode (required for edit, repeatable)
  --size              Image size: auto, 1024x1024, 1536x1024, 1024x1536 (default: 1024x1024)
  --quality           Quality: auto, low, medium, high (default: high)
  --background        Background: auto, transparent, opaque (default: auto)
  --output-format     Format: png, jpeg, webp (default: png; jpeg is faster)
  --output-compression  Compression 0-100 (for jpeg/webp only)
  --moderation        Moderation: auto, low (default: auto)
  --input-fidelity    Edit mode only: low, high (default: low)
                      'high' preserves faces/logos/textures — only the first image gets it
  --model             OpenAI model (default: gpt-image-2)
                      Alternatives: gpt-image-1.5, gpt-image-1-mini (3-4x cheaper), gpt-image-1

Environment:
  OPENAI_API_KEY      OpenAI API key (required)
  OPENAI_IMAGE_MODEL  Override default model
EOF
  exit 1
}

MODE=""
PROMPT=""
OUTPUT=""
INPUT_IMAGES=()
SIZE="1024x1024"
QUALITY="high"
BACKGROUND="auto"
OUTPUT_FORMAT="png"
OUTPUT_COMPRESSION=""
MODERATION="auto"
INPUT_FIDELITY=""
MODEL="${OPENAI_IMAGE_MODEL:-gpt-image-2}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --input-image) INPUT_IMAGES+=("$2"); shift 2 ;;
    --size) SIZE="$2"; shift 2 ;;
    --quality) QUALITY="$2"; shift 2 ;;
    --background) BACKGROUND="$2"; shift 2 ;;
    --output-format) OUTPUT_FORMAT="$2"; shift 2 ;;
    --output-compression) OUTPUT_COMPRESSION="$2"; shift 2 ;;
    --moderation) MODERATION="$2"; shift 2 ;;
    --input-fidelity) INPUT_FIDELITY="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

case "$OUTPUT_FORMAT" in
  png|jpeg|webp) ;;
  *) echo "Error: --output-format must be png, jpeg, or webp" >&2; exit 1 ;;
esac

case "$MODERATION" in
  auto|low) ;;
  *) echo "Error: --moderation must be 'auto' or 'low'" >&2; exit 1 ;;
esac

if [[ -n "$INPUT_FIDELITY" ]]; then
  case "$INPUT_FIDELITY" in
    low|high) ;;
    *) echo "Error: --input-fidelity must be 'low' or 'high'" >&2; exit 1 ;;
  esac
fi

if [[ -n "$OUTPUT_COMPRESSION" && "$OUTPUT_FORMAT" == "png" ]]; then
  echo "Error: --output-compression only applies to jpeg/webp, not png" >&2
  exit 1
fi

if [[ -z "$MODE" || -z "$PROMPT" || -z "$OUTPUT" ]]; then
  echo "Error: --mode, --prompt, and --output are required" >&2
  usage
fi

if [[ "$MODE" == "edit" && ${#INPUT_IMAGES[@]} -eq 0 ]]; then
  echo "Error: --input-image is required for edit mode" >&2
  usage
fi

if [[ ${#INPUT_IMAGES[@]} -gt 16 ]]; then
  echo "Error: at most 16 input images supported for openai" >&2
  exit 1
fi

if [[ "$MODEL" == dall-e-2* && ${#INPUT_IMAGES[@]} -gt 1 ]]; then
  echo "Error: at most 1 input image for dall-e-2" >&2
  exit 1
fi

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  echo "Error: OPENAI_API_KEY environment variable is not set" >&2
  exit 1
fi

OUTPUT_DIR=$(dirname "$OUTPUT")
if [[ ! -d "$OUTPUT_DIR" ]]; then
  mkdir -p "$OUTPUT_DIR"
fi

if [[ "$MODE" == "generate" ]]; then
  echo "Calling OpenAI API (model: ${MODEL}, mode: generate)..." >&2
  display_pane_begin "$PROVIDER_NAME" "$MODEL"

  REQUEST_BODY=$(jq -n \
    --arg model "$MODEL" \
    --arg prompt "$PROMPT" \
    --arg size "$SIZE" \
    --arg quality "$QUALITY" \
    --arg background "$BACKGROUND" \
    --arg format "$OUTPUT_FORMAT" \
    --arg moderation "$MODERATION" \
    '{
      "model": $model,
      "prompt": $prompt,
      "n": 1,
      "size": $size,
      "quality": $quality,
      "output_format": $format,
      "background": $background,
      "moderation": $moderation
    }')

  if [[ -n "$OUTPUT_COMPRESSION" ]]; then
    REQUEST_BODY=$(echo "$REQUEST_BODY" | jq \
      --argjson c "$OUTPUT_COMPRESSION" '. + {"output_compression": $c}')
  fi

  RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST "https://api.openai.com/v1/images/generations" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${OPENAI_API_KEY}" \
    -d "$REQUEST_BODY")

elif [[ "$MODE" == "edit" ]]; then
  echo "Calling OpenAI API (model: ${MODEL}, mode: edit)..." >&2
  display_pane_begin "$PROVIDER_NAME" "$MODEL"

  EDIT_ARGS=(-F "model=${MODEL}" -F "prompt=${PROMPT}" \
    -F "size=${SIZE}" -F "quality=${QUALITY}" -F "background=${BACKGROUND}" \
    -F "output_format=${OUTPUT_FORMAT}" -F "moderation=${MODERATION}")

  for img in "${INPUT_IMAGES[@]}"; do
    EDIT_ARGS+=(-F "image[]=@${img}")
  done

  if [[ -n "$OUTPUT_COMPRESSION" ]]; then
    EDIT_ARGS+=(-F "output_compression=${OUTPUT_COMPRESSION}")
  fi

  if [[ -n "$INPUT_FIDELITY" ]]; then
    EDIT_ARGS+=(-F "input_fidelity=${INPUT_FIDELITY}")
  fi

  RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST "https://api.openai.com/v1/images/edits" \
    -H "Authorization: Bearer ${OPENAI_API_KEY}" \
    "${EDIT_ARGS[@]}")
fi

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" != "200" ]]; then
  api_msg=$(echo "$BODY" | jq -r '.error.message // .' 2>/dev/null || echo "$BODY")
  provider_die "OpenAI API returned HTTP ${HTTP_CODE}: ${api_msg}"
fi

IMAGE_DATA=$(echo "$BODY" | jq -r '.data[0].b64_json')

if [[ -z "$IMAGE_DATA" || "$IMAGE_DATA" == "null" ]]; then
  provider_die "No image data in response: $(echo "$BODY" | jq -c '.' 2>/dev/null || echo "$BODY")"
fi

if [[ "$(uname)" == "Darwin" ]]; then
  echo "$IMAGE_DATA" | base64 -D > "$OUTPUT"
else
  echo "$IMAGE_DATA" | base64 -d > "$OUTPUT"
fi

echo "Image saved to: ${OUTPUT}" >&2
echo "Format: ${OUTPUT_FORMAT}" >&2
echo "Size: ${SIZE}" >&2
echo "Quality: ${QUALITY}" >&2

provider_finish "$OUTPUT"

echo "$OUTPUT"
