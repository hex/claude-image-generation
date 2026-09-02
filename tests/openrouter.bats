# ABOUTME: Bats tests for openrouter.sh argument parsing, validation, and env var handling.
# ABOUTME: Tests only local logic -- no real API calls are made.

setup() {
  load test_helper
  OPENROUTER_SH="${PLUGIN_ROOT}/scripts/openrouter.sh"
  # These tests run openrouter.sh far enough to reach the display pane, which would join or
  # split a pane in the developer's own tmux session once per test.
  disable_display
  # Clear API key by default; tests that need it set it explicitly
  unset OPENROUTER_API_KEY 2>/dev/null || true
  unset OPENROUTER_IMAGE_MODEL 2>/dev/null || true
}

@test "openrouter: no arguments prints error and usage" {
  run "$OPENROUTER_SH"
  assert_status 1
  assert_output_contains "Error: --mode, --prompt, and --output are required"
  assert_output_contains "Usage:"
}

@test "openrouter: missing --mode prints error" {
  run "$OPENROUTER_SH" --prompt "a cat" --output "/tmp/out.png"
  assert_status 1
  assert_output_contains "Error: --mode, --prompt, and --output are required"
}

@test "openrouter: missing --prompt prints error" {
  run "$OPENROUTER_SH" --mode generate --output "/tmp/out.png"
  assert_status 1
  assert_output_contains "Error: --mode, --prompt, and --output are required"
}

@test "openrouter: missing --output prints error" {
  run "$OPENROUTER_SH" --mode generate --prompt "a cat"
  assert_status 1
  assert_output_contains "Error: --mode, --prompt, and --output are required"
}

@test "openrouter: invalid --mode prints error" {
  export OPENROUTER_API_KEY="$DUMMY_OPENROUTER_KEY"
  run "$OPENROUTER_SH" --mode bogus --prompt "a cat" --output "/tmp/out.png"
  assert_status 1
  assert_output_contains "Error: --mode must be 'generate' or 'edit'"
}

@test "openrouter: edit mode without --input-image prints error" {
  export OPENROUTER_API_KEY="$DUMMY_OPENROUTER_KEY"
  run "$OPENROUTER_SH" --mode edit --prompt "make it blue" --output "/tmp/out.png"
  assert_status 1
  assert_output_contains "Error: --input-image is required for edit mode"
}

@test "openrouter: missing OPENROUTER_API_KEY prints error" {
  unset OPENROUTER_API_KEY 2>/dev/null || true
  run "$OPENROUTER_SH" --mode generate --prompt "a cat" --output "/tmp/out.png"
  assert_status 1
  assert_output_contains "Error: OPENROUTER_API_KEY environment variable is not set"
}

@test "openrouter: unknown flag prints error and usage" {
  run "$OPENROUTER_SH" --bogus-flag value
  assert_status 1
  assert_output_contains "Unknown option: --bogus-flag"
  assert_output_contains "Usage:"
}

@test "openrouter: default model is google/gemini-3.1-flash-image" {
  export OPENROUTER_API_KEY="$DUMMY_OPENROUTER_KEY"
  # The script prints "Calling OpenRouter API (model: ...)" before the curl call
  run "$OPENROUTER_SH" --mode generate --prompt "a cat" --output "/tmp/bats-test-openrouter-out.png"
  assert_output_contains "model: google/gemini-3.1-flash-image"
}

@test "openrouter: OPENROUTER_IMAGE_MODEL env var overrides default model" {
  export OPENROUTER_API_KEY="$DUMMY_OPENROUTER_KEY"
  export OPENROUTER_IMAGE_MODEL="custom/openrouter-model"
  run "$OPENROUTER_SH" --mode generate --prompt "a cat" --output "/tmp/bats-test-openrouter-out.png"
  assert_output_contains "model: custom/openrouter-model"
}

@test "openrouter: --model flag overrides default and env var" {
  export OPENROUTER_API_KEY="$DUMMY_OPENROUTER_KEY"
  export OPENROUTER_IMAGE_MODEL="custom/openrouter-model"
  run "$OPENROUTER_SH" --mode generate --prompt "a cat" --output "/tmp/bats-test-openrouter-out.png" --model "flag/model"
  assert_output_contains "model: flag/model"
}

@test "openrouter: usage text includes all documented options" {
  run "$OPENROUTER_SH"
  assert_status 1
  assert_output_contains "--mode"
  assert_output_contains "--prompt"
  assert_output_contains "--output"
  assert_output_contains "--input-image"
  assert_output_contains "--model"
  assert_output_contains "--site-url"
  assert_output_contains "--site-name"
  assert_output_contains "OPENROUTER_API_KEY"
}

# OpenRouter reports a mid-generation upstream failure as HTTP 200 with the error on the
# choice, so the script has to name it rather than report a missing image.
@test "openrouter: an error on the choice of a 200 response is reported by message" {
  export OPENROUTER_API_KEY="$DUMMY_OPENROUTER_KEY"
  export DISPLAY_PANE_DIR="${BATS_TMPDIR}/openrouter_pane_$$"
  mkdir -p "$DISPLAY_PANE_DIR"
  local mock_dir="${BATS_TMPDIR}/openrouter_mocks_$$"
  mkdir -p "$mock_dir"
  printf '%s\n200\n' '{"choices":[{"error":{"code":502,"message":"upstream boom"},"finish_reason":"error","message":{"content":""}}]}' > "$mock_dir/response.txt"
  printf '#!/bin/bash\ncat >/dev/null\ncat "$(dirname "$0")/response.txt"\n' > "$mock_dir/curl"
  chmod +x "$mock_dir/curl"
  PATH="$mock_dir:$PATH" run "$OPENROUTER_SH" --mode generate --prompt "a cat" --output "${BATS_TMPDIR}/openrouter_err_$$.png"
  rm -rf "$mock_dir" "$DISPLAY_PANE_DIR"
  assert_status 1
  assert_output_contains "OpenRouter provider error (502): upstream boom"
}
