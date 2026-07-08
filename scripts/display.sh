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
  local -a target_args=()
  if [[ -n "${TMUX_PANE:-}" ]]; then
    target_args=(-t "$TMUX_PANE")
  fi

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

# Provider-script helpers — no-op when DISPLAY_PANE_DIR is unset, so providers
# can call them unconditionally. begin records the querying state and starts
# the timer; finish/fail compute elapsed ms and emit complete/error events.
display_pane_begin() {
  [[ -z "${DISPLAY_PANE_DIR:-}" ]] && return 0
  local provider="$1" model="$2"
  __PANE_START_MS=$(__pane_now_ms)
  display_pane_status "$provider" querying "" "$model" ""
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
}

display_pane_fail() {
  [[ -z "${DISPLAY_PANE_DIR:-}" ]] && return 0
  local provider="$1" model="$2" message="$3"
  display_pane_error "$provider" "$message"
  display_pane_status "$provider" error "" "$model" ""
}

# Convenience for provider scripts. Reads PROVIDER_NAME and MODEL from the
# caller's scope. provider_die emits the error event then exits with code 1.
# provider_finish emits the complete event and falls back to direct terminal
# display when running outside a streaming pane.
provider_die() {
  local msg="$*"
  echo "$msg" >&2
  display_pane_fail "${PROVIDER_NAME:-unknown}" "${MODEL:-}" "$msg"
  exit 1
}

provider_finish() {
  local output="$1"
  display_pane_finish "${PROVIDER_NAME:-unknown}" "${MODEL:-}" "$output"
  [[ -z "${DISPLAY_PANE_DIR:-}" ]] && display_image "$output"
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
      # Without -r, PNGs with DPI metadata render at native size instead of
      # the requested width — the bug this combination of flags closes.
      render_cmd="$(printf '%q' "$imgcat_path") -W ${width}px -H ${height}px -r \"\$1\""
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

  cat > "$watch_dir/render.sh" <<RENDEREOF
#!/bin/bash
$render_cmd
RENDEREOF
  chmod +x "$watch_dir/render.sh"

  cat > "$watch_dir/watcher.sh" <<'WATCHEREOF'
#!/bin/bash
WATCH="$1"
trap 'rm -rf "$WATCH"' EXIT

# macOS ships bash 3.2, which has no associative arrays. Provider attributes are kept
# in variables named <map>_<provider> (state, timing, model, path, rendered), and the
# set of providers seen so far is tracked as a space-separated list so we can iterate.
seen_providers=""
status_lines_processed=0
manifest_shown=0
spinner_frame=0
SPINNERS=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

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

# Provider palette: emits four space-separated RGB triplets — bg, fg, accent,
# spinner — into the variables named by the first four args. Single source of
# truth for every place we color provider output. WCAG AA across themes.
provider_palette() {
    local __bg="$1" __fg="$2" __accent="$3" __spinner="$4" name="$5"
    case "$name" in
        gemini) printf -v "$__bg" '30;64;175';   printf -v "$__fg" '255;255;255'; printf -v "$__accent" '147;197;253'; printf -v "$__spinner" '59;130;246'   ;;
        openai) printf -v "$__bg" '229;231;235'; printf -v "$__fg" '31;41;55';    printf -v "$__accent" '100;116;139'; printf -v "$__spinner" '229;231;235' ;;
        xai)    printf -v "$__bg" '185;28;28';   printf -v "$__fg" '255;255;255'; printf -v "$__accent" '252;165;165'; printf -v "$__spinner" '248;113;113' ;;
        *)      printf -v "$__bg" '55;65;81';    printf -v "$__fg" '255;255;255'; printf -v "$__accent" '156;163;175'; printf -v "$__spinner" '156;163;175' ;;
    esac
}

draw_loading() {
    local pending=() p __state
    for p in $seen_providers; do
        map_get __state provider_state "$p"
        [[ "$__state" == "querying" ]] && pending+=("$p")
    done
    [[ ${#pending[@]} -eq 0 ]] && return 0
    local frame="${SPINNERS[$((spinner_frame % ${#SPINNERS[@]}))]}"

    local list="" first=1 _bg _fg _accent _spinner chunk
    for p in "${pending[@]}"; do
        provider_palette _bg _fg _accent _spinner "$p"
        if [[ $first -eq 1 ]]; then
            first=0
        else
            list+=$'\033[2m, \033[0m'
        fi
        printf -v chunk '\033[1;38;2;%sm%s\033[0m' "$_spinner" "$p"
        list+="$chunk"
    done

    provider_palette _bg _fg _accent _spinner "${pending[0]}"
    printf '\r\033[K   \033[1;38;2;%sm%s\033[0m   \033[2mgenerating\033[0m   %s' \
        "$_spinner" "$frame" "$list"
}

clear_loading() {
    printf '\r\033[K'
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
            IFS=$'\t' read -r provider state ms model path <<<"$line"
            note_provider "$provider"
            map_set provider_state "$provider" "$state"
            [[ -n "$ms" ]] && map_set provider_timing "$provider" "$ms"
            [[ -n "$model" ]] && map_set provider_model "$provider" "$model"
            [[ -n "$path" ]] && map_set provider_path "$provider" "$path"

            map_get already_rendered rendered "$provider"
            if [[ "$state" == "complete" ]]; then
                [[ -n "$already_rendered" ]] && continue
                map_set rendered "$provider" 1
                clear_loading
                printf '\033Ptmux;\033\033]1337;SetMark\a\033\\'
                build_banner_line banner_line "$provider"
                printf '\n\n%s\n\n' "$banner_line"
                map_get ppath provider_path "$provider"
                if [[ -n "$ppath" && -f "$ppath" ]]; then
                    "$WATCH/render.sh" "$ppath"
                fi
                printf '\n\n'
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
            echo
        done
    fi

    spinner_frame=$((spinner_frame + 1))
    draw_loading

    [[ -f "$WATCH/.done" ]] && break
    sleep 0.12
done

clear_loading

_esc=$(printf '\033')
printf '[f]inder [p]review [esc/ctrl-d] close '
while true; do
    read -n1 -s -r _key || break
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
  chmod +x "$watch_dir/watcher.sh"

  local safe_watch_dir safe_watcher
  safe_watch_dir=$(printf '%q' "$watch_dir")
  safe_watcher=$(printf '%q' "$watch_dir/watcher.sh")

  local -a target_args=()
  if [[ -n "${TMUX_PANE:-}" ]]; then
    target_args=(-t "$TMUX_PANE")
  fi

  tmux split-window -h -l '30%' ${target_args[@]+"${target_args[@]}"} \
    "bash $safe_watcher $safe_watch_dir" \
    >/dev/null

  printf '%s' "$watch_dir"
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

  local -a target_args=()
  if [[ -n "${TMUX_PANE:-}" ]]; then
    target_args=(-t "$TMUX_PANE")
  fi

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
