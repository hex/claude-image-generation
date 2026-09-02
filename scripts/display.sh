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

  local max_w="${DISPLAY_IMAGE_WIDTH:-512}"
  local max_h="${DISPLAY_IMAGE_HEIGHT:-512}"

  printf '\033]1337;File=name=%s;size=%s;inline=1;width=%spx;height=%spx:%s\a' \
    "$name_b64" "$size" "$max_w" "$max_h" "$image_b64" >> "$target"
}

# Rewrites an image into a small JPEG so the terminal honours the display box. gpt-image-2 PNGs
# carry physical-size metadata (e.g. 1024px at 72 DPI) that iTerm2 prefers over the requested pixel
# box, so they render far larger than sibling JPEGs even though imgcat asks for the same size.
# Re-encoding to a <=box-px JPEG drops that metadata and matches the format terminals already size
# correctly. Uses sips, a macOS built-in, so it adds no dependency; callers fall back to the
# original image when sips is unavailable or the source cannot be read.
# Usage: normalize_for_display <src> <dst>
normalize_for_display() {
  local src="$1" dst="$2"
  # Percent width (see display_pane_open) sets the on-screen size, so these source pixels only affect
  # the preview's sharpness and its wire payload -- not how big it displays. Keep the payload small:
  # above ~17KB on the wire, tmux control-mode flow control (pause-after) intermittently drops the
  # image write and the pane shows a blank. A 240px JPEG at quality 60 lands ~11KB on the wire with
  # margin to spare; the full-resolution image is saved separately, so a soft preview is fine.
  # DISPLAY_PANE_IMAGE_PX is the source pixel budget; DPI is pinned only to keep copies uniform.
  # sips exits 0 even when the source is missing and it writes nothing, so success is judged by a
  # non-empty result rather than sips's exit code.
  local px="${DISPLAY_PANE_IMAGE_PX:-240}"
  sips -Z "$px" -s format jpeg -s formatOptions 60 -s dpiWidth 72 -s dpiHeight 72 "$src" --out "$dst" >/dev/null 2>&1
  [[ -s "$dst" ]]
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
  local max_width="${2:-${DISPLAY_IMAGE_WIDTH:-512}}"
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

# Populates __PANE_TARGET_ARGS with the tmux flag that aims a command at the originating pane,
# leaving it empty when TMUX_PANE is unset. bash 3.2 has no namerefs, so the result travels in a
# fixed global rather than an array the caller names. Expand it as
# ${__PANE_TARGET_ARGS[@]+"${__PANE_TARGET_ARGS[@]}"} so an empty array is not an unbound
# variable under set -u. Usage: __pane_target_args
__pane_target_args() {
  __PANE_TARGET_ARGS=()
  [[ -n "${TMUX_PANE:-}" ]] && __PANE_TARGET_ARGS=(-t "$TMUX_PANE")
  return 0
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
      local pane_width="${DISPLAY_IMAGE_WIDTH:-512}"
      display_cmd="$(printf '%q' "$imgcat_path") -W ${pane_width}px $(printf '%q' "$file_path")"
      ;;
    kitty)
      display_cmd="kitten icat --align left $(printf '%q' "$file_path")"
      ;;
    *)
      # Fallback: try sixel if a conversion tool is available
      local sixel_tool
      local sixel_width="${DISPLAY_IMAGE_WIDTH:-512}"
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
  __pane_target_args
  local -a target_args=(${__PANE_TARGET_ARGS[@]+"${__PANE_TARGET_ARGS[@]}"})

  local safe_path
  safe_path=$(printf '%q' "$file_path")

  tmux split-window -v -l '40%' ${target_args[@]+"${target_args[@]}"} \
    "bash -c '_esc=\$(printf \"\\033\"); echo \"--- ${safe_filename} ---\"; echo; ${display_cmd}; echo; printf \"[f]inder [p]review [esc/ctrl-d] close \"; while true; do read -n1 -s -r _key || break; if [ \"\$_key\" = \"\$_esc\" ]; then break; fi; if [ \"\$_key\" = \"f\" ] || [ \"\$_key\" = \"F\" ]; then open -R ${safe_path} 2>/dev/null || xdg-open ${safe_path} 2>/dev/null; elif [ \"\$_key\" = \"p\" ] || [ \"\$_key\" = \"P\" ]; then open -a Preview ${safe_path} 2>/dev/null || xdg-open ${safe_path} 2>/dev/null; fi; done'"
}

# ── Streaming Display Pane ────────────────────────────────────────────

# Appends a file path to the streaming pane manifest.
# The watcher in the tmux pane picks up new entries and renders them.
# Usage: display_pane_add <file_path>
display_pane_add() {
  if [[ -z "${DISPLAY_PANE_DIR:-}" || ! -d "${DISPLAY_PANE_DIR:-}" ]]; then
    echo "display_pane_add: DISPLAY_PANE_DIR is not set or not a directory" >&2
    return 1
  fi
  local file_path="$1"
  if [[ "$file_path" != /* ]]; then
    file_path="$(cd "$(dirname "$file_path")" && pwd)/$(basename "$file_path")"
  fi
  printf '%s\n' "$file_path" >> "$DISPLAY_PANE_DIR/manifest"
}

# Signals the streaming pane watcher that all images have been added.
# The watcher stops polling and shows interactive controls.
# Usage: display_pane_close
display_pane_close() {
  if [[ -z "${DISPLAY_PANE_DIR:-}" || ! -d "${DISPLAY_PANE_DIR:-}" ]]; then
    echo "display_pane_close: DISPLAY_PANE_DIR is not set or not a directory" >&2
    return 1
  fi
  touch "$DISPLAY_PANE_DIR/.done"
}

# Appends a status event to the streaming pane's status log so the watcher
# can render colored banners and animated pending indicators per provider.
# Usage: display_pane_status <provider> <state> [elapsed_ms] [model] [path]
# State is one of: querying, complete, error
display_pane_status() {
  if [[ -z "${DISPLAY_PANE_DIR:-}" || ! -d "${DISPLAY_PANE_DIR:-}" ]]; then
    echo "display_pane_status: DISPLAY_PANE_DIR is not set or not a directory" >&2
    return 1
  fi
  local provider="$1" state="$2" ms="${3:-}" model="${4:-}" path="${5:-}"
  if [[ -n "$path" && "$path" != /* ]]; then
    path="$(cd "$(dirname "$path")" && pwd)/$(basename "$path")"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$provider" "$state" "$ms" "$model" "$path" \
    >> "$DISPLAY_PANE_DIR/status"
}

# Records a provider-specific error message so the watcher can display it
# inline beneath an error banner. Usage: display_pane_error <provider> <message>
display_pane_error() {
  if [[ -z "${DISPLAY_PANE_DIR:-}" || ! -d "${DISPLAY_PANE_DIR:-}" ]]; then
    echo "display_pane_error: DISPLAY_PANE_DIR is not set or not a directory" >&2
    return 1
  fi
  local provider="$1" message="$2"
  mkdir -p "$DISPLAY_PANE_DIR/errors"
  printf '%s' "$message" > "$DISPLAY_PANE_DIR/errors/${provider}.txt"
}

# Returns current epoch in milliseconds. macOS `date` lacks %N so we route
# through perl, which ships on every macOS and Linux distro by default.
__pane_now_ms() {
  perl -MTime::HiRes=time -e 'printf "%d", time*1000' 2>/dev/null
}

# Provider-script helpers, safe to call unconditionally. begin joins this window's shared pane
# when the caller has none, then records the querying state and starts the timer — outside tmux
# it does nothing, but inside it costs a tmux round-trip and can wait briefly for another
# provider to finish opening the pane. finish/fail compute elapsed ms, emit the complete/error
# event, and release this participant's hold on the pane.
display_pane_begin() {
  local provider="$1" model="$2"
  # A provider launched on its own inherits no DISPLAY_PANE_DIR, so it joins (or opens) this
  # window's shared pane here. Doing it at begin rather than at render time is what keeps a
  # batch to one pane: every provider lands on the same surface before any image exists.
  if [[ -z "${DISPLAY_PANE_DIR:-}" ]] && is_tmux; then
    local watch_dir
    if watch_dir=$(display_pane_attach_or_open 2>/dev/null); then
      DISPLAY_PANE_DIR="$watch_dir"
      __PANE_SELF_ATTACHED=1
    fi
  fi
  [[ -z "${DISPLAY_PANE_DIR:-}" ]] && return 0
  # Every provider run by a process that owns a share of the pane takes its own token, not just
  # the one whose call did the attaching -- one process driving two providers must be counted
  # twice, or the first to finish would close the pane while the second is still generating.
  if [[ -n "${__PANE_SELF_ATTACHED:-}" ]]; then
    __pane_acquire "$provider"
  fi
  __PANE_START_MS=$(__pane_now_ms)
  display_pane_status "$provider" querying "" "$model" ""
  return 0
}

# Registers a participant as still working in the shared pane and marks this process as one of
# the pane's owners, so the last one out can tell when the batch is finished and that it is
# entitled to close it. Paired with __pane_release; keeping both halves here is what keeps the
# active/ layout and the ownership flag internal to this file. Usage: __pane_acquire <name>
__pane_acquire() {
  __PANE_SELF_ATTACHED=1
  mkdir -p "$DISPLAY_PANE_DIR/active"
  : > "$DISPLAY_PANE_DIR/active/${1}.$$"
}

# Drops this participant's active token and closes the shared pane once the last one has released.
# Only a process that acquired the pane itself may close it; a process handed DISPLAY_PANE_DIR by
# a parent renders into the pane and leaves the closing to whoever handed it down.
#
# That asymmetry is deliberate, and two failures come back if it is levelled into "every process,
# children included, holds its own token". A supervisor's token brackets the whole fork..wait span,
# which per-child tokens cannot express:
#   - Start skew splits the batch. Child A finishes while child B is still parsing arguments and
#     has not reached display_pane_begin. active/ reads empty, A closes the pane and retires the
#     registry entry, and B then opens a second pane -- the very thing this feature prevents.
#   - No child ever arrives. `--providers bogus`, or every child dying before display_pane_begin,
#     leaves active/ empty forever with nobody to notice, so the pane is never closed.
# Usage: __pane_release <participant>
__pane_release() {
  [[ -n "${__PANE_SELF_ATTACHED:-}" ]] || return 0
  local provider="$1"
  rm -f "$DISPLAY_PANE_DIR/active/${provider}.$$"
  # Anything left in active/ means another provider is still working, so the pane stays open.
  [[ -n "$(ls -A "$DISPLAY_PANE_DIR/active" 2>/dev/null)" ]] && return 0
  # Retire the entry before dismissing the pane so a provider starting up in this instant opens
  # a fresh pane rather than attaching to one that is about to stop accepting images.
  local reg
  reg=$(cat "$DISPLAY_PANE_DIR/registry" 2>/dev/null)
  [[ -n "$reg" ]] && rm -rf "$reg"
  touch "$DISPLAY_PANE_DIR/.done"
  return 0
}

display_pane_finish() {
  [[ -z "${DISPLAY_PANE_DIR:-}" ]] && return 0
  local provider="$1" model="$2" path="$3"
  local elapsed=""
  if [[ -n "${__PANE_START_MS:-}" ]]; then
    local now
    now=$(__pane_now_ms)
    [[ -n "$now" ]] && elapsed=$((now - __PANE_START_MS))
  fi
  display_pane_status "$provider" complete "$elapsed" "$model" "$path"
  __pane_release "$provider"
}

display_pane_fail() {
  [[ -z "${DISPLAY_PANE_DIR:-}" ]] && return 0
  local provider="$1" model="$2" message="$3"
  display_pane_error "$provider" "$message"
  display_pane_status "$provider" error "" "$model" ""
  __pane_release "$provider"
}

# Convenience for provider scripts. Reads PROVIDER_NAME and MODEL from the
# caller's scope. provider_die emits the error event then exits with code 1.
# provider_finish emits the complete event and falls back to direct terminal
# display when running outside a streaming pane.
provider_die() {
  local msg="$*" retries=0
  declare -F retry_attempts >/dev/null && retries=$(retry_attempts)
  if [[ "$retries" -gt 0 ]]; then
    msg="${msg} (after ${retries} retries)"
  fi
  echo "$msg" >&2
  display_pane_fail "${PROVIDER_NAME:-unknown}" "${MODEL:-}" "$msg"
  exit 1
}

provider_finish() {
  local output="$1"
  # A run that retried and then succeeded must not leave its count file behind for the next
  # curl_with_retry call under this PID to find and misreport.
  declare -F retry_attempts >/dev/null && retry_attempts >/dev/null
  display_pane_finish "${PROVIDER_NAME:-unknown}" "${MODEL:-}" "$output"
  # The image is already saved; inline display is best-effort. When no streaming pane is
  # active, show it directly, but swallow any failure (e.g. tmux 'no space for new pane' in a
  # pane too small to split) so it never aborts the caller's `set -e` before the path prints.
  if [[ -z "${DISPLAY_PANE_DIR:-}" ]]; then
    display_image "$output" || true
  fi
  return 0
}

# Classifies a pane as visually "wide" or "tall" from its cell dimensions. Terminal cells are
# roughly twice as tall as they are wide, so a pane only reads as wide once its column count
# reaches twice its row count. display_pane_open splits a wide pane's horizontal axis and a
# tall pane's vertical axis so the streaming pane keeps a usable shape. Usage: pane_orientation <cols> <rows>
pane_orientation() {
  local cols="$1" rows="$2"
  if (( cols >= rows * 2 )); then
    echo "wide"
  else
    echo "tall"
  fi
}

# Splits a tab-delimited status line into its five fields (provider, state, ms, model, path),
# printing one field per line so an empty field survives as an empty line. `read` with a
# whitespace IFS -- and tab is whitespace -- collapses consecutive delimiters, so an empty
# timing field would shift every later field left: the path lands in the model slot and path
# ends up empty, and the pane shows the raw path instead of the image. Parameter-expansion
# slicing cuts at exact delimiter positions and keeps empty fields in place. The fifth field is
# the whole remainder, so a path containing a tab stays intact. Usage: pane_parse_status_line <line>
pane_parse_status_line() {
  local line="$1"
  printf '%s\n' "${line%%$'\t'*}"; line="${line#*$'\t'}"   # provider
  printf '%s\n' "${line%%$'\t'*}"; line="${line#*$'\t'}"   # state
  printf '%s\n' "${line%%$'\t'*}"; line="${line#*$'\t'}"   # ms
  printf '%s\n' "${line%%$'\t'*}"; line="${line#*$'\t'}"   # model
  printf '%s\n' "$line"                                    # path (remainder)
}

# Opens a tmux pane that watches for images and displays them as they arrive.
# Creates a temp directory with a manifest file and render script.
# Prints the watch directory path to stdout (caller sets DISPLAY_PANE_DIR).
# Usage: display_pane_open
display_pane_open() {
  if ! is_tmux; then
    echo "Not inside tmux, cannot open display pane" >&2
    return 1
  fi

  local watch_dir
  watch_dir=$(mktemp -d "${TMPDIR:-/tmp}/display_pane.XXXXXX")

  # The render script sources this library so it can reuse normalize_for_display. Resolve to an
  # absolute path because render.sh runs in a pane whose working directory may differ.
  local self="${BASH_SOURCE[0]}"
  case "$self" in
    /*) ;;
    *) self="$(cd "$(dirname "$self")" && pwd)/$(basename "$self")" ;;
  esac

  local terminal
  terminal=$(get_outer_terminal) || true

  # Write terminal-specific render script
  local render_cmd
  local width="${DISPLAY_IMAGE_WIDTH:-512}"
  local height="${DISPLAY_IMAGE_HEIGHT:-512}"
  case "$terminal" in
    iterm2)
      local imgcat_path
      imgcat_path=$(find_imgcat) || {
        echo "imgcat not found, cannot display image" >&2
        rm -rf "$watch_dir"
        return 1
      }
      # Size by percent of pane width. iTerm2 converts an inline image to a cell count and clamps it
      # to the full pane width when that count exceeds the pane. Inherent and pixel widths derive the
      # count by dividing by the pane's per-cell size, which is momentarily stale on a freshly split
      # pane -- the fastest provider renders first, before the pane settles, and trips the clamp to
      # full width. A percent width derives the count as a fraction of the cell grid (which control
      # mode does report), so it can never exceed the pane and the clamp cannot fire.
      # DISPLAY_PANE_IMAGE_PCT is the on-screen size knob (percent of pane width).
      render_cmd="$(printf '%q' "$imgcat_path") -W ${DISPLAY_PANE_IMAGE_PCT:-30}% -r \"\$1\""
      ;;
    kitty)
      render_cmd="kitten icat --align left \"\$1\""
      ;;
    *)
      local sixel_tool
      if sixel_tool=$(_sixel_find_tool 2>/dev/null); then
        case "$sixel_tool" in
          img2sixel) render_cmd="img2sixel --width=${width} \"\$1\"" ;;
          chafa)     render_cmd="chafa --format=sixels --size=${width}x \"\$1\"" ;;
          magick)    render_cmd="magick \"\$1\" -geometry ${width}x\\> sixel:-" ;;
        esac
      else
        render_cmd="echo \"Image: \$1\""
      fi
      ;;
  esac

  # render.sh normalizes each image to the display box before handing it to the terminal, so
  # DPI-laden PNGs can't out-size their JPEG siblings. Normalization is best-effort: if sips is
  # absent or fails, $1 stays the original image and the terminal displays it as before.
  {
    printf '#!/bin/bash\n'
    printf 'source %q\n' "$self"
    cat <<'RENDEREOF'
__norm="$(mktemp "${TMPDIR:-/tmp}/render.XXXXXX")"
if normalize_for_display "$1" "$__norm"; then
  set -- "$__norm"
fi
RENDEREOF
    printf '%s\n' "$render_cmd"
    printf 'rm -f "$__norm"\n'
  } > "$watch_dir/render.sh"
  chmod +x "$watch_dir/render.sh"

  # The watcher sources this library so it can reuse pane_parse_status_line for status parsing.
  {
    printf '#!/bin/bash\n'
    printf 'source %q\n' "$self"
    cat <<'WATCHEREOF'
WATCH="$1"
trap 'rm -rf "$WATCH"' EXIT

# macOS ships bash 3.2, which has no associative arrays. Provider attributes are kept
# in variables named <map>_<provider> (state, timing, model, path, rendered), and the
# set of providers seen so far is tracked as a space-separated list so we can iterate.
seen_providers=""
# Providers in the order their blocks reached the pane (completion order), which is the order
# a redraw replays; it differs from first-seen order whenever a later provider finishes first.
drawn_order=""
status_lines_processed=0
manifest_shown=0
spinner_frame=0
any_image_rendered=""
SPINNERS=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

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

# map_set <map> <provider> <value> — store one attribute for a provider.
map_set() {
    local __key="${2//[^A-Za-z0-9_]/_}"
    printf -v "${1}_${__key}" '%s' "$3"
}

# map_get <out_var> <map> <provider> — read an attribute into out_var ("" if unset).
# printf -v writes through dynamic scope, so no subshell fork per lookup.
map_get() {
    local __src="${2}_${3//[^A-Za-z0-9_]/_}"
    printf -v "$1" '%s' "${!__src:-}"
}

# note_provider <provider> — remember a provider once, preserving first-seen order.
note_provider() {
    case " $seen_providers " in
        *" $1 "*) ;;
        *) seen_providers="${seen_providers}${seen_providers:+ }$1" ;;
    esac
}

# note_drawn <provider> — remember a provider's place on the pane once; a block drawn again
# after a retry keeps its original position.
note_drawn() {
    case " $drawn_order " in
        *" $1 "*) ;;
        *) drawn_order="${drawn_order}${drawn_order:+ }$1" ;;
    esac
}

# Provider palette: emits four space-separated RGB triplets — bg, fg, accent,
# spinner — into the variables named by the first four args. Single source of
# truth for every place we color provider output. WCAG AA across themes.
provider_palette() {
    local __bg="$1" __fg="$2" __accent="$3" __spinner="$4" name="$5"
    case "$name" in
        gemini) printf -v "$__bg" '30;64;175';   printf -v "$__fg" '255;255;255'; printf -v "$__accent" '147;197;253'; printf -v "$__spinner" '59;130;246'   ;;
        openai) printf -v "$__bg" '229;231;235'; printf -v "$__fg" '31;41;55';    printf -v "$__accent" '100;116;139'; printf -v "$__spinner" '16;163;127'  ;;
        xai)    printf -v "$__bg" '185;28;28';   printf -v "$__fg" '255;255;255'; printf -v "$__accent" '252;165;165'; printf -v "$__spinner" '248;113;113' ;;
        openrouter) printf -v "$__bg" '67;56;202'; printf -v "$__fg" '255;255;255'; printf -v "$__accent" '199;210;254'; printf -v "$__spinner" '129;140;248' ;;
        *)      printf -v "$__bg" '55;65;81';    printf -v "$__fg" '255;255;255'; printf -v "$__accent" '156;163;175'; printf -v "$__spinner" '156;163;175' ;;
    esac
}

draw_loading() {
    # Once any image is on the pane, stop the animated spinner. In tmux control mode every
    # redraw resyncs the pane to tmux's text grid and erases inline images, which live as
    # overlays outside it; the spinner is only safe to animate while no image is shown yet.
    [[ -n "$any_image_rendered" ]] && return 0
    local pending=() p __state
    for p in $seen_providers; do
        map_get __state provider_state "$p"
        [[ "$__state" == "querying" || "$__state" == "retrying" ]] && pending+=("$p")
    done
    [[ ${#pending[@]} -eq 0 ]] && return 0
    local frame="${SPINNERS[$((spinner_frame % ${#SPINNERS[@]}))]}"

    local list="" first=1 _bg _fg _accent _spinner chunk __label __attempt
    for p in "${pending[@]}"; do
        provider_palette _bg _fg _accent _spinner "$p"
        if [[ $first -eq 1 ]]; then
            first=0
        else
            list+=$'\033[2m, \033[0m'
        fi
        map_get __state provider_state "$p"
        local __label="$p"
        if [[ "$__state" == "retrying" ]]; then
            map_get __attempt provider_timing "$p"
            __label="$p (retry ${__attempt})"
        fi
        printf -v chunk '\033[1;38;2;%sm%s\033[0m' "$_spinner" "$__label"
        list+="$chunk"
    done

    provider_palette _bg _fg _accent _spinner "${pending[0]}"
    # A line wider than the pane would wrap and every tick would start a new row; the growing
    # stack scrolls the images off. With auto-wrap off the terminal truncates at the edge instead.
    printf '\033[?7l\r\033[K   \033[1;38;2;%sm%s\033[0m   \033[3mgenerating\033[0m   %s\033[?7h' \
        "$_spinner" "$frame" "$list"
}

clear_loading() {
    printf '\r\033[K'
}

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

# pane_cols — prints the pane's current column count, or returns 1 when it cannot be read.
pane_cols() {
    local size
    size=$(stty size < "$PANE_TTY" 2>/dev/null) || return 1
    size="${size##* }"
    [[ "$size" =~ ^[0-9]+$ && "$size" -gt 0 ]] || return 1
    printf '%s' "$size"
}

# redraw_all — clear screen and scrollback, then replay every provider block from state, in
# the order the blocks were first drawn.
redraw_all() {
    local p __state
    printf '\033[2J\033[3J\033[H'
    for p in $drawn_order; do
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

build_banner_line() {
    local out_var="$1" name="$2"
    local state ms model
    map_get state provider_state "$name"
    map_get ms provider_timing "$name"
    map_get model provider_model "$name"
    local bg fg accent _spinner
    provider_palette bg fg accent _spinner "$name"
    local upper
    upper=$(echo "$name" | tr '[:lower:]' '[:upper:]')

    local model_inline=""
    if [[ -n "$model" ]]; then
        printf -v model_inline ' \033[22;3;38;2;%sm%s\033[23;1;38;2;%sm' "$accent" "$model" "$fg"
    fi

    local timing_str=""
    if [[ -n "$ms" && "$ms" =~ ^[0-9]+$ ]]; then
        if (( ms >= 1000 )); then
            printf -v timing_str '%d.%ds' $((ms/1000)) $((ms%1000/100))
        else
            timing_str="${ms}ms"
        fi
    fi

    local status_inline=""
    case "$state" in
        complete) [[ -n "$timing_str" ]] && printf -v status_inline ' \033[22;3m(%s)\033[23;1m' "$timing_str" ;;
        error)    printf -v status_inline ' \033[22;3;31m(error)\033[23;1m' ;;
    esac

    printf -v "$out_var" '\033[1;38;2;%s;48;2;%sm  %s%s%s  \033[K\033[0m' \
        "$fg" "$bg" "$upper" "$model_inline" "$status_inline"
}

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

# retry_offer_prompt — shows the producer's offer (retry-offer: seconds it stays open, then one
# failed provider per line) with a countdown or its time budget, and answers it. r renames the
# file to .retry, which run-all reads as "yes"; Esc or end of input closes the pane; running out
# of time removes the offer, which run-all reads as "no". The failed providers' rendered flags
# are reset on r so their next complete or error draws a fresh block.
retry_offer_prompt() {
    local seconds names="" line remaining deadline __k p offer_line
    { read -r seconds; while IFS= read -r line || [[ -n "$line" ]]; do
        names="${names:+$names, }$line"; done; } < "$WATCH/retry-offer" 2>/dev/null || return 0
    [[ "$seconds" =~ ^[0-9]+$ ]] || seconds=45
    deadline=$((SECONDS + seconds))
    # Once any image is on the pane, the offer line is drawn once with its time budget instead
    # of ticking. In tmux control mode every rewrite of the line resyncs the pane to tmux's text
    # grid and erases inline images, which live as overlays outside it; a countdown is only safe
    # to animate while no image is shown yet. A resize redraw clears the line, so it is written
    # again after one.
    printf -v offer_line '\033[?7l\r\033[K\033[2m[r] retry failed (%s) · [esc/ctrl-d] close  (up to %ds)\033[0m \033[?7h' "$names" "$seconds"
    if [[ -n "$any_image_rendered" ]]; then
        printf '%s' "$offer_line"
    fi
    while [[ -f "$WATCH/retry-offer" && ! -f "$WATCH/.done" ]]; do
        remaining=$((deadline - SECONDS))
        if [[ $remaining -le 0 ]]; then
            rm -f "$WATCH/retry-offer"
            break
        fi
        [[ -z "$any_image_rendered" ]] && \
            printf '\033[?7l\r\033[K\033[2m[r] retry failed (%s) · [esc/ctrl-d] close  %ds\033[0m \033[?7h' "$names" "$remaining"
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
                if __cols=$(pane_cols) && reflow_to "$__cols"; then
                    [[ -n "$any_image_rendered" ]] && printf '%s' "$offer_line"
                fi
                ;;
            *) exit 0 ;;
        esac
    done
    printf '\r\033[K'
}

while true; do
    if [[ -f "$WATCH/status" ]]; then
        # The status file holds at most a handful of rows, so re-reading it each tick
        # with a fork-free read loop is cheap and replaces bash 4's mapfile.
        status_lines=()
        while IFS= read -r __line || [[ -n "$__line" ]]; do
            status_lines+=("$__line")
        done < "$WATCH/status" 2>/dev/null
        while [[ $status_lines_processed -lt ${#status_lines[@]} ]]; do
            line="${status_lines[$status_lines_processed]}"
            status_lines_processed=$((status_lines_processed + 1))
            { IFS= read -r provider; IFS= read -r state; IFS= read -r ms; IFS= read -r model; IFS= read -r path; } \
                < <(pane_parse_status_line "$line")
            note_provider "$provider"
            map_set provider_state "$provider" "$state"
            [[ -n "$ms" ]] && map_set provider_timing "$provider" "$ms"
            [[ -n "$model" ]] && map_set provider_model "$provider" "$model"
            [[ -n "$path" ]] && map_set provider_path "$provider" "$path"

            map_get already_rendered rendered "$provider"
            if [[ "$state" == "complete" ]]; then
                [[ -n "$already_rendered" ]] && continue
                map_set rendered "$provider" 1
                note_drawn "$provider"
                clear_loading
                draw_complete "$provider"
            elif [[ "$state" == "error" ]]; then
                [[ -n "$already_rendered" ]] && continue
                map_set rendered "$provider" 1
                note_drawn "$provider"
                clear_loading
                draw_error "$provider"
            fi
        done
    fi

    # Manifest entries lack provider attribution — render with a plain header.
    if [[ -f "$WATCH/manifest" ]]; then
        manifest_lines=()
        while IFS= read -r __mline || [[ -n "$__mline" ]]; do
            manifest_lines+=("$__mline")
        done < "$WATCH/manifest" 2>/dev/null
        while [[ $manifest_shown -lt ${#manifest_lines[@]} ]]; do
            mpath="${manifest_lines[$manifest_shown]}"
            manifest_shown=$((manifest_shown + 1))
            [[ -z "$mpath" ]] && continue
            clear_loading
            mname=$(basename "$mpath")
            printf '\n--- %s ---\n' "$mname"
            "$WATCH/render.sh" "$mpath"
            any_image_rendered=1
            echo
        done
    fi

    [[ -f "$WATCH/retry-offer" && ! -f "$WATCH/.done" ]] && retry_offer_prompt

    if __cols=$(pane_cols); then
        reflow_to "$__cols" || true
    fi

    spinner_frame=$((spinner_frame + 1))
    draw_loading

    [[ -f "$WATCH/.done" ]] && break
    sleep 0.12
done

clear_loading

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
WATCHEREOF
  } > "$watch_dir/watcher.sh"
  chmod +x "$watch_dir/watcher.sh"

  local safe_watch_dir safe_watcher
  safe_watch_dir=$(printf '%q' "$watch_dir")
  safe_watcher=$(printf '%q' "$watch_dir/watcher.sh")

  __pane_target_args
  local -a target_args=(${__PANE_TARGET_ARGS[@]+"${__PANE_TARGET_ARGS[@]}"})

  # Split the pane's longer axis so the streaming pane keeps a usable shape. A wide pane has
  # spare horizontal room, so a side column (-h, new pane to the right) leaves both panes wide
  # enough; a tall/narrow pane has spare vertical room, so a bottom band (-v, new pane below)
  # avoids a cramped sliver. Query the pane being split (not the attached client), and fall back
  # to -h when the dimensions don't read as positive integers.
  local split_flag='-h'
  local cols rows
  read -r cols rows <<<"$(tmux display-message -p ${target_args[@]+"${target_args[@]}"} '#{pane_width} #{pane_height}' 2>/dev/null)"
  if [[ "$cols" =~ ^[0-9]+$ && "$rows" =~ ^[0-9]+$ && "$cols" -gt 0 && "$rows" -gt 0 ]]; then
    [[ "$(pane_orientation "$cols" "$rows")" == "tall" ]] && split_flag='-v'
  fi

  tmux split-window "$split_flag" -l '30%' ${target_args[@]+"${target_args[@]}"} \
    "bash $safe_watcher $safe_watch_dir" \
    >/dev/null

  printf '%s' "$watch_dir"
}

# Prints the registry path that identifies this tmux window's shared streaming pane. Keyed by
# window rather than session because a pane only exists inside one window -- a provider running
# in a different window must get its own pane, not stream into one the user cannot see.
__pane_registry_dir() {
  __pane_target_args
  local -a target_args=(${__PANE_TARGET_ARGS[@]+"${__PANE_TARGET_ARGS[@]}"})
  local key
  key=$(tmux display-message -p ${target_args[@]+"${target_args[@]}"} '#{session_id}-#{window_id}' 2>/dev/null)
  key="${key//[^A-Za-z0-9]/_}"
  [[ -z "$key" ]] && key="default"
  local tmp="${TMPDIR:-/tmp}"
  printf '%s/display_pane_registry.%s' "${tmp%/}" "$key"
}

# Reports whether a registry entry still names a pane that can accept images, leaving the watch
# directory it names in __PANE_REGISTRY_DIR. The value travels in a global because bash 3.2 has
# no namerefs, and returning it here spares the caller a second pass over the same file.
# Usage: __pane_registry_is_live <registry_dir>
__pane_registry_is_live() {
  local reg="$1"
  __PANE_REGISTRY_DIR=""
  [[ -f "$reg/dir" ]] || return 1
  # The entry is written with printf and carries no trailing newline, so read fills the variable
  # and then reports EOF; the status says nothing about whether it read anything.
  IFS= read -r __PANE_REGISTRY_DIR < "$reg/dir" 2>/dev/null || :
  # .done means the watcher has left its poll loop for the dismiss prompt: the directory is
  # still there, but nothing will pick up an image written into it.
  [[ -n "$__PANE_REGISTRY_DIR" && -d "$__PANE_REGISTRY_DIR" && ! -f "$__PANE_REGISTRY_DIR/.done" ]]
}

# Opens the pane for a registry entry this process has just claimed and publishes it, printing
# the watch directory. The entry is released again if the pane cannot be opened, so a failure
# never leaves a claim that nothing will fulfil. Usage: __pane_publish <registry_dir>
__pane_publish() {
  local reg="$1" watch_dir
  if ! watch_dir=$(display_pane_open); then
    rm -rf "$reg"
    return 1
  fi
  # The pane remembers its own entry rather than recomputing the window's slot when it closes.
  # The slot may by then hold a different batch's entry: if this watcher dies while its provider
  # is still generating, a later batch retires the stale slot and republishes. Recomputing would
  # delete that live entry out from under the new pane.
  printf '%s' "$reg" > "$watch_dir/registry"
  printf '%s' "$watch_dir" > "$reg/dir"
  printf '%s' "$watch_dir"
}

# Prints the watch directory of the pane a registry entry names, when that pane can still accept
# images. Fails without printing otherwise. Usage: __pane_try_attach <registry_dir>
__pane_try_attach() {
  __pane_registry_is_live "$1" || return 1
  printf '%s' "$__PANE_REGISTRY_DIR"
}

# Returns the shared streaming pane for this tmux window, opening it if this is the first
# caller. Concurrent providers all land on the same pane instead of each splitting its own.
# Prints the watch directory to stdout, like display_pane_open. Usage: display_pane_attach_or_open
display_pane_attach_or_open() {
  if ! is_tmux; then
    echo "Not inside tmux, cannot open display pane" >&2
    return 1
  fi

  local reg
  reg=$(__pane_registry_dir)

  # Something is already streaming in this window: join it.
  if __pane_try_attach "$reg"; then
    return 0
  fi

  # The watcher removes its watch dir when it exits, so an entry can outlive the pane it names.
  # Retiring the dead entry here is what lets the next batch open a pane someone is watching.
  # An entry with nothing published yet is a different thing: its owner is still splitting the
  # pane, and it is waited for below. Retiring that one is how a batch forked in a single breath
  # ends up with two panes.
  if [[ -f "$reg/dir" ]]; then
    rm -rf "$reg"
  fi

  # The registry is a directory so that mkdir is the atomic create-once lock: exactly one
  # racing provider can win it, and the winner is the one that opens the pane.
  if mkdir "$reg" 2>/dev/null; then
    __pane_publish "$reg"
    return $?
  fi

  # Lost the claim, so the pane belongs to another provider. It may still be splitting, so give
  # it a bounded moment to publish rather than assuming the entry is abandoned.
  local waited=0
  while (( waited < 40 )); do
    if __pane_try_attach "$reg"; then
      return 0
    fi
    sleep 0.05
    waited=$((waited + 1))
  done

  # The claim was abandoned before a pane was published. Take it over, or it strands every
  # later provider in this window behind the same fruitless wait.
  rm -rf "$reg"
  mkdir "$reg" 2>/dev/null || return 1
  __pane_publish "$reg"
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

  # Streaming pane: append to shared manifest instead of opening a new pane
  if [[ -n "${DISPLAY_PANE_DIR:-}" && -d "${DISPLAY_PANE_DIR:-}" ]]; then
    display_pane_add "$file_path"
    return $?
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

  local cmd="echo --- ${safe_filename} ---; "
  local width="${DISPLAY_IMAGE_WIDTH:-512}"

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

# Opens a vertical side pane displaying multiple images stacked top-to-bottom.
# Uses -h (horizontal split) to create a tall pane on the right side.
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

  local terminal
  terminal=$(get_outer_terminal) || true

  local display_cmd=""
  local all_safe_paths=""
  for file_path in "${files[@]}"; do
    if [[ "$file_path" != /* ]]; then
      file_path="$(cd "$(dirname "$file_path")" && pwd)/$(basename "$file_path")"
    fi
    if [[ ! -f "$file_path" ]]; then
      continue
    fi

    display_cmd+=$(_build_image_cmd "$file_path" "$terminal")

    local safe_path
    safe_path=$(printf '%q' "$file_path")
    all_safe_paths+="${safe_path} "
  done

  # Single open call with all paths (macOS), fallback to per-file xdg-open (Linux)
  local finder_cmd="open -R ${all_safe_paths}2>/dev/null || for _f in ${all_safe_paths}; do xdg-open \"\$_f\" 2>/dev/null; done; "
  local preview_cmd="open -a Preview ${all_safe_paths}2>/dev/null || for _f in ${all_safe_paths}; do xdg-open \"\$_f\" 2>/dev/null; done; "

  if [[ -z "$display_cmd" ]]; then
    return 0
  fi

  local pane_width="30%"

  __pane_target_args
  local -a target_args=(${__PANE_TARGET_ARGS[@]+"${__PANE_TARGET_ARGS[@]}"})

  tmux split-window -h -l "$pane_width" ${target_args[@]+"${target_args[@]}"} \
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
