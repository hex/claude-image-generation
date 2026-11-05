#!/usr/bin/env bats
# ABOUTME: Tests the runtime model fallback: a provider whose default model is unavailable retries
# ABOUTME: once with its fallback, and remembers the verdict per key. Stubbed curl, captured bodies.

load test_helper

FIXTURES="${PLUGIN_ROOT}/tests/fixtures/model-fallback"
# The interpreter a stock macOS runs the plugin under, so these runs also guard bash 3.2.
SYSTEM_BASH="/bin/bash"

setup() {
  disable_display
  MOCK_DIR="${BATS_TEST_TMPDIR}/mocks"
  mkdir -p "$MOCK_DIR"
  OUT="${BATS_TEST_TMPDIR}/out.png"
  export DISPLAY_PANE_DIR="${BATS_TEST_TMPDIR}/pane"
  mkdir -p "$DISPLAY_PANE_DIR"
  # Verdicts live under the cache dir; a test that wrote to the real one would change how the
  # rest of the suite's default-model runs behave on this machine.
  export XDG_CACHE_HOME="${BATS_TEST_TMPDIR}/cache"
  export IMAGE_RETRY_DELAY=0
  unset GEMINI_IMAGE_MODEL OPENAI_IMAGE_MODEL XAI_IMAGE_MODEL OPENROUTER_IMAGE_MODEL IMAGE_AVAILABILITY_TTL
  export GEMINI_API_KEY="$DUMMY_GEMINI_KEY" OPENAI_API_KEY="$DUMMY_OPENAI_KEY"
  export XAI_API_KEY="$DUMMY_XAI_KEY" OPENROUTER_API_KEY="$DUMMY_OPENROUTER_KEY"
}

# success_body <provider> — a 200 body carrying base64 "fake", in the provider's response shape.
success_body() {
  case "$1" in
    gemini) printf '%s' '{"candidates":[{"content":{"parts":[{"inlineData":{"mimeType":"image/png","data":"ZmFrZQ=="}}]}}]}' ;;
    openai|xai) printf '%s' '{"data":[{"b64_json":"ZmFrZQ=="}]}' ;;
    openrouter) printf '%s' '{"choices":[{"message":{"images":[{"image_url":{"url":"data:image/png;base64,ZmFrZQ=="}}]}}]}' ;;
  esac
}

# stub_curl_answers <provider> <answer>... — puts a curl on PATH that answers its Nth call with the
# Nth answer (the last one repeats). An answer is "ok" for the provider's success body, or the path
# of a captured fixture, whose status is the number after its last dash. Each call leaves its
# arguments in argv.N, one per line, and its body in body.N; calls holds the count.
stub_curl_answers() {
  local provider="$1" n=0 answer code
  shift
  for answer in "$@"; do
    n=$((n + 1))
    if [[ "$answer" == ok ]]; then
      success_body "$provider" > "$MOCK_DIR/answer.$n"
      code=200
    else
      cp "$answer" "$MOCK_DIR/answer.$n"
      code=$(basename "$answer" .json)
      code=${code##*-}
    fi
    printf '%s' "$code" > "$MOCK_DIR/code.$n"
  done
  printf '%s' "$n" > "$MOCK_DIR/answers"
  cat > "$MOCK_DIR/curl" <<'STUB'
#!/bin/bash
d="$(dirname "$0")"
n=$(cat "$d/calls" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$d/calls"
printf '%s\n' "$@" > "$d/argv.$n"
prev=""
for a in "$@"; do
  case "$prev" in
    --data-binary) cp "${a#@}" "$d/body.$n" ;;
    -d) printf '%s' "$a" > "$d/body.$n" ;;
  esac
  prev="$a"
done
i=$n; total=$(cat "$d/answers"); [ "$i" -gt "$total" ] && i=$total
cat "$d/answer.$i"
printf '\n%s\n' "$(cat "$d/code.$i")"
STUB
  chmod +x "$MOCK_DIR/curl"
  export PATH="$MOCK_DIR:$PATH"
}

calls() { cat "$MOCK_DIR/calls" 2>/dev/null || echo 0; }

# sent_model <n> — the model the Nth request named: gemini carries it in the URL, an openai edit
# in a form field, every other request in its JSON body.
sent_model() {
  local argv="$MOCK_DIR/argv.$1" line
  while IFS= read -r line; do
    case "$line" in
      */models/*:generateContent) line=${line##*/models/}; printf '%s' "${line%%:*}"; return ;;
      model=*) printf '%s' "${line#model=}"; return ;;
    esac
  done < "$argv"
  jq -r '.model' "$MOCK_DIR/body.$1"
}

# assert_sent <n> <model> — the Nth request named exactly this model.
assert_sent() {
  local got
  got=$(sent_model "$1")
  [[ "$got" == "$2" ]] || { echo "request $1 named '$got', expected '$2'"; echo "$output"; return 1; }
}

assert_calls() {
  [[ "$(calls)" -eq "$1" ]] || { echo "expected $1 curl calls, got $(calls)"; echo "$output"; return 1; }
}

run_provider() {
  local provider="$1"
  shift
  run "$SYSTEM_BASH" "${PLUGIN_ROOT}/scripts/${provider}.sh" --mode generate --prompt "a red dot" \
    --output "$OUT" "$@"
}

@test "openai: an unavailable default model is retried once with the fallback, which draws" {
  stub_curl_answers openai "$FIXTURES/unavailable/openai-unknown-400.json" ok
  run_provider openai --quality low

  assert_status 0
  assert_calls 2
  assert_sent 1 gpt-image-2
  assert_sent 2 gpt-image-2.5-sunburst
  [[ "$(cat "$OUT")" == "fake" ]] || { echo "fallback image not saved: $(cat "$OUT")"; return 1; }
  assert_output_contains "gpt-image-2 is unavailable"
  assert_output_contains "gpt-image-2.5-sunburst"
}

@test "openai: an edit falls back too, naming the fallback in the model form field" {
  stub_curl_answers openai "$FIXTURES/unavailable/openai-retired-400.json" ok
  run "$SYSTEM_BASH" "${PLUGIN_ROOT}/scripts/openai.sh" --mode edit --prompt "make it blue" \
    --input-image "${PLUGIN_ROOT}/tests/fixtures/oversized.png" --output "$OUT"

  assert_status 0
  assert_calls 2
  assert_sent 1 gpt-image-2
  assert_sent 2 gpt-image-2.5-sunburst
}

@test "gemini: an unavailable default model is retried once with the fallback, which draws" {
  stub_curl_answers gemini "$FIXTURES/unavailable/gemini-retired-404.json" ok
  run_provider gemini

  assert_status 0
  assert_calls 2
  assert_sent 1 gemini-3-pro-image
  assert_sent 2 gemini-nano-banana-2.1
  [[ "$(cat "$OUT")" == "fake" ]] || { echo "fallback image not saved: $(cat "$OUT")"; return 1; }
}

@test "xai: an unavailable default model is retried once with the fallback, which draws" {
  stub_curl_answers xai "$FIXTURES/unavailable/xai-retired-404.json" ok
  run_provider xai --aspect-ratio 16:9

  assert_status 0
  assert_calls 2
  assert_sent 1 grok-imagine-image-2.0
  assert_sent 2 grok-imagine-image
  [[ "$(jq -r '.aspect_ratio' "$MOCK_DIR/body.2")" == "16:9" ]] || { echo "fallback lost the request's other fields"; return 1; }
  [[ "$(cat "$OUT")" == "fake" ]] || { echo "fallback image not saved: $(cat "$OUT")"; return 1; }
}

@test "openrouter: an unavailable default model is retried once with the fallback, which draws" {
  stub_curl_answers openrouter "$FIXTURES/unavailable/openrouter-deprecated-404.json" ok
  run_provider openrouter

  assert_status 0
  assert_calls 2
  assert_sent 1 google/gemini-3.1-flash-image
  assert_sent 2 google/gemini-nano-banana-2.1
  [[ "$(jq -r '.messages[0].content' "$MOCK_DIR/body.2")" == "a red dot" ]] || { echo "fallback lost the prompt"; return 1; }
  [[ "$(cat "$OUT")" == "fake" ]] || { echo "fallback image not saved: $(cat "$OUT")"; return 1; }
  assert_output_contains "Model: google/gemini-nano-banana-2.1"
}

# classify <fixture> — runs the classifier on a captured body, under the provider and status its
# file name carries, and prints "unavailable" or "other".
classify() {
  local name provider code
  name=$(basename "$1" .json)
  provider=${name%%-*}
  code=${name##*-}
  "$SYSTEM_BASH" -c 'set -euo pipefail; source "$1"
    if model_unavailable_response "$2" "$3" "$(cat "$4")"; then echo unavailable; else echo other; fi' \
    _ "${PLUGIN_ROOT}/scripts/model-fallback.sh" "$provider" "$code" "$1"
}

@test "classifier: every captured unavailable-model answer is unavailable, every other answer is not" {
  local fixture verdict wrong=""
  for fixture in "$FIXTURES"/unavailable/*.json; do
    verdict=$(classify "$fixture")
    [[ "$verdict" == unavailable ]] || wrong+="$(basename "$fixture") classified ${verdict}"$'\n'
  done
  for fixture in "$FIXTURES"/other/*.json; do
    verdict=$(classify "$fixture")
    [[ "$verdict" == other ]] || wrong+="$(basename "$fixture") classified ${verdict}"$'\n'
  done
  [[ -z "$wrong" ]] || { printf '%s' "$wrong"; return 1; }
}

@test "classifier: an OpenRouter 403 is a refused prompt, while a 403 elsewhere is a model the key cannot reach" {
  local body='{"error":{"message":"Your prompt was flagged","code":403}}'
  [[ "$(classify_body openrouter 403 "$body")" == other ]]
  [[ "$(classify_body xai 403 '{"code":"permission-denied","error":"The model grok-4.5 is not available in your region."}')" == unavailable ]]
}

@test "classifier: a 400 that names the model but says a parameter is unsupported is not unavailable" {
  [[ "$(classify_body openai 400 '{"error":{"message":"Unsupported value: \"low\" is not supported with the \"gpt-image-2\" model.","param":"quality","code":"unsupported_value"}}')" == other ]]
}

@test "classifier: a 429, a 5xx and a body that is not JSON are not unavailable" {
  [[ "$(classify_body gemini 429 '{"error":{"code":429,"message":"Resource has been exhausted","status":"RESOURCE_EXHAUSTED"}}')" == other ]]
  [[ "$(classify_body openai 500 '{"error":{"message":"The server had an error processing your request."}}')" == other ]]
  [[ "$(classify_body xai 400 '<html>Bad Request</html>')" == other ]]
}

classify_body() {
  "$SYSTEM_BASH" -c 'set -euo pipefail; source "$1"
    if model_unavailable_response "$2" "$3" "$4"; then echo unavailable; else echo other; fi' \
    _ "${PLUGIN_ROOT}/scripts/model-fallback.sh" "$1" "$2" "$3"
}

# reset_stub <provider> <answer>... — a fresh curl stub and call count for the next run.
reset_stub() {
  rm -f "$MOCK_DIR"/calls "$MOCK_DIR"/argv.* "$MOCK_DIR"/body.* "$MOCK_DIR"/answer.* "$MOCK_DIR"/code.*
  stub_curl_answers "$@"
}

@test "openai: after a fallback draws, the next run sends the fallback first" {
  stub_curl_answers openai "$FIXTURES/unavailable/openai-unknown-400.json" ok
  run_provider openai
  assert_status 0

  reset_stub openai ok
  run_provider openai

  assert_status 0
  assert_calls 1
  assert_sent 1 gpt-image-2.5-sunburst
  assert_output_contains "gpt-image-2 is remembered as unavailable to this key; drawing with fallback gpt-image-2.5-sunburst"
}

@test "openai: a fallback that is unavailable too ends the run after two requests and is not remembered" {
  stub_curl_answers openai "$FIXTURES/unavailable/openai-unknown-400.json"
  run_provider openai

  assert_status 1
  assert_calls 2
  assert_sent 1 gpt-image-2
  assert_sent 2 gpt-image-2.5-sunburst
  assert_output_contains "OpenAI API returned HTTP 400: The model 'no-such-image-model-x9' does not exist."

  reset_stub openai ok
  run_provider openai
  assert_status 0
  assert_sent 1 gpt-image-2
}

@test "openai: a remembered verdict is ignored once it is older than IMAGE_AVAILABILITY_TTL" {
  stub_curl_answers openai "$FIXTURES/unavailable/openai-unknown-400.json" ok
  run_provider openai
  assert_status 0
  local verdict
  verdict=$(find "$XDG_CACHE_HOME" -name '*.json')
  jq --argjson t "$(( $(date +%s) - 3601 ))" '.checked_at = $t' "$verdict" > "$verdict.tmp"
  mv "$verdict.tmp" "$verdict"

  reset_stub openai ok
  IMAGE_AVAILABILITY_TTL=3600 run_provider openai
  assert_status 0
  assert_calls 1
  assert_sent 1 gpt-image-2

  reset_stub openai ok
  IMAGE_AVAILABILITY_TTL=3700 run_provider openai
  assert_sent 1 gpt-image-2.5-sunburst
}

@test "openai: IMAGE_AVAILABILITY_TTL=0 tries the default every run" {
  stub_curl_answers openai "$FIXTURES/unavailable/openai-unknown-400.json" ok
  run_provider openai
  assert_status 0

  reset_stub openai ok
  IMAGE_AVAILABILITY_TTL=0 run_provider openai
  assert_sent 1 gpt-image-2
}

@test "every provider reports a bad key or a bad parameter without trying the fallback" {
  local fixture name provider
  for fixture in "$FIXTURES"/other/*.json; do
    name=$(basename "$fixture")
    provider=${name%%-*}
    reset_stub "$provider" "$fixture" ok
    run_provider "$provider"
    [[ "$status" -eq 1 && "$(calls)" -eq 1 ]] || {
      echo "${name}: exit ${status} after $(calls) requests, expected exit 1 after 1"; echo "$output"; return 1; }
    assert_output_not_contains "fallback"
  done
}

@test "every provider sends a model named by --model or <PROVIDER>_IMAGE_MODEL as named" {
  local provider default unavailable env_var
  for provider in gemini openai xai openrouter; do
    case "$provider" in
      gemini) default=gemini-3-pro-image ;;
      openai) default=gpt-image-2 ;;
      xai) default=grok-imagine-image-2.0 ;;
      openrouter) default=google/gemini-3.1-flash-image ;;
    esac
    unavailable=$(ls "$FIXTURES"/unavailable/"$provider"-*.json | head -1)
    env_var="$(printf '%s' "$provider" | tr '[:lower:]' '[:upper:]')_IMAGE_MODEL"

    reset_stub "$provider" "$unavailable" ok
    run_provider "$provider" --model "$default"
    [[ "$status" -eq 1 && "$(calls)" -eq 1 ]] || {
      echo "${provider} --model: exit ${status} after $(calls) requests"; echo "$output"; return 1; }
    assert_sent 1 "$default"

    reset_stub "$provider" "$unavailable" ok
    run env "${env_var}=${default}" "$SYSTEM_BASH" "${PLUGIN_ROOT}/scripts/${provider}.sh" \
      --mode generate --prompt "a red dot" --output "$OUT"
    [[ "$status" -eq 1 && "$(calls)" -eq 1 ]] || {
      echo "${provider} ${env_var}: exit ${status} after $(calls) requests"; echo "$output"; return 1; }
    assert_sent 1 "$default"
  done
}

@test "openai: a remembered verdict does not replace a model named by --model" {
  stub_curl_answers openai "$FIXTURES/unavailable/openai-unknown-400.json" ok
  run_provider openai
  assert_status 0

  reset_stub openai ok
  run_provider openai --model gpt-image-2
  assert_status 0
  assert_sent 1 gpt-image-2
}

@test "openai: a verdict is kept per API key" {
  stub_curl_answers openai "$FIXTURES/unavailable/openai-unknown-400.json" ok
  run_provider openai
  assert_status 0

  reset_stub openai ok
  OPENAI_API_KEY="another-test-key-not-real" run_provider openai
  assert_sent 1 gpt-image-2
}

@test "openai: a verdict file that cannot be read counts as stale instead of failing the run" {
  stub_curl_answers openai "$FIXTURES/unavailable/openai-unknown-400.json" ok
  run_provider openai
  assert_status 0
  local verdict corrupt
  verdict=$(find "$XDG_CACHE_HOME" -name '*.json')
  # A truncated file, and a whole one whose timestamp is a word: under set -u, a word reaching
  # shell arithmetic is an unbound variable and would end the run.
  for corrupt in '{"checked_at":17' '{"checked_at":"yesterday"}'; do
    printf '%s' "$corrupt" > "$verdict"
    reset_stub openai ok
    run_provider openai
    assert_status 0
    assert_calls 1
    assert_sent 1 gpt-image-2
  done
}

@test "gemini: a transient error is retried on the default, and only the unavailable answer moves to the fallback" {
  local overloaded="${BATS_TEST_TMPDIR}/gemini-overloaded-503.json"
  printf '{"error":{"code":503,"message":"The model is overloaded.","status":"UNAVAILABLE"}}' > "$overloaded"
  stub_curl_answers gemini "$overloaded" "$FIXTURES/unavailable/gemini-retired-404.json" ok
  run_provider gemini

  assert_status 0
  assert_calls 3
  assert_sent 1 gemini-3-pro-image
  assert_sent 2 gemini-3-pro-image
  assert_sent 3 gemini-nano-banana-2.1
}

@test "openai: inside a streaming pane, the banner names the fallback that drew the image" {
  stub_curl_answers openai "$FIXTURES/unavailable/openai-unknown-400.json" ok
  run_provider openai
  assert_status 0

  local rows
  rows=$(cut -f1,2,4 "$DISPLAY_PANE_DIR/status")
  [[ "$rows" == $'openai\tquerying\tgpt-image-2\nopenai\tquerying\tgpt-image-2.5-sunburst\nopenai\tcomplete\tgpt-image-2.5-sunburst' ]] || {
    echo "status rows:"; echo "$rows"; return 1; }
}

@test "a non-numeric IMAGE_AVAILABILITY_TTL stops the run before any request" {
  stub_curl_answers openai ok
  IMAGE_AVAILABILITY_TTL=1d run_provider openai
  assert_status 1
  assert_calls 0
  assert_output_contains "Error: IMAGE_AVAILABILITY_TTL must be a whole number of seconds, got '1d'"
}
