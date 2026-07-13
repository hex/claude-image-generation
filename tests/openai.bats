# ABOUTME: Bats tests for openai.sh argument parsing, validation, and env var handling.
# ABOUTME: Tests only local logic -- no real API calls are made.

setup() {
  load test_helper
  OPENAI_SH="${PLUGIN_ROOT}/scripts/openai.sh"
  # Clear API key by default; tests that need it set it explicitly
  unset OPENAI_API_KEY 2>/dev/null || true
  unset OPENAI_IMAGE_MODEL 2>/dev/null || true
}

@test "openai: no arguments prints error and usage" {
  run "$OPENAI_SH"
  assert_status 1
  assert_output_contains "Error: --mode, --prompt, and --output are required"
  assert_output_contains "Usage:"
}

@test "openai: missing --mode prints error" {
  run "$OPENAI_SH" --prompt "a cat" --output "/tmp/out.png"
  assert_status 1
  assert_output_contains "Error: --mode, --prompt, and --output are required"
}

@test "openai: missing --prompt prints error" {
  run "$OPENAI_SH" --mode generate --output "/tmp/out.png"
  assert_status 1
  assert_output_contains "Error: --mode, --prompt, and --output are required"
}

@test "openai: missing --output prints error" {
  run "$OPENAI_SH" --mode generate --prompt "a cat"
  assert_status 1
  assert_output_contains "Error: --mode, --prompt, and --output are required"
}

@test "openai: edit mode without --input-image prints error" {
  export OPENAI_API_KEY="$DUMMY_OPENAI_KEY"
  run "$OPENAI_SH" --mode edit --prompt "make it blue" --output "/tmp/out.png"
  assert_status 1
  assert_output_contains "Error: --input-image is required for edit mode"
}

@test "openai: missing OPENAI_API_KEY prints error" {
  unset OPENAI_API_KEY 2>/dev/null || true
  run "$OPENAI_SH" --mode generate --prompt "a cat" --output "/tmp/out.png"
  assert_status 1
  assert_output_contains "Error: OPENAI_API_KEY environment variable is not set"
}

@test "openai: unknown flag prints error and usage" {
  run "$OPENAI_SH" --bogus-flag value
  assert_status 1
  assert_output_contains "Unknown option: --bogus-flag"
  assert_output_contains "Usage:"
}

@test "openai: default model is gpt-image-2" {
  export OPENAI_API_KEY="$DUMMY_OPENAI_KEY"
  # The script prints "Calling OpenAI API (model: ...)" before the curl call
  run "$OPENAI_SH" --mode generate --prompt "a cat" --output "/tmp/bats-test-openai-out.png"
  assert_output_contains "model: gpt-image-2"
}

@test "openai: OPENAI_IMAGE_MODEL env var overrides default model" {
  export OPENAI_API_KEY="$DUMMY_OPENAI_KEY"
  export OPENAI_IMAGE_MODEL="custom-openai-model"
  run "$OPENAI_SH" --mode generate --prompt "a cat" --output "/tmp/bats-test-openai-out.png"
  assert_output_contains "model: custom-openai-model"
}

@test "openai: --model flag overrides default and env var" {
  export OPENAI_API_KEY="$DUMMY_OPENAI_KEY"
  export OPENAI_IMAGE_MODEL="custom-openai-model"
  run "$OPENAI_SH" --mode generate --prompt "a cat" --output "/tmp/bats-test-openai-out.png" --model "flag-model"
  assert_output_contains "model: flag-model"
}

@test "openai: more than 16 input images is rejected" {
  export OPENAI_API_KEY="$DUMMY_OPENAI_KEY"
  local args=(--mode edit --prompt "combine these" --output "/tmp/out.png")
  for i in $(seq 1 17); do
    args+=(--input-image "/tmp/x.png")
  done
  run "$OPENAI_SH" "${args[@]}"
  assert_status 1
  assert_output_contains "at most 16"
}

@test "openai: dall-e-2 with multiple images rejected" {
  export OPENAI_API_KEY="$DUMMY_OPENAI_KEY"
  run "$OPENAI_SH" --mode edit --prompt "combine these" --output "/tmp/out.png" \
    --model dall-e-2 --input-image "/tmp/x.png" --input-image "/tmp/y.png"
  assert_status 1
  assert_output_contains "at most 1 input image for dall-e-2"
}

@test "openai: usage text includes all documented options" {
  run "$OPENAI_SH"
  assert_status 1
  assert_output_contains "--mode"
  assert_output_contains "--prompt"
  assert_output_contains "--output"
  assert_output_contains "--input-image"
  assert_output_contains "--size"
  assert_output_contains "--quality"
  assert_output_contains "--background"
  assert_output_contains "--model"
  assert_output_contains "OPENAI_API_KEY"
}
