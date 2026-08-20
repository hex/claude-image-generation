#!/usr/bin/env bats
# ABOUTME: Tests that concurrently-running providers share one streaming tmux pane.
# ABOUTME: Each provider process discovers the batch's pane through a registry instead of splitting its own.

load test_helper

DISPLAY_SH="${PLUGIN_ROOT}/scripts/display.sh"

# A tmux stub that logs every subcommand and answers display-message per format string, plus an
# imgcat stub so the iTerm2 render path resolves. TMPDIR points at a per-test directory so the
# pane registry -- which lives under TMPDIR, as the watch dirs already do -- cannot leak between
# tests or onto the developer's real tmux session.
setup() {
  MOCK_DIR="${BATS_TMPDIR}/shared_pane_$$"
  mkdir -p "$MOCK_DIR/bin" "$MOCK_DIR/tmp"
  export TMUX_STUB_LOG="$MOCK_DIR/tmux.log"
  : > "$TMUX_STUB_LOG"

  cat > "$MOCK_DIR/bin/tmux" <<'STUB'
#!/bin/bash
printf '%s\n' "$1" >> "$TMUX_STUB_LOG"
if [ "$1" = "display-message" ]; then
  case "${@: -1}" in
    *pane_width*) echo "200 50" ;;
    *) echo '$5-@3' ;;
  esac
fi
exit 0
STUB
  printf '#!/bin/bash\nexit 0\n' > "$MOCK_DIR/bin/imgcat"
  chmod +x "$MOCK_DIR/bin/tmux" "$MOCK_DIR/bin/imgcat"
}

teardown() {
  rm -rf "$MOCK_DIR" 2>/dev/null || true
}

# Runs a snippet in a fresh process that believes it is inside tmux under iTerm2.
pane_proc() {
  env "PATH=$MOCK_DIR/bin:$PATH" "TMPDIR=$MOCK_DIR/tmp" "TMUX_STUB_LOG=$TMUX_STUB_LOG" \
    TMUX="fake,1,0" TMUX_PANE="%0" LC_TERMINAL="iTerm2" TERM_PROGRAM="iTerm.app" \
    bash -c "source '$DISPLAY_SH'; $1"
}

# Counts how many times the tmux stub was asked to split a new pane.
split_count() {
  grep -c '^split-window$' "$TMUX_STUB_LOG" 2>/dev/null || true
}

@test "a second caller attaches to the first caller's pane instead of splitting its own" {
  # The whole point of the refactor: N providers, one pane. Two separate processes -- not two
  # calls in one shell -- because that is what parallel providers are, and only a filesystem
  # registry can coordinate them. Expected split count is 1 by that spec, not by re-running
  # the code: one pane for the batch, however many providers join it.
  local first second
  first=$(pane_proc 'display_pane_attach_or_open')
  second=$(pane_proc 'display_pane_attach_or_open')

  [[ -n "$first" ]] || { echo "first caller printed no watch dir"; return 1; }
  [[ "$second" == "$first" ]] || {
    echo "second caller got a different pane"
    echo "  first:  '$first'"
    echo "  second: '$second'"
    return 1
  }

  local splits
  splits=$(split_count)
  [[ "$splits" -eq 1 ]] || {
    echo "Expected exactly 1 tmux split-window across both callers, got: $splits"
    cat "$TMUX_STUB_LOG"
    return 1
  }
}

# Prints the watch directory the batch's registry entry points at.
registered_dir() {
  cat "$MOCK_DIR"/tmp/display_pane_registry.*/dir 2>/dev/null
}

@test "display_pane_begin joins the shared pane and registers the provider as active" {
  # Providers call display_pane_begin unconditionally and never set DISPLAY_PANE_DIR themselves,
  # so discovery has to happen here for a directly-launched provider to reach the shared pane.
  # The active token is what lets the last provider out close the pane; without it nobody knows
  # whether more images are still coming.
  pane_proc 'display_pane_begin gemini gemini-3-pro-image-preview'

  local splits
  splits=$(split_count)
  [[ "$splits" -eq 1 ]] || {
    echo "Expected display_pane_begin to open the shared pane once, got $splits splits"
    return 1
  }

  local dir
  dir=$(registered_dir)
  [[ -n "$dir" && -d "$dir" ]] || { echo "no watch dir registered by display_pane_begin"; return 1; }

  local tokens
  tokens=$(ls "$dir/active" 2>/dev/null | grep -c '^gemini\.' || true)
  [[ "$tokens" -eq 1 ]] || {
    echo "Expected 1 active token for gemini, got: $tokens"
    ls -la "$dir/active" 2>&1
    return 1
  }

  # Discovery must not cost the querying banner the pane already knew how to draw.
  assert_output_contains_file "$dir/status" "gemini"$'\t'"querying"
}

@test "the pane closes only once the last active provider has finished" {
  # Two providers share the pane; the first to finish must leave it open or the second's image
  # lands on a pane already in its dismiss prompt. Only the last one out writes .done. Both
  # begin/finish pairs run in one process because a token is keyed to the process that took it.
  local out
  out=$(pane_proc '
    display_pane_begin gemini gemini-3-pro-image-preview
    display_pane_begin openai gpt-image-2
    display_pane_finish gemini gemini-3-pro-image-preview /nope/a.png
    [[ -f "$DISPLAY_PANE_DIR/.done" ]] && echo "CLOSED_EARLY"
    display_pane_finish openai gpt-image-2 /nope/b.png
    [[ -f "$DISPLAY_PANE_DIR/.done" ]] && echo "CLOSED_AFTER_LAST"
    echo "REG=$(cat "$DISPLAY_PANE_DIR/registry" 2>/dev/null)"
  ')

  assert_output_not_contains_str "$out" "CLOSED_EARLY"
  assert_output_contains_str "$out" "CLOSED_AFTER_LAST"

  # The entry has to go with the pane, or the next batch attaches to a pane already dismissed.
  local reg
  reg=$(printf '%s\n' "$out" | sed -n 's/^REG=//p')
  [[ -n "$reg" ]] || { echo "finish left no registry pointer behind"; echo "$out"; return 1; }
  [[ ! -d "$reg" ]] || { echo "registry entry '$reg' survived the last finish"; return 1; }
}

@test "a registry entry whose pane is gone yields a fresh pane" {
  # The watcher removes its watch dir on exit, so an entry can outlive the pane it names. Left
  # unchecked, the next batch attaches to a directory nothing is watching and every image is
  # written into the void. Expected split count is 2 by that rule: one dead pane, one live batch.
  local first second
  first=$(pane_proc 'display_pane_attach_or_open')
  rm -rf "$first"

  second=$(pane_proc 'display_pane_attach_or_open')
  [[ -n "$second" && -d "$second" ]] || { echo "no live pane opened, got '$second'"; return 1; }
  [[ "$second" != "$first" ]] || { echo "attached to the vanished pane '$first'"; return 1; }

  local splits
  splits=$(split_count)
  [[ "$splits" -eq 2 ]] || {
    echo "Expected 2 splits (dead pane, then a fresh one), got: $splits"
    cat "$TMUX_STUB_LOG"
    return 1
  }
}

@test "a pane already dismissed is not reused by the next batch" {
  # Closing a pane writes .done and leaves the watch dir in place for the dismiss prompt. The
  # directory still exists, so an existence check alone would hand the next batch a pane that
  # has stopped polling for images.
  local first second
  first=$(pane_proc 'display_pane_attach_or_open')
  touch "$first/.done"

  second=$(pane_proc 'display_pane_attach_or_open')
  [[ "$second" != "$first" ]] || { echo "attached to the dismissed pane '$first'"; return 1; }
  [[ -n "$second" && -d "$second" ]] || { echo "no fresh pane opened, got '$second'"; return 1; }
}

# Copies run-all.sh and display.sh into a scratch dir alongside provider stubs that record
# their argv and exit clean, so run-all can be driven end to end without touching an API.
stage_run_all() {
  RUN_DIR="$MOCK_DIR/runall"
  mkdir -p "$RUN_DIR"
  cp "${PLUGIN_ROOT}/scripts/run-all.sh" "${PLUGIN_ROOT}/scripts/display.sh" "$RUN_DIR/"
  local name
  for name in gemini openai xai; do
    printf '#!/bin/bash\nexit 0\n' > "$RUN_DIR/${name}.sh"
    chmod +x "$RUN_DIR/${name}.sh"
  done
}

@test "run-all joins a pane already streaming instead of splitting a second one" {
  # A provider launched on its own is mid-generation when run-all starts. Both surfaces have to
  # land on the same pane, and run-all must not dismiss a pane whose other participant is still
  # working -- so .done stays absent while that provider holds its token.
  stage_run_all
  pane_proc 'display_pane_begin gemini gemini-3-pro-image-preview'

  local dir
  dir=$(registered_dir)
  [[ -n "$dir" ]] || { echo "the first provider registered no pane"; return 1; }

  env "PATH=$MOCK_DIR/bin:$PATH" "TMPDIR=$MOCK_DIR/tmp" "TMUX_STUB_LOG=$TMUX_STUB_LOG" \
    TMUX="fake,1,0" TMUX_PANE="%0" LC_TERMINAL="iTerm2" TERM_PROGRAM="iTerm.app" \
    bash "$RUN_DIR/run-all.sh" --mode generate --prompt "a cat" --output-base "$MOCK_DIR/out"

  local splits
  splits=$(split_count)
  [[ "$splits" -eq 1 ]] || {
    echo "Expected run-all to reuse the open pane (1 split total), got: $splits"
    cat "$TMUX_STUB_LOG"
    return 1
  }

  [[ ! -f "$dir/.done" ]] || {
    echo "run-all dismissed a pane while another provider still held a token"
    return 1
  }
}

@test "a provider handed a pane by its parent neither registers nor closes it" {
  # run-all exports DISPLAY_PANE_DIR to its children but keeps the ownership flag to itself. A
  # child that took a token and released it would write .done the moment it finished, dismissing
  # the pane while its siblings are still generating.
  local pane="$MOCK_DIR/tmp/handed_down"
  mkdir -p "$pane"

  env "PATH=$MOCK_DIR/bin:$PATH" "TMPDIR=$MOCK_DIR/tmp" "TMUX_STUB_LOG=$TMUX_STUB_LOG" \
    TMUX="fake,1,0" TMUX_PANE="%0" LC_TERMINAL="iTerm2" TERM_PROGRAM="iTerm.app" \
    DISPLAY_PANE_DIR="$pane" \
    bash -c "source '$DISPLAY_SH'
             display_pane_begin gemini gemini-3-pro-image-preview
             display_pane_finish gemini gemini-3-pro-image-preview /nope/a.png"

  [[ ! -f "$pane/.done" ]] || { echo "child dismissed its parent's pane"; return 1; }
  [[ ! -d "$pane/active" ]] || {
    echo "child took a token in a pane it does not own"
    ls -la "$pane/active"
    return 1
  }

  local splits
  splits=$(split_count)
  [[ "$splits" -eq 0 ]] || { echo "child split its own pane despite inheriting one"; return 1; }
}

@test "run-all closes the pane when it is the only participant" {
  # The everyday case: run-all opens the pane, forks providers, and dismisses it once they are
  # all waited on. The last-one-out rule has to reduce to exactly the old close-at-the-end
  # behaviour when nobody else is sharing.
  stage_run_all

  env "PATH=$MOCK_DIR/bin:$PATH" "TMPDIR=$MOCK_DIR/tmp" "TMUX_STUB_LOG=$TMUX_STUB_LOG" \
    TMUX="fake,1,0" TMUX_PANE="%0" LC_TERMINAL="iTerm2" TERM_PROGRAM="iTerm.app" \
    bash "$RUN_DIR/run-all.sh" --mode generate --prompt "a cat" --output-base "$MOCK_DIR/out"

  local dir
  dir=$(ls -d "$MOCK_DIR"/tmp/display_pane.* 2>/dev/null | head -1)
  [[ -n "$dir" ]] || { echo "run-all opened no pane"; return 1; }
  [[ -f "$dir/.done" ]] || { echo "run-all left its own pane open"; return 1; }
}

@test "a caller that loses the create race waits for the winner's pane" {
  # Between claiming the entry and publishing the pane there is a window where the entry looks
  # empty. Providers forked together land squarely in it, and treating empty as stale is how a
  # batch ends up with two panes. The loser must wait for the winner rather than race it.
  local reg pane
  reg=$(pane_proc '__pane_registry_dir')
  pane="$MOCK_DIR/tmp/winner_pane"
  mkdir -p "$reg" "$pane"
  ( sleep 0.3; printf '%s' "$pane" > "$reg/dir" ) &

  local got
  got=$(pane_proc 'display_pane_attach_or_open')
  wait

  [[ "$got" == "$pane" ]] || {
    echo "loser did not attach to the winner's pane"
    echo "  want: '$pane'"
    echo "  got:  '$got'"
    return 1
  }

  local splits
  splits=$(split_count)
  [[ "$splits" -eq 0 ]] || {
    echo "Expected the loser to open no pane of its own, got $splits splits"
    return 1
  }
}

@test "an abandoned claim is taken over instead of stranding the window" {
  # A provider killed between claiming the entry and publishing its pane leaves a claim nobody
  # will ever fulfil. Waiting on it forever would push every later batch in this window back to
  # a pane per provider, so the next arrival takes the claim over and publishes its own pane.
  local reg
  reg=$(pane_proc '__pane_registry_dir')
  mkdir -p "$reg"

  local got
  got=$(pane_proc 'display_pane_attach_or_open')
  [[ -n "$got" && -d "$got" ]] || { echo "no pane opened, got '$got'"; return 1; }

  # The entry has to name the recovered pane, or the provider after this one waits all over again.
  local published
  published=$(cat "$reg/dir" 2>/dev/null)
  [[ "$published" == "$got" ]] || {
    echo "registry still does not name a live pane"
    echo "  want: '$got'"
    echo "  got:  '$published'"
    return 1
  }
}

@test "suites that run the scripts for real keep them out of the live tmux session" {
  # Provider scripts join this window's display pane as soon as they start querying, so a suite
  # that runs one against the developer's own tmux session splits a real pane -- one per test,
  # each left waiting for a keypress nobody will press. Such a suite must call disable_display.
  # Suites that install a tmux stub are exempt: theirs is the behaviour under test.
  local f offenders=""
  for f in "${PLUGIN_ROOT}"/tests/*.bats; do
    grep -qE '(GEMINI|OPENAI|XAI|RUN_ALL)_SH|scripts/(gemini|openai|xai|run-all)\.sh' "$f" || continue
    grep -q '/tmux"' "$f" && continue
    grep -q 'disable_display' "$f" || offenders="${offenders}${offenders:+ }$(basename "$f")"
  done
  [[ -z "$offenders" ]] || {
    echo "These suites run the scripts against the live tmux session without disable_display:"
    echo "  $offenders"
    return 1
  }
}
