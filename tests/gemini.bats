# ABOUTME: Bats tests for gemini.sh argument parsing, validation, and env var handling.
# ABOUTME: Tests only local logic -- no real API calls are made.

setup() {
  load test_helper
  GEMINI_SH="${PLUGIN_ROOT}/scripts/gemini.sh"
  # These tests run gemini.sh far enough to reach the display pane, which would join or
  # split a pane in the developer's own tmux session once per test.
  disable_display
  # Some tests run gemini.sh as far as the API call, which would otherwise go to Google.
  stub_provider_api
  # An output path of this test's own, so no file left by another run stands in for it.
  OUT="${BATS_TEST_TMPDIR}/out.png"
  # Clear API key by default; tests that need it set it explicitly
  unset GEMINI_API_KEY 2>/dev/null || true
  unset GEMINI_IMAGE_MODEL 2>/dev/null || true
}

@test "gemini: no arguments prints error and usage" {
  run "$GEMINI_SH"
  assert_status 1
  assert_output_contains "Error: --mode, --prompt, and --output are required"
  assert_output_contains "Usage:"
}

@test "gemini: missing --mode prints error" {
  run "$GEMINI_SH" --prompt "a cat" --output "$OUT"
  assert_status 1
  assert_output_contains "Error: --mode, --prompt, and --output are required"
}

@test "gemini: missing --prompt prints error" {
  run "$GEMINI_SH" --mode generate --output "$OUT"
  assert_status 1
  assert_output_contains "Error: --mode, --prompt, and --output are required"
}

@test "gemini: missing --output prints error" {
  run "$GEMINI_SH" --mode generate --prompt "a cat"
  assert_status 1
  assert_output_contains "Error: --mode, --prompt, and --output are required"
}

@test "gemini: edit mode without --input-image prints error" {
  export GEMINI_API_KEY="$DUMMY_GEMINI_KEY"
  run "$GEMINI_SH" --mode edit --prompt "make it blue" --output "$OUT"
  assert_status 1
  assert_output_contains "Error: --input-image is required for edit mode"
}

@test "gemini: missing GEMINI_API_KEY prints error" {
  unset GEMINI_API_KEY 2>/dev/null || true
  run "$GEMINI_SH" --mode generate --prompt "a cat" --output "$OUT"
  assert_status 1
  assert_output_contains "Error: GEMINI_API_KEY environment variable is not set"
}

@test "gemini: unknown flag prints error and usage" {
  run "$GEMINI_SH" --bogus-flag value
  assert_status 1
  assert_output_contains "Unknown option: --bogus-flag"
  assert_output_contains "Usage:"
}

@test "gemini: default model is gemini-3-pro-image" {
  export GEMINI_API_KEY="$DUMMY_GEMINI_KEY"
  # The script will fail at the curl call, but we can check stderr for the model name
  run "$GEMINI_SH" --mode generate --prompt "a cat" --output "$OUT"
  # The script either prints the model in its API call message or fails at curl.
  # Since we have a dummy key, curl will fail, but the "Calling Gemini API" message
  # is printed before the curl call.
  assert_output_contains "model: gemini-3-pro-image,"
}

@test "gemini: GEMINI_IMAGE_MODEL env var overrides default model" {
  export GEMINI_API_KEY="$DUMMY_GEMINI_KEY"
  export GEMINI_IMAGE_MODEL="gemini-custom-model"
  run "$GEMINI_SH" --mode generate --prompt "a cat" --output "$OUT"
  assert_output_contains "model: gemini-custom-model"
}

@test "gemini: --model flag overrides default and env var" {
  export GEMINI_API_KEY="$DUMMY_GEMINI_KEY"
  export GEMINI_IMAGE_MODEL="gemini-custom-model"
  run "$GEMINI_SH" --mode generate --prompt "a cat" --output "$OUT" --model "gemini-flag-model"
  assert_output_contains "model: gemini-flag-model"
}

@test "gemini: more than 14 input images is rejected" {
  export GEMINI_API_KEY="$DUMMY_GEMINI_KEY"
  local args=(--mode edit --prompt "combine these" --output "$OUT")
  for i in $(seq 1 15); do
    args+=(--input-image "/tmp/x.png")
  done
  run "$GEMINI_SH" "${args[@]}"
  assert_status 1
  assert_output_contains "at most 14"
}

@test "gemini: an aspect ratio and a size tier reach the request's imageConfig" {
  export GEMINI_API_KEY="$DUMMY_GEMINI_KEY"
  run "$GEMINI_SH" --mode generate --prompt "a cat" --output "$OUT" --aspect-ratio 16:9 --size-tier 2K
  local config
  config=$(jq -c '.generationConfig.imageConfig' "$PROVIDER_API_STUB_DIR/body") || { echo "$output"; return 1; }
  [[ "$config" == '{"aspectRatio":"16:9","imageSize":"2K"}' ]] || { echo "imageConfig: $config"; echo "$output"; return 1; }
}

@test "gemini: --image-size given beside a size tier wins" {
  export GEMINI_API_KEY="$DUMMY_GEMINI_KEY"
  run "$GEMINI_SH" --mode generate --prompt "a cat" --output "$OUT" --image-size 4K --size-tier 2K
  [[ "$(jq -r '.generationConfig.imageConfig.imageSize' "$PROVIDER_API_STUB_DIR/body")" == 4K ]] || { echo "$output"; return 1; }
}

@test "gemini: a ratio the model does not draw is refused before any request, naming the ones it does" {
  export GEMINI_API_KEY="$DUMMY_GEMINI_KEY"
  run "$GEMINI_SH" --mode generate --prompt "a cat" --output "$OUT" --aspect-ratio 4:1
  assert_status 1
  [[ "$output" == "Error: gemini-3-pro-image does not take aspect ratio 4:1; it takes 1:1, 2:3, 3:2, 3:4, 4:3, 4:5, 5:4, 9:16, 16:9, 21:9" ]] || { echo "$output"; return 1; }
  [[ ! -e "$PROVIDER_API_STUB_DIR/url" ]] || { echo "a request went to $(cat "$PROVIDER_API_STUB_DIR/url")"; return 1; }
  # The Nano Banana 2 models draw the extreme ratios.
  run "$GEMINI_SH" --mode generate --prompt "a cat" --output "$OUT" --aspect-ratio 4:1 --model gemini-nano-banana-2.1
  [[ "$(jq -r '.generationConfig.imageConfig.aspectRatio' "$PROVIDER_API_STUB_DIR/body")" == 4:1 ]] || { echo "$output"; return 1; }
}

@test "gemini: a size for a model that takes none is refused before any request, naming the model" {
  export GEMINI_API_KEY="$DUMMY_GEMINI_KEY"
  run "$GEMINI_SH" --mode generate --prompt "a cat" --output "$OUT" --size-tier 1K --model gemini-2.5-flash-image
  assert_status 1
  [[ "$output" == "Error: gemini-2.5-flash-image takes no image size (it draws 1K only), got 1K" ]] || { echo "$output"; return 1; }
  [[ ! -e "$PROVIDER_API_STUB_DIR/url" ]] || { echo "a request went to $(cat "$PROVIDER_API_STUB_DIR/url")"; return 1; }
  # With no size it draws as before.
  run "$GEMINI_SH" --mode generate --prompt "a cat" --output "$OUT" --model gemini-2.5-flash-image
  [[ "$(jq -c '.generationConfig.imageConfig' "$PROVIDER_API_STUB_DIR/body")" == '{"aspectRatio":"1:1"}' ]] || { echo "$output"; return 1; }
}

@test "gemini: with no ratio or size tier the request asks for 1:1 and leaves the size to the API" {
  export GEMINI_API_KEY="$DUMMY_GEMINI_KEY"
  run "$GEMINI_SH" --mode generate --prompt "a cat" --output "$OUT"
  [[ "$(jq -c '.generationConfig.imageConfig' "$PROVIDER_API_STUB_DIR/body")" == '{"aspectRatio":"1:1"}' ]] || { echo "$output"; return 1; }
}

@test "gemini: usage text includes all documented options" {
  run "$GEMINI_SH"
  assert_status 1
  assert_output_contains "--mode"
  assert_output_contains "--prompt"
  assert_output_contains "--output"
  assert_output_contains "--input-image"
  assert_output_contains "--aspect-ratio"
  assert_output_contains "--model"
  assert_output_contains "GEMINI_API_KEY"
  assert_output_contains "GEMINI_IMAGE_MODEL"
}
