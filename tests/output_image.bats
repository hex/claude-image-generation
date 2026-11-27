#!/usr/bin/env bats
# ABOUTME: Runs every provider against an output path that is taken, or gets taken mid-request,
# ABOUTME: with a stubbed curl, and checks no earlier file is overwritten and no symlink followed.

load test_helper

PROVIDERS=(gemini openai xai openrouter)
# The interpreter a stock macOS runs the plugin under, so these runs also guard bash 3.2.
SYSTEM_BASH="/bin/bash"

setup() {
  MOCK_DIR="${BATS_TMPDIR}/output_image_$$"
  rm -rf "$MOCK_DIR"
  mkdir -p "$MOCK_DIR/out"
  # The image's folder holds nothing else, so a test can see every file a save left in it.
  OUT="${MOCK_DIR}/out/image.png"
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
# The timeout turns a save that blocks, on a FIFO say, into a failure instead of a hung suite.
run_provider() {
  GEMINI_API_KEY="$DUMMY_GEMINI_KEY" OPENAI_API_KEY="$DUMMY_OPENAI_KEY" \
    XAI_API_KEY="$DUMMY_XAI_KEY" OPENROUTER_API_KEY="$DUMMY_OPENROUTER_KEY" \
    run timeout 20 "$SYSTEM_BASH" "${PLUGIN_ROOT}/scripts/${1}.sh" --mode generate --prompt "a red circle" --output "$OUT"
}

# assert_save_refused <provider> <reason> — exit 1, with the save failure naming $OUT and the
# reason as the last line of output.
assert_save_refused() {
  local last="${lines[${#lines[@]}-1]}" expected="Could not save the image to ${OUT}: ${2}"
  [[ "$status" -eq 1 && "$last" == "$expected" ]] || {
    echo "$1: expected status 1 and '${expected}', got status ${status}: ${output}"; return 1; }
}

# assert_folder_holds <provider> <name>... — the image's folder holds exactly these entries.
assert_folder_holds() {
  local provider="$1" got want
  shift
  got=$(ls -A "$MOCK_DIR/out")
  want=$(printf '%s\n' "$@")
  [[ "$got" == "$want" ]] || {
    echo "$provider: the image's folder holds:"; ls -lA "$MOCK_DIR/out"; echo "expected: $*"; return 1; }
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
  local p
  for p in "${PROVIDERS[@]}"; do
    rm -rf "$MOCK_DIR/called" "$DISPLAY_PANE_DIR/errors" "$OUT"
    printf 'canary' > "$CANARY"
    stub_curl "$(body_with "$p" ZmFrZQ==)" "ln -s '${CANARY}' '${OUT}'"
    run_provider "$p"
    assert_save_refused "$p" "File exists"
    [[ "$(cat "$CANARY")" == "canary" ]] || { echo "$p: wrote through the link: $(cat "$CANARY")"; return 1; }
    [[ "$(readlink "$OUT")" == "$CANARY" ]] || { echo "$p: replaced the link"; return 1; }
    assert_folder_holds "$p" image.png
  done
}

@test "every provider refuses a symlink to a device or a FIFO that appears at the output path mid-request" {
  # Each would swallow the image or block the save forever if the write followed the link.
  local p target
  mkfifo "$MOCK_DIR/fifo"
  for target in /dev/null "$MOCK_DIR/fifo"; do
    for p in "${PROVIDERS[@]}"; do
      rm -rf "$MOCK_DIR/called" "$DISPLAY_PANE_DIR/errors" "$OUT"
      stub_curl "$(body_with "$p" ZmFrZQ==)" "ln -s '${target}' '${OUT}'"
      run_provider "$p"
      assert_save_refused "$p" "File exists"
      [[ "$(readlink "$OUT")" == "$target" ]] || { echo "$p: replaced the link to ${target}"; return 1; }
      assert_folder_holds "$p" image.png
    done
  done
}

@test "every provider refuses a directory that appears at the output path mid-request" {
  local p
  for p in "${PROVIDERS[@]}"; do
    rm -rf "$MOCK_DIR/called" "$DISPLAY_PANE_DIR/errors" "$OUT"
    stub_curl "$(body_with "$p" ZmFrZQ==)" "mkdir '${OUT}'"
    run_provider "$p"
    assert_save_refused "$p" "File exists"
    [[ -z "$(ls -A "$OUT")" ]] || { echo "$p: saved into the directory:"; ls -lA "$OUT"; return 1; }
  done
}

@test "every provider leaves no file behind when the image data does not decode" {
  local p
  for p in "${PROVIDERS[@]}"; do
    rm -rf "$MOCK_DIR/called" "$DISPLAY_PANE_DIR/errors" "$OUT"
    stub_curl "$(body_with "$p" '!!!not base64***')"
    run_provider "$p"
    assert_save_refused "$p" "error decoding base64 input stream"
    assert_folder_holds "$p"
  done
}

@test "a decode that fails leaves alone a file another process put at the output path meanwhile" {
  # This base64 plays the other process: while it decodes, a file of someone else's takes the
  # path, the way a second run saving to the same name would, and then the decode fails.
  mkdir -p "$MOCK_DIR/decode-bin"
  cat > "$MOCK_DIR/decode-bin/base64" <<STUB
#!/bin/bash
case " \$* " in *" -D "*|*" -d "*) ;; *) exec /usr/bin/base64 "\$@" ;; esac
cat > /dev/null
[ -e '${OUT}' ] && mv '${OUT}' '${MOCK_DIR}/moved-away'
printf 'SOMEONE ELSE' > '${OUT}'
echo "base64: invalid input" >&2
exit 1
STUB
  chmod +x "$MOCK_DIR/decode-bin/base64"
  local p
  for p in "${PROVIDERS[@]}"; do
    rm -rf "$MOCK_DIR/called" "$DISPLAY_PANE_DIR/errors" "$OUT" "$MOCK_DIR/moved-away"
    stub_curl "$(body_with "$p" ZmFrZQ==)"
    PATH="$MOCK_DIR/decode-bin:$PATH" run_provider "$p"
    assert_save_refused "$p" "invalid input"
    [[ "$(cat "$OUT" 2>/dev/null)" == "SOMEONE ELSE" ]] || { echo "$p: removed the other process's file"; return 1; }
    assert_folder_holds "$p" image.png
  done
}

@test "every provider saves its image with the mode a new file gets under the umask, and nothing else" {
  local p mode saved_umask
  saved_umask=$(umask)
  for p in "${PROVIDERS[@]}"; do
    rm -rf "$MOCK_DIR/called" "$DISPLAY_PANE_DIR/errors" "$OUT"
    stub_curl "$(body_with "$p" ZmFrZQ==)"
    # 027 rather than the usual 022, so a mode that only happens to be 644 cannot pass.
    umask 027
    run_provider "$p"
    umask "$saved_umask"
    [[ "$status" -eq 0 && "$(cat "$OUT")" == "fake" ]] || {
      echo "$p: expected the image saved, got status ${status}: ${output}"; return 1; }
    mode=$(stat -c %a "$OUT" 2>/dev/null || stat -f %Lp "$OUT")
    [[ "$mode" == 640 ]] || { echo "$p: saved with mode ${mode}, expected 640 under umask 027"; return 1; }
    assert_folder_holds "$p" image.png
  done
}
