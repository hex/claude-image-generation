#!/usr/bin/env bash
# ABOUTME: Runs image provider scripts (Gemini, OpenAI, xAI, and opt-in OpenRouter)
# ABOUTME: in parallel under one streaming tmux pane with colored banners + spinner.

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
  --input-image    input image path (required for edit mode, repeatable)
  --providers      comma-separated subset (default: gemini,openai,xai;
                   openrouter is available but opt-in, e.g. --providers gemini,openrouter)
  --gemini-extra     extra args passed to gemini.sh     (single shell-split string)
  --openai-extra     extra args passed to openai.sh     (single shell-split string)
  --xai-extra        extra args passed to xai.sh        (single shell-split string)
  --openrouter-extra extra args passed to openrouter.sh (single shell-split string)

Outside tmux, the streaming pane cannot open and providers fall back to direct
terminal display in this shell (sequential output, but functional).
EOF
  exit 1
}

MODE=""
PROMPT=""
OUTPUT_BASE=""
INPUT_IMAGES=()
PROVIDERS="gemini,openai,xai"
GEMINI_EXTRA=""
OPENAI_EXTRA=""
XAI_EXTRA=""
OPENROUTER_EXTRA=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --output-base) OUTPUT_BASE="$2"; shift 2 ;;
    --input-image) INPUT_IMAGES+=("$2"); shift 2 ;;
    --providers) PROVIDERS="$2"; shift 2 ;;
    --gemini-extra) GEMINI_EXTRA="$2"; shift 2 ;;
    --openai-extra) OPENAI_EXTRA="$2"; shift 2 ;;
    --xai-extra) XAI_EXTRA="$2"; shift 2 ;;
    --openrouter-extra) OPENROUTER_EXTRA="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

if [[ -z "$MODE" || -z "$PROMPT" || -z "$OUTPUT_BASE" ]]; then
  echo "Error: --mode, --prompt, and --output-base are required" >&2
  usage
fi

if [[ "$MODE" == "edit" && ${#INPUT_IMAGES[@]} -eq 0 ]]; then
  echo "Error: --input-image is required for edit mode" >&2
  usage
fi

# Join this tmux window's streaming pane, opening it when nothing is streaming yet. run-all
# holds a token for the whole batch and releases it once every provider has been waited on, so
# the pane outlives any single provider and closes on the same last-one-out rule everyone uses.
if [[ -z "${DISPLAY_PANE_DIR:-}" ]] && pane_dir=$(display_pane_attach_or_open 2>/dev/null); then
  export DISPLAY_PANE_DIR="$pane_dir"
  mkdir -p "$DISPLAY_PANE_DIR/logs"
  __pane_acquire run-all
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

# spawn_named <provider> — forks one provider with this batch's arguments. Used for the first
# round and again for a retry, so both rounds are built the same way.
spawn_named() {
  local p="$1" extra args img
  # macOS ships bash 3.2, which has neither ${p^^} nor associative arrays, so the
  # per-provider extras are selected by name rather than an uppercased indirect lookup.
  case "$p" in
    gemini)     extra="$GEMINI_EXTRA" ;;
    openai)     extra="$OPENAI_EXTRA" ;;
    xai)        extra="$XAI_EXTRA" ;;
    openrouter) extra="$OPENROUTER_EXTRA" ;;
    *) echo "Warning: unknown provider '$p' (skipping)" >&2; return 1 ;;
  esac
  args=(--mode "$MODE" --prompt "$PROMPT" --output "${OUTPUT_BASE}-${p}.png")
  if [[ "$MODE" == "edit" && ${#INPUT_IMAGES[@]} -gt 0 ]]; then
    for img in "${INPUT_IMAGES[@]}"; do
      args+=(--input-image "$img")
    done
  fi
  # ${arr[@]+"${arr[@]}"} expands to nothing when the array is empty, which bash 3.2
  # otherwise reports as an unbound variable under `set -u`.
  [[ -n "$extra" ]] && read -ra extra_arr <<<"$extra" && args+=(${extra_arr[@]+"${extra_arr[@]}"})
  spawn_provider "$p" "${SCRIPT_DIR}/${p}.sh" "${args[@]}"
}

# run_round <provider>... — forks the named providers, waits for all, and leaves the names of
# those that exited non-zero in FAILED. Returns 1 when any failed.
run_round() {
  local -a names=() pids=()
  local p pid i
  FAILED=()
  for p in "$@"; do
    spawn_named "$p" || continue
    names+=("$p")
    pids+=($!)
  done
  i=0
  for pid in ${pids[@]+"${pids[@]}"}; do
    wait "$pid" || FAILED+=("${names[$i]}")
    i=$((i + 1))
  done
  [[ ${#FAILED[@]} -eq 0 ]]
}

# offer_retry — when a provider failed and the pane is live, writes retry-offer (seconds, then
# one failed name per line) and waits for the watcher to answer. Returns 0 only when the pane
# asked for a retry (.retry appeared). The offer expiring, the file vanishing, or the whole
# directory going away (the pane was closed) all mean no retry and must not be errors.
offer_retry() {
  local wait="${DISPLAY_PANE_RETRY_WAIT:-45}" dir="${DISPLAY_PANE_DIR:-}"
  [[ ${#FAILED[@]} -gt 0 ]] || return 1
  [[ "$wait" =~ ^[0-9]+$ && $wait -gt 0 ]] || return 1
  [[ -n "$dir" && -d "$dir" ]] || return 1
  { printf '%s\n' "$wait"; printf '%s\n' "${FAILED[@]}"; } > "$dir/.retry-offer.tmp" 2>/dev/null || return 1
  mv -f "$dir/.retry-offer.tmp" "$dir/retry-offer" 2>/dev/null || return 1
  local deadline=$((SECONDS + wait))
  while [[ $SECONDS -lt $deadline ]]; do
    [[ -d "$dir" ]] || return 1
    if [[ -f "$dir/.retry" ]]; then
      rm -f "$dir/.retry"
      return 0
    fi
    if [[ ! -f "$dir/retry-offer" ]]; then
      # mv is atomic: the watcher can rename retry-offer to .retry between the two checks
      # above and this one, so retry-offer missing does not yet mean the offer was
      # withdrawn. Re-check .retry once before concluding no answer came.
      if [[ -f "$dir/.retry" ]]; then
        rm -f "$dir/.retry"
        return 0
      fi
      return 1
    fi
    sleep 0.2
  done
  rm -f "$dir/retry-offer" 2>/dev/null
  return 1
}

IFS=',' read -ra provider_list <<< "$PROVIDERS"
for i in "${!provider_list[@]}"; do
  provider_list[$i]="${provider_list[$i]// /}"
done

declare -a FAILED=()
overall_status=0
run_round "${provider_list[@]}" || overall_status=1

# One offer per run: a provider that fails its retry simply shows its error.
if [[ $overall_status -eq 1 ]] && offer_retry; then
  overall_status=0
  run_round "${FAILED[@]}" || overall_status=1
fi

# A pane closed at the retry offer has already removed its directory; there is nothing left to release.
if [[ -n "${DISPLAY_PANE_DIR:-}" && -d "$DISPLAY_PANE_DIR" ]]; then
  __pane_release run-all
fi

exit "$overall_status"
