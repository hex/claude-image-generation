#!/usr/bin/env bats
# ABOUTME: Tests streaming-pane orientation detection and display-image normalization.
# ABOUTME: Normalization forces every provider image to one on-screen size regardless of format.

load test_helper

DISPLAY_SH="${PLUGIN_ROOT}/scripts/display.sh"
OVERSIZED_FIXTURE="${PLUGIN_ROOT}/tests/fixtures/oversized.png"

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
