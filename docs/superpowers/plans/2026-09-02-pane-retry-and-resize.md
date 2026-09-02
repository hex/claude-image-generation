# Pane resize re-render, auto retry, retry-from-pane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The streaming pane redraws itself after a resize, provider scripts retry transient API errors, and a failed provider can be re-run from the pane with one key.

**Architecture:** Everything lives in bash. `scripts/display.sh` holds a heredoc (between `cat <<'WATCHEREOF'` and `WATCHEREOF`) that becomes the pane's `watcher.sh`; the watcher polls a tab-separated `status` file every 0.12s and draws banners and images. Provider scripts (`gemini.sh`, `openai.sh`, `xai.sh`, `openrouter.sh`) source `display.sh`, call `curl`, and report through `display_pane_status`. `run-all.sh` forks the providers and holds the pane open. Three slices: (1) width polling plus a full redraw in the watcher, (2) a `curl_with_retry` in a new `scripts/retry.sh`, (3) a `retry-offer`/`.retry` file handshake between run-all and the watcher.

**Tech Stack:** bash 3.2 (macOS), jq, curl, tmux, bats (`bats tests/`).

**Spec:** `docs/superpowers/specs/2026-09-02-pane-retry-and-resize-design.md`

## Global Constraints

- Every script must run under macOS bash 3.2: no associative arrays, no `${var^^}`, no `mapfile`, `read -t` takes whole seconds only.
- Scripts run with `set -euo pipefail`; an assignment from a failing command substitution exits the script, so capture exit codes with `cmd && rc=0 || rc=$?`.
- Never run `bats` with `TMUX` set in the environment: the suites call `disable_display`, but a stray pane in the developer's tmux is the failure mode to avoid. Run tests as `unset TMUX TMUX_PANE; bats tests/`.
- `tests/edit_payload.bats` and `tests/retry.bats` need a multi-megabyte `test-input.png` at the repo root (gitignored) or they skip. Create one with `python3 -c "from PIL import Image; import os; Image.frombytes('RGB',(1400,1400),os.urandom(1400*1400*3)).save('test-input.png')"` and delete it before committing.
- Inline image rendering cannot be verified from a shell. Any visual claim is verified by Alex looking at the pane. Tests assert on the stub `imgcat` output (`DISPLAYED:<path>`) only.
- Commit after every task. Commit bodies are prose Alex signs: no em dashes, no "Label:" openers, plain sentences.

---

### Task 1: Factor the watcher's provider drawing into two functions

Pure refactor so Task 2 can call the same drawing from a redraw. No behavior change; the existing suite is the test.

**Files:**
- Modify: `scripts/display.sh` (watcher heredoc, the `complete` and `error` branches of the status loop, around lines 786-815)

**Interfaces:**
- Produces: `draw_complete <provider>` (prints SetMark, banner, image via render.sh, trailing newline) and `draw_error <provider>` (prints the red block and the `errors/<provider>.txt` lines). Both set nothing except `any_image_rendered=1` inside `draw_complete` when an image was rendered.

- [ ] **Step 1: Run the suite to record the baseline**

Run: `unset TMUX TMUX_PANE; bats tests/pane_layout.bats tests/display.bats`
Expected: all `ok`.

- [ ] **Step 2: Add the two functions to the watcher heredoc**

Insert after `clear_loading()` (after the line `clear_loading() {` block closes) inside the heredoc:

```bash
# draw_complete <provider> — banner plus image for a provider that has finished.
draw_complete() {
    local p="$1" banner_line ppath
    printf '\033Ptmux;\033\033]1337;SetMark\a\033\\'
    build_banner_line banner_line "$p"
    # One blank line above each banner separates providers; one below sets the banner
    # off from its image so the two don't crowd.
    printf '\n%s\n\n' "$banner_line"
    map_get ppath provider_path "$p"
    if [[ -n "$ppath" && -f "$ppath" ]]; then
        "$WATCH/render.sh" "$ppath"
        any_image_rendered=1
    fi
    printf '\n'
}

# draw_error <provider> — the red block plus whatever the provider left in errors/.
draw_error() {
    local p="$1" err_line
    printf '\n\033[1;38;2;185;28;28m✗ %s error\033[0m\n' "$p"
    if [[ -f "$WATCH/errors/${p}.txt" ]]; then
        while IFS= read -r err_line || [[ -n "$err_line" ]]; do
            printf '   \033[2;38;2;252;165;165m%s\033[0m\n' "$err_line"
        done < "$WATCH/errors/${p}.txt"
    fi
    echo
}
```

- [ ] **Step 3: Replace the two branches in the status loop with calls**

The block that currently reads:

```bash
            if [[ "$state" == "complete" ]]; then
                [[ -n "$already_rendered" ]] && continue
                map_set rendered "$provider" 1
                clear_loading
                printf '\033Ptmux;\033\033]1337;SetMark\a\033\\'
                build_banner_line banner_line "$provider"
                # One blank line above each banner separates providers; one below sets the banner
                # off from its image so the two don't crowd.
                printf '\n%s\n\n' "$banner_line"
                map_get ppath provider_path "$provider"
                if [[ -n "$ppath" && -f "$ppath" ]]; then
                    "$WATCH/render.sh" "$ppath"
                    any_image_rendered=1
                fi
                printf '\n'
            elif [[ "$state" == "error" ]]; then
                [[ -n "$already_rendered" ]] && continue
                map_set rendered "$provider" 1
                clear_loading
                printf '\n\033[1;38;2;185;28;28m✗ %s error\033[0m\n' "$provider"
                if [[ -f "$WATCH/errors/${provider}.txt" ]]; then
                    while IFS= read -r err_line; do
                        printf '   \033[2;38;2;252;165;165m%s\033[0m\n' "$err_line"
                    done < "$WATCH/errors/${provider}.txt"
                fi
                echo
            fi
```

becomes:

```bash
            if [[ "$state" == "complete" ]]; then
                [[ -n "$already_rendered" ]] && continue
                map_set rendered "$provider" 1
                clear_loading
                draw_complete "$provider"
            elif [[ "$state" == "error" ]]; then
                [[ -n "$already_rendered" ]] && continue
                map_set rendered "$provider" 1
                clear_loading
                draw_error "$provider"
            fi
```

Note `draw_error` reads the last line even without a trailing newline (`|| [[ -n "$err_line" ]]`); `display_pane_error` writes with `printf '%s'`, so the old loop dropped a one-line message with no newline. That is the one intended behavior change; the test in Step 4 pins it.

- [ ] **Step 4: Write the failing test for the no-trailing-newline error message**

Append to `tests/pane_layout.bats`:

```bash
@test "the watcher shows an error message written without a trailing newline" {
  local mock="${BATS_TMPDIR}/watcher_err_nl_$$"
  mkdir -p "$mock/.iterm2"
  printf '#!/bin/bash\necho "DISPLAYED:${@: -1}"\n' > "$mock/.iterm2/imgcat"
  cat > "$mock/tmux" <<'STUB'
#!/bin/bash
[ "$1" = "display-message" ] && { echo "200 50"; exit 0; }
exit 0
STUB
  chmod +x "$mock/.iterm2/imgcat" "$mock/tmux"

  local wd
  wd=$(HOME="$mock" PATH="$mock:$PATH" TMUX="fake,1,0" TMUX_PANE="%0" \
       LC_TERMINAL="iTerm2" TERM_PROGRAM="iTerm.app" \
       bash -c "source '$DISPLAY_SH'; display_pane_open")
  [[ -f "$wd/watcher.sh" ]] || { echo "no watcher.sh at '$wd'"; return 1; }

  # display_pane_error writes with printf '%s': no trailing newline. A plain `read` loop
  # drops the last unterminated line, which for a one-line message is the whole message.
  mkdir -p "$wd/errors"
  printf '%s' "xAI API returned HTTP 429: rate limited" > "$wd/errors/xai.txt"
  printf 'xai\terror\t\tgrok-imagine-image-pro\t\n' > "$wd/status"
  touch "$wd/.done"

  local output
  output=$(HOME="$mock" PATH="$mock:$PATH" timeout 10 bash "$wd/watcher.sh" "$wd" </dev/null 2>&1)
  [[ "$output" == *"rate limited"* ]] || {
    echo "error text never reached the pane:"
    echo "$output"
    return 1
  }
  rm -rf "$mock"
}
```

- [ ] **Step 5: Run the new test against the unrefactored code to see it fail**

Stash the display.sh edit first (`git stash push scripts/display.sh`), run:
`unset TMUX TMUX_PANE; bats tests/pane_layout.bats -f "without a trailing newline"`
Expected: `not ok` with "error text never reached the pane". Then `git stash pop`.

- [ ] **Step 6: Run the whole suite**

Run: `unset TMUX TMUX_PANE; bats tests/`
Expected: all `ok` (161 tests: 160 plus this one).

- [ ] **Step 7: Commit**

```bash
git add scripts/display.sh tests/pane_layout.bats
git commit -m "Factor the watcher's provider drawing into draw_complete and draw_error

The redraw that follows a resize needs to replay every provider block
from state, so the two branches of the status loop become functions.
draw_error also reads a final line that has no newline: display_pane_error
writes with printf '%s', so a one-line message was never shown."
```

---

### Task 2: Redraw the pane after the width settles

**Files:**
- Modify: `scripts/display.sh` (watcher heredoc: state variables near `any_image_rendered=""`, new functions, one call in the main loop before `draw_loading`)
- Test: `tests/pane_layout.bats`

**Interfaces:**
- Consumes: `draw_complete`, `draw_error` from Task 1.
- Produces: `pane_cols` (prints the pane's tty width or returns 1), `reflow_to <cols>` (redraws once a changed width has held 4 ticks; returns 0 only when it redrew), `redraw_all`. Environment `DISPLAY_PANE_TTY` (default `/dev/tty`) names the tty whose size is read, so tests can point it at `/dev/null` and stub `stty`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/pane_layout.bats`:

```bash
# Builds a watcher dir with the standard stubs and a scripted `stty` whose `size` output is
# taken from $mock/widths, one line per call, repeating the last line once exhausted.
# Sets $wd and $mock for the caller.
make_resize_watcher() {
  mock="${BATS_TMPDIR}/watcher_resize_$$"
  mkdir -p "$mock/.iterm2"
  printf '#!/bin/bash\necho "DISPLAYED:${@: -1}"\n' > "$mock/.iterm2/imgcat"
  cat > "$mock/tmux" <<'STUB'
#!/bin/bash
[ "$1" = "display-message" ] && { echo "200 50"; exit 0; }
exit 0
STUB
  cat > "$mock/stty" <<'STUB'
#!/bin/bash
d="$(dirname "$0")"
n=$(cat "$d/stty.calls" 2>/dev/null || echo 0)
echo $((n + 1)) > "$d/stty.calls"
total=$(wc -l < "$d/widths" | tr -d ' ')
[ "$n" -ge "$total" ] && n=$((total - 1))
sed -n "$((n + 1))p" "$d/widths"
STUB
  chmod +x "$mock/.iterm2/imgcat" "$mock/tmux" "$mock/stty"
  wd=$(HOME="$mock" PATH="$mock:$PATH" TMUX="fake,1,0" TMUX_PANE="%0" \
       LC_TERMINAL="iTerm2" TERM_PROGRAM="iTerm.app" \
       bash -c "source '$DISPLAY_SH'; display_pane_open")
  [[ -f "$wd/watcher.sh" ]] || { echo "no watcher.sh at '$wd'"; return 1; }
}

@test "the watcher redraws every rendered image once a new width has held for four ticks" {
  local wd mock
  make_resize_watcher
  # Width 200 for six reads (the pane opens and renders at it), then 120 for good. The
  # watcher must redraw exactly once: the image count goes from one to two, not more.
  printf '50 200\n50 200\n50 200\n50 200\n50 200\n50 200\n50 120\n' > "$mock/widths"
  printf 'xai\tcomplete\t4210\tmascot-xai\t%s\n' "$OVERSIZED_FIXTURE" > "$wd/status"

  # .done is written after the watcher has had time to see the new width settle.
  ( sleep 3; touch "$wd/.done" ) &
  local output
  output=$(HOME="$mock" PATH="$mock:$PATH" DISPLAY_PANE_TTY=/dev/null \
           timeout 15 bash "$wd/watcher.sh" "$wd" </dev/null 2>&1)
  local n
  n=$(printf '%s' "$output" | grep -c 'DISPLAYED:')
  [[ "$n" -eq 2 ]] || {
    echo "expected the image drawn twice (once, then once after the resize), got $n:"
    echo "$output"
    return 1
  }
  # The redraw starts from a cleared screen and scrollback.
  [[ "$output" == *$'\033[2J\033[3J\033[H'* ]] || { echo "redraw did not clear the pane"; return 1; }
  rm -rf "$mock"
}

@test "a width that changes on every tick never triggers a redraw" {
  local wd mock
  make_resize_watcher
  printf '50 200\n50 120\n' > "$mock/widths"
  # Alternate 200/120 forever: the stub repeats its last line, so write the alternation out.
  local i
  for i in $(seq 1 40); do printf '50 200\n50 120\n'; done > "$mock/widths"
  printf 'xai\tcomplete\t4210\tmascot-xai\t%s\n' "$OVERSIZED_FIXTURE" > "$wd/status"
  ( sleep 3; touch "$wd/.done" ) &
  local output
  output=$(HOME="$mock" PATH="$mock:$PATH" DISPLAY_PANE_TTY=/dev/null \
           timeout 15 bash "$wd/watcher.sh" "$wd" </dev/null 2>&1)
  local n
  n=$(printf '%s' "$output" | grep -c 'DISPLAYED:')
  [[ "$n" -eq 1 ]] || {
    echo "a drag in progress must not redraw; image drawn $n times:"
    echo "$output"
    return 1
  }
  rm -rf "$mock"
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `unset TMUX TMUX_PANE; bats tests/pane_layout.bats -f "width"`
Expected: the first fails with "got 1", the second passes trivially (no redraw exists yet). That is fine: the second is the guard for the settle logic written next.

- [ ] **Step 3: Add width state and the three functions to the watcher heredoc**

After `any_image_rendered=""` add:

```bash
# Width tracking for the resize redraw. A resize in tmux control mode resyncs the pane to the
# text grid and the inline images vanish, and images are sized as a fraction of the width, so
# the pane is replayed from state once a new width has held still.
previous_cols=0
stable_ticks=0
rendered_cols=0
# How many consecutive equal readings mean the resize has finished. tmux moves panes in whole
# cells, so a drag can report the same width on two 120ms polls; four ticks is about half a
# second, which a drag never holds and a finished resize always does.
WIDTH_SETTLE_TICKS=4
PANE_TTY="${DISPLAY_PANE_TTY:-/dev/tty}"
```

After `draw_error()` add:

```bash
# pane_cols — prints the pane's current column count, or returns 1 when it cannot be read.
pane_cols() {
    local size
    size=$(stty size < "$PANE_TTY" 2>/dev/null) || return 1
    size="${size##* }"
    [[ "$size" =~ ^[0-9]+$ && "$size" -gt 0 ]] || return 1
    printf '%s' "$size"
}

# redraw_all — clear screen and scrollback, then replay every provider block from state.
redraw_all() {
    local p __state
    printf '\033[2J\033[3J\033[H'
    for p in $seen_providers; do
        map_get __state provider_state "$p"
        case "$__state" in
            complete) draw_complete "$p" ;;
            error)    draw_error "$p" ;;
        esac
    done
}

# reflow_to <cols> — redraw at cols once it has held WIDTH_SETTLE_TICKS readings and differs
# from the width the pane was last drawn at. The first reading only records the width.
# Returns 0 only when something was redrawn.
reflow_to() {
    local cols="$1"
    if [[ $cols -eq $previous_cols ]]; then
        stable_ticks=$((stable_ticks + 1))
    else
        stable_ticks=1
    fi
    previous_cols=$cols
    if [[ $rendered_cols -eq 0 ]]; then
        rendered_cols=$cols
        return 1
    fi
    [[ $cols -ne $rendered_cols && $stable_ticks -ge $WIDTH_SETTLE_TICKS ]] || return 1
    rendered_cols=$cols
    redraw_all
}
```

In the main loop, replace:

```bash
    spinner_frame=$((spinner_frame + 1))
    draw_loading
```

with:

```bash
    if __cols=$(pane_cols); then
        reflow_to "$__cols" || true
    fi

    spinner_frame=$((spinner_frame + 1))
    draw_loading
```

- [ ] **Step 4: Run the two tests**

Run: `unset TMUX TMUX_PANE; bats tests/pane_layout.bats -f "width"`
Expected: both `ok`.

- [ ] **Step 5: Run the whole suite**

Run: `unset TMUX TMUX_PANE; bats tests/`
Expected: all `ok`.

- [ ] **Step 6: Commit**

```bash
git add scripts/display.sh tests/pane_layout.bats
git commit -m "Redraw the streaming pane once a new width has held for four ticks

A resize in iTerm2 control mode resyncs the pane to tmux's text grid and
the inline images vanish; they are also sized as a fraction of the width.
The watcher now reads its tty width every tick and, when a changed width
has held for half a second, clears the pane and replays every provider
block from state. A drag never holds a width that long."
```

---

### Task 3: Reflow at the dismiss prompt

**Files:**
- Modify: `scripts/display.sh` (watcher heredoc, the `[f]inder [p]review` prompt loop at the end)
- Test: `tests/pane_layout.bats`

**Interfaces:**
- Consumes: `pane_cols`, `reflow_to` from Task 2.
- Produces: `prompt_line` (prints the dismiss prompt on a cleared line), used again by Task 7.

- [ ] **Step 1: Write the failing test**

Append to `tests/pane_layout.bats`:

```bash
@test "the dismiss prompt reflows on a resize and still closes on end of input" {
  local wd mock
  make_resize_watcher
  # Same width for the single live tick and the first prompt second; then 120 for good. The
  # prompt polls once a second, so the four-tick settle lands around the fourth second, well
  # before the pipe closes at six.
  printf '50 200\n50 200\n50 120\n' > "$mock/widths"
  printf 'xai\tcomplete\t4210\tmascot-xai\t%s\n' "$OVERSIZED_FIXTURE" > "$wd/status"
  touch "$wd/.done"

  # A pipe that stays open for six seconds with no data: read -t 1 times out at the prompt
  # (a real tick, so the width is checked), then end of input arrives and the prompt must exit.
  local output
  output=$( (sleep 6) | HOME="$mock" PATH="$mock:$PATH" DISPLAY_PANE_TTY=/dev/null \
           timeout 20 bash "$wd/watcher.sh" "$wd" 2>&1)
  local n
  n=$(printf '%s' "$output" | grep -c 'DISPLAYED:')
  [[ "$n" -eq 2 ]] || {
    echo "expected a redraw at the prompt, image drawn $n times:"
    echo "$output"
    return 1
  }
  [[ ! -d "$wd" ]] || { echo "watcher did not exit on end of input"; return 1; }
  rm -rf "$mock"
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `unset TMUX TMUX_PANE; bats tests/pane_layout.bats -f "dismiss prompt reflows"`
Expected: fails with "image drawn 1 times" (the blocking `read -n1` never checks the width).

- [ ] **Step 3: Replace the prompt loop**

The block from `_esc=$(printf '\033')` to the closing `done` before `WATCHEREOF` becomes:

```bash
_esc=$(printf '\033')

# prompt_line — the close prompt, drawn on a cleared bottom line so a redraw can reprint it.
prompt_line() {
    printf '\r\033[K[f]inder [p]review [esc/ctrl-d] close '
}

# read_key <var> — one keypress with a one-second timeout. Returns 0 with a key, 1 on a
# timeout (a real tick: safe to check the width), 2 when input is gone. bash 3.2 reports a
# timeout and end of input both as status 1, so they are told apart by cost: a timeout burns
# the full second and $SECONDS moves on, end of input returns at once.
read_key() {
    local __before=$SECONDS
    if read -t 1 -n1 -s -r "$1"; then
        return 0
    fi
    [[ $SECONDS -gt $__before ]] && return 1
    return 2
}

prompt_line
while true; do
    read_key _key
    case $? in
        0) ;;
        1)
            if __cols=$(pane_cols) && reflow_to "$__cols"; then
                prompt_line
            fi
            continue
            ;;
        *) break ;;
    esac
    if [ "$_key" = "$_esc" ]; then break; fi
    if [ "$_key" = "f" ] || [ "$_key" = "F" ]; then
        { awk -F'\t' '$5!=""{print $5}' "$WATCH/status" 2>/dev/null;
          cat "$WATCH/manifest" 2>/dev/null; } | sort -u | xargs -I{} open -R {} 2>/dev/null
    elif [ "$_key" = "p" ] || [ "$_key" = "P" ]; then
        { awk -F'\t' '$5!=""{print $5}' "$WATCH/status" 2>/dev/null;
          cat "$WATCH/manifest" 2>/dev/null; } | sort -u | xargs open -a Preview 2>/dev/null
    fi
done
```

Ctrl-D on a tty is end of input, which `read` reports at once, so `read_key` returns 2 and the loop breaks exactly as before.

- [ ] **Step 4: Run the test and the suite**

Run: `unset TMUX TMUX_PANE; bats tests/pane_layout.bats -f "dismiss prompt reflows"` then `unset TMUX TMUX_PANE; bats tests/`
Expected: all `ok`.

- [ ] **Step 5: Commit**

```bash
git add scripts/display.sh tests/pane_layout.bats
git commit -m "Keep reflowing at the close prompt

The prompt's blocking read meant a resize after the run finished left the
pane blank until it was closed. The read now times out every second and
checks the width. bash 3.2 reports a timeout and end of input the same
way, so the two are told apart by whether a second went by."
```

- [ ] **Step 6: Ask Alex to verify slice 1 visually**

Run a replay: `bash /private/tmp/claude-501/-Users-alex-geana--claude-sessions-claude-image-generation/d41fd67b-72ae-4f11-b721-d16434890451/scratchpad/replay-a.sh` (opens a pane with four images at 4s, 9s, 15s, 20s). Ask Alex to resize the pane during and after the run. Expected by eye: images come back at the new width after about half a second. If a redraw shows fewer images than exist, add `sleep 0.3` between the `draw_complete` calls in `redraw_all`, retest, and record the outcome in the narrative.

---

### Task 4: `curl_with_retry` in `scripts/retry.sh`

**Files:**
- Create: `scripts/retry.sh`
- Test: `tests/retry.bats` (new)

**Interfaces:**
- Produces: `curl_with_retry [curl args...]`. Same stdout as `curl -s -w "\n%{http_code}"` would give: body then a newline then the HTTP code. Always returns 0. Honors `IMAGE_MAX_RETRIES` (default 3) and `IMAGE_RETRY_DELAY` (default 1, doubling). Sets the global `RETRY_ATTEMPTS` to the number of retries made. Calls `retry_notice <attempt> <max>` before each retry; the default definition writes to stderr and, when `DISPLAY_PANE_DIR` is set and `PROVIDER_NAME` is known, a `retrying` status. Task 5 wires that status into the pane.
- Produces: `is_retryable_status <code>` (0 for 429 500 502 503 504).

- [ ] **Step 1: Write the failing tests**

Create `tests/retry.bats`:

```bash
#!/usr/bin/env bats
# ABOUTME: Tests curl_with_retry: which failures retry, how many times, and that a body
# ABOUTME: streamed on stdin is resent intact on every attempt.

load test_helper

RETRY_SH="${PLUGIN_ROOT}/scripts/retry.sh"
BIG_IMAGE="${PLUGIN_ROOT}/test-input.png"

setup() {
  MOCK_DIR="${BATS_TMPDIR}/retry_mocks_$$"
  mkdir -p "$MOCK_DIR"
  export IMAGE_RETRY_DELAY=0
}

teardown() {
  rm -rf "$MOCK_DIR" 2>/dev/null || true
}

# stub_curl_sequence <code>... — a curl that answers one scripted HTTP code per call (the last
# repeats), writes its stdin/--data-binary body to $MOCK_DIR/body.N, and honors -w "\n%{http_code}".
stub_curl_sequence() {
  printf '%s\n' "$@" > "$MOCK_DIR/codes"
  cat > "$MOCK_DIR/curl" <<'STUB'
#!/bin/bash
d="$(dirname "$0")"
n=$(cat "$d/calls" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$d/calls"
total=$(wc -l < "$d/codes" | tr -d ' ')
i=$n; [ "$i" -gt "$total" ] && i=$total
code=$(sed -n "${i}p" "$d/codes")
# Capture whatever body curl was handed: --data-binary @file or -d string.
body=""
while [ $# -gt 0 ]; do
  case "$1" in
    --data-binary) f="${2#@}"; body=$(cat "$f"); shift 2 ;;
    -d) body="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s' "$body" > "$d/body.$n"
[ "$code" = "fail" ] && exit 7
printf '{"seen":%s}\n%s\n' "$n" "$code"
STUB
  chmod +x "$MOCK_DIR/curl"
  export PATH="$MOCK_DIR:$PATH"
}

calls() { cat "$MOCK_DIR/calls"; }

@test "retry: a 503 followed by a 200 succeeds on the second call" {
  stub_curl_sequence 503 200
  run bash -c "source '$RETRY_SH'; curl_with_retry -s -w '\n%{http_code}' -X POST https://x -d '{}'; echo \"attempts=\$RETRY_ATTEMPTS\""
  assert_status 0
  [[ "$(calls)" -eq 2 ]] || { echo "expected 2 calls, got $(calls)"; return 1; }
  assert_output_contains '{"seen":2}'
  assert_output_contains "attempts=1"
  [[ "${lines[1]}" == "200" ]] || { echo "code line missing: $output"; return 1; }
}

@test "retry: a 400 is not retried" {
  stub_curl_sequence 400 200
  run bash -c "source '$RETRY_SH'; curl_with_retry -s -w '\n%{http_code}' https://x -d '{}'"
  [[ "$(calls)" -eq 1 ]] || { echo "expected 1 call, got $(calls)"; return 1; }
  [[ "${lines[1]}" == "400" ]] || { echo "expected the 400 passed through: $output"; return 1; }
}

@test "retry: three 503s exhaust the retries and return the last body" {
  stub_curl_sequence 503 503 503 503 200
  run bash -c "source '$RETRY_SH'; curl_with_retry -s -w '\n%{http_code}' https://x -d '{}'; echo \"attempts=\$RETRY_ATTEMPTS\""
  [[ "$(calls)" -eq 4 ]] || { echo "expected 1 + 3 retries = 4 calls, got $(calls)"; return 1; }
  assert_output_contains '{"seen":4}'
  assert_output_contains "attempts=3"
  [[ "${lines[1]}" == "503" ]] || { echo "expected the final 503: $output"; return 1; }
}

@test "retry: a curl network failure is retried" {
  stub_curl_sequence fail 200
  run bash -c "source '$RETRY_SH'; curl_with_retry -s -w '\n%{http_code}' https://x -d '{}'"
  assert_status 0
  [[ "$(calls)" -eq 2 ]] || { echo "expected 2 calls, got $(calls)"; return 1; }
  [[ "${lines[1]}" == "200" ]] || { echo "expected 200 after the retry: $output"; return 1; }
}

@test "retry: IMAGE_MAX_RETRIES=0 makes one call only" {
  stub_curl_sequence 503 200
  IMAGE_MAX_RETRIES=0 run bash -c "source '$RETRY_SH'; curl_with_retry -s -w '\n%{http_code}' https://x -d '{}'"
  [[ "$(calls)" -eq 1 ]] || { echo "expected 1 call, got $(calls)"; return 1; }
}

@test "retry: a multi-megabyte stdin body is resent identically on every attempt" {
  [[ -f "$BIG_IMAGE" ]] || skip "test-input.png not present"
  stub_curl_sequence 503 200
  local body_file="$MOCK_DIR/request.json"
  jq -n --rawfile d <(base64 < "$BIG_IMAGE" | tr -d '\n') '{image:$d}' > "$body_file"
  run bash -c "source '$RETRY_SH'; curl_with_retry -s -w '\n%{http_code}' https://x --data-binary @- < '$body_file'"
  assert_status 0
  [[ "$(calls)" -eq 2 ]] || { echo "expected 2 calls, got $(calls)"; return 1; }
  cmp -s "$body_file" "$MOCK_DIR/body.1" || { echo "first attempt body differs from the input"; return 1; }
  cmp -s "$body_file" "$MOCK_DIR/body.2" || { echo "second attempt body differs from the input"; return 1; }
}

@test "retry: each retry announces itself on stderr with the attempt count" {
  stub_curl_sequence 503 503 200
  run bash -c "source '$RETRY_SH'; curl_with_retry -s -w '\n%{http_code}' https://x -d '{}' 2>&1 >/dev/null"
  assert_output_contains "retry 1/3"
  assert_output_contains "retry 2/3"
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `unset TMUX TMUX_PANE; bats tests/retry.bats`
Expected: every test `not ok` with "No such file or directory" for `scripts/retry.sh`.

- [ ] **Step 3: Create `scripts/retry.sh`**

```bash
#!/usr/bin/env bash
# ABOUTME: curl_with_retry, a curl wrapper that retries transient API failures with backoff.
# ABOUTME: Sourced by the provider scripts after display.sh; keeps curl's body+code output.

# Retries are governed by two knobs. The delay doubles on each retry: 1s, 2s, 4s.
IMAGE_MAX_RETRIES="${IMAGE_MAX_RETRIES:-3}"
IMAGE_RETRY_DELAY="${IMAGE_RETRY_DELAY:-1}"

# How many retries the last curl_with_retry made, for the error message of a provider that
# still failed afterwards.
RETRY_ATTEMPTS=0

# is_retryable_status <http code> — rate limits and server-side failures are worth another try.
# Everything else in 4xx is a bad request that a retry would only repeat.
is_retryable_status() {
  case "$1" in
    429|500|502|503|504) return 0 ;;
    *) return 1 ;;
  esac
}

# retry_notice <attempt> <max> — announces a retry on stderr and, inside a streaming pane, as
# a `retrying` status whose timing column carries "attempt/max" for the spinner line.
retry_notice() {
  echo "Retrying (${1}/${2})..." >&2
  if [[ -n "${DISPLAY_PANE_DIR:-}" && -d "${DISPLAY_PANE_DIR:-}" && -n "${PROVIDER_NAME:-}" ]]; then
    display_pane_status "$PROVIDER_NAME" retrying "${1}/${2}" "${MODEL:-}"
  fi
}

# curl_with_retry [curl args...] — curl, retried on 429/5xx or a curl failure. The output
# contract is curl's own with -w "\n%{http_code}": body, newline, code; the last attempt's
# output is what the caller sees. A body given as `--data-binary @-` is read from stdin once
# into a temp file so every attempt can resend it. Always returns 0; callers judge the code.
curl_with_retry() {
  local -a args=()
  local a body_file=""
  for a in "$@"; do
    if [[ "$a" == "@-" ]]; then
      body_file=$(mktemp "${TMPDIR:-/tmp}/retry-body.XXXXXX")
      cat > "$body_file"
      a="@${body_file}"
    fi
    args+=("$a")
  done

  local max="$IMAGE_MAX_RETRIES" delay="$IMAGE_RETRY_DELAY" attempt=0
  local response="" curl_exit=0 code=""
  RETRY_ATTEMPTS=0
  while :; do
    response=$(curl "${args[@]}") && curl_exit=0 || curl_exit=$?
    code="${response##*$'\n'}"
    if [[ $curl_exit -eq 0 ]] && ! is_retryable_status "$code"; then
      break
    fi
    [[ $attempt -lt $max ]] || break
    attempt=$((attempt + 1))
    RETRY_ATTEMPTS=$attempt
    retry_notice "$attempt" "$max"
    sleep "$delay"
    delay=$((delay * 2))
  done

  [[ -n "$body_file" ]] && rm -f "$body_file"
  printf '%s\n' "$response"
  return 0
}
```

Note on `printf '%s\n'`: the providers capture with `RESPONSE=$(...)`, which strips trailing newlines, then `tail -1` for the code and `sed '$d'` for the body, exactly as with raw curl.

- [ ] **Step 4: Run the tests**

Run: `unset TMUX TMUX_PANE; bats tests/retry.bats`
Expected: all `ok` (the big-body test skips without `test-input.png`; create it per Global Constraints and run again to see it pass, then delete it).

- [ ] **Step 5: Commit**

```bash
git add scripts/retry.sh tests/retry.bats
git commit -m "Add curl_with_retry for transient API failures

429 and 5xx answers and curl network failures are retried up to three
times with a doubling delay; other 4xx fail at once. A body streamed on
stdin is spooled once so every attempt resends it. Output stays curl's
body-then-code shape so no provider parsing changes."
```

---

### Task 5: Wire retry into the four providers and show it on the spinner line

**Files:**
- Modify: `scripts/gemini.sh:175`, `scripts/xai.sh:140`, `scripts/openrouter.sh:144`, `scripts/openai.sh:150,176` (the five `curl -s -w` sites), plus each script's `source` block after `source "${SCRIPT_DIR}/display.sh"`
- Modify: `scripts/display.sh` (`provider_die`; watcher `draw_loading`)
- Test: `tests/edit_payload.bats`, `tests/pane_layout.bats`

**Interfaces:**
- Consumes: `curl_with_retry`, `RETRY_ATTEMPTS`, `retry_notice` from Task 4.
- Produces: status state `retrying` with the timing column `attempt/max`, drawn by the spinner as `xai (retry 2/3)`. `provider_die` appends ` (after N retries)` when `RETRY_ATTEMPTS` is above 0.

- [ ] **Step 1: Write the failing provider test**

Append to `tests/edit_payload.bats` (it already has `stub_curl` that returns one canned body with code 200; add a sequenced variant):

```bash
# stub_curl_once_503 <body> — first call answers 503 with an error body, later calls the
# canned body with 200. Records the request bodies like stub_curl.
stub_curl_once_503() {
  printf '%s\n200\n' "$1" > "$MOCK_DIR/response.txt"
  cat > "$MOCK_DIR/curl" <<STUB
#!/bin/bash
d="\$(dirname "\$0")"
cat > "\${d}/request.txt" 2>/dev/null
n=\$(cat "\$d/calls" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "\$d/calls"
if [ "\$n" -eq 1 ]; then printf '{"error":{"message":"overloaded"}}\n503\n'; exit 0; fi
cat "\$d/response.txt"
STUB
  chmod +x "$MOCK_DIR/curl"
  export PATH="$MOCK_DIR:$PATH"
}

@test "every provider retries a 503 and reports the attempt to the pane" {
  [[ -f "$BIG_IMAGE" ]] || skip "test-input.png not present"
  local p body
  for p in gemini openai xai openrouter; do
    rm -f "$MOCK_DIR/calls" "$DISPLAY_PANE_DIR/status"
    case "$p" in
      gemini)     body='{"candidates":[{"content":{"parts":[{"inlineData":{"mimeType":"image/png","data":"ZmFrZQ=="}}]}}]}' ;;
      openai|xai) body='{"data":[{"b64_json":"ZmFrZQ=="}]}' ;;
      openrouter) body='{"choices":[{"message":{"images":[{"image_url":{"url":"data:image/png;base64,ZmFrZQ=="}}]}}]}' ;;
    esac
    stub_curl_once_503 "$body"
    IMAGE_RETRY_DELAY=0 GEMINI_API_KEY="$DUMMY_GEMINI_KEY" OPENAI_API_KEY="$DUMMY_OPENAI_KEY" \
      XAI_API_KEY="$DUMMY_XAI_KEY" OPENROUTER_API_KEY="$DUMMY_OPENROUTER_KEY" \
      run bash "${PLUGIN_ROOT}/scripts/${p}.sh" --mode edit --prompt "add a rainbow" \
      --input-image "$BIG_IMAGE" --output "$OUT"
    assert_edit_succeeds
    [[ "$(cat "$MOCK_DIR/calls")" -eq 2 ]] || { echo "$p: expected 2 curl calls, got $(cat "$MOCK_DIR/calls")"; return 1; }
    grep -q "$(printf '^%s\tretrying\t1/3\t' "$p")" "$DISPLAY_PANE_DIR/status" || {
      echo "$p: no retrying status line in the pane:"; cat "$DISPLAY_PANE_DIR/status"; return 1; }
  done
}

@test "a provider that still fails after retries says so in its error" {
  stub_curl_once_503 '{"error":{"message":"still overloaded"}}'
  # Make every call a 503 by making the canned success a 503 too.
  printf '{"error":{"message":"still overloaded"}}\n503\n' > "$MOCK_DIR/response.txt"
  IMAGE_RETRY_DELAY=0 XAI_API_KEY="$DUMMY_XAI_KEY" run bash "${PLUGIN_ROOT}/scripts/xai.sh" \
    --mode generate --prompt "a cat" --output "$OUT"
  assert_status 1
  assert_output_contains "still overloaded"
  assert_output_contains "(after 3 retries)"
  grep -q "after 3 retries" "$DISPLAY_PANE_DIR/errors/xai.txt" || { echo "pane error text lacks the retry count"; return 1; }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `unset TMUX TMUX_PANE; bats tests/edit_payload.bats -f "retr"`
Expected: first fails at gemini with "expected 2 curl calls, got 1"; second fails on "(after 3 retries)".

- [ ] **Step 3: Source retry.sh and switch the five curl sites**

In each of `gemini.sh`, `openai.sh`, `xai.sh`, `openrouter.sh`, directly after `source "${SCRIPT_DIR}/display.sh"` add:

```bash
source "${SCRIPT_DIR}/retry.sh"
```

Then change each `curl -s -w "\n%{http_code}"` to `curl_with_retry -s -w "\n%{http_code}"`. The five sites, with everything else on those lines unchanged:

- `gemini.sh`: `RESPONSE=$(printf '%s' "$REQUEST_BODY" | curl_with_retry -s -w "\n%{http_code}" \`
- `xai.sh`: `RESPONSE=$(printf '%s' "$REQUEST_BODY" | curl_with_retry -s -w "\n%{http_code}" \`
- `openrouter.sh`: `RESPONSE=$(printf '%s' "$REQUEST_BODY" | curl_with_retry -s -w "\n%{http_code}" \`
- `openai.sh` generate: `RESPONSE=$(curl_with_retry -s -w "\n%{http_code}" \`
- `openai.sh` edit: `RESPONSE=$(curl_with_retry -s -w "\n%{http_code}" \`

- [ ] **Step 4: Append the retry count in `provider_die`**

In `scripts/display.sh`, `provider_die` becomes:

```bash
provider_die() {
  local msg="$*"
  if [[ "${RETRY_ATTEMPTS:-0}" -gt 0 ]]; then
    msg="${msg} (after ${RETRY_ATTEMPTS} retries)"
  fi
  echo "$msg" >&2
  display_pane_fail "${PROVIDER_NAME:-unknown}" "${MODEL:-}" "$msg"
  exit 1
}
```

- [ ] **Step 5: Run the provider tests**

Run: `unset TMUX TMUX_PANE; bats tests/edit_payload.bats`
Expected: all `ok` (with `test-input.png` present).

- [ ] **Step 6: Write the failing spinner test**

Append to `tests/pane_layout.bats`:

```bash
@test "the spinner labels a retrying provider with its attempt count" {
  local mock="${BATS_TMPDIR}/watcher_retrying_$$"
  mkdir -p "$mock/.iterm2"
  printf '#!/bin/bash\necho "DISPLAYED:${@: -1}"\n' > "$mock/.iterm2/imgcat"
  cat > "$mock/tmux" <<'STUB'
#!/bin/bash
[ "$1" = "display-message" ] && { echo "200 50"; exit 0; }
exit 0
STUB
  chmod +x "$mock/.iterm2/imgcat" "$mock/tmux"
  local wd
  wd=$(HOME="$mock" PATH="$mock:$PATH" TMUX="fake,1,0" TMUX_PANE="%0" \
       LC_TERMINAL="iTerm2" TERM_PROGRAM="iTerm.app" \
       bash -c "source '$DISPLAY_SH'; display_pane_open")
  [[ -f "$wd/watcher.sh" ]] || { echo "no watcher.sh at '$wd'"; return 1; }

  printf 'xai\tquerying\t\tgrok\t\nxai\tretrying\t2/3\tgrok\t\n' > "$wd/status"
  ( sleep 1; touch "$wd/.done" ) &
  local output
  output=$(HOME="$mock" PATH="$mock:$PATH" timeout 10 bash "$wd/watcher.sh" "$wd" </dev/null 2>&1)
  [[ "$output" == *"xai"*"(retry 2/3)"* ]] || {
    echo "spinner line lacks the retry label:"
    echo "$output"
    return 1
  }
  rm -rf "$mock"
}
```

- [ ] **Step 7: Run it to see it fail**

Run: `unset TMUX TMUX_PANE; bats tests/pane_layout.bats -f "retrying provider"`
Expected: `not ok`, "spinner line lacks the retry label".

- [ ] **Step 8: Teach `draw_loading` about `retrying`**

In the watcher heredoc, `draw_loading` currently collects pending providers with:

```bash
    local pending=() p __state
    for p in $seen_providers; do
        map_get __state provider_state "$p"
        [[ "$__state" == "querying" ]] && pending+=("$p")
    done
```

Change the condition to include `retrying`:

```bash
        [[ "$__state" == "querying" || "$__state" == "retrying" ]] && pending+=("$p")
```

And where each pending name is colored:

```bash
        printf -v chunk '\033[1;38;2;%sm%s\033[0m' "$_spinner" "$p"
        list+="$chunk"
```

becomes:

```bash
        map_get __state provider_state "$p"
        local __label="$p"
        if [[ "$__state" == "retrying" ]]; then
            map_get __attempt provider_timing "$p"
            __label="$p (retry ${__attempt})"
        fi
        printf -v chunk '\033[1;38;2;%sm%s\033[0m' "$_spinner" "$__label"
        list+="$chunk"
```

Declare `__attempt` in the function's `local` line: `local list="" first=1 _bg _fg _accent _spinner chunk __label __attempt`.

The `retrying` status row stores `2/3` in the timing map; `build_banner_line` only formats the timing for `complete`, whose row carries a fresh numeric elapsed, so the fraction never reaches a banner.

- [ ] **Step 9: Run the test and the suite**

Run: `unset TMUX TMUX_PANE; bats tests/pane_layout.bats -f "retrying provider"` then `unset TMUX TMUX_PANE; bats tests/`
Expected: all `ok`.

- [ ] **Step 10: Update the docs**

- `README.md`: in the provider comparison or a new short "Retries" paragraph under the run-all section: transient API errors (429 and 5xx, and network failures) are retried three times with a doubling delay; `IMAGE_MAX_RETRIES` and `IMAGE_RETRY_DELAY` tune it; the pane's spinner shows `(retry 2/3)`.
- `skills/image-generation/SKILL.md`: one line in the environment variables table for the two knobs.
- Add `retry.sh` to README's file table: `| Retry helper | scripts/retry.sh | curl_with_retry for transient API failures |`.

- [ ] **Step 11: Commit**

```bash
git add scripts/gemini.sh scripts/openai.sh scripts/xai.sh scripts/openrouter.sh scripts/display.sh tests/edit_payload.bats tests/pane_layout.bats README.md skills/image-generation/SKILL.md
git commit -m "Retry transient API failures in every provider

The four providers call curl through curl_with_retry, so a 429 or 5xx is
tried again before it becomes an error. Each retry writes a retrying
status that the spinner shows as (retry 2/3), and a provider that still
fails says how many retries it made."
```

---

### Task 6: run-all offers a retry and re-forks the failed providers

**Files:**
- Modify: `scripts/run-all.sh` (the fork loop and the `wait` loop, lines 95-135)
- Test: `tests/run-all.bats`

**Interfaces:**
- Consumes: pane directory layout (`DISPLAY_PANE_DIR`, `.done`).
- Produces: `retry-offer` file (line 1: seconds, then one failed provider name per line), written atomically; consumes `.retry` (the watcher renames `retry-offer` to it). `DISPLAY_PANE_RETRY_WAIT` (default 45, 0 disables). `spawn_named <provider>` forks one provider with the batch's arguments.

- [ ] **Step 1: Write the failing tests**

Append to `tests/run-all.bats`:

```bash
# stub_flaky_provider <name> — fails with exit 1 on its first call, succeeds after.
stub_flaky_provider() {
  local name="$1"
  cat > "$WORK_DIR/${name}.sh" <<'STUB'
#!/bin/bash
d="$(dirname "$0")"
printf '%s\n' "$@" >> "$d/NAME.argv"
n=$(cat "$d/NAME.calls" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$d/NAME.calls"
[ "$n" -eq 1 ] && { echo "NAME: boom" >&2; exit 1; }
exit 0
STUB
  sed -i.bak "s/NAME/${name}/g" "$WORK_DIR/${name}.sh"
  rm -f "$WORK_DIR/${name}.sh.bak"
  chmod +x "$WORK_DIR/${name}.sh"
}

# A pane dir the way display_pane_attach_or_open would hand one over, without tmux.
fake_pane() {
  PANE="$WORK_DIR/pane"
  mkdir -p "$PANE/active" "$PANE/logs"
  export DISPLAY_PANE_DIR="$PANE"
}

@test "run-all offers a retry naming only the providers that failed, then withdraws it" {
  stub_provider gemini
  stub_flaky_provider xai
  fake_pane
  # Watch for the offer and keep a copy; nobody answers it, so it must expire.
  ( for i in $(seq 1 50); do
      if [[ -f "$PANE/retry-offer" ]]; then cp "$PANE/retry-offer" "$WORK_DIR/offer.copy"; break; fi
      sleep 0.1
    done ) &
  DISPLAY_PANE_RETRY_WAIT=1 run bash "$WORK_DIR/run-all.sh" --mode generate --prompt "p" \
    --output-base "$WORK_DIR/out" --providers gemini,xai
  wait
  assert_status 1
  [[ -f "$WORK_DIR/offer.copy" ]] || { echo "no retry-offer was ever written"; return 1; }
  [[ "$(sed -n 1p "$WORK_DIR/offer.copy")" == "1" ]] || { echo "offer line 1 should be the seconds"; cat "$WORK_DIR/offer.copy"; return 1; }
  [[ "$(sed -n 2p "$WORK_DIR/offer.copy")" == "xai" ]] || { echo "offer should name xai"; cat "$WORK_DIR/offer.copy"; return 1; }
  [[ "$(wc -l < "$WORK_DIR/offer.copy" | tr -d ' ')" -eq 2 ]] || { echo "offer named more than the failed provider"; return 1; }
  [[ ! -f "$PANE/retry-offer" ]] || { echo "offer left behind after the wait"; return 1; }
  [[ "$(cat "$WORK_DIR/xai.calls")" -eq 1 ]] || { echo "xai ran again without an answer"; return 1; }
  # Provider stderr is routed to the pane's log when a pane is live.
  grep -q "xai: boom" "$PANE/logs/xai.err" || { echo "provider stderr missing from the pane log"; return 1; }
}

@test "run-all re-forks exactly the failed providers when the pane answers .retry" {
  stub_provider gemini
  stub_flaky_provider xai
  fake_pane
  # Answer the offer the way the watcher does: rename it to .retry.
  ( for i in $(seq 1 50); do
      if [[ -f "$PANE/retry-offer" ]]; then
        cp "$PANE/retry-offer" "$WORK_DIR/offer.copy"
        mv "$PANE/retry-offer" "$PANE/.retry"; break
      fi
      sleep 0.1
    done ) &
  DISPLAY_PANE_RETRY_WAIT=5 run bash "$WORK_DIR/run-all.sh" --mode generate --prompt "p" \
    --output-base "$WORK_DIR/out" --providers gemini,xai
  assert_status 0
  [[ "$(sed -n 1p "$WORK_DIR/offer.copy")" == "5" ]] || { echo "offer line 1 should be the seconds"; cat "$WORK_DIR/offer.copy"; return 1; }
  [[ "$(sed -n 2p "$WORK_DIR/offer.copy")" == "xai" ]] || { echo "offer should name xai"; cat "$WORK_DIR/offer.copy"; return 1; }
  [[ "$(wc -l < "$WORK_DIR/offer.copy" | tr -d ' ')" -eq 2 ]] || { echo "offer named more than the failed provider"; return 1; }
  [[ "$(cat "$WORK_DIR/xai.calls")" -eq 2 ]] || { echo "xai should have run twice"; return 1; }
  [[ "$(grep -c '^--prompt$' "$WORK_DIR/gemini.argv")" -eq 1 ]] || { echo "gemini must not be re-run"; return 1; }
  # The retried call got the same arguments as the first.
  [[ "$(grep -c '^--prompt$' "$WORK_DIR/xai.argv")" -eq 2 ]] || { echo "retry lacked --prompt"; cat "$WORK_DIR/xai.argv"; return 1; }
}

@test "run-all treats a pane that closed during the offer as no retry" {
  stub_provider gemini
  stub_flaky_provider xai
  fake_pane
  ( for i in $(seq 1 50); do
      if [[ -f "$PANE/retry-offer" ]]; then rm -rf "$PANE"; break; fi
      sleep 0.1
    done ) &
  DISPLAY_PANE_RETRY_WAIT=5 run bash "$WORK_DIR/run-all.sh" --mode generate --prompt "p" \
    --output-base "$WORK_DIR/out" --providers gemini,xai
  assert_status 1
  [[ "$output" != *"No such file"* ]] || { echo "a closed pane must not produce errors:"; echo "$output"; return 1; }
  [[ "$(cat "$WORK_DIR/xai.calls")" -eq 1 ]] || { echo "xai must not be re-run"; return 1; }
}

@test "run-all with DISPLAY_PANE_RETRY_WAIT=0 never writes an offer" {
  stub_flaky_provider xai
  fake_pane
  DISPLAY_PANE_RETRY_WAIT=0 run bash "$WORK_DIR/run-all.sh" --mode generate --prompt "p" \
    --output-base "$WORK_DIR/out" --providers xai
  assert_status 1
  [[ ! -f "$PANE/retry-offer" && ! -f "$PANE/.retry" ]] || { echo "an offer was written with the wait disabled"; return 1; }
}
```

Note: `fake_pane` sets `DISPLAY_PANE_DIR`, so run-all takes the branch where it already has a pane and skips `display_pane_attach_or_open`. Check the top of run-all: it currently always calls `display_pane_attach_or_open`; with `disable_display` (no TMUX) that call fails and `DISPLAY_PANE_DIR` stays as exported. The `if pane_dir=$(...)` branch must not clobber an exported dir. Step 3 handles this.

- [ ] **Step 2: Run them to see them fail**

Run: `unset TMUX TMUX_PANE; bats tests/run-all.bats`
Expected: the four new tests `not ok`. The first three fail on "no retry-offer was ever written" or on the re-fork count; the fourth (`DISPLAY_PANE_RETRY_WAIT=0`) passes already, since nothing writes an offer yet, and stays as the guard for the disable knob.

- [ ] **Step 3: Implement the offer in run-all.sh**

Replace everything from `declare -a pids=()` to the end of the file with:

```bash
# spawn_named <provider> — forks one provider with this batch's arguments. Used for the first
# round and again for a retry, so both rounds are built the same way.
spawn_named() {
  local p="$1" extra args img
  # macOS ships bash 3.2, which has neither ${p^^} nor associative arrays, so the
  # per-provider extras are selected by name rather than an uppercased indirect lookup.
  case "$p" in
    gemini)     extra="$GEMINI_EXTRA" ;;
    openai)     extra="$OPENAI_EXTRA" ;;
    xai)        extra="$XAI_EXTRA" ;;
    openrouter) extra="$OPENROUTER_EXTRA" ;;
    *) echo "Warning: unknown provider '$p' (skipping)" >&2; return 1 ;;
  esac
  args=(--mode "$MODE" --prompt "$PROMPT" --output "${OUTPUT_BASE}-${p}.png")
  if [[ "$MODE" == "edit" && ${#INPUT_IMAGES[@]} -gt 0 ]]; then
    for img in "${INPUT_IMAGES[@]}"; do
      args+=(--input-image "$img")
    done
  fi
  # ${arr[@]+"${arr[@]}"} expands to nothing when the array is empty, which bash 3.2
  # otherwise reports as an unbound variable under `set -u`.
  [[ -n "$extra" ]] && read -ra extra_arr <<<"$extra" && args+=(${extra_arr[@]+"${extra_arr[@]}"})
  spawn_provider "$p" "${SCRIPT_DIR}/${p}.sh" "${args[@]}"
}

# run_round <provider>... — forks the named providers, waits for all, and leaves the names of
# those that exited non-zero in FAILED. Returns 1 when any failed.
run_round() {
  local -a names=() pids=()
  local p pid i
  FAILED=()
  for p in "$@"; do
    spawn_named "$p" || continue
    names+=("$p")
    pids+=($!)
  done
  i=0
  for pid in ${pids[@]+"${pids[@]}"}; do
    wait "$pid" || FAILED+=("${names[$i]}")
    i=$((i + 1))
  done
  [[ ${#FAILED[@]} -eq 0 ]]
}

# offer_retry — when a provider failed and the pane is live, writes retry-offer (seconds, then
# one failed name per line) and waits for the watcher to answer. Returns 0 only when the pane
# asked for a retry (.retry appeared). The offer expiring, the file vanishing, or the whole
# directory going away (the pane was closed) all mean no retry and must not be errors.
offer_retry() {
  local wait="${DISPLAY_PANE_RETRY_WAIT:-45}" dir="${DISPLAY_PANE_DIR:-}"
  [[ ${#FAILED[@]} -gt 0 ]] || return 1
  [[ "$wait" =~ ^[0-9]+$ && $wait -gt 0 ]] || return 1
  [[ -n "$dir" && -d "$dir" ]] || return 1
  { printf '%s\n' "$wait"; printf '%s\n' "${FAILED[@]}"; } > "$dir/.retry-offer.tmp" 2>/dev/null || return 1
  mv -f "$dir/.retry-offer.tmp" "$dir/retry-offer" 2>/dev/null || return 1
  local deadline=$((SECONDS + wait))
  while [[ $SECONDS -lt $deadline ]]; do
    [[ -d "$dir" ]] || return 1
    if [[ -f "$dir/.retry" ]]; then
      rm -f "$dir/.retry"
      return 0
    fi
    [[ -f "$dir/retry-offer" ]] || return 1
    sleep 0.2
  done
  rm -f "$dir/retry-offer" 2>/dev/null
  return 1
}

IFS=',' read -ra provider_list <<< "$PROVIDERS"
for i in "${!provider_list[@]}"; do
  provider_list[$i]="${provider_list[$i]// /}"
done

declare -a FAILED=()
overall_status=0
run_round "${provider_list[@]}" || overall_status=1

# One offer per run: a provider that fails its retry simply shows its error.
if [[ $overall_status -eq 1 ]] && offer_retry; then
  overall_status=0
  run_round "${FAILED[@]}" || overall_status=1
fi

if [[ -n "${DISPLAY_PANE_DIR:-}" ]]; then
  __pane_release run-all
fi

exit "$overall_status"
```

Also change the pane join at the top of run-all so an inherited `DISPLAY_PANE_DIR` is kept:

```bash
if [[ -z "${DISPLAY_PANE_DIR:-}" ]] && pane_dir=$(display_pane_attach_or_open 2>/dev/null); then
  export DISPLAY_PANE_DIR="$pane_dir"
  mkdir -p "$DISPLAY_PANE_DIR/logs"
  __pane_acquire run-all
fi
```

With an inherited dir there is no token, so `__pane_release` returns at once (it checks `__PANE_SELF_ATTACHED`), which is what the tests' fake pane wants.

- [ ] **Step 4: Run the run-all tests**

Run: `unset TMUX TMUX_PANE; bats tests/run-all.bats`
Expected: all `ok`.

- [ ] **Step 5: Run the whole suite**

Run: `unset TMUX TMUX_PANE; bats tests/`
Expected: all `ok`. `tests/shared_pane.bats` exercises run-all's pane join and release; both must still pass with the guarded join.

- [ ] **Step 6: Commit**

```bash
git add scripts/run-all.sh tests/run-all.bats
git commit -m "Let run-all offer a retry of the providers that failed

After the first round, run-all writes retry-offer into the pane with the
failed names and waits up to DISPLAY_PANE_RETRY_WAIT seconds. A .retry
from the watcher re-forks exactly those providers once, with the same
arguments. The offer expiring or the pane closing means no retry."
```

---

### Task 7: The watcher shows the offer and answers it

**Files:**
- Modify: `scripts/display.sh` (watcher heredoc: new `retry_offer_prompt`, a check in the main loop, `rendered` reset)
- Modify: `README.md`, `skills/image-generation/SKILL.md`, `agents/image-generator.md`, `commands/generate-image.md`
- Test: `tests/pane_layout.bats`

**Interfaces:**
- Consumes: `retry-offer` file format from Task 6; `read_key`, `prompt_line`, `pane_cols`, `reflow_to` from Task 3; `rendered` map.
- Produces: `.retry` (rename of `retry-offer`) on `r`; removes `retry-offer` on timeout; exits (and so removes the directory) on Esc or Ctrl-D.

- [ ] **Step 1: Write the failing tests**

Append to `tests/pane_layout.bats`:

```bash
# Watcher dir with an xai error already drawn, and a retry-offer naming xai.
make_offer_watcher() {
  mock="${BATS_TMPDIR}/watcher_offer_$$"
  mkdir -p "$mock/.iterm2"
  printf '#!/bin/bash\necho "DISPLAYED:${@: -1}"\n' > "$mock/.iterm2/imgcat"
  cat > "$mock/tmux" <<'STUB'
#!/bin/bash
[ "$1" = "display-message" ] && { echo "200 50"; exit 0; }
exit 0
STUB
  chmod +x "$mock/.iterm2/imgcat" "$mock/tmux"
  wd=$(HOME="$mock" PATH="$mock:$PATH" TMUX="fake,1,0" TMUX_PANE="%0" \
       LC_TERMINAL="iTerm2" TERM_PROGRAM="iTerm.app" \
       bash -c "source '$DISPLAY_SH'; display_pane_open")
  [[ -f "$wd/watcher.sh" ]] || { echo "no watcher.sh at '$wd'"; return 1; }
  mkdir -p "$wd/errors"
  printf '%s' "xAI API returned HTTP 503" > "$wd/errors/xai.txt"
  printf 'xai\terror\t\tgrok\t\n' > "$wd/status"
  printf '%s\n' 5 xai > "$wd/retry-offer"
}

@test "the watcher shows the retry offer and answers r by renaming it to .retry" {
  local wd mock
  make_offer_watcher
  # After the answer, the retried provider completes and must draw again: its earlier error
  # block does not count as rendered any more.
  ( sleep 2
    printf 'xai\tquerying\t\tgrok\t\n' >> "$wd/status"
    printf 'xai\tcomplete\t900\tgrok\t%s\n' "$OVERSIZED_FIXTURE" >> "$wd/status"
    sleep 1; touch "$wd/.done" ) &
  local output
  output=$( (printf 'r'; sleep 5) | HOME="$mock" PATH="$mock:$PATH" DISPLAY_PANE_TTY=/dev/null \
           timeout 20 bash "$wd/watcher.sh" "$wd" 2>&1)
  [[ "$output" == *"[r] retry failed (xai)"* ]] || { echo "offer prompt missing:"; echo "$output"; return 1; }
  [[ "$output" == *"DISPLAYED:"* ]] || { echo "retried provider's image never drew:"; echo "$output"; return 1; }
  rm -rf "$mock"
}

@test "the watcher answers r by renaming the offer before anything else" {
  local wd mock
  make_offer_watcher
  # No .done: the watcher is killed by timeout after the check; the poller records .retry.
  ( for i in $(seq 1 40); do [[ -f "$wd/.retry" ]] && { echo yes > "$mock/seen"; break; }; sleep 0.1; done ) &
  (printf 'r'; sleep 3) | HOME="$mock" PATH="$mock:$PATH" DISPLAY_PANE_TTY=/dev/null \
     timeout 4 bash "$wd/watcher.sh" "$wd" >/dev/null 2>&1 || true
  wait
  [[ -f "$mock/seen" ]] || { echo "r did not produce .retry"; return 1; }
  rm -rf "$mock" "$wd"
}

@test "the watcher lets the offer expire and carries on to the close prompt" {
  local wd mock
  make_offer_watcher
  printf '%s\n' 1 xai > "$wd/retry-offer"
  ( sleep 3; touch "$wd/.done" ) &
  local output
  output=$( (sleep 6) | HOME="$mock" PATH="$mock:$PATH" DISPLAY_PANE_TTY=/dev/null \
           timeout 20 bash "$wd/watcher.sh" "$wd" 2>&1)
  [[ "$output" == *"[r] retry failed (xai)"* ]] || { echo "offer prompt missing:"; echo "$output"; return 1; }
  [[ "$output" == *"[f]inder [p]review"* ]] || { echo "close prompt never shown after expiry:"; echo "$output"; return 1; }
  rm -rf "$mock"
}

@test "the watcher exits on Esc at the retry offer, taking its directory with it" {
  local wd mock
  make_offer_watcher
  (printf '\033'; sleep 2) | HOME="$mock" PATH="$mock:$PATH" DISPLAY_PANE_TTY=/dev/null \
     timeout 10 bash "$wd/watcher.sh" "$wd" >/dev/null 2>&1 || true
  [[ ! -d "$wd" ]] || { echo "watcher directory still exists after Esc"; return 1; }
  rm -rf "$mock"
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `unset TMUX TMUX_PANE; bats tests/pane_layout.bats -f "retry offer\|answers r\|offer expire\|Esc at the retry"`
Expected: all four `not ok` (no prompt text; `.retry` never appears; Esc is ignored while the loop waits for `.done`).

- [ ] **Step 3: Add the offer prompt to the watcher heredoc**

Move `_esc=$(printf '\033')`, `prompt_line`, and `read_key` (from Task 3) up so they sit before the main `while true; do` loop, since the offer prompt runs inside it. Then add, after `read_key`:

```bash
# retry_offer_prompt — shows the producer's offer (retry-offer: seconds it stays open, then one
# failed provider per line) with a countdown, and answers it. r renames the file to .retry, which
# run-all reads as "yes"; Esc or end of input closes the pane; running out of time removes the
# offer, which run-all reads as "no". The failed providers' rendered flags are reset on r so
# their next complete or error draws a fresh block.
retry_offer_prompt() {
    local seconds names="" line remaining deadline __k p
    { read -r seconds; while IFS= read -r line || [[ -n "$line" ]]; do
        names="${names:+$names, }$line"; done; } < "$WATCH/retry-offer" 2>/dev/null || return 0
    [[ "$seconds" =~ ^[0-9]+$ ]] || seconds=45
    deadline=$((SECONDS + seconds))
    while [[ -f "$WATCH/retry-offer" && ! -f "$WATCH/.done" ]]; do
        remaining=$((deadline - SECONDS))
        if [[ $remaining -le 0 ]]; then
            rm -f "$WATCH/retry-offer"
            break
        fi
        printf '\r\033[K\033[2m[r] retry failed (%s) · [esc/ctrl-d] close  %ds\033[0m ' "$names" "$remaining"
        read_key __k
        case $? in
            0)
                if [ "$__k" = "r" ] || [ "$__k" = "R" ]; then
                    if mv -f "$WATCH/retry-offer" "$WATCH/.retry" 2>/dev/null; then
                        for p in $names; do
                            map_set rendered "${p%,}" ""
                        done
                        break
                    fi
                elif [ "$__k" = "$_esc" ]; then
                    exit 0
                fi
                ;;
            1)
                if __cols=$(pane_cols) && reflow_to "$__cols"; then :; fi
                ;;
            *) exit 0 ;;
        esac
    done
    printf '\r\033[K'
}
```

In the main loop, just before the width check added in Task 2, add:

```bash
    [[ -f "$WATCH/retry-offer" && ! -f "$WATCH/.done" ]] && retry_offer_prompt
```

The `rendered` reset: `map_set rendered "$p" ""` stores an empty string, and the status loop's `[[ -n "$already_rendered" ]] && continue` treats empty as not rendered, so the provider's next `complete` or `error` row draws again.

- [ ] **Step 4: Run the four tests, then the suite**

Run: `unset TMUX TMUX_PANE; bats tests/pane_layout.bats` then `unset TMUX TMUX_PANE; bats tests/`
Expected: all `ok`.

- [ ] **Step 5: Update the docs**

- `README.md`, run-all section: a paragraph that a failed provider shows its error under a red `✗ provider error` heading, and when any provider failed the pane offers `[r] retry failed (xai) · [esc/ctrl-d] close 45s`; `r` re-runs only those providers inside the same run, Esc closes the pane and the run returns with what it has; `DISPLAY_PANE_RETRY_WAIT` (default 45, 0 disables) is how long the offer stays open, and a run with a failure can take that much longer plus one provider round.
- `skills/image-generation/SKILL.md`: the same in two sentences under the parallel-generation section, plus `DISPLAY_PANE_RETRY_WAIT` in the environment table.
- `agents/image-generator.md` and `commands/generate-image.md`: one sentence each where run-all is described: when a provider fails the pane offers a retry for up to 45 seconds, so the call can return later than the slowest provider.

- [ ] **Step 6: Commit**

```bash
git add scripts/display.sh tests/pane_layout.bats README.md skills/image-generation/SKILL.md agents/image-generator.md commands/generate-image.md
git commit -m "Offer a retry of failed providers from the pane

When run-all writes retry-offer, the watcher shows the failed names with
a countdown. r renames the offer to .retry and resets those providers so
their next result draws again; Esc closes the pane; running out of time
removes the offer. Documented the extra wait in the agent and command."
```

- [ ] **Step 7: Ask Alex to verify slices 2 and 3 visually**

Run the real four-provider batch with one provider forced to fail: `XAI_API_KEY=bogus bash scripts/run-all.sh --mode generate --prompt "a flat vector icon of a potted succulent" --output-base <scratchpad>/retrytest --providers gemini,xai`. Expected by eye: xai's red error block with the 401 text, the offer line counting down, and after `r` (with the real key exported by then, or leave it bogus to see the second error) a fresh xai block. Record what Alex saw in the narrative.
