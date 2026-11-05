#!/usr/bin/env bash
# ABOUTME: Generates or edits images using OpenAI GPT Image 2 API.
# ABOUTME: Supports text-to-image and image editing via separate endpoints.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/display.sh"
source "${SCRIPT_DIR}/retry.sh"
source "${SCRIPT_DIR}/input-images.sh"
source "${SCRIPT_DIR}/output-image.sh"
source "${SCRIPT_DIR}/model-fallback.sh"

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
  --input-fidelity    Edit mode only: low, high (default: low); refused with gpt-image-2 and
                      gpt-image-2.6-sunburst. 'high' preserves faces/logos/textures on the first
                      5 images on gpt-image-1.5, the first image only on gpt-image-1 and mini
  --model             OpenAI model (default: gpt-image-2.6-sunburst)
                      Alternatives: gpt-image-2, gpt-image-1.5, gpt-image-1-mini (3-4x cheaper), gpt-image-1

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
MODEL="${OPENAI_IMAGE_MODEL:-gpt-image-2.6-sunburst}"
FALLBACK_MODEL=$(model_fallback_for_default "$PROVIDER_NAME")

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
    --model) MODEL="$2"; FALLBACK_MODEL=""; shift 2 ;;
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
  # The API answers HTTP 400 when either model is sent the parameter. gpt-image-2 edits every
  # input image at high fidelity, and its dated snapshots behave the same; gpt-image-2.6-sunburst
  # has no dated snapshot.
  case "$MODEL" in
    gpt-image-2|gpt-image-2-*|gpt-image-2.6-sunburst)
      echo "Error: --input-fidelity is not accepted by ${MODEL}; drop the flag or pass --model gpt-image-1.5" >&2
      exit 1 ;;
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

refuse_existing_output "$OUTPUT"
snapshot_input_images

OUTPUT_DIR=$(dirname "$OUTPUT")
if [[ ! -d "$OUTPUT_DIR" ]]; then
  mkdir -p "$OUTPUT_DIR"
fi

use_remembered_fallback
echo "Calling OpenAI API (model: ${MODEL}, mode: ${MODE})..." >&2
display_pane_begin "$PROVIDER_NAME" "$MODEL"

# send_request <model> — posts the generate or edit request for this model and prints
# curl_with_retry's body and status.
send_request() {
  local model="$1"
  if [[ "$MODE" == "generate" ]]; then
    local request_body
    request_body=$(jq -n \
      --arg model "$model" \
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
      request_body=$(echo "$request_body" | jq \
        --argjson c "$OUTPUT_COMPRESSION" '. + {"output_compression": $c}')
    fi

    curl_with_retry -s -w "\n%{http_code}" \
      -X POST "https://api.openai.com/v1/images/generations" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${OPENAI_API_KEY}" \
      -d "$request_body"

  elif [[ "$MODE" == "edit" ]]; then
    # curl's -F reads a value that starts with '@' or '<' from a file, so every text field goes
    # through --form-string, which sends it as typed. In an image's -F value curl also splits the
    # path at ',' and ';' unless it is double-quoted, with '\' and '"' escaped inside the quotes;
    # the copy's path starts with $TMPDIR, which may hold either.
    local -a edit_args
    local i quoted_path
    edit_args=(--form-string "model=${model}" --form-string "prompt=${PROMPT}" \
      --form-string "size=${SIZE}" --form-string "quality=${QUALITY}" \
      --form-string "background=${BACKGROUND}" --form-string "output_format=${OUTPUT_FORMAT}" \
      --form-string "moderation=${MODERATION}")

    for i in "${!INPUT_IMAGES[@]}"; do
      quoted_path=${INPUT_IMAGES[$i]//\\/\\\\}
      quoted_path=${quoted_path//\"/\\\"}
      edit_args+=(-F "image[]=@\"${quoted_path}\";type=${INPUT_MIMES[$i]}")
    done

    if [[ -n "$OUTPUT_COMPRESSION" ]]; then
      edit_args+=(--form-string "output_compression=${OUTPUT_COMPRESSION}")
    fi

    if [[ -n "$INPUT_FIDELITY" ]]; then
      edit_args+=(--form-string "input_fidelity=${INPUT_FIDELITY}")
    fi

    curl_with_retry -s -w "\n%{http_code}" \
      -X POST "https://api.openai.com/v1/images/edits" \
      -H "Authorization: Bearer ${OPENAI_API_KEY}" \
      "${edit_args[@]}"
  fi
}

request_with_model_fallback send_request

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

save_image "$OUTPUT" <<< "$IMAGE_DATA"

echo "Image saved to: ${OUTPUT}" >&2
echo "Format: ${OUTPUT_FORMAT}" >&2
echo "Size: ${SIZE}" >&2
echo "Quality: ${QUALITY}" >&2

provider_finish "$OUTPUT"

echo "$OUTPUT"
