#!/usr/bin/env bash
# ABOUTME: Reads each --input-image's type from its first bytes, so a provider script refuses
# ABOUTME: any path that is not a PNG, JPEG, WebP or GIF file before it sends anything.

# read_input_mimes — fills INPUT_MIMES from INPUT_IMAGES, index for index, or prints the refusal
# and exits 1 at the first path that is not a readable PNG, JPEG, WebP or GIF file.
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
