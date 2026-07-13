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

# Installs a curl that drains the request body from stdin (the scripts stream it with
# --data-binary @-) into $MOCK_DIR/request.txt for inspection, then prints a canned body
# followed by the HTTP status on the last line, matching the `-w "\n%{http_code}"` the
# scripts rely on. The canned image data is base64 for "fake", so a fully working
# pipeline writes exactly "fake" to the output.
stub_curl() {
  printf '%s\n200\n' "$1" > "$MOCK_DIR/response.txt"
  cat > "$MOCK_DIR/curl" <<STUB
#!/bin/bash
cat > "${MOCK_DIR}/request.txt" 2>/dev/null
cat "\$(dirname "\$0")/response.txt"
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
