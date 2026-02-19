# ABOUTME: Bats tests for display.sh iTerm2 inline image display utility.
# ABOUTME: Tests terminal detection and escape sequence generation.

setup() {
  load test_helper
  DISPLAY_SH="${PLUGIN_ROOT}/scripts/display.sh"
  # Clear iTerm2 env vars by default
  unset TERM_PROGRAM 2>/dev/null || true
  unset LC_TERMINAL 2>/dev/null || true
  unset ITERM_SESSION_ID 2>/dev/null || true
  # Redirect display output to a temp file for inspection
  DISPLAY_OUTPUT="${BATS_TMPDIR}/display_output_$$"
  export DISPLAY_IMAGE_TARGET="$DISPLAY_OUTPUT"
}

teardown() {
  rm -f "$DISPLAY_OUTPUT" 2>/dev/null || true
}

# --- is_iterm2 detection ---

@test "display: is_iterm2 returns true when TERM_PROGRAM=iTerm.app" {
  source "$DISPLAY_SH"
  export TERM_PROGRAM="iTerm.app"
  run is_iterm2
  assert_status 0
}

@test "display: is_iterm2 returns true when LC_TERMINAL=iTerm2" {
  source "$DISPLAY_SH"
  export LC_TERMINAL="iTerm2"
  run is_iterm2
  assert_status 0
}

@test "display: is_iterm2 returns false when neither var is set" {
  source "$DISPLAY_SH"
  unset TERM_PROGRAM 2>/dev/null || true
  unset LC_TERMINAL 2>/dev/null || true
  run is_iterm2
  assert_status 1
}

@test "display: is_iterm2 returns false for other terminals" {
  source "$DISPLAY_SH"
  export TERM_PROGRAM="Apple_Terminal"
  run is_iterm2
  assert_status 1
}

# --- display_image function ---

@test "display: display_image is a no-op when not in iTerm2" {
  source "$DISPLAY_SH"
  unset TERM_PROGRAM 2>/dev/null || true
  unset LC_TERMINAL 2>/dev/null || true

  local test_img="${BATS_TMPDIR}/test_img_$$.png"
  printf 'fake-png-data' > "$test_img"

  display_image "$test_img"

  # Output target file should not exist (nothing written)
  [[ ! -f "$DISPLAY_OUTPUT" ]]
}

@test "display: display_image writes escape sequence in iTerm2" {
  source "$DISPLAY_SH"
  export TERM_PROGRAM="iTerm.app"

  local test_img="${BATS_TMPDIR}/test_img_$$.png"
  printf 'fake-png-data' > "$test_img"

  display_image "$test_img"

  # Verify escape sequence was written
  [[ -f "$DISPLAY_OUTPUT" ]]
  local content
  content=$(cat "$DISPLAY_OUTPUT")
  # Should contain the iTerm2 protocol marker
  assert_output_contains_file "$DISPLAY_OUTPUT" "1337;File="
}

@test "display: display_image includes inline=1 parameter" {
  source "$DISPLAY_SH"
  export TERM_PROGRAM="iTerm.app"

  local test_img="${BATS_TMPDIR}/test_img_$$.png"
  printf 'test-data' > "$test_img"

  display_image "$test_img"

  assert_output_contains_file "$DISPLAY_OUTPUT" "inline=1"
}

@test "display: display_image includes base64-encoded filename" {
  source "$DISPLAY_SH"
  export TERM_PROGRAM="iTerm.app"

  local test_img="${BATS_TMPDIR}/myimage.png"
  printf 'test-data' > "$test_img"

  display_image "$test_img"

  # "myimage.png" in base64 is "bXlpbWFnZS5wbmc="
  local expected_name
  expected_name=$(printf 'myimage.png' | base64 | tr -d '\n')
  assert_output_contains_file "$DISPLAY_OUTPUT" "name=${expected_name}"
}

@test "display: display_image includes file size" {
  source "$DISPLAY_SH"
  export TERM_PROGRAM="iTerm.app"

  local test_img="${BATS_TMPDIR}/test_size_$$.png"
  printf '0123456789' > "$test_img"

  display_image "$test_img"

  assert_output_contains_file "$DISPLAY_OUTPUT" "size=10"
}

@test "display: display_image silently skips nonexistent file" {
  source "$DISPLAY_SH"
  export TERM_PROGRAM="iTerm.app"

  run display_image "/tmp/no_such_file_$$_$RANDOM.png"
  assert_status 0
  [[ ! -f "$DISPLAY_OUTPUT" ]]
}

@test "display: display_image works with LC_TERMINAL detection" {
  source "$DISPLAY_SH"
  export LC_TERMINAL="iTerm2"

  local test_img="${BATS_TMPDIR}/test_lc_$$.png"
  printf 'test-data' > "$test_img"

  display_image "$test_img"

  [[ -f "$DISPLAY_OUTPUT" ]]
  assert_output_contains_file "$DISPLAY_OUTPUT" "1337;File="
}
