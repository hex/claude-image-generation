#!/usr/bin/env bash
# ABOUTME: Reads each --input-image's type from its first bytes, so a provider script refuses
# ABOUTME: any path that is not a PNG, JPEG, WebP or GIF file before it sends anything.

# read_input_mimes — sets INPUT_MIMES[i] to the MIME type of INPUT_IMAGES[i], or prints why the
# first refused path was refused and exits 1. The model chooses these paths, so the type comes
# from the bytes, never the name: a key file renamed to .png is still refused. The regular-file
# test runs first because reading a FIFO would block.
read_input_mimes() {
  INPUT_MIMES=()
  local img magic
  for img in ${INPUT_IMAGES[@]+"${INPUT_IMAGES[@]}"}; do
    if [[ ! -f "$img" || ! -r "$img" ]]; then
      echo "Error: --input-image is not a readable file: ${img}" >&2
      exit 1
    fi
    magic=$(head -c 12 < "$img" | od -An -tx1 | tr -d ' \n')
    case "$magic" in
      89504e470d0a1a0a*)           INPUT_MIMES+=("image/png") ;;
      ffd8ff*)                     INPUT_MIMES+=("image/jpeg") ;;
      474946383761*|474946383961*) INPUT_MIMES+=("image/gif") ;;
      52494646????????57454250)    INPUT_MIMES+=("image/webp") ;;
      *)
        echo "Error: --input-image is not a PNG, JPEG, WebP or GIF image: ${img}" >&2
        exit 1 ;;
    esac
  done
}
