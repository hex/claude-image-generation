#!/usr/bin/env bats
# ABOUTME: Tests check-status.sh with a stub curl that answers per URL: unset, rejected and
# ABOUTME: accepted keys, listed and missing models, network failures, and where keys travel.

load test_helper

SCRIPT="${PLUGIN_ROOT}/scripts/check-status.sh"
# The bash a stock Mac runs the script under, so 3.2 is exercised at runtime too.
SYSTEM_BASH="/bin/bash"

GEMINI_URL="generativelanguage.googleapis.com/v1beta/models"
OPENAI_URL="api.openai.com/v1/models"
XAI_URL="api.x.ai/v1/image-generation-models"
OPENROUTER_KEY_URL="openrouter.ai/api/v1/key"
OPENROUTER_LIST_URL="openrouter.ai/api/v1/models"

setup() {
  disable_display
  isolate_tmpdir
  MOCK_DIR="${BATS_TMPDIR}/status_mocks_$$_${BATS_TEST_NUMBER}"
  mkdir -p "$MOCK_DIR"
  : > "$MOCK_DIR/routes"
  install_stub_curl
  unset GEMINI_API_KEY OPENAI_API_KEY XAI_API_KEY GROK_API_KEY OPENROUTER_API_KEY
  unset GEMINI_IMAGE_MODEL OPENAI_IMAGE_MODEL XAI_IMAGE_MODEL OPENROUTER_IMAGE_MODEL
}

teardown() {
  rm -rf "$MOCK_DIR" 2>/dev/null || true
  cleanup_tmpdir
}

# A curl that records its argv and any stdin it is told to read, then answers from $MOCK_DIR/routes: the first line
# whose URL fragment is in the requested URL wins. An answer is an HTTP status, written with
# the route's body to curl's -o file, or exit:<n> for a request that got no response, which
# real curl reports as status 000 and a non-zero exit. A URL with no route exits 99.
install_stub_curl() {
  cat > "$MOCK_DIR/curl" <<'STUB'
#!/bin/bash
d="$(dirname "$0")"
out=""
prev=""
url=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  prev="$a"
  url="$a"
done
printf '%s\n' "$*" >> "$d/argv.log"
# Like curl, read stdin only when told to; a provider script's request leaves it open.
case " $* " in *" @- "*) cat >> "$d/stdin.log" ;; esac
while read -r fragment answer body; do
  case "$url" in *"$fragment"*) ;; *) continue ;; esac
  case "$answer" in exit:*) printf '000'; exit "${answer#exit:}" ;; esac
  cp "$d/$body" "$out"
  printf '%s' "$answer"
  exit 0
done < "$d/routes"
echo "stub curl: no route for $url" >&2
exit 99
STUB
  chmod +x "$MOCK_DIR/curl"
  export PATH="$MOCK_DIR:$PATH"
}

# route <url fragment> <http status | exit:N> [body]
route() {
  local n
  n=$(wc -l < "$MOCK_DIR/routes" | tr -d ' ')
  printf '%s' "${3:-}" > "$MOCK_DIR/body.$n"
  printf '%s %s body.%s\n' "$1" "$2" "$n" >> "$MOCK_DIR/routes"
}

# row <provider> — that provider's line of output with each column gap shown as |.
row() {
  printf '%s\n' "$output" | grep -E "^$1 " | sed -E 's/  +/|/g'
}

# assert_row <provider> <expected> — exact match, with both sides printed on a mismatch.
assert_row() {
  local actual
  actual=$(row "$1")
  if [[ "$actual" != "$2" ]]; then
    echo "row $1"
    echo "  expected: $2"
    echo "  actual:   $actual"
    echo "full output:"
    echo "$output"
    return 1
  fi
}

use_all_keys() {
  export GEMINI_API_KEY="$DUMMY_GEMINI_KEY"
  export OPENAI_API_KEY="$DUMMY_OPENAI_KEY"
  export XAI_API_KEY="$DUMMY_XAI_KEY"
  export OPENROUTER_API_KEY="$DUMMY_OPENROUTER_KEY"
}

use_test_models() {
  export GEMINI_IMAGE_MODEL="gemini-test-image"
  export OPENAI_IMAGE_MODEL="openai-test-image"
  export XAI_IMAGE_MODEL="xai-test-image"
  export OPENROUTER_IMAGE_MODEL="vendor/test-image"
}

# Model lists in each provider's live shape, holding exactly the model ids given.
gemini_list() {
  local m entries=""
  for m in "$@"; do entries+="${entries:+,}{\"name\":\"models/${m}\"}"; done
  printf '{"models":[%s]}' "$entries"
}
openai_list() {
  local m entries=""
  for m in "$@"; do entries+="${entries:+,}{\"id\":\"${m}\",\"object\":\"model\"}"; done
  printf '{"object":"list","data":[%s]}' "$entries"
}

@test "status: a provider without a key reads not set and sends no request" {
  use_test_models
  run "$SYSTEM_BASH" "$SCRIPT"
  assert_status 0
  assert_row provider "provider|key|model listed|model"
  assert_row gemini "gemini|not set (GEMINI_API_KEY)|not checked|gemini-test-image (GEMINI_IMAGE_MODEL)"
  assert_row openai "openai|not set (OPENAI_API_KEY)|not checked|openai-test-image (OPENAI_IMAGE_MODEL)"
  assert_row xai "xai|not set (XAI_API_KEY)|not checked|xai-test-image (XAI_IMAGE_MODEL)"
  assert_row openrouter "openrouter|not set (OPENROUTER_API_KEY)|not checked|vendor/test-image (OPENROUTER_IMAGE_MODEL)"
  [[ ! -e "$MOCK_DIR/argv.log" ]]
}

@test "status: each provider's rejected-key answer reads rejected, and no body is left behind" {
  use_all_keys
  use_test_models
  # The bodies each provider sent for a fake key on 2026-11-05, OpenAI's redacted key included.
  route "$GEMINI_URL" 400 '{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"API_KEY_INVALID","domain":"googleapis.com"}]}}'
  route "$OPENAI_URL" 401 '{"error":{"message":"Incorrect API key provided: test-ope*******real.","type":"invalid_request_error","param":null,"code":"invalid_api_key"}}'
  route "$XAI_URL" 400 '{"code":"invalid-argument","error":"Incorrect API key provided. You can obtain an API key from https://console.x.ai."}'
  route "$OPENROUTER_KEY_URL" 401 '{"error":{"message":"Missing Authentication header","code":401}}'
  run "$SYSTEM_BASH" "$SCRIPT"
  assert_status 0
  assert_row gemini "gemini|rejected (HTTP 400)|not checked|gemini-test-image (GEMINI_IMAGE_MODEL)"
  assert_row openai "openai|rejected (HTTP 401)|not checked|openai-test-image (OPENAI_IMAGE_MODEL)"
  assert_row xai "xai|rejected (HTTP 400)|not checked|xai-test-image (XAI_IMAGE_MODEL)"
  assert_row openrouter "openrouter|rejected (HTTP 401)|not checked|vendor/test-image (OPENROUTER_IMAGE_MODEL)"
  [[ -z "$(ls -A "$TMPDIR")" ]]
}

@test "status: a Gemini or xAI 400 that does not name the key is not read as rejected" {
  export GEMINI_API_KEY="$DUMMY_GEMINI_KEY"
  export XAI_API_KEY="$DUMMY_XAI_KEY"
  use_test_models
  route "$GEMINI_URL" 400 '{"error":{"code":400,"message":"Invalid page size","status":"INVALID_ARGUMENT","details":[{"@type":"type.googleapis.com/google.rpc.BadRequest","reason":"FIELD_INVALID"}]}}'
  route "$XAI_URL" 400 '{"code":"invalid-argument","error":"Model xai-test-image does not exist or your team does not have access to it."}'
  run "$SYSTEM_BASH" "$SCRIPT"
  assert_status 0
  assert_row gemini "gemini|unexpected HTTP 400|not checked|gemini-test-image (GEMINI_IMAGE_MODEL)"
  assert_row xai "xai|unexpected HTTP 400|not checked|xai-test-image (XAI_IMAGE_MODEL)"
}

@test "status: an accepted key whose model is in the live list reads accepted and yes" {
  use_all_keys
  use_test_models
  route "$GEMINI_URL" 200 "$(gemini_list gemini-other-image gemini-test-image)"
  route "$OPENAI_URL" 200 "$(openai_list gpt-4o openai-test-image)"
  route "$XAI_URL" 200 '{"models":[{"id":"xai-other-image","aliases":[]},{"id":"xai-test-image","aliases":[]}]}'
  route "$OPENROUTER_KEY_URL" 200 '{"data":{"label":"sk-or-v1-abc...xyz","limit":null}}'
  route "$OPENROUTER_LIST_URL" 200 '{"data":[{"id":"vendor/text-model","architecture":{"output_modalities":["text"]}},{"id":"vendor/test-image","architecture":{"output_modalities":["image","text"]}}]}'
  run "$SYSTEM_BASH" "$SCRIPT"
  assert_status 0
  assert_row gemini "gemini|accepted|yes|gemini-test-image (GEMINI_IMAGE_MODEL)"
  assert_row openai "openai|accepted|yes|openai-test-image (OPENAI_IMAGE_MODEL)"
  assert_row xai "xai|accepted|yes|xai-test-image (XAI_IMAGE_MODEL)"
  assert_row openrouter "openrouter|accepted|yes|vendor/test-image (OPENROUTER_IMAGE_MODEL)"
}

@test "status: an xAI model named by one of its aliases reads listed" {
  export XAI_API_KEY="$DUMMY_XAI_KEY"
  export XAI_IMAGE_MODEL="xai-test-image-2026-01-01"
  route "$XAI_URL" 200 '{"models":[{"id":"xai-test-image","aliases":["xai-test-image-2026-01-01"]}]}'
  run "$SYSTEM_BASH" "$SCRIPT"
  assert_status 0
  assert_row xai "xai|accepted|yes|xai-test-image-2026-01-01 (XAI_IMAGE_MODEL)"
}

@test "status: an accepted key whose model is missing, or on OpenRouter not an image model, reads no" {
  use_all_keys
  use_test_models
  route "$GEMINI_URL" 200 "$(gemini_list gemini-test-image-preview)"
  route "$OPENAI_URL" 200 "$(openai_list openai-test-image-2)"
  route "$XAI_URL" 200 '{"models":[{"id":"xai-test-image-pro","aliases":["xai-test"]}]}'
  route "$OPENROUTER_KEY_URL" 200 '{"data":{"label":"sk-or-v1-abc...xyz","limit":null}}'
  route "$OPENROUTER_LIST_URL" 200 '{"data":[{"id":"vendor/test-image","architecture":{"output_modalities":["text"]}}]}'
  run "$SYSTEM_BASH" "$SCRIPT"
  assert_status 0
  assert_row gemini "gemini|accepted|no|gemini-test-image (GEMINI_IMAGE_MODEL)"
  assert_row openai "openai|accepted|no|openai-test-image (OPENAI_IMAGE_MODEL)"
  assert_row xai "xai|accepted|no|xai-test-image (XAI_IMAGE_MODEL)"
  assert_row openrouter "openrouter|accepted|no|vendor/test-image (OPENROUTER_IMAGE_MODEL)"
}

@test "status: a Gemini list with more pages does not call a model it lacks missing" {
  export GEMINI_API_KEY="$DUMMY_GEMINI_KEY"
  export GEMINI_IMAGE_MODEL="gemini-test-image"
  route "$GEMINI_URL" 200 '{"models":[{"name":"models/gemini-other-image"}],"nextPageToken":"page-2"}'
  run "$SYSTEM_BASH" "$SCRIPT"
  assert_status 0
  assert_row gemini "gemini|accepted|unknown (list has more pages)|gemini-test-image (GEMINI_IMAGE_MODEL)"
}

@test "status: a request with no answer reads no answer with curl's exit code" {
  use_all_keys
  use_test_models
  route "$GEMINI_URL" exit:6
  route "$OPENAI_URL" exit:7
  # An answer that is not JSON is a fault of the list, not a missing model.
  route "$XAI_URL" 200 '<html>bad gateway</html>'
  route "$OPENROUTER_KEY_URL" 200 '{"data":{"label":"sk-or-v1-abc...xyz","limit":null}}'
  route "$OPENROUTER_LIST_URL" exit:28
  run "$SYSTEM_BASH" "$SCRIPT"
  assert_status 0
  assert_row gemini "gemini|no answer (curl exit 6)|not checked|gemini-test-image (GEMINI_IMAGE_MODEL)"
  assert_row openai "openai|no answer (curl exit 7)|not checked|openai-test-image (OPENAI_IMAGE_MODEL)"
  assert_row xai "xai|accepted|unreadable model list|xai-test-image (XAI_IMAGE_MODEL)"
  assert_row openrouter "openrouter|accepted|no answer (curl exit 28)|vendor/test-image (OPENROUTER_IMAGE_MODEL)"
}

@test "status: each key goes to curl as a header on stdin, never in its arguments" {
  use_all_keys
  use_test_models
  route "$GEMINI_URL" 200 "$(gemini_list gemini-test-image)"
  route "$OPENAI_URL" 200 "$(openai_list openai-test-image)"
  route "$XAI_URL" 200 '{"models":[{"id":"xai-test-image","aliases":[]}]}'
  route "$OPENROUTER_KEY_URL" 200 '{"data":{"label":"sk-or-v1-abc...xyz","limit":null}}'
  route "$OPENROUTER_LIST_URL" 200 '{"data":[{"id":"vendor/test-image","architecture":{"output_modalities":["image"]}}]}'
  run "$SYSTEM_BASH" "$SCRIPT"
  assert_status 0

  local argv headers
  argv=$(cat "$MOCK_DIR/argv.log")
  headers=$(cat "$MOCK_DIR/stdin.log")
  assert_output_not_contains_str "$argv" "key-not-real"
  [[ "$headers" == "x-goog-api-key: ${DUMMY_GEMINI_KEY}
Authorization: Bearer ${DUMMY_OPENAI_KEY}
Authorization: Bearer ${DUMMY_XAI_KEY}
Authorization: Bearer ${DUMMY_OPENROUTER_KEY}
Authorization: Bearer ${DUMMY_OPENROUTER_KEY}" ]]
}

@test "status: xAI's key falls back to GROK_API_KEY as xai.sh does" {
  export GROK_API_KEY="$DUMMY_XAI_KEY"
  export XAI_IMAGE_MODEL="xai-test-image"
  route "$XAI_URL" 200 '{"models":[{"id":"xai-test-image","aliases":[]}]}'
  run "$SYSTEM_BASH" "$SCRIPT"
  assert_status 0
  assert_row xai "xai|accepted|yes|xai-test-image (XAI_IMAGE_MODEL)"
  [[ "$(cat "$MOCK_DIR/stdin.log")" == "Authorization: Bearer ${DUMMY_XAI_KEY}" ]]
}

@test "status: with no override, each row names the model its provider script sends" {
  use_all_keys
  # Variables other tools read for their own Grok and OpenRouter models; neither script uses them.
  export GROK_MODEL="grok-chat-model"
  export OPENROUTER_MODELS="vendor/chat-model"
  export IMAGE_MAX_RETRIES=0
  export DISPLAY_PANE_DIR="${MOCK_DIR}/pane"
  mkdir -p "$DISPLAY_PANE_DIR"

  run "$SYSTEM_BASH" "$SCRIPT"
  assert_status 0
  local status_output="$output" provider sent
  for provider in gemini openai xai openrouter; do
    # The stub has no route for the generation request, so the script fails right after
    # printing "Calling <Provider> API (model: <model>, mode: generate)...".
    run "${PLUGIN_ROOT}/scripts/${provider}.sh" --mode generate --prompt "a test" --output "${MOCK_DIR}/out.png"
    sent=$(printf '%s\n' "$output" | sed -nE 's/^Calling .* API \(model: (.*), mode: generate\)\.\.\.$/\1/p')
    [[ -n "$sent" ]] || { echo "${provider}.sh printed no model line:"; echo "$output"; return 1; }
    output="$status_output"
    [[ "$(row "$provider" | cut -d'|' -f4)" == "$sent" ]] || {
      echo "${provider}: status reports '$(row "$provider" | cut -d'|' -f4)', ${provider}.sh sends '${sent}'"
      return 1
    }
  done
}

@test "status: a provider script whose MODEL line is missing stops the check" {
  cp -R "${PLUGIN_ROOT}/scripts" "${MOCK_DIR}/scripts"
  grep -v '^MODEL=' "${PLUGIN_ROOT}/scripts/xai.sh" > "${MOCK_DIR}/scripts/xai.sh"
  run "$SYSTEM_BASH" "${MOCK_DIR}/scripts/check-status.sh"
  assert_status 1
  [[ "$output" == 'Error: xai.sh has no MODEL="${<VARIABLE>:-<default>}" line to read its model from' ]]
}

@test "status: without jq the check stops and says so" {
  mkdir -p "${MOCK_DIR}/empty-path"
  run env PATH="${MOCK_DIR}/empty-path" "$SYSTEM_BASH" "$SCRIPT"
  assert_status 1
  [[ "$output" == "Error: jq is required to read the providers' answers" ]]
}
