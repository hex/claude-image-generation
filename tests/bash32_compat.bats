#!/usr/bin/env bats
# ABOUTME: Verifies the parallel-run scripts work on the bash that ships with macOS (3.2).
# ABOUTME: The plugin declares #!/usr/bin/env bash, so a stock Mac runs these under /bin/bash.

load test_helper

DISPLAY_SH="${PLUGIN_ROOT}/scripts/display.sh"
# The interpreter a stock macOS actually uses when PATH has no newer bash.
SYSTEM_BASH="/bin/bash"

# A mock tmux + imgcat on PATH so display_pane_open can build a pane without a real terminal.
setup() {
  MOCK_DIR="${BATS_TMPDIR}/bash32_mocks_$$"
  mkdir -p "$MOCK_DIR"
  printf '#!/bin/bash\necho "%%99"\n' > "$MOCK_DIR/tmux"
  printf '#!/bin/bash\nexit 0\n' > "$MOCK_DIR/imgcat"
  chmod +x "$MOCK_DIR/tmux" "$MOCK_DIR/imgcat"
}

teardown() {
  rm -rf "$MOCK_DIR" 2>/dev/null || true
}

@test "bash32: scripts use no bash-4-only constructs" {
  # These fail at runtime on bash 3.2: ${var^^} is a bad substitution, `declare -A`
  # is an invalid option, and mapfile/readarray do not exist. None of them survive
  # `bash -n`, so a static scan is the only reliable guard. Comment lines are excluded
  # so a comment that names a construct while explaining why it is avoided does not trip.
  local hits
  hits=$(rg -n '\$\{[A-Za-z_][A-Za-z0-9_]*\^\^|declare[[:space:]]+-A\b|\bmapfile\b|\breadarray\b' \
    "${PLUGIN_ROOT}/scripts" | grep -vE ':[0-9]+:[[:space:]]*#' || true)
  if [[ -n "$hits" ]]; then
    echo "Found bash-4-only constructs that break on macOS /bin/bash 3.2:"
    echo "$hits"
    return 1
  fi
}

@test "bash32: generated watcher runs clean under system bash" {
  source "$DISPLAY_SH"
  export TMUX="fake,1,0"
  export TMUX_PANE="%0"
  export LC_TERMINAL="iTerm2"
  export PATH="$MOCK_DIR:$PATH"

  local watch_dir
  watch_dir=$(display_pane_open)
  [[ -f "$watch_dir/watcher.sh" ]]

  # A completed status row whose image path does not exist, so the render step is
  # skipped, plus the .done sentinel so the poll loop exits on the first pass.
  printf 'gemini\tcomplete\t1500\tgemini-3-pro-image-preview\t%s/nope.png\n' "$watch_dir" \
    > "$watch_dir/status"
  touch "$watch_dir/.done"

  run "$SYSTEM_BASH" "$watch_dir/watcher.sh" "$watch_dir"

  for marker in "declare: -A" "bad substitution" "mapfile" "readarray" "unbound variable"; do
    if [[ "$output" == *"$marker"* ]]; then
      echo "Watcher emitted a bash-4 failure under ${SYSTEM_BASH}: '$marker'"
      echo "$output"
      return 1
    fi
  done
  [[ "$status" -eq 0 ]] || {
    echo "Watcher exited $status under ${SYSTEM_BASH}"
    echo "$output"
    return 1
  }
}

@test "bash32: display_pane_open tolerates an empty pane target under set -u" {
  # is_tmux() only checks TMUX, so TMUX set with TMUX_PANE unset leaves target_args
  # empty. Under `set -u` on bash 3.2, expanding an empty array is an unbound-variable
  # error -- and the provider scripts all run `set -euo pipefail`.
  run env "PATH=$MOCK_DIR:$PATH" TMUX="fake,1,0" LC_TERMINAL="iTerm2" \
    "$SYSTEM_BASH" -u -c '
      unset TMUX_PANE
      source "$1"
      display_pane_open >/dev/null
    ' _ "$DISPLAY_SH"

  if [[ "$output" == *"unbound variable"* ]]; then
    echo "display_pane_open hit an unbound variable under ${SYSTEM_BASH} -u:"
    echo "$output"
    return 1
  fi
  [[ "$status" -eq 0 ]] || {
    echo "display_pane_open exited $status under ${SYSTEM_BASH} -u"
    echo "$output"
    return 1
  }
}
