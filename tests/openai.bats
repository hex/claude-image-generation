# ABOUTME: Bats tests for openai.sh argument parsing, validation, and env var handling.
# ABOUTME: Tests only local logic -- no real API calls are made.

setup() {
  load test_helper
  OPENAI_SH="${PLUGIN_ROOT}/scripts/openai.sh"
  PNG_FIXTURE="${PLUGIN_ROOT}/tests/fixtures/oversized.png"
  # These tests run openai.sh far enough to reach the display pane, which would join or
  # split a pane in the developer's own tmux session once per test.
  disable_display
  # Some tests run openai.sh as far as the API call, which would otherwise go to OpenAI.
  stub_provider_api
  # An output path of this test's own, so no file left by another run stands in for it.
  OUT="${BATS_TEST_TMPDIR}/out.png"
  # Clear API key by default; tests that need it set it explicitly
  unset OPENAI_API_KEY 2>/dev/null || true
  unset OPENAI_IMAGE_MODEL 2>/dev/null || true
}

teardown() {
  [[ -n "${MOCK_DIR:-}" ]] && rm -rf "$MOCK_DIR"
  [[ -n "${CAPTURE_FILE:-}" ]] && rm -f "$CAPTURE_FILE"
  return 0
}

@test "openai: no arguments prints error and usage" {
  run "$OPENAI_SH"
  assert_status 1
  assert_output_contains "Error: --mode, --prompt, and --output are required"
  assert_output_contains "Usage:"
}

@test "openai: missing --mode prints error" {
  run "$OPENAI_SH" --prompt "a cat" --output "$OUT"
  assert_status 1
  assert_output_contains "Error: --mode, --prompt, and --output are required"
}

@test "openai: missing --prompt prints error" {
  run "$OPENAI_SH" --mode generate --output "$OUT"
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
  run "$OPENAI_SH" --mode edit --prompt "make it blue" --output "$OUT"
  assert_status 1
  assert_output_contains "Error: --input-image is required for edit mode"
}

@test "openai: missing OPENAI_API_KEY prints error" {
  unset OPENAI_API_KEY 2>/dev/null || true
  run "$OPENAI_SH" --mode generate --prompt "a cat" --output "$OUT"
  assert_status 1
  assert_output_contains "Error: OPENAI_API_KEY environment variable is not set"
}

@test "openai: unknown flag prints error and usage" {
  run "$OPENAI_SH" --bogus-flag value
  assert_status 1
  assert_output_contains "Unknown option: --bogus-flag"
  assert_output_contains "Usage:"
}

@test "openai: default model is gpt-image-2.6-sunburst" {
  export OPENAI_API_KEY="$DUMMY_OPENAI_KEY"
  # The script prints "Calling OpenAI API (model: ...)" before the curl call
  run "$OPENAI_SH" --mode generate --prompt "a cat" --output "$OUT"
  assert_output_contains "Calling OpenAI API (model: gpt-image-2.6-sunburst, mode: generate)"
}

@test "openai: OPENAI_IMAGE_MODEL env var overrides default model" {
  export OPENAI_API_KEY="$DUMMY_OPENAI_KEY"
  export OPENAI_IMAGE_MODEL="custom-openai-model"
  run "$OPENAI_SH" --mode generate --prompt "a cat" --output "$OUT"
  assert_output_contains "model: custom-openai-model"
}

@test "openai: --model flag overrides default and env var" {
  export OPENAI_API_KEY="$DUMMY_OPENAI_KEY"
  export OPENAI_IMAGE_MODEL="custom-openai-model"
  run "$OPENAI_SH" --mode generate --prompt "a cat" --output "$OUT" --model "flag-model"
  assert_output_contains "model: flag-model"
}

@test "openai: more than 16 input images is rejected" {
  export OPENAI_API_KEY="$DUMMY_OPENAI_KEY"
  local args=(--mode edit --prompt "combine these" --output "$OUT")
  for i in $(seq 1 17); do
    args+=(--input-image "/tmp/x.png")
  done
  run "$OPENAI_SH" "${args[@]}"
  assert_status 1
  assert_output_contains "at most 16"
}

@test "openai: --input-fidelity is refused on the default gpt-image-2.6-sunburst and on gpt-image-2, whose API rejects it" {
  export OPENAI_API_KEY="$DUMMY_OPENAI_KEY"
  run "$OPENAI_SH" --mode edit --prompt "keep the face" --output "$OUT" \
    --input-image "/tmp/x.png" --input-fidelity high
  assert_status 1
  assert_output_contains "Error: --input-fidelity is not accepted by gpt-image-2.6-sunburst; drop the flag or pass --model gpt-image-1.5"

  run "$OPENAI_SH" --mode edit --prompt "keep the face" --output "$OUT" \
    --input-image "/tmp/x.png" --input-fidelity high --model gpt-image-2
  assert_status 1
  assert_output_contains "Error: --input-fidelity is not accepted by gpt-image-2; drop the flag or pass --model gpt-image-1.5"
}

@test "openai: --input-fidelity still reaches the API on gpt-image-1.5" {
  export OPENAI_API_KEY="$DUMMY_OPENAI_KEY"
  MOCK_DIR="${BATS_TMPDIR}/openai_curl_mock_$$"
  mkdir -p "$MOCK_DIR"
  printf '#!/bin/bash\nprintf "{}\\n401\\n"\n' > "$MOCK_DIR/curl"
  chmod +x "$MOCK_DIR/curl"
  PATH="$MOCK_DIR:$PATH" run "$OPENAI_SH" --mode edit --prompt "keep the face" --output "$OUT" \
    --input-image "$PNG_FIXTURE" --input-fidelity high --model gpt-image-1.5
  assert_output_contains "Calling OpenAI API (model: gpt-image-1.5, mode: edit)"
  [[ "$output" != *"is not accepted by"* ]] || { echo "refused a model that takes the flag: $output"; return 1; }
}

@test "openai: dall-e-2 with multiple images rejected" {
  export OPENAI_API_KEY="$DUMMY_OPENAI_KEY"
  run "$OPENAI_SH" --mode edit --prompt "combine these" --output "$OUT" \
    --model dall-e-2 --input-image "/tmp/x.png" --input-image "/tmp/y.png"
  assert_status 1
  assert_output_contains "at most 1 input image for dall-e-2"
}

@test "openai: edit mode sends prompt via --form-string, not -F" {
  # curl's -F treats a value starting with '@' or '<' as a file to read, so a prompt
  # starting with either would leak local file contents to the API as the "prompt"
  # field instead of being sent as text. --form-string sends it literally.
  export OPENAI_API_KEY="$DUMMY_OPENAI_KEY"
  MOCK_DIR="${BATS_TMPDIR}/openai_curl_mock_$$"
  CAPTURE_FILE="${BATS_TMPDIR}/openai_curl_args_$$"
  mkdir -p "$MOCK_DIR"
  cat > "$MOCK_DIR/curl" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "${CAPTURE_FILE}"
printf '{"data":[{"b64_json":""}]}\n200\n'
EOF
  chmod +x "$MOCK_DIR/curl"

  PATH="$MOCK_DIR:$PATH" run "$OPENAI_SH" --mode edit --prompt '@/etc/passwd' \
    --output "$OUT" --input-image "$PNG_FIXTURE"

  local flag
  flag=$(grep -B1 -x 'prompt=@/etc/passwd' "$CAPTURE_FILE" | head -1)
  [[ "$flag" == "--form-string" ]] || { echo "prompt was passed after '${flag}', not --form-string:"; cat "$CAPTURE_FILE"; return 1; }
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
