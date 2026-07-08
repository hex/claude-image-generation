#!/usr/bin/env bash
# ABOUTME: Generates or edits images using xAI Grok Image API.
# ABOUTME: Uses a single /v1/images/generations endpoint for both generation and editing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/display.sh"

readonly PROVIDER_NAME="xai"

usage() {
  cat <<EOF
Usage: $(basename "$0") --mode <generate|edit> --prompt <text> --output <path> [options]

Options:
  --mode          generate or edit (required)
  --prompt        Text prompt describing the image (required)
  --output        Output file path (required)
  --input-image   Input image path for edit mode (required for edit)
  --aspect-ratio  Aspect ratio (default: none — model picks)
                  1:1, 16:9, 9:16, 4:3, 3:4, 3:2, 2:3, 2:1, 1:2,
                  19.5:9, 9:19.5, 20:9, 9:20, auto
                  Note: single-image edits ignore aspect_ratio (output matches input)
  --resolution    Output resolution: 1k or 2k (LOWERCASE required)
  --model         xAI model (default: grok-imagine-image-pro)
                  Alternatives: grok-imagine-image (standard, 10x higher RPM)

Environment:
  XAI_API_KEY         xAI API key (or GROK_API_KEY)
  XAI_IMAGE_MODEL     Override default model
EOF
  exit 1
}

MODE=""
PROMPT=""
OUTPUT=""
INPUT_IMAGE=""
ASPECT_RATIO=""
RESOLUTION=""
MODEL="${XAI_IMAGE_MODEL:-grok-imagine-image-pro}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --input-image) INPUT_IMAGE="$2"; shift 2 ;;
    --aspect-ratio) ASPECT_RATIO="$2"; shift 2 ;;
    --resolution) RESOLUTION="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

if [[ -n "$RESOLUTION" ]]; then
  case "$RESOLUTION" in
    1k|2k) ;;
    *) echo "Error: --resolution must be '1k' or '2k' (lowercase required)" >&2; exit 1 ;;
  esac
fi

if [[ -z "$MODE" || -z "$PROMPT" || -z "$OUTPUT" ]]; then
  echo "Error: --mode, --prompt, and --output are required" >&2
  usage
fi

if [[ "$MODE" == "edit" && -z "$INPUT_IMAGE" ]]; then
  echo "Error: --input-image is required for edit mode" >&2
  usage
fi

XAI_API_KEY="${XAI_API_KEY:-${GROK_API_KEY:-}}"
if [[ -z "$XAI_API_KEY" ]]; then
  echo "Error: XAI_API_KEY or GROK_API_KEY environment variable is not set" >&2
  exit 1
fi

OUTPUT_DIR=$(dirname "$OUTPUT")
if [[ ! -d "$OUTPUT_DIR" ]]; then
  mkdir -p "$OUTPUT_DIR"
fi

echo "Calling xAI API (model: ${MODEL}, mode: ${MODE})..." >&2
display_pane_begin "$PROVIDER_NAME" "$MODEL"

# Build request body -- xAI uses the same endpoint for generation and editing.
# For editing, the source image is passed as image_url (public URL or data URI).
REQUEST_BODY=$(jq -n \
  --arg model "$MODEL" \
  --arg prompt "$PROMPT" \
  '{
    "model": $model,
    "prompt": $prompt,
    "n": 1,
    "response_format": "b64_json"
  }')

if [[ -n "$ASPECT_RATIO" ]]; then
  REQUEST_BODY=$(echo "$REQUEST_BODY" | jq --arg ar "$ASPECT_RATIO" '. + {"aspect_ratio": $ar}')
fi

if [[ -n "$RESOLUTION" ]]; then
  REQUEST_BODY=$(echo "$REQUEST_BODY" | jq --arg res "$RESOLUTION" '. + {"resolution": $res}')
fi

if [[ "$MODE" == "edit" && -n "$INPUT_IMAGE" ]]; then
  local_mime_type="image/png"
  case "${INPUT_IMAGE##*.}" in
    jpg|jpeg) local_mime_type="image/jpeg" ;;
    webp) local_mime_type="image/webp" ;;
    gif) local_mime_type="image/gif" ;;
  esac
  # A normal image's base64 exceeds ARG_MAX, so it reaches jq through --rawfile
  # instead of an argument. This jq reads REQUEST_BODY on stdin, so the base64 needs
  # its own file; the data: prefix is small enough to stay an argument.
  image_b64_file=$(mktemp)
  trap 'rm -f "$image_b64_file"' EXIT
  base64 < "$INPUT_IMAGE" | tr -d '\n' > "$image_b64_file"
  REQUEST_BODY=$(echo "$REQUEST_BODY" \
    | jq --arg prefix "data:${local_mime_type};base64," --rawfile b64 "$image_b64_file" \
    '. + {"image_url": ($prefix + $b64)}')
  rm -f "$image_b64_file"
  trap - EXIT
fi

# The body embeds the base64 image in edit mode, so it is streamed to curl on stdin
# (--data-binary @-) instead of passed as -d, which would exceed ARG_MAX.
RESPONSE=$(printf '%s' "$REQUEST_BODY" | curl -s -w "\n%{http_code}" \
  -X POST "https://api.x.ai/v1/images/generations" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${XAI_API_KEY}" \
  --data-binary @-)

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" != "200" ]]; then
  api_msg=$(echo "$BODY" | jq -r '.error.message // .' 2>/dev/null || echo "$BODY")
  provider_die "xAI API returned HTTP ${HTTP_CODE}: ${api_msg}"
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

REVISED_PROMPT=$(echo "$BODY" | jq -r '.data[0].revised_prompt // empty')

echo "Image saved to: ${OUTPUT}" >&2
echo "Format: png" >&2
if [[ -n "$REVISED_PROMPT" ]]; then
  echo "Revised prompt: ${REVISED_PROMPT}" >&2
fi

provider_finish "$OUTPUT"

echo "$OUTPUT"
