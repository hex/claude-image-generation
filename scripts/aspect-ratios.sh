#!/usr/bin/env bash
# ABOUTME: The aspect ratios each Gemini, xAI and OpenAI image model draws, the size OpenAI is asked
# ABOUTME: for at each, and the check that refuses any other ratio before a request is paid for.

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
# nothing for a model this table does not know. grok-imagine-image-2.0 adds 21:9 and 5:2 to the
# standard model's, which grok-imagine-image-2026-03-02 is a version of.
xai_aspect_ratios() {
  local standard="1:1 16:9 9:16 4:3 3:4 3:2 2:3 2:1 1:2 19.5:9 9:19.5 20:9 9:20"
  case "$1" in
    grok-imagine-image-2.0*) echo "$standard 21:9 5:2 auto" ;;
    grok-imagine-image|grok-imagine-image-20[0-9][0-9]-*) echo "$standard auto" ;;
  esac
}

# The size OpenAI's gpt-image-2, 2.5 and 2.6 models are asked for at each ratio, as a line per ratio
# of its 1K, 2K and 4K sizes. Each is the ratio at about 1024x1024 pixels (1K) or 2048x2048 (2K), or
# as large as OpenAI allows (4K), with both edges multiples of 16, no edge over 3840 and at most
# 8,294,400 pixels. Ratios past 3:1, which OpenAI refuses, are left out.
readonly OPENAI_SIZES="1:1 1024x1024 2048x2048 2880x2880
2:3 832x1248 1680x2528 2336x3504
3:2 1248x832 2528x1680 3504x2336
3:4 880x1168 1776x2368 2480x3312
4:3 1168x880 2368x1776 3312x2480
4:5 912x1136 1824x2288 2576x3216
5:4 1136x912 2288x1824 3216x2576
9:16 768x1360 1536x2736 2160x3840
16:9 1360x768 2736x1536 3840x2160
21:9 1568x672 3136x1344 3840x1648
2:1 1440x720 2912x1456 3840x1920
1:2 720x1440 1456x2912 1920x3840
19.5:9 1488x688 3024x1392 3840x1776
9:19.5 688x1488 1392x3024 1776x3840
20:9 1536x688 3056x1376 3840x1728
9:20 688x1536 1376x3056 1728x3840
5:2 1600x640 3248x1296 3840x1536"

# openai_aspect_ratios — prints the ratios OPENAI_SIZES holds, space-separated.
openai_aspect_ratios() {
  local ratio rest list=""
  while read -r ratio rest; do
    list="${list:+$list }$ratio"
  done <<<"$OPENAI_SIZES"
  echo "$list"
}

# openai_size <ratio> <1K|2K|4K> — prints the WxH OPENAI_SIZES gives the ratio at the tier.
openai_size() {
  local ratio size_1k size_2k size_4k
  while read -r ratio size_1k size_2k size_4k; do
    [[ "$ratio" == "$1" ]] || continue
    case "$2" in
      1K) echo "$size_1k" ;;
      2K) echo "$size_2k" ;;
      4K) echo "$size_4k" ;;
    esac
    return 0
  done <<<"$OPENAI_SIZES"
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
