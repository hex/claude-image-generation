# ABOUTME: Bats tests for display.sh multi-protocol terminal image display.
# ABOUTME: Tests iTerm2, Kitty, Sixel detection and tmux pane integration.

setup() {
  load test_helper
  DISPLAY_SH="${PLUGIN_ROOT}/scripts/display.sh"
  # Clear all terminal detection env vars to start clean
  unset TERM_PROGRAM 2>/dev/null || true
  unset LC_TERMINAL 2>/dev/null || true
  unset ITERM_SESSION_ID 2>/dev/null || true
  unset TMUX 2>/dev/null || true
  unset KITTY_WINDOW_ID 2>/dev/null || true
  unset WEZTERM_EXECUTABLE 2>/dev/null || true
  unset SKIP_DISPLAY 2>/dev/null || true
  unset TMUX_PANE 2>/dev/null || true
  unset DISPLAY_PANE_DIR 2>/dev/null || true
  unset DISPLAY_IMAGE_WIDTH 2>/dev/null || true
  unset DISPLAY_IMAGE_HEIGHT 2>/dev/null || true
  # Save and override TERM to prevent false Kitty detection
  ORIG_TERM="${TERM:-}"
  export TERM="xterm-256color"
  # Redirect display output to a temp file for inspection
  DISPLAY_OUTPUT="${BATS_TMPDIR}/display_output_$$"
  export DISPLAY_IMAGE_TARGET="$DISPLAY_OUTPUT"
}

teardown() {
  rm -f "$DISPLAY_OUTPUT" 2>/dev/null || true
  if [[ -n "${ORIG_TERM:-}" ]]; then
    export TERM="$ORIG_TERM"
  fi
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

# --- is_kitty detection ---

@test "display: is_kitty returns true when TERM=xterm-kitty" {
  source "$DISPLAY_SH"
  export TERM="xterm-kitty"
  run is_kitty
  assert_status 0
}

@test "display: is_kitty returns true when TERM_PROGRAM=ghostty" {
  source "$DISPLAY_SH"
  export TERM_PROGRAM="ghostty"
  run is_kitty
  assert_status 0
}

@test "display: is_kitty returns true when TERM_PROGRAM=WezTerm" {
  source "$DISPLAY_SH"
  export TERM_PROGRAM="WezTerm"
  run is_kitty
  assert_status 0
}

@test "display: is_kitty returns false for non-kitty terminals" {
  source "$DISPLAY_SH"
  export TERM="xterm-256color"
  export TERM_PROGRAM="iTerm.app"
  run is_kitty
  assert_status 1
}

# --- is_tmux detection ---

@test "display: is_tmux returns true when TMUX is set" {
  source "$DISPLAY_SH"
  export TMUX="/tmp/tmux-501/default,12345,0"
  run is_tmux
  assert_status 0
}

@test "display: is_tmux returns false when TMUX is unset" {
  source "$DISPLAY_SH"
  unset TMUX 2>/dev/null || true
  run is_tmux
  assert_status 1
}

# --- get_outer_terminal ---

@test "display: get_outer_terminal returns iterm2 for LC_TERMINAL=iTerm2" {
  source "$DISPLAY_SH"
  export LC_TERMINAL="iTerm2"
  run get_outer_terminal
  assert_status 0
  assert_output_contains "iterm2"
}

@test "display: get_outer_terminal returns iterm2 for ITERM_SESSION_ID" {
  source "$DISPLAY_SH"
  export ITERM_SESSION_ID="w0t0p0:SOME-UUID"
  run get_outer_terminal
  assert_status 0
  assert_output_contains "iterm2"
}

@test "display: get_outer_terminal returns kitty for KITTY_WINDOW_ID" {
  source "$DISPLAY_SH"
  export KITTY_WINDOW_ID="1"
  run get_outer_terminal
  assert_status 0
  assert_output_contains "kitty"
}

@test "display: get_outer_terminal returns unknown when nothing detected" {
  source "$DISPLAY_SH"
  unset LC_TERMINAL ITERM_SESSION_ID KITTY_WINDOW_ID 2>/dev/null || true
  run get_outer_terminal
  assert_status 1
  assert_output_contains "unknown"
}

# --- display_image iTerm2 path (non-tmux) ---

@test "display: display_image writes iTerm2 escape sequence" {
  source "$DISPLAY_SH"
  export TERM_PROGRAM="iTerm.app"

  local test_img="${BATS_TMPDIR}/test_img_$$.png"
  printf 'fake-png-data' > "$test_img"

  display_image "$test_img"

  [[ -f "$DISPLAY_OUTPUT" ]]
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

# --- display image size control ---

@test "display: display_image_iterm2 defaults to 512px width and height" {
  source "$DISPLAY_SH"
  export TERM_PROGRAM="iTerm.app"

  local test_img="${BATS_TMPDIR}/test_size_default_$$.png"
  printf 'fake-png-data' > "$test_img"

  display_image "$test_img"

  [[ -f "$DISPLAY_OUTPUT" ]]
  assert_output_contains_file "$DISPLAY_OUTPUT" "width=512px"
  assert_output_contains_file "$DISPLAY_OUTPUT" "height=512px"
}

@test "display: display_image_iterm2 uses DISPLAY_IMAGE_WIDTH and HEIGHT" {
  source "$DISPLAY_SH"
  export TERM_PROGRAM="iTerm.app"
  export DISPLAY_IMAGE_WIDTH=400
  export DISPLAY_IMAGE_HEIGHT=300

  local test_img="${BATS_TMPDIR}/test_size_custom_$$.png"
  printf 'fake-png-data' > "$test_img"

  display_image "$test_img"

  [[ -f "$DISPLAY_OUTPUT" ]]
  assert_output_contains_file "$DISPLAY_OUTPUT" "width=400px"
  assert_output_contains_file "$DISPLAY_OUTPUT" "height=300px"
}

@test "display: display_image_in_pane uses DISPLAY_IMAGE_WIDTH for iTerm2" {
  source "$DISPLAY_SH"
  export TMUX="/tmp/tmux-501/default,12345,0"
  export TMUX_PANE="%0"
  export LC_TERMINAL="iTerm2"
  export DISPLAY_IMAGE_WIDTH=512

  local mock_dir="${BATS_TMPDIR}/mock_size_pane_$$"
  mkdir -p "$mock_dir"
  local args_file="${mock_dir}/tmux_args"
  printf '#!/bin/bash\necho "$@" > "%s"\n' "$args_file" > "$mock_dir/tmux"
  printf '#!/bin/bash\nexit 0\n' > "$mock_dir/imgcat"
  chmod +x "$mock_dir/tmux" "$mock_dir/imgcat"
  export PATH="$mock_dir:$PATH"

  local test_img="${BATS_TMPDIR}/test_size_pane_$$.png"
  printf 'test-data' > "$test_img"

  display_image_in_pane "$test_img"

  [[ -f "$args_file" ]]
  local captured
  captured=$(cat "$args_file")
  [[ "$captured" == *"512px"* ]] || {
    echo "Expected pane command to contain '512px'"
    echo "Actual args: $captured"
    return 1
  }
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

# --- display_image Kitty path (non-tmux) ---

@test "display: display_image writes Kitty escape sequence for xterm-kitty" {
  source "$DISPLAY_SH"
  export TERM="xterm-kitty"

  local test_img="${BATS_TMPDIR}/test_kitty_$$.png"
  printf 'kitty-test-data' > "$test_img"

  display_image "$test_img"

  [[ -f "$DISPLAY_OUTPUT" ]]
  # Kitty protocol uses APC escape with a=T,f=100 metadata
  assert_output_contains_file "$DISPLAY_OUTPUT" "a=T,f=100,"
}

@test "display: display_image writes Kitty escape for Ghostty" {
  source "$DISPLAY_SH"
  export TERM_PROGRAM="ghostty"

  local test_img="${BATS_TMPDIR}/test_ghostty_$$.png"
  printf 'ghostty-data' > "$test_img"

  display_image "$test_img"

  [[ -f "$DISPLAY_OUTPUT" ]]
  assert_output_contains_file "$DISPLAY_OUTPUT" "a=T,f=100,"
}

# --- display_image no-op when no protocol available ---

@test "display: display_image is a no-op when no terminal detected" {
  source "$DISPLAY_SH"
  unset TERM_PROGRAM 2>/dev/null || true
  unset LC_TERMINAL 2>/dev/null || true
  unset TMUX 2>/dev/null || true
  export TERM="xterm-256color"

  local test_img="${BATS_TMPDIR}/test_noop_$$.png"
  printf 'fake-png-data' > "$test_img"

  display_image "$test_img"

  # Output target file should not exist (nothing written)
  [[ ! -f "$DISPLAY_OUTPUT" ]]
}

# --- Protocol priority ---

@test "display: iTerm2 takes priority over Kitty when both detected" {
  source "$DISPLAY_SH"
  # Set both iTerm2 and Kitty indicators
  export TERM_PROGRAM="iTerm.app"
  export TERM="xterm-kitty"

  local test_img="${BATS_TMPDIR}/test_priority_$$.png"
  printf 'priority-test' > "$test_img"

  display_image "$test_img"

  [[ -f "$DISPLAY_OUTPUT" ]]
  # Should use iTerm2 protocol (OSC 1337), not Kitty (APC)
  assert_output_contains_file "$DISPLAY_OUTPUT" "1337;File="
}

# --- display_image_kitty directly ---

@test "display: display_image_kitty sends chunked data with m=0 terminator" {
  source "$DISPLAY_SH"

  local test_img="${BATS_TMPDIR}/test_kitty_chunks_$$.png"
  printf 'small-data' > "$test_img"

  display_image_kitty "$test_img"

  [[ -f "$DISPLAY_OUTPUT" ]]
  # Final chunk should have m=0 to signal end of transmission
  assert_output_contains_file "$DISPLAY_OUTPUT" "m=0;"
}

@test "display: display_image_kitty skips nonexistent file" {
  source "$DISPLAY_SH"

  run display_image_kitty "/tmp/no_such_file_$$.png"
  assert_status 1
}

# --- display_image_sixel directly ---

@test "display: display_image_sixel fails gracefully with nonexistent file" {
  source "$DISPLAY_SH"

  run display_image_sixel "/tmp/no_such_file_$$.png"
  assert_status 1
  assert_output_contains "File not found"
}

# --- display_image_in_pane ---

@test "display: display_image_in_pane fails when not in tmux" {
  source "$DISPLAY_SH"
  unset TMUX 2>/dev/null || true

  run display_image_in_pane "/tmp/some_image.png"
  assert_status 1
  assert_output_contains "Not inside tmux"
}

@test "display: display_image_in_pane fails for nonexistent file" {
  source "$DISPLAY_SH"
  export TMUX="/tmp/tmux-501/default,12345,0"

  run display_image_in_pane "/tmp/no_such_file_$$.png"
  assert_status 1
  assert_output_contains "File not found"
}

# --- Pane targeting ---

@test "display: display_image_in_pane targets TMUX_PANE when set" {
  source "$DISPLAY_SH"
  export TMUX="/tmp/tmux-501/default,12345,0"
  export TMUX_PANE="%42"
  export LC_TERMINAL="iTerm2"

  # Create mock tmux and imgcat in isolated PATH
  local mock_dir="${BATS_TMPDIR}/mock_pane_$$"
  mkdir -p "$mock_dir"
  local args_file="${mock_dir}/tmux_args"
  printf '#!/bin/bash\necho "$@" > "%s"\n' "$args_file" > "$mock_dir/tmux"
  printf '#!/bin/bash\nexit 0\n' > "$mock_dir/imgcat"
  chmod +x "$mock_dir/tmux" "$mock_dir/imgcat"
  export PATH="$mock_dir:$PATH"

  local test_img="${BATS_TMPDIR}/test_pane_target_$$.png"
  printf 'test-data' > "$test_img"

  display_image_in_pane "$test_img"

  [[ -f "$args_file" ]]
  local captured
  captured=$(cat "$args_file")
  [[ "$captured" == *"-t %42"* ]] || {
    echo "Expected tmux args to contain '-t %42'"
    echo "Actual args: $captured"
    return 1
  }
}

# --- SKIP_DISPLAY ---

@test "display: display_image skips when SKIP_DISPLAY=1" {
  source "$DISPLAY_SH"
  export TERM_PROGRAM="iTerm.app"
  export SKIP_DISPLAY="1"

  local test_img="${BATS_TMPDIR}/test_skip_$$.png"
  printf 'test-data' > "$test_img"

  display_image "$test_img"

  # Nothing should be written
  [[ ! -f "$DISPLAY_OUTPUT" ]]
}

# --- display_images (grid) ---

@test "display: display_images returns 0 for empty args" {
  source "$DISPLAY_SH"
  run display_images
  assert_status 0
}

@test "display: display_images delegates to display_image outside tmux" {
  source "$DISPLAY_SH"
  export TERM_PROGRAM="iTerm.app"
  unset TMUX 2>/dev/null || true

  local img1="${BATS_TMPDIR}/grid_a_$$.png"
  local img2="${BATS_TMPDIR}/grid_b_$$.png"
  printf 'data-a' > "$img1"
  printf 'data-b' > "$img2"

  display_images "$img1" "$img2"

  [[ -f "$DISPLAY_OUTPUT" ]]
  # Both images should produce iTerm2 escape sequences
  local content
  content=$(cat "$DISPLAY_OUTPUT")
  local count
  count=$(echo "$content" | grep -o "1337;File=" | wc -l | tr -d ' ')
  [[ "$count" -eq 2 ]] || {
    echo "Expected 2 iTerm2 sequences, got $count"
    return 1
  }
}

@test "display: display_images skips when SKIP_DISPLAY=1" {
  source "$DISPLAY_SH"
  export TERM_PROGRAM="iTerm.app"
  export SKIP_DISPLAY="1"

  local test_img="${BATS_TMPDIR}/test_skip_grid_$$.png"
  printf 'test-data' > "$test_img"

  display_images "$test_img"
  [[ ! -f "$DISPLAY_OUTPUT" ]]
}

@test "display: display_images_in_pane fails when not in tmux" {
  source "$DISPLAY_SH"
  unset TMUX 2>/dev/null || true

  run display_images_in_pane "/tmp/some_image.png"
  assert_status 1
  assert_output_contains "Not inside tmux"
}

@test "display: display_images_in_pane uses 30% pane width" {
  source "$DISPLAY_SH"
  export TMUX="/tmp/tmux-501/default,12345,0"
  export TMUX_PANE="%5"
  export LC_TERMINAL="iTerm2"

  local mock_dir="${BATS_TMPDIR}/mock_grid_full_$$"
  mkdir -p "$mock_dir"
  local args_file="${mock_dir}/tmux_args"
  printf '#!/bin/bash\nprintf "%%s" "$*" > "%s"\n' "$args_file" > "$mock_dir/tmux"
  printf '#!/bin/bash\nexit 0\n' > "$mock_dir/imgcat"
  chmod +x "$mock_dir/tmux" "$mock_dir/imgcat"
  export PATH="$mock_dir:$PATH"

  local img1="${BATS_TMPDIR}/full_a_$$.png"
  printf 'a' > "$img1"

  display_images_in_pane "$img1"

  [[ -f "$args_file" ]]
  local captured
  captured=$(cat "$args_file")
  [[ "$captured" == *"-l 30%"* ]] || {
    echo "Expected -l 30% pane width"
    echo "Actual args: $captured"
    return 1
  }
}

@test "display: display_images_in_pane includes all filenames in command" {
  source "$DISPLAY_SH"
  export TMUX="/tmp/tmux-501/default,12345,0"
  export TMUX_PANE="%5"
  export LC_TERMINAL="iTerm2"

  local mock_dir="${BATS_TMPDIR}/mock_grid_$$"
  mkdir -p "$mock_dir"
  local calls_file="${mock_dir}/tmux_calls"
  printf '#!/bin/bash\necho "$@" >> "%s"\necho "%%%%$((RANDOM %% 100))"\n' "$calls_file" > "$mock_dir/tmux"
  printf '#!/bin/bash\nexit 0\n' > "$mock_dir/imgcat"
  chmod +x "$mock_dir/tmux" "$mock_dir/imgcat"
  export PATH="$mock_dir:$PATH"

  local img1="${BATS_TMPDIR}/fox_$$.png"
  local img2="${BATS_TMPDIR}/cat_$$.png"
  local img3="${BATS_TMPDIR}/dog_$$.png"
  printf 'a' > "$img1"
  printf 'b' > "$img2"
  printf 'c' > "$img3"

  display_images_in_pane "$img1" "$img2" "$img3"

  [[ -f "$calls_file" ]]
  local captured
  captured=$(cat "$calls_file")
  [[ "$captured" == *"fox_"* ]] || { echo "Missing fox in: $captured"; return 1; }
  [[ "$captured" == *"cat_"* ]] || { echo "Missing cat in: $captured"; return 1; }
  [[ "$captured" == *"dog_"* ]] || { echo "Missing dog in: $captured"; return 1; }
}

@test "display: display_images_in_pane skips nonexistent files" {
  source "$DISPLAY_SH"
  export TMUX="/tmp/tmux-501/default,12345,0"
  export TMUX_PANE="%5"
  export LC_TERMINAL="iTerm2"

  local mock_dir="${BATS_TMPDIR}/mock_grid_skip_$$"
  mkdir -p "$mock_dir"
  local args_file="${mock_dir}/tmux_args"
  printf '#!/bin/bash\necho "$@" > "%s"\n' "$args_file" > "$mock_dir/tmux"
  printf '#!/bin/bash\nexit 0\n' > "$mock_dir/imgcat"
  chmod +x "$mock_dir/tmux" "$mock_dir/imgcat"
  export PATH="$mock_dir:$PATH"

  local real_img="${BATS_TMPDIR}/real_img_$$.png"
  printf 'data' > "$real_img"

  display_images_in_pane "/tmp/nonexistent_$$.png" "$real_img"

  [[ -f "$args_file" ]]
  local captured
  captured=$(cat "$args_file")
  [[ "$captured" == *"real_img_"* ]] || { echo "Missing real_img in: $captured"; return 1; }
  [[ "$captured" != *"nonexistent_"* ]] || { echo "Should not contain nonexistent file"; return 1; }
}

# --- multi-image vertical side pane ---

@test "display: display_images_in_pane uses horizontal split for side pane" {
  source "$DISPLAY_SH"
  export TMUX="/tmp/tmux-501/default,12345,0"
  export TMUX_PANE="%5"
  export LC_TERMINAL="iTerm2"

  local mock_dir="${BATS_TMPDIR}/mock_side_$$"
  mkdir -p "$mock_dir"
  local tmux_args_file="${mock_dir}/tmux_args"
  printf '#!/bin/bash\nprintf "%%s" "$*" > "%s"\n' "$tmux_args_file" > "$mock_dir/tmux"
  printf '#!/bin/bash\nexit 0\n' > "$mock_dir/imgcat"
  chmod +x "$mock_dir/tmux" "$mock_dir/imgcat"
  export PATH="$mock_dir:$PATH"

  local img1="${BATS_TMPDIR}/alpha_$$.png"
  local img2="${BATS_TMPDIR}/beta_$$.png"
  printf 'a' > "$img1"
  printf 'b' > "$img2"

  display_images_in_pane "$img1" "$img2"

  [[ -f "$tmux_args_file" ]]
  local captured
  captured=$(cat "$tmux_args_file")
  # Multi-image should use -h (horizontal split = vertical side pane)
  [[ "$captured" == *"split-window -h"* ]] || { echo "Expected -h split for multi-image: $captured"; return 1; }
  # Both filenames should appear (vertical stacking within the pane)
  [[ "$captured" == *"alpha_"* ]] || { echo "Missing alpha in: $captured"; return 1; }
  [[ "$captured" == *"beta_"* ]] || { echo "Missing beta in: $captured"; return 1; }
}

@test "display: display_images_in_pane opens all files in single preview call" {
  source "$DISPLAY_SH"
  export TMUX="/tmp/tmux-501/default,12345,0"
  export TMUX_PANE="%5"
  export LC_TERMINAL="iTerm2"

  local mock_dir="${BATS_TMPDIR}/mock_preview_$$"
  mkdir -p "$mock_dir"
  local args_file="${mock_dir}/tmux_args"
  printf '#!/bin/bash\nprintf "%%s" "$*" > "%s"\n' "$args_file" > "$mock_dir/tmux"
  printf '#!/bin/bash\nexit 0\n' > "$mock_dir/imgcat"
  chmod +x "$mock_dir/tmux" "$mock_dir/imgcat"
  export PATH="$mock_dir:$PATH"

  local img1="${BATS_TMPDIR}/prev_a_$$.png"
  local img2="${BATS_TMPDIR}/prev_b_$$.png"
  local img3="${BATS_TMPDIR}/prev_c_$$.png"
  printf 'a' > "$img1"
  printf 'b' > "$img2"
  printf 'c' > "$img3"

  display_images_in_pane "$img1" "$img2" "$img3"

  [[ -f "$args_file" ]]
  local captured
  captured=$(cat "$args_file")
  # Preview should be a single 'open -a Preview' with all 3 paths, not 3 separate calls
  local preview_count
  preview_count=$(echo "$captured" | grep -o 'open -a Preview' | wc -l | tr -d ' ')
  [[ "$preview_count" -eq 1 ]] || {
    echo "Expected 1 'open -a Preview' call, got $preview_count"
    echo "Args: $captured"
    return 1
  }
  # Same for Finder: single 'open -R' call
  local finder_count
  finder_count=$(echo "$captured" | grep -o 'open -R' | wc -l | tr -d ' ')
  [[ "$finder_count" -eq 1 ]] || {
    echo "Expected 1 'open -R' call, got $finder_count"
    echo "Args: $captured"
    return 1
  }
}

# --- open_in_viewer ---

@test "display: open_in_viewer uses open on macOS" {
  source "$DISPLAY_SH"

  local mock_dir="${BATS_TMPDIR}/mock_open_$$"
  mkdir -p "$mock_dir"
  local args_file="${mock_dir}/open_args"
  printf '#!/bin/bash\necho "$@" > "%s"\n' "$args_file" > "$mock_dir/open"
  chmod +x "$mock_dir/open"
  export PATH="$mock_dir:$PATH"

  open_in_viewer "/tmp/test.png"

  [[ -f "$args_file" ]]
  local captured
  captured=$(cat "$args_file")
  [[ "$captured" == *"/tmp/test.png"* ]] || {
    echo "Expected open to receive /tmp/test.png, got: $captured"
    return 1
  }
}

@test "display: open_in_viewer uses xdg-open as fallback" {
  source "$DISPLAY_SH"

  local mock_dir="${BATS_TMPDIR}/mock_xdg_$$"
  mkdir -p "$mock_dir"
  local args_file="${mock_dir}/xdg_args"
  # xdg-open available, but NOT open (exclude /usr/bin where macOS open lives)
  printf '#!/bin/bash\necho "$@" > "%s"\n' "$args_file" > "$mock_dir/xdg-open"
  chmod +x "$mock_dir/xdg-open"
  export PATH="$mock_dir:/bin"

  open_in_viewer "/tmp/test.png"

  [[ -f "$args_file" ]]
  local captured
  captured=$(cat "$args_file")
  [[ "$captured" == *"/tmp/test.png"* ]] || {
    echo "Expected xdg-open to receive /tmp/test.png, got: $captured"
    return 1
  }
}

@test "display: open_in_viewer fails when no viewer available" {
  source "$DISPLAY_SH"

  # Neither open nor xdg-open available (exclude /usr/bin)
  local mock_dir="${BATS_TMPDIR}/mock_empty_$$"
  mkdir -p "$mock_dir"
  export PATH="$mock_dir:/bin"

  run open_in_viewer "/tmp/test.png"
  assert_status 1
  assert_output_contains "No system viewer available"
}

@test "display: display_image_in_pane prompt includes Finder, Preview, and esc close" {
  source "$DISPLAY_SH"
  export TMUX="/tmp/tmux-501/default,12345,0"
  export TMUX_PANE="%0"
  export LC_TERMINAL="iTerm2"

  local mock_dir="${BATS_TMPDIR}/mock_viewer_prompt_$$"
  mkdir -p "$mock_dir"
  local args_file="${mock_dir}/tmux_args"
  printf '#!/bin/bash\necho "$@" > "%s"\n' "$args_file" > "$mock_dir/tmux"
  printf '#!/bin/bash\nexit 0\n' > "$mock_dir/imgcat"
  chmod +x "$mock_dir/tmux" "$mock_dir/imgcat"
  export PATH="$mock_dir:$PATH"

  local test_img="${BATS_TMPDIR}/test_viewer_prompt_$$.png"
  printf 'test-data' > "$test_img"

  display_image_in_pane "$test_img"

  [[ -f "$args_file" ]]
  local captured
  captured=$(cat "$args_file")
  [[ "$captured" == *"[f]inder"* ]] || {
    echo "Expected prompt to mention '[f]inder'"
    echo "Actual args: $captured"
    return 1
  }
  [[ "$captured" == *"[p]review"* ]] || {
    echo "Expected prompt to mention '[p]review'"
    echo "Actual args: $captured"
    return 1
  }
  [[ "$captured" == *"esc"* ]] || {
    echo "Expected prompt to mention 'esc'"
    echo "Actual args: $captured"
    return 1
  }
  [[ "$captured" != *"any key to close"* ]] || {
    echo "Prompt should not say 'any key to close'"
    echo "Actual args: $captured"
    return 1
  }
}

@test "display: display_images_in_pane prompt includes esc close option" {
  source "$DISPLAY_SH"
  export TMUX="/tmp/tmux-501/default,12345,0"
  export TMUX_PANE="%5"
  export LC_TERMINAL="iTerm2"

  local mock_dir="${BATS_TMPDIR}/mock_grid_prompt_$$"
  mkdir -p "$mock_dir"
  local args_file="${mock_dir}/tmux_args"
  printf '#!/bin/bash\necho "$@" > "%s"\n' "$args_file" > "$mock_dir/tmux"
  printf '#!/bin/bash\nexit 0\n' > "$mock_dir/imgcat"
  chmod +x "$mock_dir/tmux" "$mock_dir/imgcat"
  export PATH="$mock_dir:$PATH"

  local test_img="${BATS_TMPDIR}/test_grid_prompt_$$.png"
  printf 'test-data' > "$test_img"

  display_images_in_pane "$test_img"

  [[ -f "$args_file" ]]
  local captured
  captured=$(cat "$args_file")
  [[ "$captured" == *"esc"* ]] || {
    echo "Expected grid prompt to mention 'esc'"
    echo "Actual args: $captured"
    return 1
  }
  [[ "$captured" != *"any key to close"* ]] || {
    echo "Grid prompt should not say 'any key to close'"
    echo "Actual args: $captured"
    return 1
  }
}

@test "display: display_image_in_pane works without TMUX_PANE" {
  source "$DISPLAY_SH"
  export TMUX="/tmp/tmux-501/default,12345,0"
  unset TMUX_PANE 2>/dev/null || true
  export LC_TERMINAL="iTerm2"

  # Create mock tmux and imgcat
  local mock_dir="${BATS_TMPDIR}/mock_no_pane_$$"
  mkdir -p "$mock_dir"
  local args_file="${mock_dir}/tmux_args"
  printf '#!/bin/bash\necho "$@" > "%s"\n' "$args_file" > "$mock_dir/tmux"
  printf '#!/bin/bash\nexit 0\n' > "$mock_dir/imgcat"
  chmod +x "$mock_dir/tmux" "$mock_dir/imgcat"
  export PATH="$mock_dir:$PATH"

  local test_img="${BATS_TMPDIR}/test_no_pane_$$.png"
  printf 'test-data' > "$test_img"

  display_image_in_pane "$test_img"

  [[ -f "$args_file" ]]
  local captured
  captured=$(cat "$args_file")
  [[ "$captured" != *"-t "* ]] || {
    echo "Expected tmux args to NOT contain '-t' flag"
    echo "Actual args: $captured"
    return 1
  }
}

# --- display_pane_add (streaming pane) ---

@test "display: display_pane_add writes path to manifest" {
  source "$DISPLAY_SH"
  local pane_dir="${BATS_TMPDIR}/pane_add_$$"
  mkdir -p "$pane_dir"
  export DISPLAY_PANE_DIR="$pane_dir"

  local test_img="${BATS_TMPDIR}/add_test_$$.png"
  printf 'data' > "$test_img"

  display_pane_add "$test_img"

  [[ -f "$pane_dir/manifest" ]]
  local content
  content=$(cat "$pane_dir/manifest")
  [[ "$content" == *"add_test_"* ]] || {
    echo "Expected manifest to contain file path"
    echo "Actual: $content"
    return 1
  }
}

@test "display: display_pane_add appends multiple paths in order" {
  source "$DISPLAY_SH"
  local pane_dir="${BATS_TMPDIR}/pane_multi_$$"
  mkdir -p "$pane_dir"
  export DISPLAY_PANE_DIR="$pane_dir"

  local img1="${BATS_TMPDIR}/first_$$.png"
  local img2="${BATS_TMPDIR}/second_$$.png"
  local img3="${BATS_TMPDIR}/third_$$.png"
  printf 'a' > "$img1"
  printf 'b' > "$img2"
  printf 'c' > "$img3"

  display_pane_add "$img1"
  display_pane_add "$img2"
  display_pane_add "$img3"

  [[ -f "$pane_dir/manifest" ]]
  local line1 line2 line3
  line1=$(sed -n '1p' "$pane_dir/manifest")
  line2=$(sed -n '2p' "$pane_dir/manifest")
  line3=$(sed -n '3p' "$pane_dir/manifest")
  [[ "$line1" == *"first_"* ]] || { echo "Line 1 wrong: $line1"; return 1; }
  [[ "$line2" == *"second_"* ]] || { echo "Line 2 wrong: $line2"; return 1; }
  [[ "$line3" == *"third_"* ]] || { echo "Line 3 wrong: $line3"; return 1; }
}

@test "display: display_pane_add resolves relative path to absolute" {
  source "$DISPLAY_SH"
  local pane_dir="${BATS_TMPDIR}/pane_rel_$$"
  mkdir -p "$pane_dir"
  export DISPLAY_PANE_DIR="$pane_dir"

  # Create a file in BATS_TMPDIR with a relative reference
  local test_img="${BATS_TMPDIR}/rel_test_$$.png"
  printf 'data' > "$test_img"

  # Call with relative path from BATS_TMPDIR
  (cd "$BATS_TMPDIR" && display_pane_add "rel_test_$$.png")

  [[ -f "$pane_dir/manifest" ]]
  local content
  content=$(cat "$pane_dir/manifest")
  # Should start with / (absolute path)
  [[ "$content" == /* ]] || {
    echo "Expected absolute path, got: $content"
    return 1
  }
}

@test "display: display_pane_add fails when DISPLAY_PANE_DIR unset" {
  source "$DISPLAY_SH"
  unset DISPLAY_PANE_DIR 2>/dev/null || true

  run display_pane_add "/tmp/some_file.png"
  assert_status 1
  assert_output_contains "DISPLAY_PANE_DIR"
}

# --- display_pane_close (streaming pane) ---

@test "display: display_pane_close creates .done sentinel" {
  source "$DISPLAY_SH"
  local pane_dir="${BATS_TMPDIR}/pane_close_$$"
  mkdir -p "$pane_dir"
  export DISPLAY_PANE_DIR="$pane_dir"

  display_pane_close

  [[ -f "$pane_dir/.done" ]] || {
    echo "Expected .done sentinel to exist"
    return 1
  }
}

@test "display: display_pane_close fails when DISPLAY_PANE_DIR unset" {
  source "$DISPLAY_SH"
  unset DISPLAY_PANE_DIR 2>/dev/null || true

  run display_pane_close
  assert_status 1
  assert_output_contains "DISPLAY_PANE_DIR"
}

# --- display_image routing to streaming pane ---

@test "display: display_image routes to shared pane when DISPLAY_PANE_DIR set" {
  source "$DISPLAY_SH"
  local pane_dir="${BATS_TMPDIR}/pane_route_$$"
  mkdir -p "$pane_dir"
  export DISPLAY_PANE_DIR="$pane_dir"

  local test_img="${BATS_TMPDIR}/route_test_$$.png"
  printf 'data' > "$test_img"

  display_image "$test_img"

  # Should have written to manifest instead of opening a pane or writing escape sequences
  [[ -f "$pane_dir/manifest" ]] || {
    echo "Expected manifest file to exist"
    return 1
  }
  local content
  content=$(cat "$pane_dir/manifest")
  [[ "$content" == *"route_test_"* ]] || {
    echo "Expected manifest to contain file path"
    echo "Actual: $content"
    return 1
  }
  # Should NOT have written any escape sequences
  [[ ! -f "$DISPLAY_OUTPUT" ]] || {
    echo "Should not have written escape sequences when routing to pane"
    return 1
  }
}

@test "display: SKIP_DISPLAY takes priority over DISPLAY_PANE_DIR" {
  source "$DISPLAY_SH"
  local pane_dir="${BATS_TMPDIR}/pane_skip_$$"
  mkdir -p "$pane_dir"
  export DISPLAY_PANE_DIR="$pane_dir"
  export SKIP_DISPLAY="1"

  local test_img="${BATS_TMPDIR}/skip_pane_$$.png"
  printf 'data' > "$test_img"

  display_image "$test_img"

  # SKIP_DISPLAY should prevent even the pane routing
  [[ ! -f "$pane_dir/manifest" ]] || {
    echo "SKIP_DISPLAY should prevent manifest write"
    return 1
  }
}

# --- display_pane_open (streaming pane) ---

@test "display: display_pane_open fails when not in tmux" {
  source "$DISPLAY_SH"
  unset TMUX 2>/dev/null || true

  run display_pane_open
  assert_status 1
  assert_output_contains "Not inside tmux"
}

@test "display: display_pane_open creates watch directory with render.sh" {
  source "$DISPLAY_SH"
  export TMUX="/tmp/tmux-501/default,12345,0"
  export TMUX_PANE="%0"
  export LC_TERMINAL="iTerm2"

  local mock_dir="${BATS_TMPDIR}/mock_pane_open_$$"
  mkdir -p "$mock_dir"
  # Mock tmux to capture args and print a fake pane id
  printf '#!/bin/bash\necho "%%%%99"\n' > "$mock_dir/tmux"
  printf '#!/bin/bash\nexit 0\n' > "$mock_dir/imgcat"
  chmod +x "$mock_dir/tmux" "$mock_dir/imgcat"
  export PATH="$mock_dir:$PATH"

  local watch_dir
  watch_dir=$(display_pane_open)

  [[ -d "$watch_dir" ]] || {
    echo "Expected watch directory to exist: $watch_dir"
    return 1
  }
  [[ -f "$watch_dir/render.sh" ]] || {
    echo "Expected render.sh to exist in watch dir"
    return 1
  }
  [[ -x "$watch_dir/render.sh" ]] || {
    echo "Expected render.sh to be executable"
    return 1
  }
  # Clean up
  rm -rf "$watch_dir"
}

@test "display: display_pane_open calls tmux with -h -l 30%" {
  source "$DISPLAY_SH"
  export TMUX="/tmp/tmux-501/default,12345,0"
  export TMUX_PANE="%0"
  export LC_TERMINAL="iTerm2"

  local mock_dir="${BATS_TMPDIR}/mock_pane_tmux_$$"
  mkdir -p "$mock_dir"
  local args_file="${mock_dir}/tmux_args"
  printf '#!/bin/bash\nprintf "%%s" "$*" > "%s"\necho "%%%%99"\n' "$args_file" > "$mock_dir/tmux"
  printf '#!/bin/bash\nexit 0\n' > "$mock_dir/imgcat"
  chmod +x "$mock_dir/tmux" "$mock_dir/imgcat"
  export PATH="$mock_dir:$PATH"

  local watch_dir
  watch_dir=$(display_pane_open)

  [[ -f "$args_file" ]]
  local captured
  captured=$(cat "$args_file")
  [[ "$captured" == *"split-window -h"* ]] || {
    echo "Expected -h split"
    echo "Actual: $captured"
    rm -rf "$watch_dir"
    return 1
  }
  [[ "$captured" == *"-l 30%"* ]] || {
    echo "Expected -l 30%"
    echo "Actual: $captured"
    rm -rf "$watch_dir"
    return 1
  }
  rm -rf "$watch_dir"
}

@test "display: display_pane_open targets TMUX_PANE" {
  source "$DISPLAY_SH"
  export TMUX="/tmp/tmux-501/default,12345,0"
  export TMUX_PANE="%42"
  export LC_TERMINAL="iTerm2"

  local mock_dir="${BATS_TMPDIR}/mock_pane_target_$$"
  mkdir -p "$mock_dir"
  local args_file="${mock_dir}/tmux_args"
  printf '#!/bin/bash\nprintf "%%s" "$*" > "%s"\necho "%%%%99"\n' "$args_file" > "$mock_dir/tmux"
  printf '#!/bin/bash\nexit 0\n' > "$mock_dir/imgcat"
  chmod +x "$mock_dir/tmux" "$mock_dir/imgcat"
  export PATH="$mock_dir:$PATH"

  local watch_dir
  watch_dir=$(display_pane_open)

  [[ -f "$args_file" ]]
  local captured
  captured=$(cat "$args_file")
  [[ "$captured" == *"-t %42"* ]] || {
    echo "Expected -t %42 targeting"
    echo "Actual: $captured"
    rm -rf "$watch_dir"
    return 1
  }
  rm -rf "$watch_dir"
}

@test "display: display_pane_open render.sh contains imgcat for iterm2" {
  source "$DISPLAY_SH"
  export TMUX="/tmp/tmux-501/default,12345,0"
  export TMUX_PANE="%0"
  export LC_TERMINAL="iTerm2"

  local mock_dir="${BATS_TMPDIR}/mock_pane_iterm_$$"
  mkdir -p "$mock_dir"
  printf '#!/bin/bash\necho "%%%%99"\n' > "$mock_dir/tmux"
  printf '#!/bin/bash\nexit 0\n' > "$mock_dir/imgcat"
  chmod +x "$mock_dir/tmux" "$mock_dir/imgcat"
  export PATH="$mock_dir:$PATH"

  local watch_dir
  watch_dir=$(display_pane_open)

  local render_content
  render_content=$(cat "$watch_dir/render.sh")
  [[ "$render_content" == *"imgcat"* ]] || {
    echo "Expected render.sh to use imgcat for iTerm2"
    echo "Actual: $render_content"
    rm -rf "$watch_dir"
    return 1
  }
  rm -rf "$watch_dir"
}

@test "display: display_pane_open render.sh contains kitten for kitty" {
  source "$DISPLAY_SH"
  export TMUX="/tmp/tmux-501/default,12345,0"
  export TMUX_PANE="%0"
  export KITTY_WINDOW_ID="1"
  unset LC_TERMINAL ITERM_SESSION_ID 2>/dev/null || true

  local mock_dir="${BATS_TMPDIR}/mock_pane_kitty_$$"
  mkdir -p "$mock_dir"
  printf '#!/bin/bash\necho "%%%%99"\n' > "$mock_dir/tmux"
  chmod +x "$mock_dir/tmux"
  export PATH="$mock_dir:$PATH"

  local watch_dir
  watch_dir=$(display_pane_open)

  local render_content
  render_content=$(cat "$watch_dir/render.sh")
  [[ "$render_content" == *"kitten icat"* ]] || {
    echo "Expected render.sh to use kitten icat for Kitty"
    echo "Actual: $render_content"
    rm -rf "$watch_dir"
    return 1
  }
  rm -rf "$watch_dir"
}

@test "display: display_pane_open watcher checks for .done sentinel" {
  source "$DISPLAY_SH"
  export TMUX="/tmp/tmux-501/default,12345,0"
  export TMUX_PANE="%0"
  export LC_TERMINAL="iTerm2"

  local mock_dir="${BATS_TMPDIR}/mock_pane_done_$$"
  mkdir -p "$mock_dir"
  printf '#!/bin/bash\necho "%%%%99"\n' > "$mock_dir/tmux"
  printf '#!/bin/bash\nexit 0\n' > "$mock_dir/imgcat"
  chmod +x "$mock_dir/tmux" "$mock_dir/imgcat"
  export PATH="$mock_dir:$PATH"

  local watch_dir
  watch_dir=$(display_pane_open)

  [[ -f "$watch_dir/watcher.sh" ]] || {
    echo "Expected watcher.sh to exist"
    rm -rf "$watch_dir"
    return 1
  }
  local watcher_content
  watcher_content=$(cat "$watch_dir/watcher.sh")
  [[ "$watcher_content" == *".done"* ]] || {
    echo "Expected watcher.sh to poll for .done sentinel"
    rm -rf "$watch_dir"
    return 1
  }
  rm -rf "$watch_dir"
}

@test "display: display_pane_status writes TSV row to status file" {
  source "$DISPLAY_SH"
  local pane_dir="${BATS_TMPDIR}/pane_status_$$"
  mkdir -p "$pane_dir"
  export DISPLAY_PANE_DIR="$pane_dir"

  display_pane_status gemini complete 1500 gemini-3-pro-image-preview /tmp/x.png

  [[ -f "$pane_dir/status" ]]
  local row
  row=$(cat "$pane_dir/status")
  # Five tab-separated fields: provider, state, ms, model, path
  local field_count
  field_count=$(awk -F'\t' '{print NF; exit}' "$pane_dir/status")
  [[ "$field_count" -eq 5 ]] || {
    echo "Expected 5 fields, got $field_count: $row"
    return 1
  }
  [[ "$row" == *"gemini"* && "$row" == *"complete"* && "$row" == *"1500"* ]] || {
    echo "Row missing expected fields: $row"
    return 1
  }
}

@test "display: display_pane_status fails when DISPLAY_PANE_DIR unset" {
  source "$DISPLAY_SH"
  unset DISPLAY_PANE_DIR 2>/dev/null || true
  run display_pane_status gemini complete 100 model /tmp/x.png
  assert_status 1
  assert_output_contains "DISPLAY_PANE_DIR"
}

@test "display: provider_finish returns success when the streaming pane is active" {
  source "$DISPLAY_SH"
  local pane_dir="${BATS_TMPDIR}/pane_finish_$$"
  mkdir -p "$pane_dir"
  export DISPLAY_PANE_DIR="$pane_dir"
  PROVIDER_NAME=gemini
  MODEL=test-model

  # Provider scripts call provider_finish under `set -e` and then print the output
  # path. If it returns non-zero on a successful generation, the script aborts before
  # reporting the path and run-all.sh records a failure for an image that was created.
  run provider_finish "/tmp/generated.png"
  assert_status 0
}

@test "display: provider_finish survives a failing display when no streaming pane is active" {
  # Reproduces a provider script running under `set -e` with no streaming pane, where the
  # inline display fails (e.g. tmux 'no space for new pane' in a pane too small to split).
  # The image is already saved, so a best-effort display failure must not abort the script
  # before it reports the output path.
  run bash -c '
    set -euo pipefail
    source "'"$DISPLAY_SH"'"
    unset DISPLAY_PANE_DIR
    display_image() { echo "display boom" >&2; return 1; }
    provider_finish "/tmp/generated.png"
    echo "AFTER_FINISH"
  '
  assert_status 0
  assert_output_contains "AFTER_FINISH"
}

@test "display: display_pane_error writes message to errors/<provider>.txt" {
  source "$DISPLAY_SH"
  local pane_dir="${BATS_TMPDIR}/pane_err_$$"
  mkdir -p "$pane_dir"
  export DISPLAY_PANE_DIR="$pane_dir"

  display_pane_error openai "rate limit hit"

  [[ -f "$pane_dir/errors/openai.txt" ]]
  local content
  content=$(cat "$pane_dir/errors/openai.txt")
  [[ "$content" == "rate limit hit" ]] || {
    echo "Expected exact error message, got: $content"
    return 1
  }
}

@test "display: display_pane_begin/finish/fail are no-ops when DISPLAY_PANE_DIR unset" {
  source "$DISPLAY_SH"
  unset DISPLAY_PANE_DIR 2>/dev/null || true

  # Should not write anything, not fail, and not require DISPLAY_PANE_DIR
  run display_pane_begin gemini gemini-3-pro
  assert_status 0
  run display_pane_finish gemini gemini-3-pro /tmp/x.png
  assert_status 0
  run display_pane_fail gemini gemini-3-pro "error msg"
  assert_status 0
}

@test "display: display_pane_finish records elapsed timing after begin" {
  source "$DISPLAY_SH"
  local pane_dir="${BATS_TMPDIR}/pane_timing_$$"
  mkdir -p "$pane_dir"
  export DISPLAY_PANE_DIR="$pane_dir"

  display_pane_begin xai grok-imagine-image-pro
  sleep 0.05
  display_pane_finish xai grok-imagine-image-pro /tmp/dummy.png

  [[ -f "$pane_dir/status" ]]
  # First row: querying. Second row: complete with elapsed > 0.
  local complete_row
  complete_row=$(grep -P '^xai\tcomplete' "$pane_dir/status" 2>/dev/null \
    || awk -F'\t' '$1=="xai" && $2=="complete"' "$pane_dir/status")
  local ms
  ms=$(echo "$complete_row" | awk -F'\t' '{print $3}')
  [[ -n "$ms" && "$ms" -gt 0 ]] || {
    echo "Expected positive elapsed ms, got: '$ms' (full row: $complete_row)"
    return 1
  }
}

@test "display: display_pane_open watcher uses council-style provider colors" {
  source "$DISPLAY_SH"
  export TMUX="/tmp/tmux-501/default,12345,0"
  export TMUX_PANE="%0"
  export LC_TERMINAL="iTerm2"

  local mock_dir="${BATS_TMPDIR}/mock_pane_colors_$$"
  mkdir -p "$mock_dir"
  printf '#!/bin/bash\necho "%%%%99"\n' > "$mock_dir/tmux"
  printf '#!/bin/bash\nexit 0\n' > "$mock_dir/imgcat"
  chmod +x "$mock_dir/tmux" "$mock_dir/imgcat"
  export PATH="$mock_dir:$PATH"

  local watch_dir
  watch_dir=$(display_pane_open)
  local watcher_content
  watcher_content=$(cat "$watch_dir/watcher.sh")

  # Colors keyed off provider names — verify both the case branches and at
  # least one of the council-derived RGB triplets are present.
  [[ "$watcher_content" == *"gemini)"* ]] || { echo "Missing gemini case"; rm -rf "$watch_dir"; return 1; }
  [[ "$watcher_content" == *"openai)"* ]] || { echo "Missing openai case"; rm -rf "$watch_dir"; return 1; }
  [[ "$watcher_content" == *"xai)"*    ]] || { echo "Missing xai case";    rm -rf "$watch_dir"; return 1; }
  [[ "$watcher_content" == *"30;64;175"* ]]   || { echo "Missing gemini blue-700"; rm -rf "$watch_dir"; return 1; }
  [[ "$watcher_content" == *"185;28;28"* ]]   || { echo "Missing xai red-700";     rm -rf "$watch_dir"; return 1; }
  [[ "$watcher_content" == *"draw_loading"* ]] || { echo "Missing spinner";         rm -rf "$watch_dir"; return 1; }
  rm -rf "$watch_dir"
}

@test "display: display_pane_open watcher includes interactive controls" {
  source "$DISPLAY_SH"
  export TMUX="/tmp/tmux-501/default,12345,0"
  export TMUX_PANE="%0"
  export LC_TERMINAL="iTerm2"

  local mock_dir="${BATS_TMPDIR}/mock_pane_ctrl_$$"
  mkdir -p "$mock_dir"
  printf '#!/bin/bash\necho "%%%%99"\n' > "$mock_dir/tmux"
  printf '#!/bin/bash\nexit 0\n' > "$mock_dir/imgcat"
  chmod +x "$mock_dir/tmux" "$mock_dir/imgcat"
  export PATH="$mock_dir:$PATH"

  local watch_dir
  watch_dir=$(display_pane_open)

  [[ -f "$watch_dir/watcher.sh" ]] || {
    echo "Expected watcher.sh to exist"
    rm -rf "$watch_dir"
    return 1
  }
  local watcher_content
  watcher_content=$(cat "$watch_dir/watcher.sh")
  [[ "$watcher_content" == *"[f]inder"* ]] || {
    echo "Expected watcher.sh to include [f]inder control"
    rm -rf "$watch_dir"
    return 1
  }
  [[ "$watcher_content" == *"[p]review"* ]] || {
    echo "Expected watcher.sh to include [p]review control"
    rm -rf "$watch_dir"
    return 1
  }
  [[ "$watcher_content" == *"esc"* ]] || {
    echo "Expected watcher.sh to include esc control"
    rm -rf "$watch_dir"
    return 1
  }
  rm -rf "$watch_dir"
}
