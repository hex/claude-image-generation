#!/usr/bin/env bash
# ABOUTME: curl_with_retry, a curl wrapper that retries transient API failures with backoff.
# ABOUTME: Sourced by the provider scripts after display.sh; keeps curl's body+code output.

# Retries are governed by two knobs. The delay doubles on each retry: 1s, 2s, 4s.
IMAGE_MAX_RETRIES="${IMAGE_MAX_RETRIES:-3}"
IMAGE_RETRY_DELAY="${IMAGE_RETRY_DELAY:-1}"

# The count has to survive the command substitution the providers capture curl's output with:
# a variable set inside that subshell dies with it, so the count is left in a file keyed by the
# provider's PID ($$ is the same inside the substitution) and read back by retry_attempts.
__retry_count_file() {
  printf '%s/image-retry.%s' "${TMPDIR:-/tmp}" "$$"
}

# retry_attempts — prints how many retries the last curl_with_retry made, then forgets it.
retry_attempts() {
  local f
  f=$(__retry_count_file)
  if [[ -s "$f" ]]; then cat "$f"; else printf '0'; fi
  rm -f "$f"
}

# is_retryable_status <http code> — rate limits and server-side failures are worth another try.
# Everything else in 4xx is a bad request that a retry would only repeat.
is_retryable_status() {
  case "$1" in
    429|500|502|503|504) return 0 ;;
    *) return 1 ;;
  esac
}

# retry_notice <attempt> <max> — announces a retry on stderr and, inside a streaming pane, as
# a `retrying` status whose timing column carries "attempt/max" for the spinner line.
retry_notice() {
  echo "retry ${1}/${2} after a transient failure" >&2
  if [[ -n "${DISPLAY_PANE_DIR:-}" && -d "${DISPLAY_PANE_DIR:-}" && -n "${PROVIDER_NAME:-}" ]]; then
    display_pane_status "$PROVIDER_NAME" retrying "${1}/${2}" "${MODEL:-}"
  fi
}

# curl_with_retry [curl args...] — curl, retried on 429/5xx or a curl failure. The output
# contract is curl's own with -w "\n%{http_code}": body, newline, code; the last attempt's
# output is what the caller sees. A body given as `--data-binary @-` is read from stdin once
# into a temp file so every attempt can resend it. Always returns 0; callers judge the code.
curl_with_retry() {
  local -a args=()
  local a body_file=""
  for a in "$@"; do
    if [[ "$a" == "@-" ]]; then
      body_file=$(mktemp "${TMPDIR:-/tmp}/retry-body.XXXXXX")
      cat > "$body_file"
      a="@${body_file}"
    fi
    args+=("$a")
  done

  local max="$IMAGE_MAX_RETRIES" delay="$IMAGE_RETRY_DELAY" attempt=0
  local response="" curl_exit=0 code=""
  rm -f "$(__retry_count_file)"
  while :; do
    response=$(curl "${args[@]}") && curl_exit=0 || curl_exit=$?
    code="${response##*$'\n'}"
    if [[ $curl_exit -eq 0 ]] && ! is_retryable_status "$code"; then
      break
    fi
    [[ $attempt -lt $max ]] || break
    attempt=$((attempt + 1))
    printf '%s' "$attempt" > "$(__retry_count_file)"
    retry_notice "$attempt" "$max"
    sleep "$delay"
    delay=$((delay * 2))
  done

  [[ -n "$body_file" ]] && rm -f "$body_file"
  printf '%s\n' "$response"
  return 0
}
