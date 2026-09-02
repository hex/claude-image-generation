#!/usr/bin/env bats
# ABOUTME: Tests streaming-pane orientation detection and display-image normalization.
# ABOUTME: Normalization forces every provider image to one on-screen size regardless of format.

load test_helper

DISPLAY_SH="${PLUGIN_ROOT}/scripts/display.sh"
OVERSIZED_FIXTURE="${PLUGIN_ROOT}/tests/fixtures/oversized.png"

setup() {
  isolate_tmpdir
}

teardown() {
  cleanup_tmpdir
}

@test "pane_orientation classifies wide vs tall by the 2x cell-aspect threshold" {
  source "$DISPLAY_SH"
  # Terminal cells are ~2x taller than wide, so a pane reads as visually wide only once its
  # column count reaches twice its row count. Expected values are derived from that rule, not
  # recomputed by calling the function.
  # cols rows expected
  local cases=(
    "80 24 wide"
    "200 20 wide"
    "100 50 wide"
    "99 50 tall"
    "48 70 tall"
    "30 60 tall"
  )
  local c cols rows want got
  for c in "${cases[@]}"; do
    read -r cols rows want <<<"$c"
    got=$(pane_orientation "$cols" "$rows")
    [[ "$got" == "$want" ]] || {
      echo "pane_orientation $cols $rows = '$got', want '$want'"
      return 1
    }
  done
}

@test "pane_parse_status_line keeps an empty timing field from swallowing the path" {
  source "$DISPLAY_SH"
  # A completed provider whose elapsed-time field is empty. A whitespace-IFS read collapses the
  # double tab, so the model would land in the timing slot and the image path in the model slot,
  # leaving path empty -- the pane then shows the raw path as a banner and never renders the image.
  # Expected fields come from the known input, not from re-running the split.
  local line
  line=$(printf 'xai\tcomplete\t\tmascot-xai\t/tmp/coffee-xai.png')
  local provider state ms model path
  { IFS= read -r provider; IFS= read -r state; IFS= read -r ms; IFS= read -r model; IFS= read -r path; } \
    < <(pane_parse_status_line "$line")
  [[ "$provider" == "xai" ]]              || { echo "provider='$provider' want 'xai'"; return 1; }
  [[ "$state" == "complete" ]]            || { echo "state='$state' want 'complete'"; return 1; }
  [[ -z "$ms" ]]                          || { echo "ms='$ms' want empty"; return 1; }
  [[ "$model" == "mascot-xai" ]]          || { echo "model='$model' want 'mascot-xai'"; return 1; }
  [[ "$path" == "/tmp/coffee-xai.png" ]]  || { echo "path='$path' want '/tmp/coffee-xai.png'"; return 1; }
}

@test "the watcher renders a completed image even when the timing field is empty" {
  local mock="${BATS_TMPDIR}/watcher_empty_ms_$$"
  mkdir -p "$mock/.iterm2"
  # Stub imgcat announces it was asked to display something; reaching it proves the path parsed.
  printf '#!/bin/bash\necho "DISPLAYED:${@: -1}"\n' > "$mock/.iterm2/imgcat"
  # tmux stub reports wide dims and swallows split-window, so display_pane_open only builds files.
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

  # A completed provider whose elapsed-time field is empty, pointing at a real image. The empty
  # field is what a whitespace-IFS read collapses, stranding the path and blanking the pane.
  printf 'xai\tcomplete\t\tmascot-xai\t%s\n' "$OVERSIZED_FIXTURE" > "$wd/status"
  touch "$wd/.done"

  local output
  output=$(HOME="$mock" PATH="$mock:$PATH" timeout 10 bash "$wd/watcher.sh" "$wd" </dev/null 2>&1)
  [[ "$output" == *"DISPLAYED:"* ]] || {
    echo "watcher never rendered the image (empty timing field swallowed the path):"
    echo "$output"
    return 1
  }
  rm -rf "$mock"
}

@test "the spinner goes silent once an image renders so it can't wipe accumulated images" {
  local mock="${BATS_TMPDIR}/watcher_spinner_$$"
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

  # One provider has finished (its image is on the pane); another is still generating. In tmux
  # control mode every spinner redraw resyncs the pane to tmux's text grid and erases inline
  # images, which live as overlays outside it. So the animated spinner must stay silent for the
  # rest of the run once any image has rendered -- otherwise it wipes the images it sits beneath.
  {
    printf 'xai\tcomplete\t\tmascot-xai\t%s\n' "$OVERSIZED_FIXTURE"
    printf 'openai\tquerying\t\t\t\n'
  } > "$wd/status"
  touch "$wd/.done"

  local output
  output=$(HOME="$mock" PATH="$mock:$PATH" timeout 10 bash "$wd/watcher.sh" "$wd" </dev/null 2>&1)
  [[ "$output" == *"DISPLAYED:"* ]] || { echo "image never rendered: $output"; return 1; }
  [[ "$output" != *"generating"* ]] || {
    echo "spinner drew while an image was displayed (would erase it in control mode):"
    echo "$output"
    return 1
  }
  rm -rf "$mock"
}

@test "normalize_for_display shrinks an oversized image to the display box" {
  command -v sips >/dev/null || skip "sips is a macOS built-in; not available here"
  source "$DISPLAY_SH"
  [[ -f "$OVERSIZED_FIXTURE" ]] || skip "oversized fixture missing"

  local dir="${BATS_TMPDIR}/norm_$$"
  mkdir -p "$dir"
  local dst="$dir/display.jpg"

  run normalize_for_display "$OVERSIZED_FIXTURE" "$dst"
  [[ "$status" -eq 0 ]] || { echo "normalize_for_display failed: $output"; return 1; }
  [[ -f "$dst" ]] || { echo "no display copy produced"; return 1; }

  # The 1024px fixture must come back within the 512px box. The bug is that iTerm2 ignores
  # the requested box for DPI-laden PNGs, so the pixels themselves have to be small.
  local w
  w=$(sips -g pixelWidth "$dst" 2>/dev/null | awk '/pixelWidth/{print $2}')
  [[ "$w" -le 512 ]] || { echo "expected <=512px display copy, got ${w}px"; return 1; }

  # And it must be a JPEG — the format iTerm2 already sizes correctly (no DPI metadata to prefer).
  local fmt
  fmt=$(sips -g format "$dst" 2>/dev/null | awk '/format:/{print $2}')
  [[ "$fmt" == "jpeg" ]] || { echo "expected jpeg display copy, got '$fmt'"; return 1; }
  rm -rf "$dir"
}

@test "normalize_for_display pins DPI so equal-pixel images render the same size" {
  command -v sips >/dev/null || skip "sips is a macOS built-in; not available here"
  source "$DISPLAY_SH"
  [[ -f "$OVERSIZED_FIXTURE" ]] || skip "oversized fixture missing"

  local dir="${BATS_TMPDIR}/norm_dpi_$$"
  mkdir -p "$dir"
  # Two copies of the same image at different DPI, mirroring real providers (Gemini 300, xAI 72).
  # iTerm2 sizes by pixels/DPI, so equal-pixel copies with different DPI render at different sizes.
  cp "$OVERSIZED_FIXTURE" "$dir/lo.png"
  sips -s dpiWidth 300 -s dpiHeight 300 "$OVERSIZED_FIXTURE" --out "$dir/hi.png" >/dev/null 2>&1

  normalize_for_display "$dir/lo.png" "$dir/lo.jpg"
  normalize_for_display "$dir/hi.png" "$dir/hi.jpg"

  local dlo dhi
  dlo=$(sips -g dpiWidth "$dir/lo.jpg" 2>/dev/null | awk '/dpiWidth/{print $2}')
  dhi=$(sips -g dpiWidth "$dir/hi.jpg" 2>/dev/null | awk '/dpiWidth/{print $2}')
  [[ "$dlo" == "$dhi" ]] || { echo "normalized DPI differs: lo=$dlo hi=$dhi"; return 1; }
  rm -rf "$dir"
}

@test "normalize_for_display reports failure when the source is unreadable" {
  command -v sips >/dev/null || skip "sips is a macOS built-in; not available here"
  source "$DISPLAY_SH"
  local dir="${BATS_TMPDIR}/norm_fail_$$"
  mkdir -p "$dir"

  run normalize_for_display "$dir/does-not-exist.png" "$dir/out.jpg"
  [[ "$status" -ne 0 ]] || { echo "expected non-zero status for missing source"; return 1; }
  rm -rf "$dir"
}

# Drives display_pane_open with stubbed pane dimensions and returns the captured
# split-window argument string, so orientation-aware split tests can assert the flag.
_open_pane_with_dims() {
  local dims="$1"
  local mock="${BATS_TMPDIR}/pane_split_$$_$BATS_TEST_NUMBER"
  mkdir -p "$mock/.iterm2"
  printf '#!/bin/bash\nexit 0\n' > "$mock/.iterm2/imgcat"
  local args_file="$mock/split_args"
  cat > "$mock/tmux" <<STUB
#!/bin/bash
if [ "\$1" = "display-message" ]; then
  echo "$dims"
  exit 0
fi
if [ "\$1" = "split-window" ]; then
  printf '%s' "\$*" > "$args_file"
fi
exit 0
STUB
  chmod +x "$mock/.iterm2/imgcat" "$mock/tmux"

  HOME="$mock" PATH="$mock:$PATH" TMUX="fake,1,0" TMUX_PANE="%0" \
    LC_TERMINAL="iTerm2" TERM_PROGRAM="iTerm.app" \
    bash -c "source '$DISPLAY_SH'; display_pane_open >/dev/null"

  cat "$args_file"
  rm -rf "$mock"
}

@test "display_pane_open splits -v on a tall pane" {
  # A tall/narrow pane has spare vertical room, so the streaming pane should be a
  # bottom band (-v) rather than a narrow right-hand sliver. 40x100 is well under the
  # 2x cols>=rows threshold, so pane_orientation classifies it tall.
  local captured
  captured=$(_open_pane_with_dims "40 100")
  [[ "$captured" == *"split-window -v"* ]] || {
    echo "Expected -v split for a tall pane, got: $captured"
    return 1
  }
}

@test "display_pane_open splits -h on a wide pane" {
  # A wide pane has spare horizontal room, so the streaming pane should be a side
  # column (-h). 200x20 clears the 2x threshold, so pane_orientation classifies it wide.
  local captured
  captured=$(_open_pane_with_dims "200 20")
  [[ "$captured" == *"split-window -h"* ]] || {
    echo "Expected -h split for a wide pane, got: $captured"
    return 1
  }
}

@test "the pane render script normalizes the image before displaying it" {
  command -v sips >/dev/null || skip "sips is a macOS built-in; not available here"
  source "$DISPLAY_SH"

  local mock="${BATS_TMPDIR}/render_wire_$$"
  mkdir -p "$mock/.iterm2"
  # Stub imgcat records the path it is asked to display, via HOME so find_imgcat picks it up.
  printf '#!/bin/bash\necho "DISPLAYED:${@: -1}"\n' > "$mock/.iterm2/imgcat"
  printf '#!/bin/bash\necho "%%9"\n' > "$mock/tmux"
  chmod +x "$mock/.iterm2/imgcat" "$mock/tmux"

  export HOME="$mock"
  export PATH="$mock:$PATH"
  export TMUX="fake,1,0"
  export TMUX_PANE="%0"
  export LC_TERMINAL="iTerm2"
  export TERM_PROGRAM="iTerm.app"

  local wd
  wd=$(display_pane_open)
  [[ -f "$wd/render.sh" ]] || { echo "no render.sh"; return 1; }

  run bash "$wd/render.sh" "$OVERSIZED_FIXTURE"
  [[ "$status" -eq 0 ]] || { echo "render.sh failed: $output"; return 1; }
  [[ "$output" == DISPLAYED:* ]] || { echo "stub imgcat was not invoked: $output"; return 1; }
  # The display step must receive a normalized copy, never the raw oversized fixture.
  [[ "$output" != *"oversized.png"* ]] || {
    echo "render displayed the raw fixture instead of a normalized copy: $output"
    return 1
  }
  rm -rf "$mock" "$wd"
}

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

@test "banner and error lines turn auto-wrap off around their text" {
  local mock="${BATS_TMPDIR}/watcher_autowrap_$$"
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

  # A banner or error line wider than the pane would wrap onto a second row, shifting
  # everything below and losing the images already drawn.
  mkdir -p "$wd/errors"
  printf '%s' "xAI API returned HTTP 429: rate limited" > "$wd/errors/xai.txt"
  {
    printf 'gemini\tcomplete\t\tgemini\t%s\n' "$OVERSIZED_FIXTURE"
    printf 'xai\terror\t\tgrok-imagine-image-pro\t\n'
  } > "$wd/status"
  touch "$wd/.done"

  local output
  output=$(HOME="$mock" PATH="$mock:$PATH" timeout 10 bash "$wd/watcher.sh" "$wd" </dev/null 2>&1)

  local esc=$'\033'
  [[ "$output" == *"${esc}[?7l${esc}[1;38;2;"* ]] || {
    echo "banner text was never wrapped in an auto-wrap-off guard:"
    echo "$output"
    return 1
  }
  [[ "$output" == *"${esc}[?7l"*"✗ xai error"* ]] || {
    echo "error heading was never wrapped in an auto-wrap-off guard:"
    echo "$output"
    return 1
  }

  local opens closes
  opens=$(grep -oF "${esc}[?7l" <<<"$output" | wc -l | tr -d ' ')
  closes=$(grep -oF "${esc}[?7h" <<<"$output" | wc -l | tr -d ' ')
  [[ "$opens" == "$closes" ]] || {
    echo "mismatched auto-wrap guards: $opens opens vs $closes closes:"
    echo "$output"
    return 1
  }

  [[ "$output" == *"DISPLAYED:"* ]] || { echo "image never rendered: $output"; return 1; }
  [[ "$output" == *"rate limited"* ]] || {
    echo "error text never reached the pane:"
    echo "$output"
    return 1
  }
  rm -rf "$mock"
}

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

  # .done is written after the watcher has had time to see the new width settle. Seven ticks
  # (a fork for stty plus a status parse each) can run slower than 3s on a loaded machine, so
  # the margin here covers that rather than the couple hundred ms this normally takes.
  ( sleep 6; touch "$wd/.done" ) &
  local output
  output=$(HOME="$mock" PATH="$mock:$PATH" DISPLAY_PANE_TTY=/dev/null \
           timeout 20 bash "$wd/watcher.sh" "$wd" </dev/null 2>&1)
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

@test "a redraw keeps the order the blocks were drawn in" {
  local wd mock
  make_resize_watcher
  printf '50 200\n50 200\n50 200\n50 200\n50 200\n50 200\n50 120\n' > "$mock/widths"
  # openai is seen first (its querying row leads) but xai finishes first, so the pane shows
  # xai above openai. The redraw must keep that order, not fall back to first-seen order.
  {
    printf 'openai\tquerying\t\t\t\n'
    printf 'xai\tquerying\t\t\t\n'
    printf 'xai\tcomplete\t900\tgrok\t%s\n' "$OVERSIZED_FIXTURE"
    printf 'openai\tcomplete\t900\tgpt-image-1\t%s\n' "$OVERSIZED_FIXTURE"
  } > "$wd/status"
  ( sleep 6; touch "$wd/.done" ) &
  local output
  output=$(HOME="$mock" PATH="$mock:$PATH" DISPLAY_PANE_TTY=/dev/null \
           timeout 20 bash "$wd/watcher.sh" "$wd" </dev/null 2>&1)
  [[ "$output" == *$'\033[2J\033[3J\033[H'* ]] || { echo "no redraw happened:"; echo "$output"; return 1; }
  # Both providers share one fixture, so the banners are the only thing that tells them apart.
  local rest before_xai before_openai
  rest="${output#*$'\033[2J\033[3J\033[H'}"
  before_xai="${rest%%XAI*}"
  before_openai="${rest%%OPENAI*}"
  [[ ${#before_xai} -lt ${#before_openai} ]] || {
    echo "redraw put OPENAI before XAI; the pane had drawn xai first:"
    echo "$rest"
    return 1
  }
  rm -rf "$mock"
}

@test "the dismiss prompt reflows on a resize and still closes on end of input" {
  local wd mock
  make_resize_watcher
  # Same width for the single live tick and the first prompt second; then 120 for good. The
  # prompt polls once a second, so the four-tick settle lands around the fifth second, well
  # before the pipe closes at nine.
  printf '50 200\n50 200\n50 120\n' > "$mock/widths"
  printf 'xai\tcomplete\t4210\tmascot-xai\t%s\n' "$OVERSIZED_FIXTURE" > "$wd/status"
  touch "$wd/.done"

  # A pipe that stays open for nine seconds with no data: read -t 1 times out at the prompt
  # (a real tick, so the width is checked), then end of input arrives and the prompt must exit.
  local output
  output=$( (sleep 9) | HOME="$mock" PATH="$mock:$PATH" DISPLAY_PANE_TTY=/dev/null \
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

@test "the spinner line turns auto-wrap off while it draws and back on after" {
  local mock="${BATS_TMPDIR}/watcher_wrap_$$"
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

  # Four providers make a spinner line wider than a narrow pane. Without auto-wrap off, the
  # line wraps, every tick starts a new row, and the growing stack scrolls the images away.
  printf 'openai\tquerying\t\t\t\nxai\tquerying\t\t\t\ngemini\tquerying\t\t\t\nopenrouter\tquerying\t\t\t\n' > "$wd/status"
  ( sleep 1; touch "$wd/.done" ) &
  local output
  output=$(HOME="$mock" PATH="$mock:$PATH" timeout 10 bash "$wd/watcher.sh" "$wd" </dev/null 2>&1)
  [[ "$output" == *$'\033[?7l'*generating*$'\033[?7h'* ]] || {
    echo "spinner line is not bracketed by auto-wrap off and on:"
    echo "$output"
    return 1
  }
  local off on
  off=$(printf '%s' "$output" | grep -oF -e $'\033[?7l' | wc -l | tr -d ' ')
  on=$(printf '%s' "$output" | grep -oF -e $'\033[?7h' | wc -l | tr -d ' ')
  [[ "$off" -eq "$on" ]] || { echo "auto-wrap turned off $off times but on $on times"; return 1; }
  rm -rf "$mock"
}

# Watcher dir with an xai error already drawn, and a retry-offer naming xai. The stty stub
# reads widths like make_resize_watcher's; with no $mock/widths file it fails and the watcher
# never sees a width, so tests that don't resize are unaffected.
make_offer_watcher() {
  mock="${BATS_TMPDIR}/watcher_offer_$$"
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

@test "the watcher resets rendered for every provider named in a multi-provider retry offer" {
  local wd mock
  mock="${BATS_TMPDIR}/watcher_offer_multi_$$"
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
  printf '%s' "OpenAI API returned HTTP 503" > "$wd/errors/openai.txt"
  printf 'xai\terror\t\tgrok\t\nopenai\terror\t\tgpt-image-1\t\n' > "$wd/status"
  printf '%s\n' 5 xai openai > "$wd/retry-offer"

  # Both retried providers complete and must draw again: neither one's earlier error block
  # counts as rendered any more, not just the first name in the offer.
  ( sleep 2
    printf 'xai\tquerying\t\tgrok\t\n' >> "$wd/status"
    printf 'openai\tquerying\t\tgpt-image-1\t\n' >> "$wd/status"
    printf 'xai\tcomplete\t900\tgrok\t%s\n' "$OVERSIZED_FIXTURE" >> "$wd/status"
    printf 'openai\tcomplete\t900\tgpt-image-1\t%s\n' "$OVERSIZED_FIXTURE" >> "$wd/status"
    sleep 1; touch "$wd/.done" ) &
  local output
  output=$( (printf 'r'; sleep 5) | HOME="$mock" PATH="$mock:$PATH" DISPLAY_PANE_TTY=/dev/null \
           timeout 20 bash "$wd/watcher.sh" "$wd" 2>&1)
  [[ "$output" == *"[r] retry failed (xai, openai)"* ]] || { echo "offer prompt missing both providers:"; echo "$output"; return 1; }
  local n
  n=$(printf '%s' "$output" | grep -c 'DISPLAYED:')
  [[ "$n" -eq 2 ]] || {
    echo "expected both retried providers to draw, got $n:"
    echo "$output"
    return 1
  }
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
  # run-all reads a missing retry-offer as "no": confirm the watcher actually removes it on
  # timeout, not just that the close prompt eventually shows for some other reason. Polls
  # while the watch dir is still there so a removal after the watcher has already exited
  # doesn't count.
  ( for i in $(seq 1 60); do
      [[ -d "$wd" ]] || break
      [[ -f "$wd/retry-offer" ]] || { echo yes > "$mock/offer_removed"; break; }
      sleep 0.1
    done ) &
  local output
  output=$( (sleep 6) | HOME="$mock" PATH="$mock:$PATH" DISPLAY_PANE_TTY=/dev/null \
           timeout 20 bash "$wd/watcher.sh" "$wd" 2>&1)
  [[ "$output" == *"[r] retry failed (xai)"* ]] || { echo "offer prompt missing:"; echo "$output"; return 1; }
  [[ "$output" == *"[f]inder [p]review"* ]] || { echo "close prompt never shown after expiry:"; echo "$output"; return 1; }
  wait
  [[ -f "$mock/offer_removed" ]] || { echo "retry-offer was not removed on expiry"; return 1; }
  rm -rf "$mock"
}

@test "the retry offer does not tick once an image is on the pane" {
  local wd mock
  make_offer_watcher
  # A completed provider ahead of the error puts an image on the pane before the offer shows.
  # Every rewrite of the offer line would erase that image, so the line must print once,
  # with the time budget in place of a countdown.
  printf 'gemini\tcomplete\t900\tgemini\t%s\nxai\terror\t\tgrok\t\n' "$OVERSIZED_FIXTURE" > "$wd/status"
  printf '%s\n' 4 xai > "$wd/retry-offer"
  ( sleep 7; touch "$wd/.done" ) &
  local output n
  output=$( (sleep 9) | HOME="$mock" PATH="$mock:$PATH" DISPLAY_PANE_TTY=/dev/null \
           timeout 20 bash "$wd/watcher.sh" "$wd" 2>&1)
  [[ "$output" == *"DISPLAYED:"* ]] || { echo "image never drew:"; echo "$output"; return 1; }
  n=$(printf '%s' "$output" | grep -oF '[r] retry failed (xai)' | wc -l | tr -d ' ')
  [[ "$n" -eq 1 ]] || { echo "offer line printed $n times, want 1:"; echo "$output"; return 1; }
  [[ "$output" == *"(up to 4s)"* ]] || { echo "offer line lacks the time budget:"; echo "$output"; return 1; }
  rm -rf "$mock"
}

@test "the static retry offer is reprinted after a resize redraw" {
  local wd mock
  make_offer_watcher
  # An image is up before the offer shows, so the offer line prints once and stays static. A
  # resize during the offer clears the pane; the line has to come back after the redraw.
  printf 'gemini\tcomplete\t900\tgemini\t%s\nxai\terror\t\tgrok\t\n' "$OVERSIZED_FIXTURE" > "$wd/status"
  printf '%s\n' 10 xai > "$wd/retry-offer"
  # Two prompt seconds at 200 (the first only records the width), then 120 for good: the
  # four-tick settle lands on the sixth tick. A tick runs a little over a second on a loaded
  # machine and $SECONDS moves in whole seconds, so the offer is given four spare ticks; were
  # it to expire first, the settle would land in the main loop with no offer line to reprint.
  printf '50 200\n50 200\n50 120\n' > "$mock/widths"
  ( sleep 12; touch "$wd/.done" ) &
  local output n clears
  output=$( (sleep 13) | HOME="$mock" PATH="$mock:$PATH" DISPLAY_PANE_TTY=/dev/null \
           timeout 30 bash "$wd/watcher.sh" "$wd" 2>&1)
  clears=$(printf '%s' "$output" | grep -oF -e $'\033[2J\033[3J\033[H' | wc -l | tr -d ' ')
  [[ "$clears" -eq 1 ]] || { echo "expected one redraw, got $clears:"; echo "$output"; return 1; }
  n=$(printf '%s' "$output" | grep -oF '[r] retry failed (xai)' | wc -l | tr -d ' ')
  [[ "$n" -eq 2 ]] || { echo "offer line printed $n times, want 2 (before and after the redraw):"; echo "$output"; return 1; }
  rm -rf "$mock"
}

@test "the retry offer counts down while no image is on the pane" {
  local wd mock
  make_offer_watcher
  printf '%s\n' 4 xai > "$wd/retry-offer"
  ( sleep 7; touch "$wd/.done" ) &
  local output n distinct
  output=$( (sleep 9) | HOME="$mock" PATH="$mock:$PATH" DISPLAY_PANE_TTY=/dev/null \
           timeout 20 bash "$wd/watcher.sh" "$wd" 2>&1)
  n=$(printf '%s' "$output" | grep -oF '[r] retry failed (xai)' | wc -l | tr -d ' ')
  [[ "$n" -ge 3 ]] || { echo "offer line printed $n times, want at least 3:"; echo "$output"; return 1; }
  # A tick can land just past a second boundary and skip one value, so the check is for
  # distinct remaining values rather than specific ones.
  distinct=$(printf '%s' "$output" | grep -oE 'close  [0-9]+s' | sort -u | wc -l | tr -d ' ')
  [[ "$distinct" -ge 2 ]] || { echo "countdown never moved ($distinct distinct values):"; echo "$output"; return 1; }
  [[ "$output" != *"(up to"* ]] || { echo "time budget shown instead of a countdown:"; echo "$output"; return 1; }
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

@test "the retry offer line turns auto-wrap off while it draws and back on after" {
  local wd mock
  make_offer_watcher
  printf '%s\n' 2 xai > "$wd/retry-offer"
  ( sleep 4; touch "$wd/.done" ) &
  local output
  output=$( (sleep 5) | HOME="$mock" PATH="$mock:$PATH" DISPLAY_PANE_TTY=/dev/null \
           timeout 20 bash "$wd/watcher.sh" "$wd" 2>&1)
  [[ "$output" == *$'\033[?7l'*'[r] retry failed (xai)'*$'\033[?7h'* ]] || {
    echo "offer line is not bracketed by auto-wrap off and on:"
    echo "$output"
    return 1
  }
  local off on
  off=$(printf '%s' "$output" | grep -oF -e $'\033[?7l' | wc -l | tr -d ' ')
  on=$(printf '%s' "$output" | grep -oF -e $'\033[?7h' | wc -l | tr -d ' ')
  [[ "$off" -eq "$on" ]] || { echo "auto-wrap turned off $off times but on $on times"; return 1; }
  rm -rf "$mock"
}
