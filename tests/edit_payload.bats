#!/usr/bin/env bats
# ABOUTME: Runs the provider edit paths to completion with a stubbed curl and a real
# ABOUTME: multi-megabyte input image, guarding against argv-size limits in payload building.

load test_helper

# A real image whose base64 (~1.8 MB) exceeds ARG_MAX, so passing it as a jq argument
# instead of streaming it fails with "argument list too long".
BIG_IMAGE="${PLUGIN_ROOT}/test-input.png"

setup() {
  MOCK_DIR="${BATS_TMPDIR}/edit_mocks_$$"
  mkdir -p "$MOCK_DIR"
  OUT="${BATS_TMPDIR}/edit_out_$$.png"
  rm -f "$OUT"
  disable_display
  export DISPLAY_PANE_DIR="${MOCK_DIR}/pane"
  mkdir -p "$DISPLAY_PANE_DIR"
}

teardown() {
  rm -rf "$MOCK_DIR" 2>/dev/null || true
  rm -f "$OUT" 2>/dev/null || true
}

# Writes the request-capturing prelude shared by every curl stub in this file, overwriting
# $MOCK_DIR/curl with a shebang and the argv walk. curl_with_retry rewrites a streamed
# `--data-binary @-` body to `@<tempfile>` before every real curl invocation, so a stub never
# actually sees `@-` from a provider script -- what it sees is `@<path>` from curl_with_retry,
# or (openai's -d/-F calls, which pass no --data-binary at all) nothing, in which case it falls
# back to draining stdin. Callers append their own response-serving lines after this and chmod
# the result themselves.
__stub_curl_prelude() {
  cat > "$MOCK_DIR/curl" <<'STUB'
#!/bin/bash
d="$(dirname "$0")"
body_arg=""
prev=""
for a in "$@"; do
  [ "$prev" = "--data-binary" ] && body_arg="$a"
  prev="$a"
done
case "$body_arg" in
  @-) cat > "${d}/request.txt" 2>/dev/null ;;
  @*) cp "${body_arg#@}" "${d}/request.txt" 2>/dev/null ;;
  *)  cat > "${d}/request.txt" 2>/dev/null ;;
esac
STUB
}

# Installs a curl that captures the request body (see __stub_curl_prelude) then prints a canned
# body followed by the HTTP status on the last line, matching the `-w "\n%{http_code}"` the
# scripts rely on. The canned image data is base64 for "fake", so a fully working pipeline
# writes exactly "fake" to the output.
stub_curl() {
  printf '%s\n200\n' "$1" > "$MOCK_DIR/response.txt"
  __stub_curl_prelude
  cat >> "$MOCK_DIR/curl" <<'STUB'
cat "${d}/response.txt"
STUB
  chmod +x "$MOCK_DIR/curl"
  export PATH="$MOCK_DIR:$PATH"
}

# assert_edit_succeeds <output-var> — the run must not hit an argv-size limit (case
# insensitive, since bash prints "Argument list too long"), must exit 0, and must decode
# the stub's base64 through to the output file.
assert_edit_succeeds() {
  if echo "$output" | grep -qi 'argument list too long'; then
    echo "Payload building exceeded ARG_MAX:"
    echo "$output"
    return 1
  fi
  if echo "$output" | grep -qi 'unbound variable'; then
    echo "Script emitted a set -u unbound-variable error (e.g. a trap referencing an out-of-scope var):"
    echo "$output"
    return 1
  fi
  assert_status 0
  local content
  content=$(cat "$OUT" 2>/dev/null)
  [[ "$content" == "fake" ]] || {
    echo "Expected decoded output 'fake', got: '${content}'"
    echo "$output"
    return 1
  }
}

@test "gemini: edit mode builds a payload for a multi-megabyte image" {
  [[ -f "$BIG_IMAGE" ]] || skip "test-input.png not present"
  stub_curl '{"candidates":[{"content":{"parts":[{"inlineData":{"mimeType":"image/png","data":"ZmFrZQ=="}}]}}]}'

  GEMINI_API_KEY="$DUMMY_GEMINI_KEY" run bash "${PLUGIN_ROOT}/scripts/gemini.sh" \
    --mode edit --prompt "add a rainbow" --input-image "$BIG_IMAGE" --output "$OUT"

  assert_edit_succeeds
}

@test "xai: edit mode builds a payload for a multi-megabyte image" {
  [[ -f "$BIG_IMAGE" ]] || skip "test-input.png not present"
  stub_curl '{"data":[{"b64_json":"ZmFrZQ=="}]}'

  XAI_API_KEY="$DUMMY_XAI_KEY" run bash "${PLUGIN_ROOT}/scripts/xai.sh" \
    --mode edit --prompt "add a rainbow" --input-image "$BIG_IMAGE" --output "$OUT"

  assert_edit_succeeds
}

@test "gemini: edit mode with two --input-image builds two inlineData parts" {
  [[ -f "$BIG_IMAGE" ]] || skip "test-input.png not present"
  stub_curl '{"candidates":[{"content":{"parts":[{"inlineData":{"mimeType":"image/png","data":"ZmFrZQ=="}}]}}]}'

  GEMINI_API_KEY="$DUMMY_GEMINI_KEY" run bash "${PLUGIN_ROOT}/scripts/gemini.sh" \
    --mode edit --prompt "combine these" \
    --input-image "$BIG_IMAGE" --input-image "$BIG_IMAGE" --output "$OUT"

  assert_edit_succeeds
  local part_count
  part_count=$(jq '[.contents[0].parts[] | select(.inlineData)] | length' "$MOCK_DIR/request.txt")
  [[ "$part_count" -eq 2 ]] || {
    echo "Expected 2 inlineData parts, got: $part_count"
    return 1
  }
}

@test "openai: two --input-image emits two image[] parts" {
  [[ -f "$BIG_IMAGE" ]] || skip "test-input.png not present"
  cat > "$MOCK_DIR/curl" <<STUB
#!/bin/bash
printf '%s\n' "\$@" > "${MOCK_DIR}/argv.txt"
printf '%s\n200\n' '{"data":[{"b64_json":"ZmFrZQ=="}]}'
STUB
  chmod +x "$MOCK_DIR/curl"
  export PATH="$MOCK_DIR:$PATH"

  OPENAI_API_KEY="$DUMMY_OPENAI_KEY" run bash "${PLUGIN_ROOT}/scripts/openai.sh" \
    --mode edit --prompt "combine these" \
    --input-image "$BIG_IMAGE" --input-image "$BIG_IMAGE" --output "$OUT"

  assert_edit_succeeds
  local count
  count=$(grep -c '^image\[\]=@' "$MOCK_DIR/argv.txt")
  [[ "$count" -eq 2 ]] || {
    echo "Expected 2 image[]=@ parts, got: $count"
    cat "$MOCK_DIR/argv.txt"
    return 1
  }
}

@test "xai: two --input-image builds a two-element images array" {
  [[ -f "$BIG_IMAGE" ]] || skip "test-input.png not present"
  stub_curl '{"data":[{"b64_json":"ZmFrZQ=="}]}'

  XAI_API_KEY="$DUMMY_XAI_KEY" run bash "${PLUGIN_ROOT}/scripts/xai.sh" \
    --mode edit --prompt "combine these" \
    --input-image "$BIG_IMAGE" --input-image "$BIG_IMAGE" --output "$OUT"

  assert_edit_succeeds
  local count
  count=$(jq '.images | length' "$MOCK_DIR/request.txt")
  [[ "$count" -eq 2 ]] || {
    echo "Expected images array of length 2, got: $count"
    return 1
  }
}

@test "xai: --quality lands in the request body" {
  stub_curl '{"data":[{"b64_json":"ZmFrZQ=="}]}'

  # grok-imagine-image-2.0 bills at the quality served; omitting the field means auto,
  # which is low for generation, so a caller who wants medium has to be able to say so.
  XAI_API_KEY="$DUMMY_XAI_KEY" run bash "${PLUGIN_ROOT}/scripts/xai.sh" \
    --mode generate --prompt "a cat" --quality medium --output "$OUT"

  assert_edit_succeeds
  local quality
  quality=$(jq -r '.quality' "$MOCK_DIR/request.txt")
  [[ "$quality" == "medium" ]] || {
    echo "Expected quality 'medium' in the request body, got: $quality"
    cat "$MOCK_DIR/request.txt"
    return 1
  }
}

@test "xai: the reported format follows the bytes the API returned" {
  # grok-imagine-image-2.0 answers with JPEG data even though the file keeps the caller's
  # name, so the format line has to come from the saved bytes, not a constant.
  stub_curl '{"data":[{"b64_json":"/9j/4EpGSUZmYWtl"}]}'

  XAI_API_KEY="$DUMMY_XAI_KEY" run bash "${PLUGIN_ROOT}/scripts/xai.sh" \
    --mode generate --prompt "a cat" --output "$OUT"

  assert_status 0
  assert_output_contains "Format: jpeg"
}

@test "openrouter: edit mode builds a payload for a multi-megabyte image" {
  [[ -f "$BIG_IMAGE" ]] || skip "test-input.png not present"
  stub_curl '{"choices":[{"message":{"images":[{"image_url":{"url":"data:image/png;base64,ZmFrZQ=="}}]}}]}'

  OPENROUTER_API_KEY="$DUMMY_OPENROUTER_KEY" run bash "${PLUGIN_ROOT}/scripts/openrouter.sh" \
    --mode edit --prompt "add a rainbow" --input-image "$BIG_IMAGE" --output "$OUT"

  assert_edit_succeeds
}

@test "openrouter: two --input-image builds two image_url content parts" {
  [[ -f "$BIG_IMAGE" ]] || skip "test-input.png not present"
  stub_curl '{"choices":[{"message":{"images":[{"image_url":{"url":"data:image/png;base64,ZmFrZQ=="}}]}}]}'

  OPENROUTER_API_KEY="$DUMMY_OPENROUTER_KEY" run bash "${PLUGIN_ROOT}/scripts/openrouter.sh" \
    --mode edit --prompt "combine these" \
    --input-image "$BIG_IMAGE" --input-image "$BIG_IMAGE" --output "$OUT"

  assert_edit_succeeds
  local count
  count=$(jq '[.messages[0].content[] | select(.type == "image_url")] | length' "$MOCK_DIR/request.txt")
  [[ "$count" -eq 2 ]] || {
    echo "Expected 2 image_url content parts, got: $count"
    return 1
  }
}

@test "gemini: generate mode with --input-image includes a reference part" {
  [[ -f "$BIG_IMAGE" ]] || skip "test-input.png not present"
  stub_curl '{"candidates":[{"content":{"parts":[{"inlineData":{"mimeType":"image/png","data":"ZmFrZQ=="}}]}}]}'

  GEMINI_API_KEY="$DUMMY_GEMINI_KEY" run bash "${PLUGIN_ROOT}/scripts/gemini.sh" \
    --mode generate --prompt "a cat like this" \
    --input-image "$BIG_IMAGE" --output "$OUT"

  assert_edit_succeeds
  local part_count
  part_count=$(jq '[.contents[0].parts[] | select(.inlineData)] | length' "$MOCK_DIR/request.txt")
  [[ "$part_count" -eq 1 ]] || {
    echo "Expected 1 inlineData part, got: $part_count"
    return 1
  }
}

# success_body <provider> — a 200 body that the provider decodes to the image "fake".
success_body() {
  case "$1" in
    gemini)     echo '{"candidates":[{"content":{"parts":[{"inlineData":{"mimeType":"image/png","data":"ZmFrZQ=="}}]}}]}' ;;
    openai|xai) echo '{"data":[{"b64_json":"ZmFrZQ=="}]}' ;;
    openrouter) echo '{"choices":[{"message":{"images":[{"image_url":{"url":"data:image/png;base64,ZmFrZQ=="}}]}}]}' ;;
  esac
}

# run_provider_edit <provider> <input-image>... — one provider's edit mode, with every dummy key set.
run_provider_edit() {
  local provider="$1" img
  shift
  local -a image_args=()
  for img in "$@"; do image_args+=(--input-image "$img"); done
  GEMINI_API_KEY="$DUMMY_GEMINI_KEY" OPENAI_API_KEY="$DUMMY_OPENAI_KEY" \
    XAI_API_KEY="$DUMMY_XAI_KEY" OPENROUTER_API_KEY="$DUMMY_OPENROUTER_KEY" \
    run bash "${PLUGIN_ROOT}/scripts/${provider}.sh" --mode edit --prompt "add a rainbow" \
    "${image_args[@]}" --output "$OUT"
}

@test "every provider refuses an input file that is not an image, before sending anything" {
  local not_image="$MOCK_DIR/key.png"
  printf 'stand-in for a private key\n' > "$not_image"
  local p
  for p in gemini openai xai openrouter; do
    rm -f "$MOCK_DIR/request.txt"
    stub_curl "$(success_body "$p")"
    run_provider_edit "$p" "$not_image"
    [[ "$status" -eq 1 && "$output" == "Error: --input-image is not a PNG, JPEG, WebP or GIF image: ${not_image}" ]] || {
      echo "$p: expected status 1 and the refusal, got status $status: $output"; return 1; }
    [[ ! -e "$MOCK_DIR/request.txt" ]] || { echo "$p: called curl"; return 1; }
  done
}

@test "every provider refuses a missing path or a device as an input image" {
  local p path
  for p in gemini openai xai openrouter; do
    for path in "$MOCK_DIR/missing.png" /dev/zero; do
      rm -f "$MOCK_DIR/request.txt"
      stub_curl "$(success_body "$p")"
      run_provider_edit "$p" "$path"
      [[ "$status" -eq 1 && "$output" == "Error: --input-image is not a readable file: ${path}" ]] || {
        echo "$p ${path}: expected status 1 and the refusal, got status $status: $output"; return 1; }
      [[ ! -e "$MOCK_DIR/request.txt" ]] || { echo "$p ${path}: called curl"; return 1; }
    done
  done
}

@test "gemini, xai and openrouter send each input image's own bytes, typed by its content" {
  # The second file is named .png but holds GIF bytes.
  local first="${PLUGIN_ROOT}/tests/fixtures/oversized.png" second="$MOCK_DIR/second.png"
  printf 'GIF89a bytes of the second image' > "$second"
  local data_url='capture("^data:(?<m>[^;]+);base64,(?<d>.*)$") | "\(.m) \(.d)"'
  local p query parts count mime1 data1 mime2 data2
  for p in gemini xai openrouter; do
    case "$p" in
      gemini)     query='.contents[0].parts[] | select(.inlineData) | .inlineData | "\(.mimeType) \(.data)"' ;;
      xai)        query=".images[].url | ${data_url}" ;;
      openrouter) query=".messages[0].content[] | select(.type == \"image_url\") | .image_url.url | ${data_url}" ;;
    esac
    stub_curl "$(success_body "$p")"
    run_provider_edit "$p" "$first" "$second"
    assert_edit_succeeds
    parts=$(jq -r "$query" "$MOCK_DIR/request.txt")
    count=$(printf '%s\n' "$parts" | wc -l | tr -d ' ')
    [[ "$count" -eq 2 ]] || { echo "$p: expected 2 image parts, got $count"; return 1; }
    { read -r mime1 data1; read -r mime2 data2; } <<< "$parts"
    [[ "$mime1" == "image/png" && "$mime2" == "image/gif" ]] || {
      echo "$p: expected image/png then image/gif, got $mime1 then $mime2"; return 1; }
    printf '%s' "$data1" | base64 --decode | cmp -s - "$first" || { echo "$p: first part is not the first image"; return 1; }
    printf '%s' "$data2" | base64 --decode | cmp -s - "$second" || { echo "$p: second part is not the second image"; return 1; }
  done
}

# route_curl_to_local_server <body> — installs a curl that runs the real curl against
# tests/one_request_server.py in place of the provider's https URL. The server saves the whole
# request to $MOCK_DIR/request.raw before it answers 200 with <body>. An executable
# $MOCK_DIR/before_curl runs just before the real curl.
route_curl_to_local_server() {
  local real_curl
  real_curl=$(command -v curl)
  printf '%s' "$1" > "$MOCK_DIR/response.body"
  cat > "$MOCK_DIR/curl" <<STUB
#!/bin/bash
d="$MOCK_DIR"
rm -f "\$d/port"
python3 -I "${PLUGIN_ROOT}/tests/one_request_server.py" "\$d/port" "\$d/request.raw" "\$d/response.body" &
server_pid=\$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -s "\$d/port" ] && break
  sleep 0.1
done
if [ ! -s "\$d/port" ]; then
  kill "\$server_pid" 2>/dev/null
  echo "the local server never started" >&2
  exit 7
fi
port=\$(cat "\$d/port")
args=()
for a in "\$@"; do
  case "\$a" in https://*) a="http://127.0.0.1:\$port/\${a#https://*/}" ;; esac
  args+=("\$a")
done
[ -x "\$d/before_curl" ] && "\$d/before_curl"
"$real_curl" --max-time 5 "\${args[@]}"
curl_status=\$?
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  kill -0 "\$server_pid" 2>/dev/null || break
  sleep 0.1
done
kill "\$server_pid" 2>/dev/null
exit \$curl_status
STUB
  chmod +x "$MOCK_DIR/curl"
  export PATH="$MOCK_DIR:$PATH"
}

@test "openai: the request carries text fields as typed and each image's own bytes" {
  command -v python3 >/dev/null || skip "needs python3"
  # curl's -F reads a value starting with '@' from a file, splits an image path at ',' and ';',
  # and reads the path '-' from stdin. Every free-text field must arrive as typed, and each image
  # as its own bytes, never as a file curl split out of its name or as the script's stdin.
  local dir="$MOCK_DIR/odd"
  mkdir -p "$dir"
  local typed="@${dir}/notes.txt"
  printf 'canary from a file named in a field\n' > "$dir/notes.txt"
  printf 'canary from a split name\n' > "$dir/a"
  printf 'canary from stdin\n' > "$dir/stdin.txt"
  local odd="$dir/a,b;c\"d\\e.png"
  { printf '\211PNG\r\n\032\n'; printf 'bytes of the oddly named image'; } > "$odd"
  { printf '\211PNG\r\n\032\n'; printf 'bytes of the image named dash'; } > "$dir/-"
  route_curl_to_local_server "$(success_body openai)"
  cd "$dir"

  IMAGE_MAX_RETRIES=0 OPENAI_API_KEY="$DUMMY_OPENAI_KEY" run bash "${PLUGIN_ROOT}/scripts/openai.sh" \
    --mode edit --prompt "$typed" --model "$typed" --size "$typed" --quality "$typed" \
    --background "$typed" --output-format webp --output-compression "$typed" \
    --input-image "$odd" --input-image - --output "$OUT" < "$dir/stdin.txt"

  assert_edit_succeeds
  local request="$MOCK_DIR/request.raw" count
  count=$(grep -cxF "${typed}"$'\r' "$request")
  [[ "$count" -eq 6 ]] || { echo "expected 6 fields sent as typed, got $count:"; cat "$request"; return 1; }
  grep -qF 'bytes of the oddly named image' "$request" || { echo "oddly named image missing:"; cat "$request"; return 1; }
  grep -qF 'bytes of the image named dash' "$request" || { echo "image named - missing:"; cat "$request"; return 1; }
  count=$(grep -cxF $'Content-Type: image/png\r' "$request")
  [[ "$count" -eq 2 ]] || { echo "expected 2 parts typed image/png, got $count:"; cat "$request"; return 1; }
  if grep -qF 'canary' "$request"; then echo "uploaded something that is not an input image:"; cat "$request"; return 1; fi
}

@test "openai: an input file replaced after the check still uploads the bytes that were checked" {
  command -v python3 >/dev/null || skip "needs python3"
  local image="$MOCK_DIR/photo.png"
  { printf '\211PNG\r\n\032\n'; printf 'bytes that were checked'; } > "$image"
  printf 'canary written after the check\n' > "$MOCK_DIR/replacement"
  printf '#!/bin/bash\ncp "%s" "%s"\n' "$MOCK_DIR/replacement" "$image" > "$MOCK_DIR/before_curl"
  chmod +x "$MOCK_DIR/before_curl"
  route_curl_to_local_server "$(success_body openai)"

  run_provider_edit openai "$image"

  assert_edit_succeeds
  grep -qF 'bytes that were checked' "$MOCK_DIR/request.raw" || { echo "checked bytes missing:"; cat "$MOCK_DIR/request.raw"; return 1; }
  if grep -qF 'canary' "$MOCK_DIR/request.raw"; then echo "uploaded the replacement:"; cat "$MOCK_DIR/request.raw"; return 1; fi
}

@test "every provider removes its copies of the input images when it exits" {
  local scratch="$MOCK_DIR/tmp" p path
  for p in gemini openai xai openrouter; do
    for path in "${PLUGIN_ROOT}/tests/fixtures/oversized.png" "$MOCK_DIR/key.png"; do
      printf 'stand-in for a private key\n' > "$MOCK_DIR/key.png"
      rm -rf "$scratch" && mkdir -p "$scratch"
      stub_curl "$(success_body "$p")"
      TMPDIR="$scratch" run_provider_edit "$p" "$path"
      [[ -z "$(ls -A "$scratch")" ]] || { echo "$p ${path}: left behind:"; ls -A "$scratch"; return 1; }
    done
  done
}

# stub_curl_once_503 <body> — first call answers 503 with an error body, later calls the
# canned body with 200. Captures the request body the same way stub_curl does.
stub_curl_once_503() {
  printf '%s\n200\n' "$1" > "$MOCK_DIR/response.txt"
  __stub_curl_prelude
  cat >> "$MOCK_DIR/curl" <<'STUB'
n=$(cat "${d}/calls" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "${d}/calls"
if [ "$n" -eq 1 ]; then printf '{"error":{"message":"overloaded"}}\n503\n'; exit 0; fi
cat "${d}/response.txt"
STUB
  chmod +x "$MOCK_DIR/curl"
  export PATH="$MOCK_DIR:$PATH"
}

@test "every provider retries a 503 and reports the attempt to the pane" {
  local input_file="$MOCK_DIR/big-input.png"
  { printf '\211PNG\r\n\032\n'; head -c 3000000 /dev/urandom; } > "$input_file"
  local p
  for p in gemini openai xai openrouter; do
    rm -f "$MOCK_DIR/calls" "$DISPLAY_PANE_DIR/status"
    stub_curl_once_503 "$(success_body "$p")"
    IMAGE_RETRY_DELAY=0 GEMINI_API_KEY="$DUMMY_GEMINI_KEY" OPENAI_API_KEY="$DUMMY_OPENAI_KEY" \
      XAI_API_KEY="$DUMMY_XAI_KEY" OPENROUTER_API_KEY="$DUMMY_OPENROUTER_KEY" \
      run bash "${PLUGIN_ROOT}/scripts/${p}.sh" --mode edit --prompt "add a rainbow" \
      --input-image "$input_file" --output "$OUT"
    assert_edit_succeeds
    [[ "$(cat "$MOCK_DIR/calls")" -eq 2 ]] || { echo "$p: expected 2 curl calls, got $(cat "$MOCK_DIR/calls")"; return 1; }
    grep -q "$(printf '^%s\tretrying\t1/3\t' "$p")" "$DISPLAY_PANE_DIR/status" || {
      echo "$p: no retrying status line in the pane:"; cat "$DISPLAY_PANE_DIR/status"; return 1; }
  done
}

@test "a provider that still fails after retries says so in its error" {
  stub_curl_once_503 '{"error":{"message":"still overloaded"}}'
  # Make every call a 503 by making the canned success a 503 too.
  printf '{"error":{"message":"still overloaded"}}\n503\n' > "$MOCK_DIR/response.txt"
  IMAGE_RETRY_DELAY=0 XAI_API_KEY="$DUMMY_XAI_KEY" run bash "${PLUGIN_ROOT}/scripts/xai.sh" \
    --mode generate --prompt "a cat" --output "$OUT"
  assert_status 1
  assert_output_contains "still overloaded"
  assert_output_contains "(after 3 retries)"
  grep -q "after 3 retries" "$DISPLAY_PANE_DIR/errors/xai.txt" || { echo "pane error text lacks the retry count"; return 1; }
}
