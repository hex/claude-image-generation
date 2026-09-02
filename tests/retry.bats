#!/usr/bin/env bats
# ABOUTME: Tests curl_with_retry: which failures retry, how many times, and that a body
# ABOUTME: streamed on stdin is resent intact on every attempt.

load test_helper

RETRY_SH="${PLUGIN_ROOT}/scripts/retry.sh"
BIG_IMAGE="${PLUGIN_ROOT}/test-input.png"

setup() {
  MOCK_DIR="${BATS_TMPDIR}/retry_mocks_$$"
  mkdir -p "$MOCK_DIR"
  export IMAGE_RETRY_DELAY=0
}

teardown() {
  rm -rf "$MOCK_DIR" 2>/dev/null || true
}

# stub_curl_sequence <code>... — a curl that answers one scripted HTTP code per call (the last
# repeats), writes its stdin/--data-binary body to $MOCK_DIR/body.N, and honors -w "\n%{http_code}".
stub_curl_sequence() {
  printf '%s\n' "$@" > "$MOCK_DIR/codes"
  cat > "$MOCK_DIR/curl" <<'STUB'
#!/bin/bash
d="$(dirname "$0")"
n=$(cat "$d/calls" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$d/calls"
total=$(wc -l < "$d/codes" | tr -d ' ')
i=$n; [ "$i" -gt "$total" ] && i=$total
code=$(sed -n "${i}p" "$d/codes")
# Capture whatever body curl was handed: --data-binary @file or -d string. The file case is
# copied directly rather than round-tripped through a shell variable, since $(cat ...) strips
# trailing newlines and would corrupt the byte-for-byte comparison in the big-body test.
body=""
body_file_arg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --data-binary) body_file_arg="${2#@}"; shift 2 ;;
    -d) body="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ -n "$body_file_arg" ]; then
  cp "$body_file_arg" "$d/body.$n"
else
  printf '%s' "$body" > "$d/body.$n"
fi
[ "$code" = "fail" ] && exit 7
printf '{"seen":%s}\n%s\n' "$n" "$code"
STUB
  chmod +x "$MOCK_DIR/curl"
  export PATH="$MOCK_DIR:$PATH"
}

calls() { cat "$MOCK_DIR/calls"; }

@test "retry: a 503 followed by a 200 succeeds on the second call" {
  stub_curl_sequence 503 200
  run bash -c "source '$RETRY_SH'; curl_with_retry -s -w '\n%{http_code}' -X POST https://x -d '{}' 2>/dev/null; echo \"attempts=\$(retry_attempts)\""
  assert_status 0
  [[ "$(calls)" -eq 2 ]] || { echo "expected 2 calls, got $(calls)"; return 1; }
  assert_output_contains '{"seen":2}'
  assert_output_contains "attempts=1"
  [[ "${lines[1]}" == "200" ]] || { echo "code line missing: $output"; return 1; }
}

@test "retry: a 400 is not retried" {
  stub_curl_sequence 400 200
  run bash -c "source '$RETRY_SH'; curl_with_retry -s -w '\n%{http_code}' https://x -d '{}'"
  [[ "$(calls)" -eq 1 ]] || { echo "expected 1 call, got $(calls)"; return 1; }
  [[ "${lines[1]}" == "400" ]] || { echo "expected the 400 passed through: $output"; return 1; }
}

@test "retry: three 503s exhaust the retries and return the last body" {
  stub_curl_sequence 503 503 503 503 200
  run bash -c "source '$RETRY_SH'; curl_with_retry -s -w '\n%{http_code}' https://x -d '{}' 2>/dev/null; echo \"attempts=\$(retry_attempts)\""
  [[ "$(calls)" -eq 4 ]] || { echo "expected 1 + 3 retries = 4 calls, got $(calls)"; return 1; }
  assert_output_contains '{"seen":4}'
  assert_output_contains "attempts=3"
  [[ "${lines[1]}" == "503" ]] || { echo "expected the final 503: $output"; return 1; }
}

@test "retry: a curl network failure is retried" {
  stub_curl_sequence fail 200
  run bash -c "source '$RETRY_SH'; curl_with_retry -s -w '\n%{http_code}' https://x -d '{}' 2>/dev/null"
  assert_status 0
  [[ "$(calls)" -eq 2 ]] || { echo "expected 2 calls, got $(calls)"; return 1; }
  [[ "${lines[1]}" == "200" ]] || { echo "expected 200 after the retry: $output"; return 1; }
}

@test "retry: IMAGE_MAX_RETRIES=0 makes one call only" {
  stub_curl_sequence 503 200
  IMAGE_MAX_RETRIES=0 run bash -c "source '$RETRY_SH'; curl_with_retry -s -w '\n%{http_code}' https://x -d '{}'"
  [[ "$(calls)" -eq 1 ]] || { echo "expected 1 call, got $(calls)"; return 1; }
}

@test "retry: a multi-megabyte stdin body is resent identically on every attempt" {
  [[ -f "$BIG_IMAGE" ]] || skip "test-input.png not present"
  stub_curl_sequence 503 200
  local body_file="$MOCK_DIR/request.json"
  jq -n --rawfile d <(base64 < "$BIG_IMAGE" | tr -d '\n') '{image:$d}' > "$body_file"
  run bash -c "source '$RETRY_SH'; curl_with_retry -s -w '\n%{http_code}' https://x --data-binary @- < '$body_file'"
  assert_status 0
  [[ "$(calls)" -eq 2 ]] || { echo "expected 2 calls, got $(calls)"; return 1; }
  cmp -s "$body_file" "$MOCK_DIR/body.1" || { echo "first attempt body differs from the input"; return 1; }
  cmp -s "$body_file" "$MOCK_DIR/body.2" || { echo "second attempt body differs from the input"; return 1; }
}

@test "retry: each retry announces itself on stderr with the attempt count" {
  stub_curl_sequence 503 503 200
  run bash -c "source '$RETRY_SH'; curl_with_retry -s -w '\n%{http_code}' https://x -d '{}' 2>&1 >/dev/null"
  assert_output_contains "retry 1/3"
  assert_output_contains "retry 2/3"
}

@test "retry: retry_attempts reports the count once, then forgets it" {
  stub_curl_sequence 503 200
  run bash -c "source '$RETRY_SH'; curl_with_retry -s -w '\n%{http_code}' https://x -d '{}' >/dev/null 2>/dev/null; echo \"first=\$(retry_attempts)\"; echo \"second=\$(retry_attempts)\""
  assert_output_contains "first=1"
  assert_output_contains "second=0"
}
