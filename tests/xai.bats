# ABOUTME: Bats tests for xai.sh argument parsing, validation, and env var handling.
# ABOUTME: Tests only local logic -- no real API calls are made.

setup() {
  load test_helper
  XAI_SH="${PLUGIN_ROOT}/scripts/xai.sh"
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

@test "xai: default model is grok-imagine-image-pro" {
  export XAI_API_KEY="$DUMMY_XAI_KEY"
  run "$XAI_SH" --mode generate --prompt "a cat" --output "/tmp/bats-test-xai-out.png"
  assert_output_contains "model: grok-imagine-image-pro"
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

@test "xai: more than 3 input images is rejected" {
  export XAI_API_KEY="$DUMMY_XAI_KEY"
  run "$XAI_SH" --mode edit --prompt "combine these" --output "/tmp/out.png" \
    --input-image "/tmp/x.png" --input-image "/tmp/x.png" \
    --input-image "/tmp/x.png" --input-image "/tmp/x.png"
  assert_status 1
  assert_output_contains "at most 3"
}

@test "xai: usage text includes all documented options" {
  run "$XAI_SH"
  assert_status 1
  assert_output_contains "--mode"
  assert_output_contains "--prompt"
  assert_output_contains "--output"
  assert_output_contains "--input-image"
  assert_output_contains "--aspect-ratio"
  assert_output_contains "--model"
  assert_output_contains "XAI_API_KEY"
}
