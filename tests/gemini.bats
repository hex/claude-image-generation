# ABOUTME: Bats tests for gemini.sh argument parsing, validation, and env var handling.
# ABOUTME: Tests only local logic -- no real API calls are made.

setup() {
  load test_helper
  GEMINI_SH="${PLUGIN_ROOT}/scripts/gemini.sh"
  # These tests run gemini.sh far enough to reach the display pane, which would join or
  # split a pane in the developer's own tmux session once per test.
  disable_display
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
  run "$GEMINI_SH" --prompt "a cat" --output "/tmp/out.png"
  assert_status 1
  assert_output_contains "Error: --mode, --prompt, and --output are required"
}

@test "gemini: missing --prompt prints error" {
  run "$GEMINI_SH" --mode generate --output "/tmp/out.png"
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
  run "$GEMINI_SH" --mode edit --prompt "make it blue" --output "/tmp/out.png"
  assert_status 1
  assert_output_contains "Error: --input-image is required for edit mode"
}

@test "gemini: missing GEMINI_API_KEY prints error" {
  unset GEMINI_API_KEY 2>/dev/null || true
  run "$GEMINI_SH" --mode generate --prompt "a cat" --output "/tmp/out.png"
  assert_status 1
  assert_output_contains "Error: GEMINI_API_KEY environment variable is not set"
}

@test "gemini: unknown flag prints error and usage" {
  run "$GEMINI_SH" --bogus-flag value
  assert_status 1
  assert_output_contains "Unknown option: --bogus-flag"
  assert_output_contains "Usage:"
}

@test "gemini: default model is gemini-3-pro-image-preview" {
  export GEMINI_API_KEY="$DUMMY_GEMINI_KEY"
  # The script will fail at the curl call, but we can check stderr for the model name
  run "$GEMINI_SH" --mode generate --prompt "a cat" --output "/tmp/bats-test-gemini-out.png"
  # The script either prints the model in its API call message or fails at curl.
  # Since we have a dummy key, curl will fail, but the "Calling Gemini API" message
  # is printed before the curl call.
  assert_output_contains "model: gemini-3-pro-image-preview"
}

@test "gemini: GEMINI_IMAGE_MODEL env var overrides default model" {
  export GEMINI_API_KEY="$DUMMY_GEMINI_KEY"
  export GEMINI_IMAGE_MODEL="gemini-custom-model"
  run "$GEMINI_SH" --mode generate --prompt "a cat" --output "/tmp/bats-test-gemini-out.png"
  assert_output_contains "model: gemini-custom-model"
}

@test "gemini: --model flag overrides default and env var" {
  export GEMINI_API_KEY="$DUMMY_GEMINI_KEY"
  export GEMINI_IMAGE_MODEL="gemini-custom-model"
  run "$GEMINI_SH" --mode generate --prompt "a cat" --output "/tmp/bats-test-gemini-out.png" --model "gemini-flag-model"
  assert_output_contains "model: gemini-flag-model"
}

@test "gemini: more than 14 input images is rejected" {
  export GEMINI_API_KEY="$DUMMY_GEMINI_KEY"
  local args=(--mode edit --prompt "combine these" --output "/tmp/out.png")
  for i in $(seq 1 15); do
    args+=(--input-image "/tmp/x.png")
  done
  run "$GEMINI_SH" "${args[@]}"
  assert_status 1
  assert_output_contains "at most 14"
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
