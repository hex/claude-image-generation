#!/usr/bin/env bash
# ABOUTME: The aspect ratios each Gemini and xAI image model draws, and the check that refuses any
# ABOUTME: other before a request is paid for. gemini.sh, xai.sh and openrouter.sh share them.

# gemini_aspect_ratios <model> — prints the ratios a Gemini image model draws, space-separated, or
# nothing for a model this table does not know. The Nano Banana 2 models (3.1 Flash, 3.1 Flash Lite
# and 2.1) add four extreme ratios to the ten every Gemini image model draws.
gemini_aspect_ratios() {
  local common="1:1 2:3 3:2 3:4 4:3 4:5 5:4 9:16 16:9 21:9"
  case "$1" in
    gemini-3.1-flash-image*|gemini-3.1-flash-lite-image*|gemini-nano-banana-2*) echo "$common 1:4 4:1 1:8 8:1" ;;
    gemini-3-pro-image*|gemini-2.5-flash-image*) echo "$common" ;;
  esac
}

# xai_aspect_ratios <model> — prints the ratios an xAI image model draws, space-separated, or
# nothing for a model this table does not know.
xai_aspect_ratios() {
  case "$1" in
    grok-imagine-image*) echo "1:1 16:9 9:16 4:3 3:4 3:2 2:3 2:1 1:2 19.5:9 9:19.5 20:9 9:20 21:9 5:2 auto" ;;
  esac
}

# check_aspect_ratio <model> <ratio> <ratios> — exits 1 naming the ratios <model> draws when <ratio>
# is not one of them. An empty <ratios> is a model the tables above do not know: its ratio is sent
# as asked, and a line says that nothing checked it.
check_aspect_ratio() {
  local model="$1" ratio="$2" ratios="$3" known
  if [[ -z "$ratios" ]]; then
    echo "${model} is not in this plugin's aspect ratio table; sending ${ratio} unchecked" >&2
    return 0
  fi
  for known in $ratios; do
    [[ "$known" == "$ratio" ]] && return 0
  done
  echo "Error: ${model} does not take aspect ratio ${ratio}; it takes ${ratios// /, }" >&2
  exit 1
}
