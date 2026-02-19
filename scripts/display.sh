# ABOUTME: iTerm2 inline image display utility.
# ABOUTME: Detects iTerm2 and renders images directly in the terminal via OSC 1337.

# Returns 0 if running in iTerm2, 1 otherwise.
is_iterm2() {
  [[ "${TERM_PROGRAM:-}" == "iTerm.app" || "${LC_TERMINAL:-}" == "iTerm2" ]]
}

# Displays an image inline in iTerm2. No-op in other terminals.
# Usage: display_image <file_path>
display_image() {
  local file_path="$1"

  if ! is_iterm2; then
    return 0
  fi

  if [[ ! -f "$file_path" ]]; then
    return 0
  fi

  # Allow overriding the output target for testing (default: /dev/tty)
  local target="${DISPLAY_IMAGE_TARGET:-/dev/tty}"

  if [[ "$target" == "/dev/tty" && ! -w /dev/tty ]]; then
    return 0
  fi

  local filename name_b64 size image_b64
  filename=$(basename "$file_path")
  name_b64=$(printf '%s' "$filename" | base64 | tr -d '\n')
  size=$(wc -c < "$file_path" | tr -d ' ')
  image_b64=$(base64 < "$file_path" | tr -d '\n')

  # OSC 1337 inline image protocol:
  # \033] opens OSC, 1337 is iTerm2's code, \a (BEL) terminates.
  # width=80% scales to 80% of terminal width, preserving aspect ratio.
  printf '\033]1337;File=name=%s;size=%s;inline=1;width=80%%:%s\a' \
    "$name_b64" "$size" "$image_b64" > "$target"
}
