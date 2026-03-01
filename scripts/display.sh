# ABOUTME: Multi-protocol terminal image display utility.
# ABOUTME: Supports iTerm2, Kitty, Sixel protocols and tmux pane display.

# ── Terminal Detection ─────────────────────────────────────────────────

# Returns 0 if running in iTerm2, 1 otherwise.
is_iterm2() {
  [[ "${TERM_PROGRAM:-}" == "iTerm.app" || "${LC_TERMINAL:-}" == "iTerm2" ]]
}

# Returns 0 if the terminal supports the Kitty graphics protocol.
# Covers Kitty, Ghostty, and WezTerm.
is_kitty() {
  case "${TERM:-}" in
    xterm-kitty) return 0 ;;
  esac
  case "${TERM_PROGRAM:-}" in
    kitty|ghostty|WezTerm) return 0 ;;
  esac
  return 1
}

# Returns 0 if running inside a tmux session.
is_tmux() {
  [[ -n "${TMUX:-}" ]]
}

# Prints the outer terminal type when inside tmux.
# Returns: "iterm2", "kitty", or "unknown"
get_outer_terminal() {
  case "${LC_TERMINAL:-}" in
    iTerm2) echo "iterm2"; return 0 ;;
  esac

  if [[ -n "${ITERM_SESSION_ID:-}" ]]; then
    echo "iterm2"; return 0
  fi

  if [[ -n "${KITTY_WINDOW_ID:-}" ]]; then
    echo "kitty"; return 0
  fi

  echo "unknown"
  return 1
}

# ── Sixel Detection ────────────────────────────────────────────────────

# Find the best available sixel conversion tool.
# Prints the tool name and returns 0, or returns 1 if none found.
_sixel_find_tool() {
  if command -v img2sixel &>/dev/null; then
    echo "img2sixel"
  elif command -v chafa &>/dev/null; then
    echo "chafa"
  elif command -v magick &>/dev/null; then
    if magick identify -list format 2>/dev/null | grep -qi sixel; then
      echo "magick"
    else
      return 1
    fi
  else
    return 1
  fi
}

# Check if the current terminal likely supports sixel graphics.
_sixel_check_terminal() {
  case "${LC_TERMINAL:-}" in
    iTerm2) return 0 ;;
  esac

  case "${TERM_PROGRAM:-}" in
    iTerm.app|WezTerm|mintty) return 0 ;;
  esac

  case "${TERM:-}" in
    mlterm*|foot*|xterm-direct*) return 0 ;;
  esac

  [[ -n "${WEZTERM_EXECUTABLE:-}" ]] && return 0

  # In tmux, check outer terminal
  if [[ -n "${TMUX:-}" ]]; then
    local outer_term
    outer_term=$(tmux show-environment LC_TERMINAL 2>/dev/null | sed 's/^LC_TERMINAL=//')
    case "$outer_term" in
      iTerm2|WezTerm) return 0 ;;
    esac
    outer_term=$(tmux show-environment TERM_PROGRAM 2>/dev/null | sed 's/^TERM_PROGRAM=//')
    case "$outer_term" in
      iTerm.app|WezTerm|mintty) return 0 ;;
    esac
  fi

  return 1
}

# Returns 0 if both a sixel conversion tool and a capable terminal are available.
is_sixel_capable() {
  _sixel_find_tool &>/dev/null && _sixel_check_terminal
}

# ── System Viewer ─────────────────────────────────────────────────────

# Opens a file in the system's default viewer.
# Uses `open` on macOS, `xdg-open` on Linux.
open_in_viewer() {
  local file_path="$1"
  if command -v open &>/dev/null; then
    open "$file_path"
  elif command -v xdg-open &>/dev/null; then
    xdg-open "$file_path"
  else
    echo "No system viewer available (tried: open, xdg-open)" >&2
    return 1
  fi
}

# ── iTerm2 Display (OSC 1337) ─────────────────────────────────────────

# Displays an image using the iTerm2 inline image protocol.
# Usage: display_image_iterm2 <file_path>
display_image_iterm2() {
  local file_path="$1"
  local target="${DISPLAY_IMAGE_TARGET:-/dev/tty}"

  local filename name_b64 size image_b64
  filename=$(basename "$file_path")
  name_b64=$(printf '%s' "$filename" | base64 | tr -d '\n')
  size=$(wc -c < "$file_path" | tr -d ' ')
  image_b64=$(base64 < "$file_path" | tr -d '\n')

  local max_w="${DISPLAY_IMAGE_WIDTH:-256}"
  local max_h="${DISPLAY_IMAGE_HEIGHT:-256}"

  printf '\033]1337;File=name=%s;size=%s;inline=1;width=%spx;height=%spx:%s\a' \
    "$name_b64" "$size" "$max_w" "$max_h" "$image_b64" >> "$target"
}

# ── Kitty Display (APC graphics protocol) ──────────────────────────────

# Read base64 lines from stdin and emit Kitty APC escape sequences.
# First line gets metadata (a=T,f=100); all but last sent with m=1; final m=0.
_kitty_emit_chunks() {
  local first=1
  local metadata

  while IFS= read -r chunk; do
    [[ -z "$chunk" ]] && continue
    if [[ "$first" -eq 1 ]]; then
      metadata="a=T,f=100,"
      first=0
    else
      metadata=""
    fi
    printf '\033_G%sm=1;%s\033\\' "$metadata" "$chunk"
  done

  # Final m=0 signals end of transmission
  if [[ "$first" -eq 0 ]]; then
    printf '\033_Gm=0;\033\\'
  fi
}

# Send base64-encoded image data as chunked Kitty graphics sequences.
# Encodes the file, strips line breaks, then re-chunks to 4096 bytes.
_kitty_send_chunked() {
  local filepath="$1"
  local encoded
  encoded=$(base64 < "$filepath" | tr -d '\n')
  printf '%s\n' "$encoded" | fold -b -w 4096 | _kitty_emit_chunks
}

# Displays an image using the Kitty graphics protocol.
# Usage: display_image_kitty <file_path>
display_image_kitty() {
  local filepath="$1"

  if [[ -z "$filepath" ]]; then
    echo "display_image_kitty: missing filepath argument" >&2
    return 1
  fi

  if [[ ! -f "$filepath" ]]; then
    echo "display_image_kitty: file not found: $filepath" >&2
    return 1
  fi

  local target="${DISPLAY_IMAGE_TARGET:-/dev/tty}"
  _kitty_send_chunked "$filepath" >> "$target"
}

# ── Sixel Display ──────────────────────────────────────────────────────

# Displays an image using the Sixel protocol.
# Requires img2sixel, chafa, or ImageMagick (magick).
# Usage: display_image_sixel <file_path> [max_width]
display_image_sixel() {
  local filepath="$1"
  local max_width="${2:-${DISPLAY_IMAGE_WIDTH:-256}}"
  local target="${DISPLAY_IMAGE_TARGET:-/dev/tty}"

  if [[ -z "$filepath" ]]; then
    echo "Usage: display_image_sixel <filepath> [max_width]" >&2
    return 1
  fi

  if [[ ! -f "$filepath" ]]; then
    echo "Error: File not found: $filepath" >&2
    return 1
  fi

  local tool
  tool=$(_sixel_find_tool) || {
    echo "Error: No sixel conversion tool found." >&2
    echo "Install one of: libsixel (img2sixel), chafa, or ImageMagick 7 (magick)" >&2
    return 1
  }

  local exit_code=0
  case "$tool" in
    img2sixel)
      img2sixel --width="$max_width" "$filepath" > "$target" || exit_code=$?
      ;;
    chafa)
      chafa --format=sixels --size="${max_width}x" "$filepath" > "$target" || exit_code=$?
      ;;
    magick)
      magick "$filepath" -geometry "${max_width}x>" sixel:- > "$target" || exit_code=$?
      ;;
  esac

  if [[ $exit_code -ne 0 ]]; then
    echo "Error: $tool failed to convert '$filepath' to sixel (exit code: $exit_code)" >&2
    return 1
  fi

  return 0
}

# ── Tmux Pane Display ──────────────────────────────────────────────────

# Locates the imgcat binary for iTerm2 inline image display.
find_imgcat() {
  local paths=(
    "${HOME}/.iterm2/imgcat"
    "/usr/local/bin/imgcat"
    "/opt/homebrew/bin/imgcat"
  )
  for p in "${paths[@]}"; do
    [[ -x "$p" ]] && echo "$p" && return 0
  done
  command -v imgcat 2>/dev/null && return 0
  return 1
}

# Opens a tmux split pane that displays an image and closes on keypress.
# Usage: display_image_in_pane <file_path>
display_image_in_pane() {
  local file_path="$1"

  if ! is_tmux; then
    echo "Not inside tmux, cannot open display pane" >&2
    return 1
  fi

  # Resolve to absolute path
  if [[ "$file_path" != /* ]]; then
    file_path="$(cd "$(dirname "$file_path")" && pwd)/$(basename "$file_path")"
  fi

  if [[ ! -f "$file_path" ]]; then
    echo "File not found: $file_path" >&2
    return 1
  fi

  local terminal
  terminal=$(get_outer_terminal) || true

  local display_cmd
  case "$terminal" in
    iterm2)
      local imgcat_path
      imgcat_path=$(find_imgcat) || {
        echo "imgcat not found, cannot display image" >&2
        return 1
      }
      local pane_width="${DISPLAY_IMAGE_WIDTH:-256}"
      display_cmd="$(printf '%q' "$imgcat_path") -W ${pane_width}px $(printf '%q' "$file_path")"
      ;;
    kitty)
      display_cmd="kitten icat --align left $(printf '%q' "$file_path")"
      ;;
    *)
      # Fallback: try sixel if a conversion tool is available
      local sixel_tool
      local sixel_width="${DISPLAY_IMAGE_WIDTH:-256}"
      if sixel_tool=$(_sixel_find_tool 2>/dev/null); then
        case "$sixel_tool" in
          img2sixel) display_cmd="img2sixel --width=${sixel_width} $(printf '%q' "$file_path")" ;;
          chafa)     display_cmd="chafa --format=sixels --size=${sixel_width}x $(printf '%q' "$file_path")" ;;
          magick)    display_cmd="magick $(printf '%q' "$file_path") -geometry ${sixel_width}x\\> sixel:-" ;;
        esac
      else
        display_cmd="echo 'No inline image protocol detected'; echo 'Image saved to: $(printf '%q' "$file_path")'"
      fi
      ;;
  esac

  local filename
  filename=$(basename "$file_path")
  local safe_filename
  safe_filename=$(printf '%q' "$filename")

  # Target the originating pane so the split opens here even if the user
  # has switched to a different tmux window/tab.
  # Uses an array to avoid zsh word-splitting issues with ${var:+...}.
  local -a target_args=()
  if [[ -n "${TMUX_PANE:-}" ]]; then
    target_args=(-t "$TMUX_PANE")
  fi

  local safe_path
  safe_path=$(printf '%q' "$file_path")

  tmux split-window -v -l '40%' "${target_args[@]}" \
    "bash -c '_esc=\$(printf \"\\033\"); echo \"--- ${safe_filename} ---\"; echo; ${display_cmd}; echo; printf \"[f]inder [p]review [esc/ctrl-d] close \"; while true; do read -n1 -s -r _key || break; if [ \"\$_key\" = \"\$_esc\" ]; then break; fi; if [ \"\$_key\" = \"f\" ] || [ \"\$_key\" = \"F\" ]; then open -R ${safe_path} 2>/dev/null || xdg-open ${safe_path} 2>/dev/null; elif [ \"\$_key\" = \"p\" ] || [ \"\$_key\" = \"P\" ]; then open -a Preview ${safe_path} 2>/dev/null || xdg-open ${safe_path} 2>/dev/null; fi; done'"
}

# ── Main Entry Point ───────────────────────────────────────────────────

# Displays an image using the best available method.
# In tmux: opens a split pane with the image (works inside Claude Code).
# Otherwise: writes escape sequences directly (iTerm2 > Kitty > Sixel).
# Usage: display_image <file_path>
display_image() {
  local file_path="$1"

  if [[ "${SKIP_DISPLAY:-}" == "1" ]]; then
    return 0
  fi

  if [[ ! -f "$file_path" ]]; then
    return 0
  fi

  # In tmux: use pane display (works even when stdout/stderr is captured)
  if is_tmux; then
    display_image_in_pane "$file_path"
    return $?
  fi

  # Direct terminal display: try protocols in priority order
  local target="${DISPLAY_IMAGE_TARGET:-/dev/tty}"

  if [[ "$target" == "/dev/tty" && ! -w /dev/tty ]]; then
    return 0
  fi

  if is_iterm2; then
    display_image_iterm2 "$file_path"
  elif is_kitty; then
    display_image_kitty "$file_path"
  elif is_sixel_capable; then
    display_image_sixel "$file_path"
  fi
}

# ── Multi-Image Grid Display ──────────────────────────────────────────

# Builds the display command for a single image.
# Prints the command fragment to stdout.
_build_image_cmd() {
  local file_path="$1"
  local terminal="$2"

  local filename safe_filename safe_path
  filename=$(basename "$file_path")
  safe_filename=$(printf '%q' "$filename")
  safe_path=$(printf '%q' "$file_path")

  local cmd="echo '--- ${safe_filename} ---'; "
  local width="${DISPLAY_IMAGE_WIDTH:-256}"

  case "$terminal" in
    iterm2)
      local imgcat_path
      imgcat_path=$(find_imgcat) || return 1
      cmd+="$(printf '%q' "$imgcat_path") -W ${width}px ${safe_path}; "
      ;;
    kitty)
      cmd+="kitten icat --align left ${safe_path}; "
      ;;
    *)
      local sixel_tool
      if sixel_tool=$(_sixel_find_tool 2>/dev/null); then
        case "$sixel_tool" in
          img2sixel) cmd+="img2sixel --width=${width} ${safe_path}; " ;;
          chafa)     cmd+="chafa --format=sixels --size=${width}x ${safe_path}; " ;;
          magick)    cmd+="magick ${safe_path} -geometry ${width}x\\> sixel:-; " ;;
        esac
      else
        cmd+="echo 'Image: ${safe_path}'; "
      fi
      ;;
  esac

  cmd+="echo; "
  printf '%s' "$cmd"
}

# Opens a tmux pane displaying multiple images with labels.
# Usage: display_images_in_pane <file1> <file2> [...]
display_images_in_pane() {
  local files=("$@")
  local count=${#files[@]}

  if [[ $count -eq 0 ]]; then
    return 0
  fi

  if ! is_tmux; then
    echo "Not inside tmux, cannot open display pane" >&2
    return 1
  fi

  # Scale pane height for more images
  local pane_height="40%"
  if [[ $count -ge 3 ]]; then
    pane_height="60%"
  elif [[ $count -eq 2 ]]; then
    pane_height="50%"
  fi

  local terminal
  terminal=$(get_outer_terminal) || true

  local display_cmd=""
  local finder_cmd=""
  local preview_cmd=""
  for file_path in "${files[@]}"; do
    # Resolve to absolute path
    if [[ "$file_path" != /* ]]; then
      file_path="$(cd "$(dirname "$file_path")" && pwd)/$(basename "$file_path")"
    fi
    if [[ ! -f "$file_path" ]]; then
      continue
    fi

    display_cmd+=$(_build_image_cmd "$file_path" "$terminal")

    local safe_path
    safe_path=$(printf '%q' "$file_path")
    finder_cmd+="open -R ${safe_path} 2>/dev/null || xdg-open ${safe_path} 2>/dev/null; "
    preview_cmd+="open -a Preview ${safe_path} 2>/dev/null || xdg-open ${safe_path} 2>/dev/null; "
  done

  if [[ -z "$display_cmd" ]]; then
    return 0
  fi

  local -a target_args=()
  if [[ -n "${TMUX_PANE:-}" ]]; then
    target_args=(-t "$TMUX_PANE")
  fi

  tmux split-window -v -l "$pane_height" "${target_args[@]}" \
    "bash -c '_esc=\$(printf \"\\033\"); ${display_cmd}printf \"[f]inder [p]review [esc/ctrl-d] close \"; while true; do read -n1 -s -r _key || break; if [ \"\$_key\" = \"\$_esc\" ]; then break; fi; if [ \"\$_key\" = \"f\" ] || [ \"\$_key\" = \"F\" ]; then ${finder_cmd}elif [ \"\$_key\" = \"p\" ] || [ \"\$_key\" = \"P\" ]; then ${preview_cmd}fi; done'"
}

# Displays multiple images using the best available method.
# In tmux: opens a single pane showing all images as a grid.
# Otherwise: displays each image sequentially via escape sequences.
# Usage: display_images <file1> <file2> [...]
display_images() {
  local files=("$@")

  if [[ ${#files[@]} -eq 0 ]]; then
    return 0
  fi

  if [[ "${SKIP_DISPLAY:-}" == "1" ]]; then
    return 0
  fi

  if is_tmux; then
    display_images_in_pane "${files[@]}"
    return $?
  fi

  # Outside tmux: display each image sequentially
  for file in "${files[@]}"; do
    display_image "$file"
  done
}
