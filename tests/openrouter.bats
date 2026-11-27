# ABOUTME: Bats tests for openrouter.sh argument parsing, validation, and env var handling.
# ABOUTME: Tests only local logic -- no real API calls are made.

setup() {
  load test_helper
  OPENROUTER_SH="${PLUGIN_ROOT}/scripts/openrouter.sh"
  # These tests run openrouter.sh far enough to reach the display pane, which would join or
  # split a pane in the developer's own tmux session once per test.
  disable_display
  # Some tests run openrouter.sh as far as the API call, which would otherwise go to OpenRouter.
  stub_provider_api
  # An output path of this test's own, so no file left by another run stands in for it.
  OUT="${BATS_TEST_TMPDIR}/out.png"
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
  run "$OPENROUTER_SH" --prompt "a cat" --output "$OUT"
  assert_status 1
  assert_output_contains "Error: --mode, --prompt, and --output are required"
}

@test "openrouter: missing --prompt prints error" {
  run "$OPENROUTER_SH" --mode generate --output "$OUT"
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
  run "$OPENROUTER_SH" --mode bogus --prompt "a cat" --output "$OUT"
  assert_status 1
  assert_output_contains "Error: --mode must be 'generate' or 'edit'"
}

@test "openrouter: edit mode without --input-image prints error" {
  export OPENROUTER_API_KEY="$DUMMY_OPENROUTER_KEY"
  run "$OPENROUTER_SH" --mode edit --prompt "make it blue" --output "$OUT"
  assert_status 1
  assert_output_contains "Error: --input-image is required for edit mode"
}

@test "openrouter: missing OPENROUTER_API_KEY prints error" {
  unset OPENROUTER_API_KEY 2>/dev/null || true
  run "$OPENROUTER_SH" --mode generate --prompt "a cat" --output "$OUT"
  assert_status 1
  assert_output_contains "Error: OPENROUTER_API_KEY environment variable is not set"
}

@test "openrouter: unknown flag prints error and usage" {
  run "$OPENROUTER_SH" --bogus-flag value
  assert_status 1
  assert_output_contains "Unknown option: --bogus-flag"
  assert_output_contains "Usage:"
}

@test "openrouter: default model is google/gemini-nano-banana-2.1" {
  export OPENROUTER_API_KEY="$DUMMY_OPENROUTER_KEY"
  # The script prints "Calling OpenRouter API (model: ...)" before the curl call
  run "$OPENROUTER_SH" --mode generate --prompt "a cat" --output "$OUT"
  assert_output_contains "Calling OpenRouter API (model: google/gemini-nano-banana-2.1, mode: generate)"
}

@test "openrouter: OPENROUTER_IMAGE_MODEL env var overrides default model" {
  export OPENROUTER_API_KEY="$DUMMY_OPENROUTER_KEY"
  export OPENROUTER_IMAGE_MODEL="custom/openrouter-model"
  run "$OPENROUTER_SH" --mode generate --prompt "a cat" --output "$OUT"
  assert_output_contains "model: custom/openrouter-model"
}

@test "openrouter: --model flag overrides default and env var" {
  export OPENROUTER_API_KEY="$DUMMY_OPENROUTER_KEY"
  export OPENROUTER_IMAGE_MODEL="custom/openrouter-model"
  run "$OPENROUTER_SH" --mode generate --prompt "a cat" --output "$OUT" --model "flag/model"
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
  printf '#!/bin/bash\n. "$OPENROUTER_MODEL_LIST_STUB"\ncat >/dev/null\ncat "$(dirname "$0")/response.txt"\n' > "$mock_dir/curl"
  chmod +x "$mock_dir/curl"
  PATH="$mock_dir:$PATH" run "$OPENROUTER_SH" --mode generate --prompt "a cat" --output "$OUT"
  rm -rf "$mock_dir" "$DISPLAY_PANE_DIR"
  assert_status 1
  assert_output_contains "OpenRouter provider error (502): upstream boom"
}

# answer_openrouter <body> <status> — the stub answers every request but the model list with these.
answer_openrouter() {
  printf '%s\n%s\n' "$1" "$2" > "$PROVIDER_API_STUB_DIR/answer"
  export DISPLAY_PANE_DIR="${BATS_TEST_TMPDIR}/pane"
  mkdir -p "$DISPLAY_PANE_DIR"
}

# openai/gpt-image-2 lists only image among its output modalities, and OpenRouter's chat endpoint
# answers it with HTTP 404, so it has to go to the images endpoint.
@test "openrouter: a model that outputs only images draws through the images endpoint" {
  export OPENROUTER_API_KEY="$DUMMY_OPENROUTER_KEY"
  answer_openrouter '{"created":1748372400,"data":[{"b64_json":"ZmFrZQ==","media_type":"image/png"}]}' 200
  run "$OPENROUTER_SH" --mode generate --prompt "a cat" --output "$OUT" --model openai/gpt-image-2
  assert_status 0
  [[ "$(cat "$PROVIDER_API_STUB_DIR/url")" == "https://openrouter.ai/api/v1/images" ]] || {
    echo "Expected one request, to the images endpoint, got:"; cat "$PROVIDER_API_STUB_DIR/url"; return 1; }
  [[ "$(jq -cS . "$PROVIDER_API_STUB_DIR/body")" == '{"model":"openai/gpt-image-2","prompt":"a cat","response_format":"b64_json"}' ]] || {
    echo "Unexpected body:"; cat "$PROVIDER_API_STUB_DIR/body"; return 1; }
  [[ "$(cat "$OUT")" == "fake" ]] || { echo "Expected the decoded image 'fake' in $OUT"; return 1; }
}

@test "openrouter: a model that also outputs text keeps the chat completions request" {
  export OPENROUTER_API_KEY="$DUMMY_OPENROUTER_KEY"
  answer_openrouter '{"choices":[{"message":{"images":[{"image_url":{"url":"data:image/png;base64,ZmFrZQ=="}}]}}]}' 200
  run "$OPENROUTER_SH" --mode generate --prompt "a cat" --output "$OUT"
  assert_status 0
  [[ "$(cat "$PROVIDER_API_STUB_DIR/url")" == "https://openrouter.ai/api/v1/chat/completions" ]] || {
    echo "Expected one request, to chat completions, got:"; cat "$PROVIDER_API_STUB_DIR/url"; return 1; }
  [[ "$(jq -cS . "$PROVIDER_API_STUB_DIR/body")" == '{"messages":[{"content":"a cat","role":"user"}],"modalities":["image","text"],"model":"google/gemini-nano-banana-2.1"}' ]] || {
    echo "Unexpected body:"; cat "$PROVIDER_API_STUB_DIR/body"; return 1; }
  [[ "$(cat "$OUT")" == "fake" ]] || { echo "Expected the decoded image 'fake' in $OUT"; return 1; }
}

@test "openrouter: an error from the images endpoint is reported with its status and message" {
  export OPENROUTER_API_KEY="$DUMMY_OPENROUTER_KEY"
  answer_openrouter '{"error":{"code":400,"message":"Invalid request parameters"}}' 400
  run "$OPENROUTER_SH" --mode generate --prompt "a cat" --output "$OUT" --model x-ai/grok-imagine-image-2.0
  assert_status 1
  assert_output_contains "OpenRouter API returned HTTP 400: Invalid request parameters"
  [[ "$(cat "$PROVIDER_API_STUB_DIR/url")" == "https://openrouter.ai/api/v1/images" ]] || {
    echo "Expected one request, to the images endpoint, got:"; cat "$PROVIDER_API_STUB_DIR/url"; return 1; }
  [[ ! -e "$OUT" ]] || { echo "A failed run left $OUT"; return 1; }
}

@test "openrouter: an edit with a model that outputs only images sends the input image as a reference" {
  export OPENROUTER_API_KEY="$DUMMY_OPENROUTER_KEY"
  local input="${BATS_TEST_TMPDIR}/photo.png"
  { printf '\211PNG\r\n\032\n'; printf 'bytes of the photo'; } > "$input"
  answer_openrouter '{"created":1748372400,"data":[{"b64_json":"ZmFrZQ=="}]}' 200
  run "$OPENROUTER_SH" --mode edit --prompt "make it blue" --input-image "$input" --output "$OUT" --model openai/gpt-image-2
  assert_status 0
  local body="$PROVIDER_API_STUB_DIR/body"
  [[ "$(jq -cS 'del(.input_references)' "$body")" == '{"model":"openai/gpt-image-2","prompt":"make it blue","response_format":"b64_json"}' ]] || {
    echo "Unexpected body fields:"; jq -c 'del(.input_references)' "$body"; return 1; }
  [[ "$(jq -c '[.input_references[] | {type, prefix: (.image_url.url | split(",")[0])}]' "$body")" == '[{"type":"image_url","prefix":"data:image/png;base64"}]' ]] || {
    echo "Expected one image_url reference holding a PNG data URL, got:"; jq -c '.input_references' "$body"; return 1; }
  jq -r '.input_references[0].image_url.url | split(",")[1]' "$body" | base64 --decode | cmp -s - "$input" || {
    echo "The reference does not hold the input image's bytes"; return 1; }
  [[ "$(cat "$OUT")" == "fake" ]] || { echo "Expected the decoded image 'fake' in $OUT"; return 1; }
}

@test "openrouter: a model list that cannot be read stops the run before any paid request" {
  export OPENROUTER_API_KEY="$DUMMY_OPENROUTER_KEY"
  export DISPLAY_PANE_DIR="${BATS_TEST_TMPDIR}/pane"
  mkdir -p "$DISPLAY_PANE_DIR"
  local mock_dir="${BATS_TEST_TMPDIR}/mocks"
  mkdir -p "$mock_dir"
  cat > "$mock_dir/curl" <<'STUB'
#!/bin/bash
for a in "$@"; do
  case "$a" in https://*) printf '%s\n' "$a" >> "$(dirname "$0")/url" ;; esac
done
printf '%s\n503\n' '{"error":{"code":503,"message":"Service Unavailable"}}'
STUB
  chmod +x "$mock_dir/curl"
  PATH="$mock_dir:$PATH" IMAGE_MAX_RETRIES=0 run "$OPENROUTER_SH" --mode generate --prompt "a cat" --output "$OUT" --model openai/gpt-image-2
  assert_status 1
  assert_output_contains "Could not read OpenRouter's image model list to choose an endpoint for openai/gpt-image-2: HTTP 503"
  [[ "$(cat "$mock_dir/url")" == "https://openrouter.ai/api/v1/models?output_modalities=image" ]] || {
    echo "Expected only the model list request, got:"; cat "$mock_dir/url"; return 1; }
}
