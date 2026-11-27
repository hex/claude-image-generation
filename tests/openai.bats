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

# Puts a curl first on PATH that keeps the JSON body openai.sh sends with -d in $MOCK_DIR/body and
# answers HTTP 401, as the API answers the dummy key.
capture_request_body() {
  MOCK_DIR="${BATS_TEST_TMPDIR}/curl_mock"
  mkdir -p "$MOCK_DIR"
  cat > "$MOCK_DIR/curl" <<'EOF'
#!/bin/bash
while [[ $# -gt 0 ]]; do
  [[ "$1" == -d ]] && printf '%s' "$2" > "$(dirname "$0")/body"
  shift
done
printf '{}\n401\n'
EOF
  chmod +x "$MOCK_DIR/curl"
  export PATH="$MOCK_DIR:$PATH"
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

@test "openai: an aspect ratio and a size tier become the request's size" {
  export OPENAI_API_KEY="$DUMMY_OPENAI_KEY"
  capture_request_body
  run "$OPENAI_SH" --mode generate --prompt "a cat" --output "$OUT" --aspect-ratio 16:9 --size-tier 2K
  [[ "$(jq -r '.size' "$MOCK_DIR/body")" == 2736x1536 ]] || { echo "$output"; return 1; }
}

@test "openai: every size in the ratio table is one OpenAI accepts, at its ratio, growing with the tier" {
  source "${PLUGIN_ROOT}/scripts/aspect-ratios.sh"
  # Sizes OpenAI's guide names: 1024x1024, 2048x2048 (2K square), 3840x2160 (4K landscape) and
  # 2160x3840 (4K portrait).
  [[ "$(openai_size 1:1 1K) $(openai_size 1:1 2K) $(openai_size 16:9 4K) $(openai_size 9:16 4K)" == \
    "1024x1024 2048x2048 3840x2160 2160x3840" ]]
  [[ "$(openai_size 16:9 1K) $(openai_size 16:9 2K) $(openai_size 21:9 4K)" == "1360x768 2736x1536 3840x1648" ]]
  local ratio tier size w h previous
  for ratio in $(openai_aspect_ratios); do
    previous=0
    for tier in 1K 2K 4K; do
      size=$(openai_size "$ratio" "$tier")
      w=${size%x*}
      h=${size#*x}
      # Both edges multiples of 16 and at most 3840, long edge at most 3x the short one, 655,360
      # to 8,294,400 pixels, within 1% of the ratio, and more pixels than the tier below.
      awk -v w="$w" -v h="$h" -v r="$ratio" -v prev="$previous" 'BEGIN {
        split(r, p, ":"); want = p[1] / p[2]; long = (w > h) ? w : h; short = (w > h) ? h : w
        ok = w % 16 == 0 && h % 16 == 0 && long <= 3840 && long <= 3 * short &&
             w * h >= 655360 && w * h <= 8294400 && (w / h) / want > 0.99 && (w / h) / want < 1.01 &&
             w * h > prev
        exit !ok }' || { echo "$ratio at $tier is $size"; return 1; }
      previous=$((w * h))
    done
  done
  # The ratios past 3:1 that Gemini draws are not in it.
  [[ " $(openai_aspect_ratios) " != *" 4:1 "* && -z "$(openai_size 4:1 1K)" ]]
}

@test "openai: a ratio past 3:1 is refused before any request, naming the ratios it draws" {
  export OPENAI_API_KEY="$DUMMY_OPENAI_KEY"
  capture_request_body
  run "$OPENAI_SH" --mode generate --prompt "a cat" --output "$OUT" --aspect-ratio 4:1
  assert_status 1
  [[ "$output" == "Error: gpt-image-2.6-sunburst does not take aspect ratio 4:1; it takes 1:1, 2:3, 3:2, 3:4, 4:3, 4:5, 5:4, 9:16, 16:9, 21:9, 2:1, 1:2, 19.5:9, 9:19.5, 20:9, 9:20, 5:2" ]] || { echo "$output"; return 1; }
  [[ ! -e "$MOCK_DIR/body" ]]
}

@test "openai: --size given beside a ratio and tier wins" {
  export OPENAI_API_KEY="$DUMMY_OPENAI_KEY"
  capture_request_body
  run "$OPENAI_SH" --mode generate --prompt "a cat" --output "$OUT" --size 1536x1024 --aspect-ratio 16:9 --size-tier 2K
  [[ "$(jq -r '.size' "$MOCK_DIR/body")" == 1536x1024 ]] || { echo "$output"; return 1; }
}

@test "openai: a ratio or tier on a model that takes only three sizes is refused before any request" {
  export OPENAI_API_KEY="$DUMMY_OPENAI_KEY"
  capture_request_body
  run "$OPENAI_SH" --mode generate --prompt "a cat" --output "$OUT" --size-tier 2K --model gpt-image-1.5
  assert_status 1
  [[ "$output" == "Error: gpt-image-1.5 draws only 1024x1024, 1536x1024 or 1024x1536, so it takes no aspect ratio or size tier; pass --size, or a gpt-image-2 model" ]] || { echo "$output"; return 1; }
  [[ ! -e "$MOCK_DIR/body" ]]
}

@test "openai: with no ratio or size tier the request asks for 1024x1024" {
  export OPENAI_API_KEY="$DUMMY_OPENAI_KEY"
  capture_request_body
  run "$OPENAI_SH" --mode generate --prompt "a cat" --output "$OUT"
  [[ "$(jq -r '.size' "$MOCK_DIR/body")" == 1024x1024 ]] || { echo "$output"; return 1; }
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
