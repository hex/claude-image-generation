#!/usr/bin/env bash
# ABOUTME: Runs Gemini, OpenAI, and xAI image scripts in parallel under one
# ABOUTME: streaming tmux pane with council-style colored banners + spinner.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/display.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") --mode <generate|edit> --prompt <text> --output-base <base> [options]

Runs Gemini, OpenAI, and xAI in parallel and streams their output into a single
tmux pane with per-provider colored banners (blue / gray / red) and an animated
spinner showing which providers are still working.

Each provider writes <base>-<provider>.png. Per-provider stderr/stdout is
captured under \$DISPLAY_PANE_DIR/logs/<provider>.{out,err} for debugging.

Options:
  --mode           generate or edit (required)
  --prompt         text prompt (required)
  --output-base    base path; produces <base>-gemini.png, <base>-openai.png, <base>-xai.png
  --input-image    input image path (required for edit mode)
  --providers      comma-separated subset (default: gemini,openai,xai)
  --gemini-extra   extra args passed to gemini.sh (single shell-split string)
  --openai-extra   extra args passed to openai.sh (single shell-split string)
  --xai-extra      extra args passed to xai.sh    (single shell-split string)

Outside tmux, the streaming pane cannot open and providers fall back to direct
terminal display in this shell (sequential output, but functional).
EOF
  exit 1
}

MODE=""
PROMPT=""
OUTPUT_BASE=""
INPUT_IMAGE=""
PROVIDERS="gemini,openai,xai"
GEMINI_EXTRA=""
OPENAI_EXTRA=""
XAI_EXTRA=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --output-base) OUTPUT_BASE="$2"; shift 2 ;;
    --input-image) INPUT_IMAGE="$2"; shift 2 ;;
    --providers) PROVIDERS="$2"; shift 2 ;;
    --gemini-extra) GEMINI_EXTRA="$2"; shift 2 ;;
    --openai-extra) OPENAI_EXTRA="$2"; shift 2 ;;
    --xai-extra) XAI_EXTRA="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

if [[ -z "$MODE" || -z "$PROMPT" || -z "$OUTPUT_BASE" ]]; then
  echo "Error: --mode, --prompt, and --output-base are required" >&2
  usage
fi

if [[ "$MODE" == "edit" && -z "$INPUT_IMAGE" ]]; then
  echo "Error: --input-image is required for edit mode" >&2
  usage
fi

if pane_dir=$(display_pane_open 2>/dev/null); then
  export DISPLAY_PANE_DIR="$pane_dir"
  mkdir -p "$DISPLAY_PANE_DIR/logs"
fi

# Routes a provider's stdio to per-provider log files when the pane is open;
# otherwise inherits this shell's stdio so users can still see what's happening.
spawn_provider() {
  local name="$1" script="$2"
  shift 2
  if [[ -n "${DISPLAY_PANE_DIR:-}" ]]; then
    bash "$script" "$@" \
      >"$DISPLAY_PANE_DIR/logs/${name}.out" \
      2>"$DISPLAY_PANE_DIR/logs/${name}.err" &
  else
    bash "$script" "$@" &
  fi
}

declare -a pids=()

IFS=',' read -ra provider_list <<< "$PROVIDERS"
for p in "${provider_list[@]}"; do
  p="${p// /}"
  # macOS ships bash 3.2, which has neither ${p^^} nor associative arrays, so the
  # per-provider extras are selected by name rather than an uppercased indirect lookup.
  case "$p" in
    gemini) extra="$GEMINI_EXTRA" ;;
    openai) extra="$OPENAI_EXTRA" ;;
    xai)    extra="$XAI_EXTRA" ;;
    *) echo "Warning: unknown provider '$p' (skipping)" >&2; continue ;;
  esac
  args=(--mode "$MODE" --prompt "$PROMPT" --output "${OUTPUT_BASE}-${p}.png")
  [[ "$MODE" == "edit" && -n "$INPUT_IMAGE" ]] && args+=(--input-image "$INPUT_IMAGE")
  # ${arr[@]+"${arr[@]}"} expands to nothing when the array is empty, which bash 3.2
  # otherwise reports as an unbound variable under `set -u`.
  [[ -n "$extra" ]] && read -ra extra_arr <<<"$extra" && args+=(${extra_arr[@]+"${extra_arr[@]}"})
  spawn_provider "$p" "${SCRIPT_DIR}/${p}.sh" "${args[@]}"
  pids+=($!)
done

overall_status=0
for pid in ${pids[@]+"${pids[@]}"}; do
  wait "$pid" || overall_status=1
done

if [[ -n "${DISPLAY_PANE_DIR:-}" ]]; then
  display_pane_close
fi

exit "$overall_status"
