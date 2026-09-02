#!/usr/bin/env bats
# ABOUTME: Runs the provider edit paths to completion with a stubbed curl and a real
# ABOUTME: multi-megabyte input image, guarding against argv-size limits in payload building.

load test_helper

# A real image whose base64 (~1.8 MB) exceeds ARG_MAX, so passing it as a jq argument
# instead of streaming it fails with "argument list too long".
BIG_IMAGE="${PLUGIN_ROOT}/test-input.png"

setup() {
  MOCK_DIR="${BATS_TMPDIR}/edit_mocks_$$"
  mkdir -p "$MOCK_DIR"
  OUT="${BATS_TMPDIR}/edit_out_$$.png"
  rm -f "$OUT"
  disable_display
  export DISPLAY_PANE_DIR="${MOCK_DIR}/pane"
  mkdir -p "$DISPLAY_PANE_DIR"
}

teardown() {
  rm -rf "$MOCK_DIR" 2>/dev/null || true
  rm -f "$OUT" 2>/dev/null || true
}

# Writes the request-capturing prelude shared by every curl stub in this file, overwriting
# $MOCK_DIR/curl with a shebang and the argv walk. curl_with_retry rewrites a streamed
# `--data-binary @-` body to `@<tempfile>` before every real curl invocation, so a stub never
# actually sees `@-` from a provider script -- what it sees is `@<path>` from curl_with_retry,
# or (openai's -d/-F calls, which pass no --data-binary at all) nothing, in which case it falls
# back to draining stdin. Callers append their own response-serving lines after this and chmod
# the result themselves.
__stub_curl_prelude() {
  cat > "$MOCK_DIR/curl" <<'STUB'
#!/bin/bash
d="$(dirname "$0")"
body_arg=""
prev=""
for a in "$@"; do
  [ "$prev" = "--data-binary" ] && body_arg="$a"
  prev="$a"
done
case "$body_arg" in
  @-) cat > "${d}/request.txt" 2>/dev/null ;;
  @*) cp "${body_arg#@}" "${d}/request.txt" 2>/dev/null ;;
  *)  cat > "${d}/request.txt" 2>/dev/null ;;
esac
STUB
}

# Installs a curl that captures the request body (see __stub_curl_prelude) then prints a canned
# body followed by the HTTP status on the last line, matching the `-w "\n%{http_code}"` the
# scripts rely on. The canned image data is base64 for "fake", so a fully working pipeline
# writes exactly "fake" to the output.
stub_curl() {
  printf '%s\n200\n' "$1" > "$MOCK_DIR/response.txt"
  __stub_curl_prelude
  cat >> "$MOCK_DIR/curl" <<'STUB'
cat "${d}/response.txt"
STUB
  chmod +x "$MOCK_DIR/curl"
  export PATH="$MOCK_DIR:$PATH"
}

# assert_edit_succeeds <output-var> — the run must not hit an argv-size limit (case
# insensitive, since bash prints "Argument list too long"), must exit 0, and must decode
# the stub's base64 through to the output file.
assert_edit_succeeds() {
  if echo "$output" | grep -qi 'argument list too long'; then
    echo "Payload building exceeded ARG_MAX:"
    echo "$output"
    return 1
  fi
  if echo "$output" | grep -qi 'unbound variable'; then
    echo "Script emitted a set -u unbound-variable error (e.g. a trap referencing an out-of-scope var):"
    echo "$output"
    return 1
  fi
  assert_status 0
  local content
  content=$(cat "$OUT" 2>/dev/null)
  [[ "$content" == "fake" ]] || {
    echo "Expected decoded output 'fake', got: '${content}'"
    echo "$output"
    return 1
  }
}

@test "gemini: edit mode builds a payload for a multi-megabyte image" {
  [[ -f "$BIG_IMAGE" ]] || skip "test-input.png not present"
  stub_curl '{"candidates":[{"content":{"parts":[{"inlineData":{"mimeType":"image/png","data":"ZmFrZQ=="}}]}}]}'

  GEMINI_API_KEY="$DUMMY_GEMINI_KEY" run bash "${PLUGIN_ROOT}/scripts/gemini.sh" \
    --mode edit --prompt "add a rainbow" --input-image "$BIG_IMAGE" --output "$OUT"

  assert_edit_succeeds
}

@test "xai: edit mode builds a payload for a multi-megabyte image" {
  [[ -f "$BIG_IMAGE" ]] || skip "test-input.png not present"
  stub_curl '{"data":[{"b64_json":"ZmFrZQ=="}]}'

  XAI_API_KEY="$DUMMY_XAI_KEY" run bash "${PLUGIN_ROOT}/scripts/xai.sh" \
    --mode edit --prompt "add a rainbow" --input-image "$BIG_IMAGE" --output "$OUT"

  assert_edit_succeeds
}

@test "gemini: edit mode with two --input-image builds two inlineData parts" {
  [[ -f "$BIG_IMAGE" ]] || skip "test-input.png not present"
  stub_curl '{"candidates":[{"content":{"parts":[{"inlineData":{"mimeType":"image/png","data":"ZmFrZQ=="}}]}}]}'

  GEMINI_API_KEY="$DUMMY_GEMINI_KEY" run bash "${PLUGIN_ROOT}/scripts/gemini.sh" \
    --mode edit --prompt "combine these" \
    --input-image "$BIG_IMAGE" --input-image "$BIG_IMAGE" --output "$OUT"

  assert_edit_succeeds
  local part_count
  part_count=$(jq '[.contents[0].parts[] | select(.inlineData)] | length' "$MOCK_DIR/request.txt")
  [[ "$part_count" -eq 2 ]] || {
    echo "Expected 2 inlineData parts, got: $part_count"
    return 1
  }
}

@test "openai: two --input-image emits two image[] parts" {
  [[ -f "$BIG_IMAGE" ]] || skip "test-input.png not present"
  cat > "$MOCK_DIR/curl" <<STUB
#!/bin/bash
printf '%s\n' "\$@" > "${MOCK_DIR}/argv.txt"
printf '%s\n200\n' '{"data":[{"b64_json":"ZmFrZQ=="}]}'
STUB
  chmod +x "$MOCK_DIR/curl"
  export PATH="$MOCK_DIR:$PATH"

  OPENAI_API_KEY="$DUMMY_OPENAI_KEY" run bash "${PLUGIN_ROOT}/scripts/openai.sh" \
    --mode edit --prompt "combine these" \
    --input-image "$BIG_IMAGE" --input-image "$BIG_IMAGE" --output "$OUT"

  assert_edit_succeeds
  local count
  count=$(grep -c '^image\[\]=@' "$MOCK_DIR/argv.txt")
  [[ "$count" -eq 2 ]] || {
    echo "Expected 2 image[]=@ parts, got: $count"
    cat "$MOCK_DIR/argv.txt"
    return 1
  }
}

@test "xai: two --input-image builds a two-element images array" {
  [[ -f "$BIG_IMAGE" ]] || skip "test-input.png not present"
  stub_curl '{"data":[{"b64_json":"ZmFrZQ=="}]}'

  XAI_API_KEY="$DUMMY_XAI_KEY" run bash "${PLUGIN_ROOT}/scripts/xai.sh" \
    --mode edit --prompt "combine these" \
    --input-image "$BIG_IMAGE" --input-image "$BIG_IMAGE" --output "$OUT"

  assert_edit_succeeds
  local count
  count=$(jq '.images | length' "$MOCK_DIR/request.txt")
  [[ "$count" -eq 2 ]] || {
    echo "Expected images array of length 2, got: $count"
    return 1
  }
}

@test "xai: --quality lands in the request body" {
  stub_curl '{"data":[{"b64_json":"ZmFrZQ=="}]}'

  # grok-imagine-image-2.0 bills at the quality served; omitting the field means auto,
  # which is low for generation, so a caller who wants medium has to be able to say so.
  XAI_API_KEY="$DUMMY_XAI_KEY" run bash "${PLUGIN_ROOT}/scripts/xai.sh" \
    --mode generate --prompt "a cat" --quality medium --output "$OUT"

  assert_edit_succeeds
  local quality
  quality=$(jq -r '.quality' "$MOCK_DIR/request.txt")
  [[ "$quality" == "medium" ]] || {
    echo "Expected quality 'medium' in the request body, got: $quality"
    cat "$MOCK_DIR/request.txt"
    return 1
  }
}

@test "openrouter: edit mode builds a payload for a multi-megabyte image" {
  [[ -f "$BIG_IMAGE" ]] || skip "test-input.png not present"
  stub_curl '{"choices":[{"message":{"images":[{"image_url":{"url":"data:image/png;base64,ZmFrZQ=="}}]}}]}'

  OPENROUTER_API_KEY="$DUMMY_OPENROUTER_KEY" run bash "${PLUGIN_ROOT}/scripts/openrouter.sh" \
    --mode edit --prompt "add a rainbow" --input-image "$BIG_IMAGE" --output "$OUT"

  assert_edit_succeeds
}

@test "openrouter: two --input-image builds two image_url content parts" {
  [[ -f "$BIG_IMAGE" ]] || skip "test-input.png not present"
  stub_curl '{"choices":[{"message":{"images":[{"image_url":{"url":"data:image/png;base64,ZmFrZQ=="}}]}}]}'

  OPENROUTER_API_KEY="$DUMMY_OPENROUTER_KEY" run bash "${PLUGIN_ROOT}/scripts/openrouter.sh" \
    --mode edit --prompt "combine these" \
    --input-image "$BIG_IMAGE" --input-image "$BIG_IMAGE" --output "$OUT"

  assert_edit_succeeds
  local count
  count=$(jq '[.messages[0].content[] | select(.type == "image_url")] | length' "$MOCK_DIR/request.txt")
  [[ "$count" -eq 2 ]] || {
    echo "Expected 2 image_url content parts, got: $count"
    return 1
  }
}

@test "gemini: generate mode with --input-image includes a reference part" {
  [[ -f "$BIG_IMAGE" ]] || skip "test-input.png not present"
  stub_curl '{"candidates":[{"content":{"parts":[{"inlineData":{"mimeType":"image/png","data":"ZmFrZQ=="}}]}}]}'

  GEMINI_API_KEY="$DUMMY_GEMINI_KEY" run bash "${PLUGIN_ROOT}/scripts/gemini.sh" \
    --mode generate --prompt "a cat like this" \
    --input-image "$BIG_IMAGE" --output "$OUT"

  assert_edit_succeeds
  local part_count
  part_count=$(jq '[.contents[0].parts[] | select(.inlineData)] | length' "$MOCK_DIR/request.txt")
  [[ "$part_count" -eq 1 ]] || {
    echo "Expected 1 inlineData part, got: $part_count"
    return 1
  }
}

# stub_curl_once_503 <body> — first call answers 503 with an error body, later calls the
# canned body with 200. Captures the request body the same way stub_curl does.
stub_curl_once_503() {
  printf '%s\n200\n' "$1" > "$MOCK_DIR/response.txt"
  __stub_curl_prelude
  cat >> "$MOCK_DIR/curl" <<'STUB'
n=$(cat "${d}/calls" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "${d}/calls"
if [ "$n" -eq 1 ]; then printf '{"error":{"message":"overloaded"}}\n503\n'; exit 0; fi
cat "${d}/response.txt"
STUB
  chmod +x "$MOCK_DIR/curl"
  export PATH="$MOCK_DIR:$PATH"
}

@test "every provider retries a 503 and reports the attempt to the pane" {
  local input_file="$MOCK_DIR/big-input.png"
  head -c 3000000 /dev/urandom > "$input_file"
  local p body
  for p in gemini openai xai openrouter; do
    rm -f "$MOCK_DIR/calls" "$DISPLAY_PANE_DIR/status"
    case "$p" in
      gemini)     body='{"candidates":[{"content":{"parts":[{"inlineData":{"mimeType":"image/png","data":"ZmFrZQ=="}}]}}]}' ;;
      openai|xai) body='{"data":[{"b64_json":"ZmFrZQ=="}]}' ;;
      openrouter) body='{"choices":[{"message":{"images":[{"image_url":{"url":"data:image/png;base64,ZmFrZQ=="}}]}}]}' ;;
    esac
    stub_curl_once_503 "$body"
    IMAGE_RETRY_DELAY=0 GEMINI_API_KEY="$DUMMY_GEMINI_KEY" OPENAI_API_KEY="$DUMMY_OPENAI_KEY" \
      XAI_API_KEY="$DUMMY_XAI_KEY" OPENROUTER_API_KEY="$DUMMY_OPENROUTER_KEY" \
      run bash "${PLUGIN_ROOT}/scripts/${p}.sh" --mode edit --prompt "add a rainbow" \
      --input-image "$input_file" --output "$OUT"
    assert_edit_succeeds
    [[ "$(cat "$MOCK_DIR/calls")" -eq 2 ]] || { echo "$p: expected 2 curl calls, got $(cat "$MOCK_DIR/calls")"; return 1; }
    grep -q "$(printf '^%s\tretrying\t1/3\t' "$p")" "$DISPLAY_PANE_DIR/status" || {
      echo "$p: no retrying status line in the pane:"; cat "$DISPLAY_PANE_DIR/status"; return 1; }
  done
}

@test "a provider that still fails after retries says so in its error" {
  stub_curl_once_503 '{"error":{"message":"still overloaded"}}'
  # Make every call a 503 by making the canned success a 503 too.
  printf '{"error":{"message":"still overloaded"}}\n503\n' > "$MOCK_DIR/response.txt"
  IMAGE_RETRY_DELAY=0 XAI_API_KEY="$DUMMY_XAI_KEY" run bash "${PLUGIN_ROOT}/scripts/xai.sh" \
    --mode generate --prompt "a cat" --output "$OUT"
  assert_status 1
  assert_output_contains "still overloaded"
  assert_output_contains "(after 3 retries)"
  grep -q "after 3 retries" "$DISPLAY_PANE_DIR/errors/xai.txt" || { echo "pane error text lacks the retry count"; return 1; }
}
