#!/usr/bin/env bash
# ABOUTME: Where a provider script writes its image: never over a file that already exists and
# ABOUTME: never through a symlink, so a run cannot destroy an earlier image or any other file.

# refuse_existing_output <path> — dies naming the path when it exists as a file or as a symlink,
# dangling included, so a run that could not save its image stops before it pays for one.
refuse_existing_output() {
  if [[ -e "$1" || -L "$1" ]]; then
    provider_die "Error: --output already exists, refusing to overwrite it: $1"
  fi
}

# save_image <path> — decodes the base64 on stdin into a temp file beside <path>, then gives it
# the name <path> with link(2). link refuses any entry already there (a file, a directory, a
# device, a FIFO, a symlink to any of them or a dangling one) and never follows it, so the image
# lands only at a name nothing held, and a save that fails removes its own temp file and nothing
# else. `ln` would not do: given a directory it links the file inside it. A filesystem without
# hard links fails the link, naming the path. Dies naming the path when it cannot save.
# Call it as `save_image "$OUTPUT" <<< "$data"`: on the right of a pipe it would run in a
# subshell, where provider_die's exit would not end the script.
save_image() {
  local path="$1" decode=-d tmp mode err
  [[ "$(uname)" == "Darwin" ]] && decode=-D
  tmp=$(mktemp "$(dirname "$path")/.image.XXXXXX" 2>&1) \
    || provider_die "Could not save the image to ${path}: ${tmp##*: }"
  # mktemp makes the file 0600; the image gets the mode a plain > would give it under the umask.
  printf -v mode '%o' $(( 0666 & ~0$(umask) ))
  if ! err=$(chmod "$mode" "$tmp" 2>&1 && base64 "$decode" 2>&1 >"$tmp" && link "$tmp" "$path" 2>&1); then
    rm -f "$tmp"
    provider_die "Could not save the image to ${path}: ${err##*: }"
  fi
  rm -f "$tmp"
}
