# ABOUTME: Bats tests for xai.sh argument parsing, validation, and env var handling.
# ABOUTME: Tests only local logic -- no real API calls are made.

setup() {
  load test_helper
  XAI_SH="${PLUGIN_ROOT}/scripts/xai.sh"
  # These tests run xai.sh far enough to reach the display pane, which would join or
  # split a pane in the developer's own tmux session once per test.
  disable_display
  # Some tests run xai.sh as far as the API call, which would otherwise go to api.x.ai.
  stub_provider_api
  # An output path of this test's own, so no file left by another run stands in for it.
  OUT="${BATS_TEST_TMPDIR}/out.png"
  # Clear API keys by default; tests that need them set them explicitly
  unset XAI_API_KEY 2>/dev/null || true
  unset GROK_API_KEY 2>/dev/null || true
  unset XAI_IMAGE_MODEL 2>/dev/null || true
}

@test "xai: no arguments prints error and usage" {
  run "$XAI_SH"
  assert_status 1
  assert_output_contains "Error: --mode, --prompt, and --output are required"
  assert_output_contains "Usage:"
}

@test "xai: missing --mode prints error" {
  run "$XAI_SH" --prompt "a cat" --output "$OUT"
  assert_status 1
  assert_output_contains "Error: --mode, --prompt, and --output are required"
}

@test "xai: missing --prompt prints error" {
  run "$XAI_SH" --mode generate --output "$OUT"
  assert_status 1
  assert_output_contains "Error: --mode, --prompt, and --output are required"
}

@test "xai: missing --output prints error" {
  run "$XAI_SH" --mode generate --prompt "a cat"
  assert_status 1
  assert_output_contains "Error: --mode, --prompt, and --output are required"
}

@test "xai: edit mode without --input-image prints error" {
  export XAI_API_KEY="$DUMMY_XAI_KEY"
  run "$XAI_SH" --mode edit --prompt "make it blue" --output "$OUT"
  assert_status 1
  assert_output_contains "Error: --input-image is required for edit mode"
}

@test "xai: missing XAI_API_KEY and GROK_API_KEY prints error" {
  unset XAI_API_KEY 2>/dev/null || true
  unset GROK_API_KEY 2>/dev/null || true
  run "$XAI_SH" --mode generate --prompt "a cat" --output "$OUT"
  assert_status 1
  assert_output_contains "XAI_API_KEY or GROK_API_KEY"
}

@test "xai: GROK_API_KEY works as fallback" {
  export GROK_API_KEY="$DUMMY_XAI_KEY"
  run "$XAI_SH" --mode generate --prompt "a cat" --output "$OUT"
  assert_output_contains "Calling xAI API"
}

@test "xai: unknown flag prints error and usage" {
  run "$XAI_SH" --bogus-flag value
  assert_status 1
  assert_output_contains "Unknown option: --bogus-flag"
  assert_output_contains "Usage:"
}

@test "xai: default model is grok-imagine-image-2.0" {
  export XAI_API_KEY="$DUMMY_XAI_KEY"
  run "$XAI_SH" --mode generate --prompt "a cat" --output "$OUT"
  assert_output_contains "model: grok-imagine-image-2.0,"
}

@test "xai: XAI_IMAGE_MODEL env var overrides default model" {
  export XAI_API_KEY="$DUMMY_XAI_KEY"
  export XAI_IMAGE_MODEL="grok-imagine-image"
  run "$XAI_SH" --mode generate --prompt "a cat" --output "$OUT"
  assert_output_contains "model: grok-imagine-image"
}

@test "xai: --model flag overrides default and env var" {
  export XAI_API_KEY="$DUMMY_XAI_KEY"
  export XAI_IMAGE_MODEL="grok-imagine-image"
  run "$XAI_SH" --mode generate --prompt "a cat" --output "$OUT" --model "custom-xai-model"
  assert_output_contains "model: custom-xai-model"
}

@test "xai: more than 5 input images is rejected" {
  export XAI_API_KEY="$DUMMY_XAI_KEY"
  run "$XAI_SH" --mode edit --prompt "combine these" --output "$OUT" \
    --input-image "/tmp/x.png" --input-image "/tmp/x.png" --input-image "/tmp/x.png" \
    --input-image "/tmp/x.png" --input-image "/tmp/x.png" --input-image "/tmp/x.png"
  assert_status 1
  assert_output_contains "at most 5"
}

@test "xai: five input images pass the cap" {
  export XAI_API_KEY="$DUMMY_XAI_KEY"
  local img="${PLUGIN_ROOT}/tests/fixtures/oversized.png"
  # grok-imagine-image-2.0 edits take up to five reference images. The stubbed API refuses
  # the dummy key, which is past the cap check.
  run "$XAI_SH" --mode edit --prompt "combine these" --output "$OUT" \
    --input-image "$img" --input-image "$img" --input-image "$img" \
    --input-image "$img" --input-image "$img"
  [[ "$output" != *"at most"* ]] || { echo "five images were rejected by the cap:"; echo "$output"; return 1; }
  local url sent
  url=$(cat "$PROVIDER_API_STUB_DIR/url" 2>/dev/null)
  [[ "$url" == "https://api.x.ai/v1/images/edits" ]] || { echo "edit request went to '$url'"; echo "$output"; return 1; }
  sent=$(jq '.images | length' "$PROVIDER_API_STUB_DIR/body")
  [[ "$sent" == "5" ]] || { echo "edit request carried '$sent' images, want 5"; return 1; }
}

@test "xai: --quality rejects a value the API does not know" {
  export XAI_API_KEY="$DUMMY_XAI_KEY"
  run "$XAI_SH" --mode generate --prompt "a cat" --output "$OUT" --quality high
  assert_status 1
  assert_output_contains "--quality must be 'low', 'medium' or 'auto'"
}

@test "xai: an aspect ratio and a size tier reach the request as aspect_ratio and resolution" {
  export XAI_API_KEY="$DUMMY_XAI_KEY"
  run "$XAI_SH" --mode generate --prompt "a cat" --output "$OUT" --aspect-ratio 16:9 --size-tier 2K
  [[ "$(jq -c '[.aspect_ratio, .resolution]' "$PROVIDER_API_STUB_DIR/body")" == '["16:9","2k"]' ]] || { echo "$output"; return 1; }
}

@test "xai: a 4K size tier draws at xAI's largest, 2k, and says so" {
  export XAI_API_KEY="$DUMMY_XAI_KEY"
  run "$XAI_SH" --mode generate --prompt "a cat" --output "$OUT" --size-tier 4K
  [[ "$(jq -r '.resolution' "$PROVIDER_API_STUB_DIR/body")" == 2k ]] || { echo "$output"; return 1; }
  assert_output_contains "xAI draws at most 2k; drawing 2k for the 4K size tier"
}

@test "xai: a ratio the model does not draw is refused before any request, naming the ones it does" {
  export XAI_API_KEY="$DUMMY_XAI_KEY"
  run "$XAI_SH" --mode generate --prompt "a cat" --output "$OUT" --aspect-ratio 4:5
  assert_status 1
  [[ "$output" == "Error: grok-imagine-image-2.0 does not take aspect ratio 4:5; it takes 1:1, 16:9, 9:16, 4:3, 3:4, 3:2, 2:3, 2:1, 1:2, 19.5:9, 9:19.5, 20:9, 9:20, 21:9, 5:2, auto" ]] || { echo "$output"; return 1; }
  [[ ! -e "$PROVIDER_API_STUB_DIR/url" ]] || { echo "a request went to $(cat "$PROVIDER_API_STUB_DIR/url")"; return 1; }
}

@test "xai: --resolution given beside a size tier wins, and a hand-run 4k is still refused" {
  export XAI_API_KEY="$DUMMY_XAI_KEY"
  run "$XAI_SH" --mode generate --prompt "a cat" --output "$OUT" --resolution 1k --size-tier 2K
  [[ "$(jq -r '.resolution' "$PROVIDER_API_STUB_DIR/body")" == 1k ]] || { echo "$output"; return 1; }
  run "$XAI_SH" --mode generate --prompt "a cat" --output "$OUT" --resolution 4k
  assert_status 1
  assert_output_contains "Error: --resolution must be '1k' or '2k' (lowercase required)"
}

@test "xai: with no ratio or size tier the request leaves both to the model" {
  export XAI_API_KEY="$DUMMY_XAI_KEY"
  run "$XAI_SH" --mode generate --prompt "a cat" --output "$OUT"
  [[ "$(jq -c '[has("aspect_ratio"), has("resolution")]' "$PROVIDER_API_STUB_DIR/body")" == '[false,false]' ]] || { echo "$output"; return 1; }
}

@test "xai: usage text includes all documented options" {
  run "$XAI_SH"
  assert_status 1
  assert_output_contains "--mode"
  assert_output_contains "--prompt"
  assert_output_contains "--output"
  assert_output_contains "--input-image"
  assert_output_contains "--aspect-ratio"
  assert_output_contains "--quality"
  assert_output_contains "--model"
  assert_output_contains "XAI_API_KEY"
}
