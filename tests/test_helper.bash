# ABOUTME: Shared test setup for bats tests of image-generation plugin scripts.
# ABOUTME: Provides PLUGIN_ROOT, dummy API keys, and common assertion helpers.

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Dummy API keys for tests that need them (no real calls are made)
export DUMMY_GEMINI_KEY="test-gemini-key-not-real"
export DUMMY_OPENAI_KEY="test-openai-key-not-real"
export DUMMY_XAI_KEY="test-xai-key-not-real"

# Assert that output contains a substring
# Usage: assert_output_contains "expected substring"
assert_output_contains() {
  local expected="$1"
  if [[ "$output" != *"$expected"* ]]; then
    echo "Expected output to contain: $expected"
    echo "Actual output: $output"
    return 1
  fi
}

# Assert that output does NOT contain a substring
# Usage: assert_output_not_contains "unexpected substring"
assert_output_not_contains() {
  local unexpected="$1"
  if [[ "$output" == *"$unexpected"* ]]; then
    echo "Expected output to NOT contain: $unexpected"
    echo "Actual output: $output"
    return 1
  fi
}

# Prevent the display machinery from splitting a real tmux pane during tests. Unsetting TMUX
# makes is_tmux() false, so display_pane_open (run-all.sh) and display_image's tmux path (the
# provider_finish fallback) both no-op instead of running `tmux split-window`. Tests that run a
# provider script to completion should ALSO set DISPLAY_PANE_DIR to a scratch dir so
# provider_finish skips display_image entirely rather than falling back to inline rendering.
# Usage: disable_display
disable_display() {
  unset TMUX TMUX_PANE
}

# Assert exit status equals expected value
# Usage: assert_status 1
assert_status() {
  local expected="$1"
  if [[ "$status" -ne "$expected" ]]; then
    echo "Expected exit status: $expected"
    echo "Actual exit status: $status"
    return 1
  fi
}

# Assert a file contains a substring
# Usage: assert_output_contains_file "/path/to/file" "expected substring"
assert_output_contains_file() {
  local file="$1"
  local expected="$2"
  local content
  content=$(cat "$file")
  if [[ "$content" != *"$expected"* ]]; then
    echo "Expected file to contain: $expected"
    echo "Actual content: $content"
    return 1
  fi
}

# Assert output is valid JSON
# Usage: assert_valid_json
assert_valid_json() {
  if ! echo "$output" | jq . >/dev/null 2>&1; then
    echo "Expected valid JSON output"
    echo "Actual output: $output"
    return 1
  fi
}

# Assert that a captured string contains a substring. Companion to assert_output_contains for
# transcripts captured into a local variable rather than bats' $output.
# Usage: assert_output_contains_str "$captured" "expected substring"
assert_output_contains_str() {
  local output="$1"
  assert_output_contains "$2"
}

# Assert that a captured string does NOT contain a substring.
# Usage: assert_output_not_contains_str "$captured" "unexpected substring"
assert_output_not_contains_str() {
  local output="$1"
  assert_output_not_contains "$2"
}

# Points TMPDIR at a per-test scratch directory. display_pane_open builds its watch dir with
# mktemp under TMPDIR, so without this a suite that opens panes accumulates watch dirs in the
# developer's real temp directory. Pair with cleanup_tmpdir in teardown. Usage: isolate_tmpdir
isolate_tmpdir() {
  ISOLATED_TMPDIR="${BATS_TMPDIR}/isolated_tmp_$$_${BATS_TEST_NUMBER:-0}"
  mkdir -p "$ISOLATED_TMPDIR"
  export TMPDIR="$ISOLATED_TMPDIR"
}

# Removes the scratch directory isolate_tmpdir created. Usage: cleanup_tmpdir
cleanup_tmpdir() {
  [[ -n "${ISOLATED_TMPDIR:-}" ]] && rm -rf "$ISOLATED_TMPDIR"
  return 0
}
