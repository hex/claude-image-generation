#!/usr/bin/env bats
# ABOUTME: Opens the single-image and multi-image panes on a private, detached tmux server and
# ABOUTME: checks each image path reaches the pane's drawing command byte for byte.

load test_helper

DISPLAY_SH="${PLUGIN_ROOT}/scripts/display.sh"
FIXTURE="${PLUGIN_ROOT}/tests/fixtures/oversized.png"
# The interpreter a stock macOS runs the plugin under, so these runs also guard bash 3.2.
SYSTEM_BASH="/bin/bash"

setup() {
  command -v tmux >/dev/null 2>&1 || skip "tmux is not installed"
  disable_display
  MOCK_DIR="${BATS_TEST_TMPDIR}/mocks"
  mkdir -p "$MOCK_DIR/.iterm2" "$MOCK_DIR/bin"
  # Every tmux call goes to a server of this test's own, never the one the suite runs in.
  SOCKET="bats-tmux-pane-$$-${BATS_TEST_NUMBER}"
  local real_tmux
  real_tmux=$(command -v tmux)
  printf '#!/bin/bash\nexec %q -L %q "$@"\n' "$real_tmux" "$SOCKET" > "$MOCK_DIR/bin/tmux"
  # The pane draws each image with this imgcat, which logs the path it was handed, one per line.
  printf '#!/bin/bash\nprintf "%%s\\n" "${@: -1}" >> %q\n' "$MOCK_DIR/shown.log" > "$MOCK_DIR/.iterm2/imgcat"
  chmod +x "$MOCK_DIR/bin/tmux" "$MOCK_DIR/.iterm2/imgcat"
  "$MOCK_DIR/bin/tmux" -f /dev/null new-session -d -x 200 -y 50
  SOCKET_PATH=$("$MOCK_DIR/bin/tmux" display-message -p '#{socket_path}')
  PANE=$("$MOCK_DIR/bin/tmux" display-message -p '#{pane_id}')
}

teardown() {
  # The pane's key loop never ends on its own, so the server goes whether the test passed or not,
  # and its socket file with it: kill-server leaves the file behind.
  [[ -n "${SOCKET:-}" ]] && tmux -L "$SOCKET" kill-server 2>/dev/null
  [[ -n "${SOCKET_PATH:-}" ]] && rm -f "$SOCKET_PATH"
  return 0
}

# image <name> — a copy of the fixture under that file name, its path printed.
image() {
  cp "$FIXTURE" "$MOCK_DIR/$1"
  printf '%s' "$MOCK_DIR/$1"
}

# open_pane <function> <path>... — runs a display function under /bin/bash inside the private
# server's first pane, as a provider script there would.
open_pane() {
  : > "$MOCK_DIR/shown.log"
  run env HOME="$MOCK_DIR" PATH="$MOCK_DIR/bin:$PATH" TMUX="${SOCKET_PATH},0,0" TMUX_PANE="$PANE" \
    LC_TERMINAL=iTerm2 "$SYSTEM_BASH" -c 'source "$1"; shift; "$@"' _ "$DISPLAY_SH" "$@"
}

# assert_shown <path>... — the pane drew exactly these paths, in this order, within five seconds.
assert_shown() {
  local want got i
  want=$(printf '%s\n' "$@")
  for i in $(seq 1 50); do
    got=$(cat "$MOCK_DIR/shown.log")
    [[ "$got" == "$want" ]] && return 0
    sleep 0.1
  done
  echo "the pane drew:"; cat "$MOCK_DIR/shown.log"
  echo "expected:"; printf '%s\n' "$@"
  echo "the display function said (status ${status}): ${output}"
  return 1
}

@test "the single-image pane draws a path ending in a semicolon, or a backslash and a semicolon, whole" {
  local path
  for path in "$(image 'picture.png;')" "$(image 'back\;')" "$(image ';')"; do
    open_pane display_image_in_pane "$path"
    [[ "$status" -eq 0 && -z "$output" ]] || { echo "status ${status}: ${output}"; return 1; }
    assert_shown "$path"
    "$MOCK_DIR/bin/tmux" kill-pane -a -t "$PANE"
  done
}

@test "the multi-image pane draws every path whole when one ends in a semicolon" {
  local odd plain
  odd=$(image 'picture.png;')
  plain=$(image 'plain.png')
  open_pane display_images_in_pane "$odd" "$plain"
  [[ "$status" -eq 0 && -z "$output" ]] || { echo "status ${status}: ${output}"; return 1; }
  assert_shown "$odd" "$plain"
}
