# ABOUTME: Bats tests for xai.sh argument parsing, validation, and env var handling.
# ABOUTME: Tests only local logic -- no real API calls are made.

setup() {
  load test_helper
  XAI_SH="${PLUGIN_ROOT}/scripts/xai.sh"
  # These tests run xai.sh far enough to reach the display pane, which would join or
  # split a pane in the developer's own tmux session once per test.
  disable_display
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
  run "$XAI_SH" --prompt "a cat" --output "/tmp/out.png"
  assert_status 1
  assert_output_contains "Error: --mode, --prompt, and --output are required"
}

@test "xai: missing --prompt prints error" {
  run "$XAI_SH" --mode generate --output "/tmp/out.png"
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
  run "$XAI_SH" --mode edit --prompt "make it blue" --output "/tmp/out.png"
  assert_status 1
  assert_output_contains "Error: --input-image is required for edit mode"
}

@test "xai: missing XAI_API_KEY and GROK_API_KEY prints error" {
  unset XAI_API_KEY 2>/dev/null || true
  unset GROK_API_KEY 2>/dev/null || true
  run "$XAI_SH" --mode generate --prompt "a cat" --output "/tmp/out.png"
  assert_status 1
  assert_output_contains "XAI_API_KEY or GROK_API_KEY"
}

@test "xai: GROK_API_KEY works as fallback" {
  export GROK_API_KEY="$DUMMY_XAI_KEY"
  run "$XAI_SH" --mode generate --prompt "a cat" --output "/tmp/bats-test-xai-out.png"
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
  run "$XAI_SH" --mode generate --prompt "a cat" --output "/tmp/bats-test-xai-out.png"
  assert_output_contains "model: grok-imagine-image-2.0,"
}

@test "xai: XAI_IMAGE_MODEL env var overrides default model" {
  export XAI_API_KEY="$DUMMY_XAI_KEY"
  export XAI_IMAGE_MODEL="grok-imagine-image"
  run "$XAI_SH" --mode generate --prompt "a cat" --output "/tmp/bats-test-xai-out.png"
  assert_output_contains "model: grok-imagine-image"
}

@test "xai: --model flag overrides default and env var" {
  export XAI_API_KEY="$DUMMY_XAI_KEY"
  export XAI_IMAGE_MODEL="grok-imagine-image"
  run "$XAI_SH" --mode generate --prompt "a cat" --output "/tmp/bats-test-xai-out.png" --model "custom-xai-model"
  assert_output_contains "model: custom-xai-model"
}

@test "xai: more than 5 input images is rejected" {
  export XAI_API_KEY="$DUMMY_XAI_KEY"
  run "$XAI_SH" --mode edit --prompt "combine these" --output "/tmp/out.png" \
    --input-image "/tmp/x.png" --input-image "/tmp/x.png" --input-image "/tmp/x.png" \
    --input-image "/tmp/x.png" --input-image "/tmp/x.png" --input-image "/tmp/x.png"
  assert_status 1
  assert_output_contains "at most 5"
}

@test "xai: five input images pass the cap" {
  export XAI_API_KEY="$DUMMY_XAI_KEY"
  local img="${PLUGIN_ROOT}/tests/fixtures/oversized.png"
  # grok-imagine-image-2.0 edits take up to five reference images. The dummy key fails at
  # the API call, which is past the cap check.
  run "$XAI_SH" --mode edit --prompt "combine these" --output "/tmp/out.png" \
    --input-image "$img" --input-image "$img" --input-image "$img" \
    --input-image "$img" --input-image "$img"
  [[ "$output" != *"at most"* ]] || { echo "five images were rejected by the cap:"; echo "$output"; return 1; }
}

@test "xai: --quality rejects a value the API does not know" {
  export XAI_API_KEY="$DUMMY_XAI_KEY"
  run "$XAI_SH" --mode generate --prompt "a cat" --output "/tmp/out.png" --quality high
  assert_status 1
  assert_output_contains "--quality must be 'low', 'medium' or 'auto'"
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
