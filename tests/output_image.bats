#!/usr/bin/env bats
# ABOUTME: Runs every provider against an output path that is taken, or gets taken mid-request,
# ABOUTME: with a stubbed curl, and checks no earlier file is overwritten and no symlink followed.

load test_helper

PROVIDERS=(gemini openai xai openrouter)

setup() {
  MOCK_DIR="${BATS_TMPDIR}/output_image_$$"
  rm -rf "$MOCK_DIR"
  mkdir -p "$MOCK_DIR"
  OUT="${MOCK_DIR}/image.png"
  CANARY="${MOCK_DIR}/canary.txt"
  disable_display
  export DISPLAY_PANE_DIR="${MOCK_DIR}/pane"
  mkdir -p "$DISPLAY_PANE_DIR"
}

teardown() {
  rm -rf "$MOCK_DIR" 2>/dev/null || true
}

# body_with <provider> <base64> — a 200 body in the provider's response shape carrying the data.
body_with() {
  case "$1" in
    gemini)     printf '{"candidates":[{"content":{"parts":[{"inlineData":{"mimeType":"image/png","data":"%s"}}]}}]}' "$2" ;;
    openai|xai) printf '{"data":[{"b64_json":"%s"}]}' "$2" ;;
    openrouter) printf '{"choices":[{"message":{"images":[{"image_url":{"url":"data:image/png;base64,%s"}}]}}]}' "$2" ;;
  esac
}

# stub_curl <body> [shell command] — a curl that leaves $MOCK_DIR/called, runs the command
# while the request is in flight, then answers 200 with the body.
stub_curl() {
  printf '%s\n200\n' "$1" > "$MOCK_DIR/response.txt"
  printf '%s\n' "${2:-}" > "$MOCK_DIR/during-request.sh"
  cat > "$MOCK_DIR/curl" <<'STUB'
#!/bin/bash
d="$(dirname "$0")"
touch "${d}/called"
bash "${d}/during-request.sh"
cat "${d}/response.txt"
STUB
  chmod +x "$MOCK_DIR/curl"
  export PATH="$MOCK_DIR:$PATH"
}

# run_provider <provider> — one provider's generate mode into $OUT, with every dummy key set.
run_provider() {
  GEMINI_API_KEY="$DUMMY_GEMINI_KEY" OPENAI_API_KEY="$DUMMY_OPENAI_KEY" \
    XAI_API_KEY="$DUMMY_XAI_KEY" OPENROUTER_API_KEY="$DUMMY_OPENROUTER_KEY" \
    run bash "${PLUGIN_ROOT}/scripts/${1}.sh" --mode generate --prompt "a red circle" --output "$OUT"
}

# assert_refused_up_front <provider> — exit 1 with the refusal naming $OUT, shown in the pane
# too, and the API never called.
assert_refused_up_front() {
  local expected="Error: --output already exists, refusing to overwrite it: ${OUT}"
  [[ "$status" -eq 1 && "$output" == "$expected" ]] || {
    echo "$1: expected status 1 and '${expected}', got status ${status}: ${output}"; return 1; }
  [[ "$(cat "$DISPLAY_PANE_DIR/errors/${1}.txt" 2>/dev/null)" == "$expected" ]] || {
    echo "$1: the pane shows: $(cat "$DISPLAY_PANE_DIR/errors/${1}.txt" 2>/dev/null)"; return 1; }
  [[ ! -e "$MOCK_DIR/called" ]] || { echo "$1: called curl"; return 1; }
}

@test "every provider refuses an output file that already exists, before calling the API" {
  local p
  for p in "${PROVIDERS[@]}"; do
    rm -rf "$MOCK_DIR/called" "$DISPLAY_PANE_DIR/errors"
    printf 'OLD IMAGE' > "$OUT"
    stub_curl "$(body_with "$p" ZmFrZQ==)"
    run_provider "$p"
    assert_refused_up_front "$p"
    [[ "$(cat "$OUT")" == "OLD IMAGE" ]] || { echo "$p: overwrote the file: $(cat "$OUT")"; return 1; }
  done
}

@test "every provider refuses a symlink at the output path and leaves what it points at alone" {
  local p
  for p in "${PROVIDERS[@]}"; do
    rm -rf "$MOCK_DIR/called" "$DISPLAY_PANE_DIR/errors" "$OUT"
    printf 'canary' > "$CANARY"
    ln -s "$CANARY" "$OUT"
    stub_curl "$(body_with "$p" ZmFrZQ==)"
    run_provider "$p"
    assert_refused_up_front "$p"
    [[ "$(cat "$CANARY")" == "canary" ]] || { echo "$p: wrote through the link: $(cat "$CANARY")"; return 1; }
  done
}

@test "every provider refuses a dangling symlink at the output path and creates nothing at its target" {
  local p
  for p in "${PROVIDERS[@]}"; do
    rm -rf "$MOCK_DIR/called" "$DISPLAY_PANE_DIR/errors" "$OUT" "$CANARY"
    ln -s "$CANARY" "$OUT"
    stub_curl "$(body_with "$p" ZmFrZQ==)"
    run_provider "$p"
    assert_refused_up_front "$p"
    [[ ! -e "$CANARY" ]] || { echo "$p: created the link's target: $(cat "$CANARY")"; return 1; }
  done
}

@test "every provider refuses to write through a symlink that appears at the output path mid-request" {
  local p last
  for p in "${PROVIDERS[@]}"; do
    rm -rf "$MOCK_DIR/called" "$DISPLAY_PANE_DIR/errors" "$OUT"
    printf 'canary' > "$CANARY"
    stub_curl "$(body_with "$p" ZmFrZQ==)" "ln -s '${CANARY}' '${OUT}'"
    run_provider "$p"
    last="${lines[${#lines[@]}-1]}"
    [[ "$status" -eq 1 && "$last" == "Could not save the image to ${OUT}: cannot overwrite existing file" ]] || {
      echo "$p: expected status 1 and the save refusal, got status ${status}: ${output}"; return 1; }
    [[ "$(cat "$CANARY")" == "canary" ]] || { echo "$p: wrote through the link: $(cat "$CANARY")"; return 1; }
    [[ "$(readlink "$OUT")" == "$CANARY" ]] || { echo "$p: replaced the link"; return 1; }
  done
}

@test "every provider leaves no file behind when the image data does not decode" {
  local p last
  for p in "${PROVIDERS[@]}"; do
    rm -rf "$MOCK_DIR/called" "$DISPLAY_PANE_DIR/errors" "$OUT"
    stub_curl "$(body_with "$p" '!!!not base64***')"
    run_provider "$p"
    last="${lines[${#lines[@]}-1]}"
    [[ "$status" -eq 1 && "$last" == "Could not save the image to ${OUT}: error decoding base64 input stream" ]] || {
      echo "$p: expected status 1 and the decode failure, got status ${status}: ${output}"; return 1; }
    [[ ! -e "$OUT" && ! -L "$OUT" ]] || { echo "$p: left a file at the output path"; ls -la "$OUT"; return 1; }
  done
}
