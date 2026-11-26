#!/usr/bin/env bash
# ABOUTME: Runs image provider scripts (Gemini, OpenAI, xAI, and opt-in OpenRouter) in parallel,
# ABOUTME: showing them as one run in the browser gallery or one streaming tmux pane (IMAGE_DISPLAY).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/display.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") --mode <generate|edit> --prompt <text> --output-base <base> [options]

Runs Gemini, OpenAI, and xAI in parallel and shows them as one run. Where the
run shows is IMAGE_DISPLAY's choice:
  gallery (default)  one section on the browser gallery page, a frame per provider
  pane               a single tmux pane with per-provider colored banners
                     (blue / gray / red / indigo) and an animated spinner
  none               nowhere; the images are only saved

Each provider writes <base>-<provider>.png. In the tmux pane, per-provider
stderr/stdout is captured under \$DISPLAY_PANE_DIR/logs/<provider>.{out,err} for
debugging; in the gallery and with none it stays on this script's own output.

Options:
  --mode           generate or edit (required)
  --prompt         text prompt (required)
  --output-base    base path; produces <base>-gemini.png, <base>-openai.png, <base>-xai.png,
                   <base>-openrouter.png
  --input-image    input image path (required for edit mode, repeatable)
  --providers      comma-separated subset (default: gemini,openai,xai;
                   openrouter is available but opt-in, e.g. --providers gemini,openrouter)
  --gemini-extra     extra args passed to gemini.sh     (single shell-split string)
  --openai-extra     extra args passed to openai.sh     (single shell-split string)
  --xai-extra        extra args passed to xai.sh        (single shell-split string)
  --openrouter-extra extra args passed to openrouter.sh (single shell-split string)

With pane, outside tmux the streaming pane cannot open and providers fall back to
direct terminal display in this shell (sequential output, but functional).
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

if [[ "$MODE" != generate && "$MODE" != edit ]]; then
  echo "Error: --mode must be generate or edit, got '$MODE'" >&2
  usage
fi

if [[ "$MODE" == "edit" && ${#INPUT_IMAGES[@]} -eq 0 ]]; then
  echo "Error: --input-image is required for edit mode" >&2
  usage
fi

IFS=',' read -ra provider_list <<< "$PROVIDERS"
for i in "${!provider_list[@]}"; do
  provider_list[$i]="${provider_list[$i]// /}"
done

# run_arguments — prints this run's arguments as the JSON object the gallery records, so its page can
# resend the run: the mode, the output base and input images made absolute against the working
# directory, and each provider's extra arguments.
run_arguments() {
  local path
  local -a inputs=()
  for path in ${INPUT_IMAGES[@]+"${INPUT_IMAGES[@]}"}; do
    [[ "$path" == /* ]] || path="$PWD/$path"
    inputs+=("$path")
  done
  path="$OUTPUT_BASE"
  [[ "$path" == /* ]] || path="$PWD/$path"
  jq -n --arg mode "$MODE" --arg base "$path" --arg gemini "$GEMINI_EXTRA" --arg openai "$OPENAI_EXTRA" \
    --arg xai "$XAI_EXTRA" --arg openrouter "$OPENROUTER_EXTRA" \
    '{mode: $mode, output_base: $base, input_images: $ARGS.positional,
      extras: {gemini: $gemini, openai: $openai, xai: $xai, openrouter: $openrouter}}' \
    --args ${inputs[@]+"${inputs[@]}"}
}

# Decided once here and handed down, so the providers neither probe python3 again nor repeat
# the fallback notice. A bad IMAGE_DISPLAY ends the run here, before any provider is paid.
DISPLAY_MODE=$(display_mode)
export IMAGE_DISPLAY="$DISPLAY_MODE"

# Either way run-all holds a token for the whole batch and releases it once every provider has
# been waited on, so the surface outlives any single provider and is finished on the same
# last-one-out rule everyone uses.
if [[ "$DISPLAY_MODE" == pane ]]; then
  # Join this tmux window's streaming pane, opening it when nothing is streaming yet.
  if [[ -z "${DISPLAY_PANE_DIR:-}" ]] && pane_dir=$(display_pane_attach_or_open 2>/dev/null); then
    export DISPLAY_PANE_DIR="$pane_dir"
    mkdir -p "$DISPLAY_PANE_DIR/logs"
    __pane_acquire run-all
  fi
elif [[ "$DISPLAY_MODE" == gallery && -z "${DISPLAY_PANE_DIR:-}" ]]; then
  # The run directory comes first, so a server deciding whether it is idle already sees a live run.
  if gallery_begin_run run-all "$PROMPT" "$(run_arguments)" "${provider_list[@]}"; then
    export DISPLAY_PANE_DIR
    trap '__pane_release run-all' EXIT
    gallery_ensure
  fi
fi

# Routes a provider's stdio to per-provider log files when the pane is open, where nothing
# but the pane may write to the terminal; otherwise inherits this shell's stdio, so whoever
# ran this (the generate tool, a person) still sees what's happening.
spawn_provider() {
  local name="$1" script="$2"
  shift 2
  if [[ "$DISPLAY_MODE" == pane && -n "${DISPLAY_PANE_DIR:-}" ]]; then
    bash "$script" "$@" \
      >>"$DISPLAY_PANE_DIR/logs/${name}.out" \
      2>>"$DISPLAY_PANE_DIR/logs/${name}.err" &
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

# status_size — how many bytes the status log holds now: 0 before it exists or with no surface.
status_size() {
  local size
  size=$({ wc -c < "${DISPLAY_PANE_DIR:-}/status"; } 2>/dev/null) || size=0
  echo $((size))
}

# record_unreported_failure <provider> <exit status> <status size at spawn> — gives a provider that
# exited without a result in the status log (a missing key or bad option before it began, an abort
# after) an error record, so the finished run does not show it as never started or stopped midway.
# Only records written since it was spawned count, which leaves out those of earlier rounds and
# batches in a shared pane. A batch running at the same time in that pane can still write a record
# under the same provider name after the spawn, and that record then counts as this provider's.
# Its own error output says why it stopped.
record_unreported_failure() {
  local p="$1" code="$2" offset="$3" dir="${DISPLAY_PANE_DIR:-}" last
  [[ -n "$dir" && -d "$dir" ]] || return 0
  last=$(tail -c "+$((offset + 1))" "$dir/status" 2>/dev/null | grep "^${p}"$'\t' | tail -n 1 | cut -f2) || last=""
  [[ "$last" == complete || "$last" == error ]] && return 0
  display_pane_error "$p" "$p exited $code before reporting a result; its error output says why"
  display_pane_status "$p" error "" "" ""
}

# run_round <provider>... — forks the named providers, waits for all, and leaves the names of
# those that exited non-zero in FAILED. Returns 1 when any failed.
run_round() {
  local -a names=() pids=() offsets=()
  local p pid i code offset
  FAILED=()
  for p in "$@"; do
    offset=$(status_size)
    spawn_named "$p" || continue
    names+=("$p")
    pids+=($!)
    offsets+=("$offset")
  done
  i=0
  for pid in ${pids[@]+"${pids[@]}"}; do
    wait "$pid" || {
      code=$?
      FAILED+=("${names[$i]}")
      record_unreported_failure "${names[$i]}" "$code" "${offsets[$i]}"
    }
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
  # Nobody answers an offer on a gallery no page shows, and the generate tool would sit out the wait.
  if [[ "$DISPLAY_MODE" == gallery ]]; then
    gallery_page_connected || return 1
  fi
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
  # The offer closes by removing it. An answer can rename it to .retry up to that moment, and
  # none can after it, so .retry is looked for once the offer is gone.
  rm -f "$dir/retry-offer" 2>/dev/null
  if [[ -f "$dir/.retry" ]]; then
    rm -f "$dir/.retry"
    return 0
  fi
  return 1
}

declare -a FAILED=()
overall_status=0
run_round "${provider_list[@]}" || overall_status=1

# One offer per run: a provider that fails its retry simply shows its error.
if [[ $overall_status -eq 1 ]] && offer_retry; then
  overall_status=0
  run_round "${FAILED[@]}" || overall_status=1
fi

# A pane closed at the retry offer has already removed its directory; there is nothing left to
# release. A gallery run is released by the EXIT trap set where it began.
if [[ "$DISPLAY_MODE" == pane && -n "${DISPLAY_PANE_DIR:-}" && -d "$DISPLAY_PANE_DIR" ]]; then
  __pane_release run-all
fi

exit "$overall_status"
