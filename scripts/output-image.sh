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

# save_image <path> — decodes the base64 on stdin into <path>. noclobber makes the redirect
# refuse a path that exists by now, a symlink too, so the image lands only in a file this call
# created; a decode that fails removes that file. Dies naming the path when it cannot save.
# Call it as `save_image "$OUTPUT" <<< "$data"`: on the right of a pipe it would run in a
# subshell, where provider_die's exit would not end the script.
save_image() {
  local path="$1" decode=-d status=0 err
  [[ "$(uname)" == "Darwin" ]] && decode=-D
  err=$(set -C; { base64 "$decode" || exit 3; } 2>&1 >"$path") || status=$?
  [[ $status -eq 0 ]] && return 0
  [[ $status -eq 3 ]] && rm -f "$path"
  provider_die "Could not save the image to ${path}: ${err##*: }"
}
