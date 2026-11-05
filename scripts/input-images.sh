#!/usr/bin/env bash
# ABOUTME: Copies each --input-image into a private temp dir and reads its type from the copy's
# ABOUTME: first bytes, so a provider script only ever sends PNG, JPEG, WebP or GIF bytes it checked.

# image_mime <file> — prints the MIME type the file's first bytes declare, or nothing.
image_mime() {
  local magic
  magic=$(head -c 12 < "$1" | od -An -tx1 | tr -d ' \n')
  case "$magic" in
    89504e470d0a1a0a*)           echo "image/png" ;;
    ffd8ff*)                     echo "image/jpeg" ;;
    474946383761*|474946383961*) echo "image/gif" ;;
    52494646????????57454250)    echo "image/webp" ;;
  esac
}

# snapshot_input_images — copies each INPUT_IMAGES path into $tmpdir (created here, removed on
# exit), points INPUT_IMAGES at the copy and fills INPUT_MIMES from it, index for index. Prints
# the refusal and exits 1 at the first path that is not a readable PNG, JPEG, WebP or GIF file.
snapshot_input_images() {
  INPUT_MIMES=()
  [[ ${#INPUT_IMAGES[@]} -gt 0 ]] || return 0
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/input-images.XXXXXX")
  trap 'rm -rf "$tmpdir"' EXIT
  local i src copy mime
  for i in "${!INPUT_IMAGES[@]}"; do
    src=${INPUT_IMAGES[$i]}
    if [[ ! -f "$src" || ! -r "$src" ]]; then
      echo "Error: --input-image is not a readable file: ${src}" >&2
      exit 1
    fi
    mime=$(image_mime "$src")
    if [[ -n "$mime" ]]; then
      copy="${tmpdir}/input-${i}"
      cat < "$src" > "$copy"
      mime=$(image_mime "$copy")
    fi
    if [[ -z "$mime" ]]; then
      echo "Error: --input-image is not a PNG, JPEG, WebP or GIF image: ${src}" >&2
      exit 1
    fi
    mv "$copy" "${copy}.${mime#image/}"
    INPUT_IMAGES[$i]="${copy}.${mime#image/}"
    INPUT_MIMES+=("$mime")
  done
}
