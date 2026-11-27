#!/usr/bin/env bats
# ABOUTME: Image runs against the real gallery server, started under the test's temp directory:
# ABOUTME: what its page reads from /events and /img, its request guards, liveness, reuse, retry and delete.

load test_helper

SCRIPTS="${PLUGIN_ROOT}/scripts"
DISPLAY_SH="${SCRIPTS}/display.sh"
GALLERY_PY="${SCRIPTS}/gallery-server.py"
# A 1x1 PNG, so the image the page is served is a real one its type can be read from.
PNG_B64="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
GEMINI_IMAGE="{\"candidates\":[{\"content\":{\"parts\":[{\"inlineData\":{\"mimeType\":\"image/png\",\"data\":\"${PNG_B64}\"}}]}}]}"
GEMINI_REFUSAL='{"candidates":[{"content":{"parts":[{"text":"no picture today"}]}}]}'

setup() {
  command -v python3 >/dev/null 2>&1 || skip "needs python3"
  disable_display
  isolate_tmpdir
  export IMAGE_DISPLAY=gallery
  export IMAGE_GALLERY_DIR="${BATS_TEST_TMPDIR}/gallery"
  export IMAGE_GALLERY_NO_OPEN=1
  export XDG_CACHE_HOME="${BATS_TEST_TMPDIR}/cache"
  export GEMINI_API_KEY="$DUMMY_GEMINI_KEY"
  MOCK_DIR="${BATS_TEST_TMPDIR}/mock"
  mkdir -p "$MOCK_DIR" "${BATS_TEST_TMPDIR}/out"
  OUT_BASE="${BATS_TEST_TMPDIR}/out/picture"
}

teardown() {
  [[ -n "${EVENTS_PID:-}" ]] && kill "$EVENTS_PID" 2>/dev/null
  [[ -n "${HOLDER_PID:-}" ]] && kill "$HOLDER_PID" 2>/dev/null
  [[ -n "${LISTENER_PID:-}" ]] && kill "$LISTENER_PID" 2>/dev/null
  stop_gallery
  cleanup_tmpdir
}

# stop_gallery — ends the running server and waits for it to go.
stop_gallery() {
  local pid i
  pid=$(server_field pid) || return 0
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  kill "$pid" 2>/dev/null || return 0
  for i in $(seq 1 30); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
}

# servers_on <root> — the pids of the servers running on <root>, one per line. pgrep matches in the
# C locale: in UTF-8 it fails with "illegal byte sequence" whenever any process on the machine has
# arguments that are not valid UTF-8, and a failure must not read as "no server". It prints the
# failure instead, which no pid list or empty check accepts.
servers_on() {
  local status=0
  LC_ALL=C pgrep -f "gallery-server.py serve --root $1" || status=$?
  [[ $status -le 1 ]] || echo "pgrep failed with exit $status"
}

# server_field <name> — a field of the health the running server answers on its control socket,
# asked from inside the gallery folder the way the client commands ask; fails with no server.
server_field() {
  (cd "$IMAGE_GALLERY_DIR" 2>/dev/null && python3 -I -c '
import json, socket, sys
with socket.socket(socket.AF_UNIX) as sock:
    sock.settimeout(5)
    sock.connect("server.sock")
    sock.sendall(b"health\n")
    print(json.loads(sock.makefile().readline())[sys.argv[1]])' "$1" 2>/dev/null)
}

# gallery_curl [curl args...] <path> — curl at the running server, the path under the page's token.
gallery_curl() {
  local path="${*: -1}"
  curl -s --max-time 5 "${@:1:$#-1}" "http://127.0.0.1:$(server_field port)/$(server_field token)${path}"
}

origin() { printf 'Origin: http://127.0.0.1:%s' "$(server_field port)"; }

# snapshot — the first runs snapshot /events sends a page that connects now.
snapshot() {
  gallery_curl -N --max-time 1 /events | sed -n 's/^data: //p' | head -1 || true
}

# wait_for_snapshot <jq filter> — waits up to ten seconds for a snapshot the filter holds for,
# leaving it in SNAPSHOT.
wait_for_snapshot() {
  local i snap=""
  for i in $(seq 1 10); do
    snap=$(snapshot)
    if [[ -n "$snap" ]] && jq -e "$1" >/dev/null <<< "$snap"; then
      SNAPSHOT="$snap"
      return 0
    fi
    # No server to answer yet returns at once; wait out the second a snapshot would have taken.
    [[ -n "$snap" ]] || sleep 1
  done
  echo "no snapshot matched $1; the last one was: $snap"
  return 1
}

# answer_provider_with <body>... — puts a curl first on PATH that sends each https request to
# tests/one_request_server.py instead, answering the nth request with the nth body (the last
# body answers every later one). Each request it served is counted in $MOCK_DIR/calls.
answer_provider_with() {
  local real_curl n=0 body
  real_curl=$(command -v curl)
  for body in "$@"; do
    n=$((n + 1))
    printf '%s' "$body" > "$MOCK_DIR/answer.$n"
  done
  cat > "$MOCK_DIR/curl" <<STUB
#!/bin/bash
d="$MOCK_DIR"
case "\$*" in *https://*) ;; *) exec "$real_curl" "\$@" ;; esac
n=\$(cat "\$d/calls" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "\$d/calls"
answer="\$d/answer.\$n"; [ -f "\$answer" ] || answer="\$d/answer.$n"
rm -f "\$d/port"
python3 -I "${PLUGIN_ROOT}/tests/one_request_server.py" "\$d/port" "\$d/request.raw" "\$answer" &
server_pid=\$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -s "\$d/port" ] && break
  sleep 0.1
done
port=\$(cat "\$d/port")
args=()
for a in "\$@"; do
  case "\$a" in https://*) a="http://127.0.0.1:\$port/\${a#https://*/}" ;; esac
  args+=("\$a")
done
"$real_curl" --max-time 5 "\${args[@]}"
curl_status=\$?
wait "\$server_pid"
exit \$curl_status
STUB
  chmod +x "$MOCK_DIR/curl"
  export PATH="$MOCK_DIR:$PATH"
}

# connect_page — holds /events open in the background the way an open page does, its curl's pid
# in EVENTS_PID, and waits until the server counts it.
connect_page() {
  local i
  curl -s -N --max-time 60 "http://127.0.0.1:$(server_field port)/$(server_field token)/events" > /dev/null &
  EVENTS_PID=$!
  for i in $(seq 1 50); do
    [[ "$(server_field clients)" == 1 ]] && return 0
    sleep 0.1
  done
  echo "the server never counted the page"
  return 1
}

start_gallery() {
  python3 -I "$GALLERY_PY" ensure --root "$IMAGE_GALLERY_DIR"
}

run_all_gemini() {
  run bash "${SCRIPTS}/run-all.sh" --mode generate --prompt "a lighthouse at dusk" \
    --output-base "$OUT_BASE" --providers gemini
}

@test "a run's image reaches the page through /events, and /img serves its bytes as image/png" {
  # A carriage return in the output path is kept as it is in the status log and read back whole.
  OUT_BASE="${BATS_TEST_TMPDIR}/out/pic"$'\r'"ture"
  answer_provider_with "$GEMINI_IMAGE"
  run_all_gemini
  assert_status 0
  wait_for_snapshot '.runs[0].status == "done"'
  local run
  run=$(jq -c '.runs[0]' <<< "$SNAPSHOT")
  [[ "$(jq -r '[.prompt, .status, (.providers | length)] | @tsv' <<< "$run")" == $'a lighthouse at dusk\tdone\t1' ]] || {
    echo "run: $run"; return 1; }
  [[ "$(jq -r '.providers[0] | [.name, .state, .model, .image.n] | @tsv' <<< "$run")" == \
    "gemini	complete	gemini-3-pro-image	0" ]] || { echo "run: $run"; return 1; }
  [[ "$(jq -r '.providers[0].image.path' <<< "$run")" == "${OUT_BASE}-gemini.png" ]] || { echo "run: $run"; return 1; }
  [[ "$(jq -r .cwd <<< "$run")" == "$PWD" ]] || { echo "run: $run"; return 1; }
  local id type
  id=$(jq -r .id <<< "$run")
  type=$(gallery_curl -o "$MOCK_DIR/served.png" -w '%{http_code} %{content_type}' "/img/${id}/gemini/0")
  [[ "$type" == "200 image/png" ]] || { echo "served: $type"; return 1; }
  cmp "$MOCK_DIR/served.png" "${OUT_BASE}-gemini.png"
}

@test "with the gallery, a provider's stderr stays on run-all's own output" {
  answer_provider_with "$GEMINI_IMAGE"
  run_all_gemini
  assert_status 0
  assert_output_contains "Calling Gemini API (model: gemini-3-pro-image, mode: generate)..."
  assert_output_contains "Image saved to: ${OUT_BASE}-gemini.png"
  [[ ! -e "$(ls -d "$IMAGE_GALLERY_DIR"/runs/*)/logs" ]]
}

@test "the server answers 403 to a wrong Host, a missing or wrong token, a token in a cookie and a POST from another Origin, reading no POST body" {
  start_gallery
  local port url
  port=$(server_field port)
  url="http://127.0.0.1:${port}"
  [[ "$(gallery_curl -o /dev/null -w '%{http_code}' -H "Host: localhost:${port}" /app.js)" == 403 ]]
  [[ "$(gallery_curl -o /dev/null -w '%{http_code}' -H "Host: 127.0.0.1" /app.js)" == 403 ]]
  [[ "$(curl -s -o /dev/null -w '%{http_code}' "${url}/app.js")" == 403 ]]
  [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "${url}/events")" == 403 ]]
  [[ "$(curl -s -o /dev/null -w '%{http_code}' "${url}/wrong/app.js")" == 403 ]]
  [[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Cookie: gallery_token=$(server_field token)" "${url}/app.js")" == 403 ]]
  local retry=/retry/20990101T000000Z-0000000000
  [[ "$(gallery_curl -o /dev/null -w '%{http_code}' -X POST -H "Origin: http://localhost:${port}" "$retry")" == 403 ]]
  [[ "$(gallery_curl -o /dev/null -w '%{http_code}' -X POST "$retry")" == 403 ]]
  # A POST that declares a body it never sends is answered at once, without reading it.
  [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 -X POST -H 'Content-Length: 100' "${url}/wrong${retry}")" == 403 ]]
  [[ "$(gallery_curl -o /dev/null -w '%{http_code}' --max-time 3 -X POST -H "$(origin)" -H 'Content-Length: 100' "$retry")" == 413 ]]
  [[ "$(printf 'body' | gallery_curl -o /dev/null -w '%{http_code}' --max-time 3 -X POST -H "$(origin)" -H 'Transfer-Encoding: chunked' --data-binary @- "$retry")" == 413 ]]
  [[ "$(gallery_curl -o /dev/null -w '%{http_code}' -X POST -H "$(origin)" "$retry")" == 404 ]]
  [[ "$(gallery_curl -o /dev/null -w '%{http_code}' /app.js)" == 200 ]]
}

@test "the page and its files are served under the token's path, and the server sets no cookie" {
  start_gallery
  local base headers
  base="http://127.0.0.1:$(server_field port)/$(server_field token)"
  headers=$(curl -s -D - -o /dev/null -w '%{http_code} %{content_type}' "${base}/" | tr -d '\r')
  [[ "$headers" == *$'\n\n200 text/html; charset=utf-8' && "$headers" != *Set-Cookie* ]] || { echo "$headers"; return 1; }
  [[ "$headers" == *$'\nContent-Security-Policy: default-src \'self\'; frame-ancestors \'none\'; base-uri \'none\'; form-action \'none\'\n'* ]] || {
    echo "$headers"; return 1; }
  [[ "$(curl -s -o /dev/null -w '%{http_code} %{content_type}' "${base}/app.js")" == "200 text/javascript; charset=utf-8" ]]
  [[ "$(curl -s -o /dev/null -w '%{http_code} %{content_type}' "${base}/app.css")" == "200 text/css; charset=utf-8" ]]
}

@test "an image, reveal or retry of a run or provider the gallery does not have is a 404" {
  answer_provider_with "$GEMINI_IMAGE"
  run_all_gemini
  assert_status 0
  wait_for_snapshot '.runs | length == 1'
  local id
  id=$(jq -r '.runs[0].id' <<< "$SNAPSHOT")
  [[ "$(gallery_curl -o /dev/null -w '%{http_code}' /img/20990101T000000Z-0000000000/gemini/0)" == 404 ]]
  [[ "$(gallery_curl -o /dev/null -w '%{http_code}' "/img/${id}/openai/0")" == 404 ]]
  [[ "$(gallery_curl -o /dev/null -w '%{http_code}' "/img/${id}/gemini/1")" == 404 ]]
  [[ "$(gallery_curl -o /dev/null -w '%{http_code}' "/img/${id}/..%2F..%2Ftoken/0")" == 404 ]]
  [[ "$(gallery_curl -o /dev/null -w '%{http_code}' -X POST -H "$(origin)" "/reveal/${id}/openai/0")" == 404 ]]
  [[ "$(gallery_curl -o /dev/null -w '%{http_code}' -X POST -H "$(origin)" /retry/20990101T000000Z-0000000000)" == 404 ]]
  [[ "$(gallery_curl -w ' %{http_code}' -X POST -H "$(origin)" "/retry/${id}")" == \
    "{\"error\": \"run ${id} has no retry offer open\"} 409" ]]
  rm "${OUT_BASE}-gemini.png"
  [[ "$(gallery_curl -w ' %{http_code}' "/img/${id}/gemini/0")" == \
    "{\"error\": \"file moved or deleted\", \"path\": \"${OUT_BASE}-gemini.png\"} 404" ]]
}

@test "a run whose process was killed shows as interrupted, its provider too" {
  bash -c 'source "$1"; display_pane_begin gemini gemini-3-pro-image "a fox in snow"; exec sleep 30' \
    _ "$DISPLAY_SH" &
  local pid=$!
  wait_for_snapshot '.runs[0].providers[0].state == "querying"'
  [[ "$(jq -r '.runs[0] | [.prompt, .providers[0].name, .providers[0].state] | @tsv' <<< "$SNAPSHOT")" == \
    $'a fox in snow\tgemini\tquerying' ]] || { echo "$SNAPSHOT"; return 1; }
  kill -9 "$pid"
  wait "$pid" 2>/dev/null || true
  wait_for_snapshot '.runs[0].status == "interrupted"'
  [[ "$(jq -r '.runs[0].providers[0].state' <<< "$SNAPSHOT")" == interrupted ]] || { echo "$SNAPSHOT"; return 1; }
}

@test "runs started together share one server and open one page" {
  # Each start finds no page connected and asks for one; a browser slow to open still opens once.
  # The gallery folder is too deep for its control socket's path to fit a socket address.
  export IMAGE_GALLERY_DIR="${BATS_TEST_TMPDIR}/a-gallery-folder-whose-control-socket-path-is-longer-than-a-socket-address-holds"
  [[ ${#IMAGE_GALLERY_DIR} -gt 104 ]]
  stub_browser
  printf 'sleep 1\n' | tee -a "$MOCK_DIR/browser/open" >> "$MOCK_DIR/browser/xdg-open"
  local first second status=0 pid i root
  start_gallery &
  first=$!
  start_gallery &
  second=$!
  wait "$first" || status=$?
  [[ $status -eq 0 ]] || { echo "the first start exited $status"; return 1; }
  wait "$second" || status=$?
  [[ $status -eq 0 ]] || { echo "the second start exited $status"; return 1; }
  pid=$(server_field pid)
  # The server is started with the root resolved, /var becoming /private/var on macOS.
  root=$(cd "$IMAGE_GALLERY_DIR" && pwd -P)
  start_gallery
  [[ "$(server_field pid)" == "$pid" && "$(python3 -I "$GALLERY_PY" clients --root "$IMAGE_GALLERY_DIR")" == 0 ]]
  [[ "$(wc -l < "$MOCK_DIR/opened" | tr -d ' ')" == 1 ]] || { cat "$MOCK_DIR/opened"; return 1; }
  # The racer that lost the lock gives up within its five-second wait.
  for i in $(seq 1 70); do
    [[ "$(servers_on "$root" | tr '\n' ' ')" == "$pid " ]] && return 0
    sleep 0.1
  done
  echo "servers for this root: $(servers_on "$root" | tr '\n' ' '), expected $pid"
  return 1
}

@test "a server of another version is replaced by one of this plugin's version, which a run that found the old one too keeps" {
  # The old server exits the moment it is told to stop, so only an answer sent before that reaches the run.
  python3 -I "${PLUGIN_ROOT}/tests/gallery_race.py" "$GALLERY_PY" serve-stopping-at-once "$IMAGE_GALLERY_DIR"
  local i old version replacement root
  for i in $(seq 1 50); do
    [[ "$(server_field version)" == 0.0.0-other ]] && break
    sleep 0.1
  done
  [[ "$(server_field version)" == 0.0.0-other ]]
  old=$(server_field pid)
  # The second run read the old server's health before the first replaced it, and asks to stop it after.
  replacement=$(python3 -I "${PLUGIN_ROOT}/tests/gallery_race.py" "$GALLERY_PY" ensure-after-another "$IMAGE_GALLERY_DIR")
  # A server asked to stop exits within one scan, a quarter second.
  sleep 1
  version=$(jq -r .version "${PLUGIN_ROOT}/.claude-plugin/plugin.json")
  [[ "$(server_field pid)" == "$replacement" && "$(server_field version)" == "$version" ]] || {
    echo "serving: $(server_field pid) $(server_field version), expected $replacement $version"; return 1; }
  [[ "$replacement" != "$old" ]]
  ! kill -0 "$old" 2>/dev/null
  root=$(cd "$IMAGE_GALLERY_DIR" && pwd -P)
  [[ "$(servers_on "$root" | tr '\n' ' ')" == "$replacement " ]]
}

# stub_browser — puts an open and an xdg-open first on PATH that record each call in
# $MOCK_DIR/opened instead of opening a browser, and lets ensure try to open one.
stub_browser() {
  mkdir -p "$MOCK_DIR/browser"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> %q\n' "$MOCK_DIR/opened" > "$MOCK_DIR/browser/open"
  cp "$MOCK_DIR/browser/open" "$MOCK_DIR/browser/xdg-open"
  chmod +x "$MOCK_DIR/browser/open" "$MOCK_DIR/browser/xdg-open"
  export PATH="$MOCK_DIR/browser:$PATH" DISPLAY=:99
  unset IMAGE_GALLERY_NO_OPEN SSH_CONNECTION SSH_TTY
}

# serve_other_version — starts a server that reports another version, the way an older install's does.
serve_other_version() {
  local i
  python3 -I "$GALLERY_PY" serve --root "$IMAGE_GALLERY_DIR" --version 0.0.0-other
  for i in $(seq 1 50); do
    [[ "$(server_field version)" == 0.0.0-other ]] && return 0
    sleep 0.1
  done
  echo "the server of another version never answered on its control socket"
  return 1
}

@test "replacing a server of another version opens the page only when no page was connected to it" {
  stub_browser
  serve_other_version
  start_gallery
  [[ "$(wc -l < "$MOCK_DIR/opened" | tr -d ' ')" == 1 ]] || { cat "$MOCK_DIR/opened"; return 1; }
  stop_gallery
  serve_other_version
  connect_page
  start_gallery
  # The page reconnects to the server that replaced it on the same port, so no second tab opens.
  [[ "$(wc -l < "$MOCK_DIR/opened" | tr -d ' ')" == 1 ]] || { cat "$MOCK_DIR/opened"; return 1; }
}

@test "runs started together each print the page's address when the browser never finishes opening" {
  # The first run's answer comes when the server gives up on its launch after ten seconds. The
  # second run's own launch then hangs past its fifteen-second wait, and the server answers it
  # after the run is gone, with nothing in server.log.
  stub_browser
  printf 'echo $$ >> %q\nexec sleep 30\n' "$MOCK_DIR/launched" | tee -a "$MOCK_DIR/browser/open" >> "$MOCK_DIR/browser/xdg-open"
  local first second status=0 address pid i
  start_gallery 2> "$MOCK_DIR/first.err" &
  first=$!
  start_gallery 2> "$MOCK_DIR/second.err" &
  second=$!
  wait "$first" || status=$?
  [[ $status -eq 0 ]] || { echo "the first start exited $status: $(cat "$MOCK_DIR/first.err")"; return 1; }
  wait "$second" || status=$?
  [[ $status -eq 0 ]] || { echo "the second start exited $status: $(cat "$MOCK_DIR/second.err")"; return 1; }
  address="image gallery: open http://127.0.0.1:$(server_field port)/$(server_field token)/ to watch the images"
  [[ "$(cat "$MOCK_DIR/first.err")" == "$address" && "$(cat "$MOCK_DIR/second.err")" == "$address" ]] || {
    echo "first: $(cat "$MOCK_DIR/first.err")"; echo "second: $(cat "$MOCK_DIR/second.err")"; return 1; }
  [[ "$(wc -l < "$MOCK_DIR/launched" | tr -d ' ')" == 2 ]]
  for pid in $(cat "$MOCK_DIR/launched"); do
    for i in $(seq 1 100); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
  done
  # The server writes its answer once the launch it waited on is killed.
  sleep 0.5
  [[ ! -s "$IMAGE_GALLERY_DIR/server.log" ]] || { cat "$IMAGE_GALLERY_DIR/server.log"; return 1; }
}

@test "the browser is opened at a one-time address without the token, which sends it on to the page once" {
  stub_browser
  start_gallery
  local opened url location
  opened=$(cat "$MOCK_DIR/opened")
  [[ "$opened" != *"$(server_field token)"* ]] || { echo "opened with: $opened"; return 1; }
  url=${opened##* }
  location=$(curl -s -D - -o /dev/null "$url" | tr -d '\r' | sed -n 's/^Location: //p')
  [[ "$location" == "/$(server_field token)/" ]] || { echo "$url sent the browser to: $location"; return 1; }
  [[ "$(curl -s -o /dev/null -w '%{http_code}' "$url")" == 403 ]]
}

@test "over SSH the run prints the page's address, token included, instead of opening a browser" {
  stub_browser
  export SSH_CONNECTION="198.51.100.7 50000 192.0.2.1 22"
  run start_gallery
  assert_status 0
  [[ "$output" == "image gallery: open http://127.0.0.1:$(server_field port)/$(server_field token)/ to watch the images" ]] || {
    echo "output: $output"; return 1; }
  [[ ! -e "$MOCK_DIR/opened" ]]
}

@test "the token never reaches a listener on the port the gallery folder records" {
  # The folder's last-port names a port another listener now holds. The listener records whatever
  # it is sent.
  mkdir -p "$IMAGE_GALLERY_DIR"
  printf 'null' > "$MOCK_DIR/answer"
  python3 -I "${PLUGIN_ROOT}/tests/one_request_server.py" "$MOCK_DIR/port" "$MOCK_DIR/request.raw" "$MOCK_DIR/answer" &
  LISTENER_PID=$!
  local i
  for i in $(seq 1 50); do
    [[ -s "$MOCK_DIR/port" ]] && break
    sleep 0.1
  done
  cp "$MOCK_DIR/port" "$IMAGE_GALLERY_DIR/last-port"
  start_gallery
  python3 -I "$GALLERY_PY" clients --root "$IMAGE_GALLERY_DIR"
  [[ ! -e "$MOCK_DIR/request.raw" ]] || { echo "the listener was sent:"; cat "$MOCK_DIR/request.raw"; return 1; }
  [[ "$(server_field version)" == "$(jq -r .version "${PLUGIN_ROOT}/.claude-plugin/plugin.json")" ]]
}

@test "the Retry button's POST /retry runs the failed provider again" {
  answer_provider_with "$GEMINI_REFUSAL" "$GEMINI_IMAGE"
  start_gallery
  connect_page
  DISPLAY_PANE_RETRY_WAIT=30 bash "${SCRIPTS}/run-all.sh" --mode generate --prompt "a lighthouse at dusk" \
    --output-base "$OUT_BASE" --providers gemini > "$MOCK_DIR/run.out" 2>&1 &
  local run_pid=$!
  wait_for_snapshot '.runs[0].retry == ["gemini"]'
  [[ "$(jq -r '.runs[0].providers[0] | [.state, .error] | @tsv' <<< "$SNAPSHOT")" == \
    $'error\tNo image data in response. Model said: no picture today' ]] || { echo "$SNAPSHOT"; return 1; }
  # The offer closes DISPLAY_PANE_RETRY_WAIT seconds after it opened, which was moments ago.
  local now_ms left_ms
  now_ms=$(python3 -c 'import time; print(int(time.time() * 1000))')
  left_ms=$(( $(jq -r '.runs[0].retry_ends_ms' <<< "$SNAPSHOT") - now_ms ))
  [[ "$(jq -r '.runs[0].retry_seconds' <<< "$SNAPSHOT")" == 30 && $left_ms -gt 15000 && $left_ms -le 30000 ]] || {
    echo "left_ms=$left_ms; $SNAPSHOT"; return 1; }
  local id
  id=$(jq -r '.runs[0].id' <<< "$SNAPSHOT")
  [[ "$(gallery_curl -X POST -H "$(origin)" "/retry/${id}")" == "{\"retrying\": \"${id}\"}" ]]
  local status=0
  wait "$run_pid" || status=$?
  [[ $status -eq 0 ]] || { echo "run-all exited $status:"; cat "$MOCK_DIR/run.out"; return 1; }
  wait_for_snapshot '.runs[0].status == "done"'
  [[ "$(jq -r '.runs[0] | [.retry, (.providers[0] | .state, .round, .image.n)] | @tsv' <<< "$SNAPSHOT")" == \
    $'\tcomplete\t1\t0' ]] || { echo "$SNAPSHOT"; return 1; }
  [[ "$(cat "$MOCK_DIR/calls")" == 2 ]]
}

@test "a page that hangs up stops counting as connected within two seconds" {
  start_gallery
  connect_page
  kill "$EVENTS_PID"
  sleep 2
  [[ "$(server_field clients)" == 0 ]]
}

@test "a provider that exits before it starts shows as failed, saying so" {
  answer_provider_with "$GEMINI_IMAGE"
  unset GEMINI_API_KEY
  run_all_gemini
  assert_status 1
  assert_output_contains "Error: GEMINI_API_KEY environment variable is not set"
  wait_for_snapshot '.runs[0].status == "done"'
  [[ "$(jq -r '.runs[0].providers[0] | [.state, .error] | @tsv' <<< "$SNAPSHOT")" == \
    $'error\tgemini exited 1 before reporting a result; its error output says why' ]] || { echo "$SNAPSHOT"; return 1; }
  [[ ! -e "$MOCK_DIR/calls" ]]
}

@test "with no page connected, a failed run makes no retry offer and returns at once" {
  answer_provider_with "$GEMINI_REFUSAL"
  local started=$SECONDS
  DISPLAY_PANE_RETRY_WAIT=45 run_all_gemini
  assert_status 1
  [[ $((SECONDS - started)) -lt 15 ]] || { echo "run-all took $((SECONDS - started)) s"; return 1; }
  wait_for_snapshot '.runs[0].status == "done"'
  [[ "$(jq -r '.runs[0].retry' <<< "$SNAPSHOT")" == null ]]
  [[ "$(cat "$MOCK_DIR/calls")" == 1 ]]
}

@test "an IMAGE_GALLERY_DIR that already exists keeps its mode, and one other users can write is not used" {
  answer_provider_with "$GEMINI_IMAGE"
  mkdir -m 755 "$IMAGE_GALLERY_DIR"
  run_all_gemini
  assert_status 0
  [[ "$(ls -ld "$IMAGE_GALLERY_DIR" | cut -c1-10)" == drwxr-xr-x ]] || { ls -ld "$IMAGE_GALLERY_DIR"; return 1; }
  wait_for_snapshot '.runs | length == 1'
  chmod 775 "$IMAGE_GALLERY_DIR"
  OUT_BASE="${OUT_BASE}-again"
  run_all_gemini
  assert_status 0
  [[ "$(grep -c '^image display: ' <<< "$output")" == 1 ]] || { echo "output: $output"; return 1; }
  assert_output_contains "image display: IMAGE_GALLERY_DIR ${IMAGE_GALLERY_DIR} can be written by other users; using the terminal instead"
  [[ "$(ls -ld "$IMAGE_GALLERY_DIR" | cut -c1-10)" == drwxrwxr-x ]] || { ls -ld "$IMAGE_GALLERY_DIR"; return 1; }
  [[ "$(ls "$IMAGE_GALLERY_DIR/runs" | wc -l | tr -d ' ')" == 1 ]]
}

@test "a file named server.sock that is not a socket stays where it is, and the run and the server say so" {
  mkdir -m 700 "$IMAGE_GALLERY_DIR"
  printf 'notes\n' > "$IMAGE_GALLERY_DIR/server.sock"
  local root message i
  root=$(cd "$IMAGE_GALLERY_DIR" && pwd -P)
  message="${root}/server.sock is not a socket; move it so the server can make its control socket there"
  run start_gallery
  assert_status 1
  [[ "$output" == "image gallery: ${message}" ]] || { echo "output: $output"; return 1; }
  # A server started on the folder directly refuses it too, and exits.
  python3 -I "$GALLERY_PY" serve --root "$IMAGE_GALLERY_DIR" --version 0.0.0-other
  for i in $(seq 1 50); do
    [[ -z "$(servers_on "$IMAGE_GALLERY_DIR")" ]] && break
    sleep 0.1
  done
  [[ -z "$(servers_on "$IMAGE_GALLERY_DIR")" ]]
  [[ "$(tail -n 1 "$IMAGE_GALLERY_DIR/server.log")" == "image gallery: ${message}" ]] || { cat "$IMAGE_GALLERY_DIR/server.log"; return 1; }
  [[ "$(cat "$IMAGE_GALLERY_DIR/server.sock")" == notes ]]
}

@test "an IMAGE_DISPLAY that is not gallery, pane or none stops run-all before any provider runs" {
  answer_provider_with "$GEMINI_IMAGE"
  IMAGE_DISPLAY=bogus run_all_gemini
  assert_status 1
  [[ "$output" == "IMAGE_DISPLAY must be gallery, pane or none, got 'bogus'" ]] || { echo "output: $output"; return 1; }
  [[ ! -e "$MOCK_DIR/calls" && ! -e "$IMAGE_GALLERY_DIR" ]]
}

@test "display_mode: unset means gallery, SKIP_DISPLAY=1 means none, and no python3 means pane" {
  run env -u IMAGE_DISPLAY bash -c 'source "$1"; display_mode' _ "$DISPLAY_SH"
  [[ "$status" -eq 0 && "$output" == gallery ]] || { echo "unset: $status $output"; return 1; }
  run env SKIP_DISPLAY=1 IMAGE_DISPLAY=pane bash -c 'source "$1"; display_mode' _ "$DISPLAY_SH"
  [[ "$status" -eq 0 && "$output" == none ]] || { echo "skip: $status $output"; return 1; }
  mkdir -p "$MOCK_DIR/nopython"
  printf '#!/bin/bash\nexit 1\n' > "$MOCK_DIR/nopython/python3"
  chmod +x "$MOCK_DIR/nopython/python3"
  run env PATH="$MOCK_DIR/nopython:$PATH" bash -c 'source "$1"; display_mode 2>"$2"' _ "$DISPLAY_SH" "$MOCK_DIR/err"
  [[ "$status" -eq 0 && "$output" == pane ]] || { echo "no python: $status $output"; return 1; }
  [[ "$(cat "$MOCK_DIR/err")" == "image display: the gallery needs python3 3.9 or later, none found; using the terminal instead" ]]
}

@test "the gallery draws nothing in the terminal: no pane split in tmux, no inline image outside it" {
  command -v tmux >/dev/null 2>&1 || skip "tmux is not installed"
  answer_provider_with "$GEMINI_IMAGE"
  # A tmux server of this test's own, never the one the suite runs in.
  local socket="bats-gallery-$$-${BATS_TEST_NUMBER}" real_tmux socket_path pane
  real_tmux=$(command -v tmux)
  mkdir -p "$MOCK_DIR/bin"
  printf '#!/bin/bash\nexec %q -L %q "$@"\n' "$real_tmux" "$socket" > "$MOCK_DIR/bin/tmux"
  chmod +x "$MOCK_DIR/bin/tmux"
  "$MOCK_DIR/bin/tmux" -f /dev/null new-session -d -x 200 -y 50
  socket_path=$("$MOCK_DIR/bin/tmux" display-message -p '#{socket_path}')
  pane=$("$MOCK_DIR/bin/tmux" display-message -p '#{pane_id}')
  : > "$MOCK_DIR/tty"
  run env PATH="$MOCK_DIR/bin:$PATH" TMUX="${socket_path},0,0" TMUX_PANE="$pane" LC_TERMINAL=iTerm2 \
    DISPLAY_IMAGE_TARGET="$MOCK_DIR/tty" bash "${SCRIPTS}/gemini.sh" --mode generate --prompt "a quiet harbour" \
    --output "${OUT_BASE}-gemini.png"
  local panes
  panes=$("$MOCK_DIR/bin/tmux" list-panes -a | wc -l | tr -d ' ')
  "$MOCK_DIR/bin/tmux" kill-server 2>/dev/null || true
  rm -f "$socket_path"
  assert_status 0
  [[ "$panes" == 1 ]] || { echo "the run split the pane: $panes panes"; return 1; }
  wait_for_snapshot '.runs[0].status == "done"'
  [[ "$(jq -r '.runs[0] | [.prompt, .providers[0].state] | @tsv' <<< "$SNAPSHOT")" == $'a quiet harbour\tcomplete' ]]
  run env TERM_PROGRAM=iTerm.app DISPLAY_IMAGE_TARGET="$MOCK_DIR/tty" bash -c 'source "$1"; display_image "$2"' \
    _ "$DISPLAY_SH" "${OUT_BASE}-gemini.png"
  assert_status 0
  [[ ! -s "$MOCK_DIR/tty" ]] || { echo "drew $(wc -c < "$MOCK_DIR/tty") bytes on the terminal"; return 1; }
}

# listing <run-id>... — a delete's JSON body that lists, for each run, every file the run names in
# SNAPSHOT, so what the server keeps is down to its own rules.
listing() {
  jq -c '(reduce .runs[] as $run ({}; .[$run.id] = [$run.files[].path])) as $named
    | {runs: (reduce $ARGS.positional[] as $id ({}; .[$id] = ($named[$id] // [])))}' --args "$@" <<< "$SNAPSHOT"
}

# delete_runs <body> — POSTs a delete the way the page's dialog does, printing the answer and then
# its status.
delete_runs() {
  gallery_curl -w ' %{http_code}' -X POST -H "$(origin)" -H 'Content-Type: application/json' --data-binary "$1" /delete
}

# write_run <run-id> <cwd> <status lines> [done] — writes a run directory by hand the way display.sh
# lays one out, the providers read from the status lines; "done" marks it finished.
write_run() {
  local dir="$IMAGE_GALLERY_DIR/runs/$1" providers
  mkdir -p "$dir/active"
  printf '%b' "$3" > "$dir/status"
  providers=$(cut -f1 "$dir/status" | sort -u | jq -R . | jq -sc .)
  jq -n --arg cwd "$2" --argjson providers "$providers" \
    '{prompt: "a kettle", cwd: $cwd, started_at: "2026-11-25T10:00:00Z", providers: $providers}' > "$dir/meta.json"
  [[ "${4:-}" == done ]] && touch "$dir/.done"
  return 0
}

@test "a token whose pid now belongs to another process, of this user or another, does not keep its run live" {
  # pid 1 is another user's process; the sleep is this user's, started after the token's time.
  write_run 20261125T100000Z-00000000a1 /work/alpha 'gemini\tquerying\t\tmodel-a\t\n'
  printf 'Thu Jan  1 00:00:00 1970\n' > "$IMAGE_GALLERY_DIR/runs/20261125T100000Z-00000000a1/active/gemini.1"
  sleep 60 &
  HOLDER_PID=$!
  write_run 20261125T100100Z-00000000b2 /work/alpha 'gemini\tquerying\t\tmodel-a\t\n'
  printf 'Thu Jan  1 00:00:00 1970\n' > "$IMAGE_GALLERY_DIR/runs/20261125T100100Z-00000000b2/active/gemini.$HOLDER_PID"
  start_gallery
  wait_for_snapshot '.runs | length == 2'
  [[ "$(jq -r '[.runs[] | .status, .providers[0].state] | @tsv' <<< "$SNAPSHOT")" == \
    $'interrupted\tinterrupted\tinterrupted\tinterrupted' ]] || { echo "$SNAPSHOT"; return 1; }
}

@test "a retry offer whose wait is too long to count still shows, with no countdown" {
  write_run 20261125T100000Z-00000000a1 /work/alpha 'gemini\terror\t\tmodel-a\t\n'
  local dir="$IMAGE_GALLERY_DIR/runs/20261125T100000Z-00000000a1"
  sleep 60 &
  HOLDER_PID=$!
  LC_ALL=C TZ=UTC0 ps -o lstart= -p "$HOLDER_PID" > "$dir/active/run-all.$HOLDER_PID"
  printf '%s\ngemini\n' "$(printf '9%.0s' $(seq 1 400))" > "$dir/retry-offer"
  start_gallery
  wait_for_snapshot '.runs[0].status == "live"'
  [[ "$(jq -c '.runs[0] | [.retry, .retry_seconds, .retry_ends_ms]' <<< "$SNAPSHOT")" == '[["gemini"],null,null]' ]] || {
    echo "$SNAPSHOT"; return 1; }
}

@test "a run directory that does not parse is left out with one line in server.log, and the server serves the rest" {
  write_run 20261125T100000Z-00000000a1 /work/alpha 'gemini\tcomplete\t1000\tmodel-a\t/tmp/a.png\n' done
  local runs="$IMAGE_GALLERY_DIR/runs"
  mkdir -p "$runs/20261125T100100Z-00000000b2" "$runs/20261125T100200Z-00000000c3"
  printf '[]' > "$runs/20261125T100100Z-00000000b2/meta.json"
  printf '{"prompt": "a kettle", "cwd": 5, "started_at": "", "providers": []}' > "$runs/20261125T100200Z-00000000c3/meta.json"
  printf 'not a run' > "$runs/20261125T100300Z-00000000d4"
  # A run still being assembled under its dot name that is gone by the time the server looks.
  ln -s "$runs/nowhere" "$runs/.20261125T100400Z-00000000e5"
  start_gallery
  wait_for_snapshot '.runs | length == 1'
  [[ "$(jq -r '.runs[0].id' <<< "$SNAPSHOT")" == 20261125T100000Z-00000000a1 ]] || { echo "$SNAPSHOT"; return 1; }
  # Each rejected run is named once, however many scans have passed.
  sleep 1
  local root
  root=$(cd "$IMAGE_GALLERY_DIR" && pwd -P)
  [[ "$(cat "$IMAGE_GALLERY_DIR/server.log")" == "image gallery: skipping run $root/runs/20261125T100300Z-00000000d4: meta.json: Not a directory
image gallery: skipping run $root/runs/20261125T100200Z-00000000c3: meta.json's cwd is 5, not a string
image gallery: skipping run $root/runs/20261125T100100Z-00000000b2: meta.json holds [], not an object" ]] || {
    cat "$IMAGE_GALLERY_DIR/server.log"; return 1; }
}

# cpu_seconds <pid> — the CPU time, user and system, a process has used so far, in seconds.
cpu_seconds() {
  if [[ -r "/proc/$1/stat" ]]; then
    awk -v tick="$(getconf CLK_TCK)" '{ printf "%.2f\n", ($14 + $15) / tick }' "/proc/$1/stat"
  else
    ps -o time= -p "$1" | awk -F: '{ printf "%.2f\n", $1 * 60 + $2 }'
  fi
}

@test "a server holding 200 finished runs stays under a quarter CPU-second in five idle seconds" {
  local i id dir
  for i in $(seq 1 200); do
    id=$(printf '20261125T%06dZ-%010x' "$i" "$i")
    dir="$IMAGE_GALLERY_DIR/runs/$id"
    mkdir -p "$dir/active" "$dir/errors"
    printf '{"prompt": "a kettle", "cwd": "/work/alpha", "started_at": "2026-11-25T10:00:00Z", "providers": ["gemini", "openai"]}' > "$dir/meta.json"
    printf 'gemini\tcomplete\t1000\tmodel-a\t/tmp/a.png\nopenai\terror\t\tmodel-b\t\n' > "$dir/status"
    printf 'refused' > "$dir/errors/openai.txt"
    touch "$dir/.done"
  done
  start_gallery
  wait_for_snapshot '.runs | length == 200'
  local pid before after
  pid=$(server_field pid)
  before=$(cpu_seconds "$pid")
  sleep 5
  after=$(cpu_seconds "$pid")
  awk -v a="$before" -v b="$after" 'BEGIN { exit !(b - a < 0.25) }' || {
    echo "the server used $before s before and $after s after five idle seconds"; return 1; }
}

@test "each run in the snapshot names its session by the last folder of its working directory" {
  write_run 20261125T100000Z-00000000a1 /work/projects/alpha 'gemini\tcomplete\t1000\tmodel-a\t/tmp/a.png\n' done
  write_run 20261125T100100Z-00000000b2 /work/beta 'gemini\tcomplete\t1000\tmodel-a\t/tmp/b.png\n' done
  start_gallery
  wait_for_snapshot '.runs | length == 2'
  [[ "$(jq -r '[.runs[].session] | @tsv' <<< "$SNAPSHOT")" == $'beta\talpha' ]] || { echo "$SNAPSHOT"; return 1; }
}

@test "a provider at work carries usual_ms, the median time of the last five frames its model completed" {
  # Oldest first: the 100000 ms frame is sixth newest, so it falls outside the five that count.
  local ms n=0
  for ms in 100000 1000 3000 2000 4000 5000; do
    n=$((n + 1))
    write_run "20261125T10000${n}Z-000000000${n}" /work/alpha "gemini\tcomplete\t${ms}\tmodel-a\t/tmp/${n}.png\nopenai\tcomplete\t9000\tmodel-b\t/tmp/o${n}.png\n" done
  done
  write_run 20261125T110000Z-00000000ff /work/alpha 'gemini\tquerying\t\tmodel-a\t\nopenai\tquerying\t\tmodel-c\t\nxai\tretrying\t2/3\tmodel-a\t\n'
  sleep 60 &
  HOLDER_PID=$!
  LC_ALL=C TZ=UTC0 ps -o lstart= -p "$HOLDER_PID" > "$IMAGE_GALLERY_DIR/runs/20261125T110000Z-00000000ff/active/test.$HOLDER_PID"
  start_gallery
  wait_for_snapshot '.runs[0].status == "live"'
  # gemini on model-a: median of 1000 3000 2000 4000 5000. openai has no history on model-c, and
  # xai none at all, so theirs is absent; a finished frame carries none.
  [[ "$(jq -c '.runs[0].providers | map({(.name): .usual_ms}) | add' <<< "$SNAPSHOT")" == \
    '{"gemini":3000,"openai":null,"xai":null}' ]] || { echo "$SNAPSHOT"; return 1; }
  [[ "$(jq -c '[.runs[0].providers[] | has("usual_ms")]' <<< "$SNAPSHOT")" == '[true,false,false]' ]]
  [[ "$(jq -c '[.runs[1:][].providers[] | has("usual_ms")] | unique' <<< "$SNAPSHOT")" == '[false]' ]]
}

@test "a run held by a session in another timezone stays live on a server started in UTC" {
  write_run 20261125T100000Z-00000000a1 /work/alpha 'gemini\tquerying\t\tmodel-a\t\n'
  local dir="$IMAGE_GALLERY_DIR/runs/20261125T100000Z-00000000a1"
  TZ=Pacific/Kiritimati bash -c 'source "$1/scripts/display.sh"; DISPLAY_PANE_DIR="$2"; __pane_acquire run-all; sleep 60' _ "$PLUGIN_ROOT" "$dir" &
  HOLDER_PID=$!
  local waited=0
  until compgen -G "$dir/active/run-all.*" > /dev/null; do sleep 0.1; waited=$((waited + 1)); [[ $waited -lt 50 ]]; done
  TZ=UTC start_gallery
  wait_for_snapshot '.runs[0].status == "live"'
  [[ "$(jq -r '.runs[0].providers[0].state' <<< "$SNAPSHOT")" == querying ]] || { echo "$SNAPSHOT"; return 1; }
}

@test "an entry in active/ that is not a file, or names a pid no process can have, neither holds a run nor stops the server" {
  write_run 20261125T100000Z-00000000a1 /work/alpha 'gemini\tquerying\t\tmodel-a\t\n'
  local dir="$IMAGE_GALLERY_DIR/runs/20261125T100000Z-00000000a1"
  printf 'Thu Jan  1 00:00:00 1970\n' > "$dir/active/run-all.999999999999"
  sleep 60 &
  HOLDER_PID=$!
  LC_ALL=C TZ=UTC0 ps -o lstart= -p "$HOLDER_PID" > "$dir/active/run-all.$HOLDER_PID"
  start_gallery
  wait_for_snapshot '.runs[0].status == "live"'
  kill "$HOLDER_PID"
  wait "$HOLDER_PID" 2>/dev/null || true
  mkdir "$dir/active/run-all.123"
  wait_for_snapshot '.runs[0].status == "interrupted"'
}

@test "deleting a run removes the image files its records name and its folder, and leaves every other file and run" {
  local out="${BATS_TEST_TMPDIR}/out" a=20261125T100000Z-00000000a1 b=20261125T100100Z-00000000b2
  printf 'png' > "$out/one-gemini.png"
  printf 'png' > "$out/two-gemini.png"
  # A record that names a symlink: the link goes, the file it points at stays.
  printf 'png' > "$out/target.png"
  ln -s "$out/target.png" "$out/link-openai.png"
  printf 'png' > "$out/keep-gemini.png"
  printf 'png' > "$out/one-xai.png"
  printf 'notes' > "$out/notes.txt"
  # gone-xai.png is named by a record but no longer on disk, which does not stop the delete.
  write_run "$a" /work/alpha "gemini\tcomplete\t1000\tmodel-a\t$out/one-gemini.png\ngemini\tquerying\t\tmodel-a\t\ngemini\tcomplete\t1000\tmodel-a\t$out/two-gemini.png\nopenai\tcomplete\t1000\tmodel-b\t$out/link-openai.png\nxai\tcomplete\t1000\tmodel-c\t$out/gone-xai.png\n" done
  write_run "$b" /work/alpha "gemini\tcomplete\t1000\tmodel-a\t$out/keep-gemini.png\n" done
  start_gallery
  wait_for_snapshot '.runs | length == 2'
  [[ "$(jq -c --arg a "$a" '.runs[] | select(.id == $a) | [.files[].path]' <<< "$SNAPSHOT")" == \
    "[\"$out/one-gemini.png\",\"$out/two-gemini.png\",\"$out/link-openai.png\",\"$out/gone-xai.png\"]" ]] || {
    echo "$SNAPSHOT"; return 1; }
  # A POST without the page's Origin deletes nothing.
  [[ "$(gallery_curl -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data-binary "$(listing "$a")" /delete)" == 403 ]]
  [[ -f "$out/one-gemini.png" && -L "$out/link-openai.png" && -d "$IMAGE_GALLERY_DIR/runs/$a" ]]
  local answer
  answer=$(delete_runs "$(listing "$a")")
  [[ "$answer" == "{\"deleted\": [{\"id\": \"$a\", \"removed\": [\"$out/one-gemini.png\", \"$out/two-gemini.png\", \"$out/link-openai.png\"], \"missing\": [\"$out/gone-xai.png\"], \"kept_files\": []}], \"kept\": []} 200" ]] || {
    echo "$answer"; return 1; }
  [[ "$(ls "$out" | tr '\n' ' ')" == "keep-gemini.png notes.txt one-xai.png target.png " ]] || { ls -la "$out"; return 1; }
  [[ ! -e "$IMAGE_GALLERY_DIR/runs/$a" && -d "$IMAGE_GALLERY_DIR/runs/$b" ]]
  # The page hears of it at once: the snapshot already published holds only the other run.
  [[ "$(snapshot | jq -r '[.runs[].id] | @tsv')" == "$b" ]]
  answer=$(delete_runs "$(listing "$a")")
  [[ "$answer" == "{\"deleted\": [], \"kept\": [{\"id\": \"$a\", \"error\": \"no run $a\"}], \"error\": \"no run $a\"} 404" ]] || {
    echo "$answer"; return 1; }
}

@test "deleting a run deletes the files named <name>-<provider> with an image extension and keeps each other file it names, saying why" {
  local out="${BATS_TEST_TMPDIR}/out" a=20261125T100000Z-00000000a1
  printf 'png' > "$out/fine-gemini.png"
  # A single provider script called as SKILL.md shows saves to a name of the caller's choosing.
  printf 'png' > "$out/generated.png"
  printf 'png' > "$out/photo-openai.png"
  printf 'secret' > "$out/notes.txt"
  mkdir "$out/folder-xai.png"
  write_run "$a" /work/alpha "gemini\tcomplete\t1000\tmodel-a\t$out/fine-gemini.png\ngemini\tcomplete\t1000\tmodel-a\t$out/generated.png\ngemini\tcomplete\t1000\tmodel-a\t$out/photo-openai.png\nopenai\tcomplete\t1000\tmodel-b\t$out/notes.txt\nxai\tcomplete\t1000\tmodel-c\t$out/folder-xai.png\nxai\tcomplete\t1000\tmodel-c\trelative-xai.png\nxai\tcomplete\t1000\tmodel-c\t$out/nul\0-xai.png\n" done
  start_gallery
  wait_for_snapshot '.runs | length == 1'
  # The page is told which files stay, and why, before it asks: the same files and reasons the delete gives.
  local foreseen answer
  [[ "$(jq -c '[.runs[0].files[] | select(.kept == null) | .path]' <<< "$SNAPSHOT")" == "[\"$out/fine-gemini.png\"]" ]] || {
    echo "$SNAPSHOT"; return 1; }
  foreseen=$(jq -c '[.runs[0].files[] | select(.kept) | {path, reason: .kept}]' <<< "$SNAPSHOT")
  answer=$(delete_runs "$(listing "$a")")
  [[ "$(jq -c '.deleted[0].kept_files' <<< "${answer% *}")" == "$foreseen" ]] || { echo "$foreseen"; echo "$answer"; return 1; }
  [[ "$(ls "$out" | tr '\n' ' ')" == "folder-xai.png generated.png notes.txt photo-openai.png " ]] || { ls -la "$out"; return 1; }
  [[ ! -e "$IMAGE_GALLERY_DIR/runs/$a" ]]
  [[ "$answer" == "{\"deleted\": [{\"id\": \"$a\", \"removed\": [\"$out/fine-gemini.png\"], \"missing\": [], \"kept_files\": [{\"path\": \"$out/generated.png\", \"reason\": \"its name does not end in -gemini and .png, .jpg, .jpeg, .webp or .gif\"}, {\"path\": \"$out/photo-openai.png\", \"reason\": \"its name does not end in -gemini and .png, .jpg, .jpeg, .webp or .gif\"}, {\"path\": \"$out/notes.txt\", \"reason\": \"its name does not end in -openai and .png, .jpg, .jpeg, .webp or .gif\"}, {\"path\": \"$out/folder-xai.png\", \"reason\": \"not a file\"}, {\"path\": \"relative-xai.png\", \"reason\": \"not an absolute path\"}, {\"path\": \"$out/nul\\u0000-xai.png\", \"reason\": \"its path holds a NUL character\"}]}], \"kept\": []} 200" ]] || {
    echo "$answer"; return 1; }
}

@test "a run still held by a process is kept with its images, answered 409" {
  local out="${BATS_TEST_TMPDIR}/out" a=20261125T100000Z-00000000a1
  printf 'png' > "$out/held-gemini.png"
  write_run "$a" /work/alpha "gemini\tcomplete\t1000\tmodel-a\t$out/held-gemini.png\nopenai\tquerying\t\tmodel-b\t\n"
  sleep 60 &
  HOLDER_PID=$!
  LC_ALL=C TZ=UTC0 ps -o lstart= -p "$HOLDER_PID" > "$IMAGE_GALLERY_DIR/runs/$a/active/run-all.$HOLDER_PID"
  start_gallery
  wait_for_snapshot '.runs[0].status == "live"'
  local answer
  answer=$(delete_runs "$(listing "$a")")
  [[ "$answer" == "{\"deleted\": [], \"kept\": [{\"id\": \"$a\", \"error\": \"run $a is still generating\"}], \"error\": \"run $a is still generating\"} 409" ]] || {
    echo "$answer"; return 1; }
  [[ -f "$out/held-gemini.png" && -d "$IMAGE_GALLERY_DIR/runs/$a" ]]
}

@test "deleting a project's runs in one request deletes each that is not live and reports the live one it kept" {
  local out="${BATS_TEST_TMPDIR}/out" a1=20261125T100000Z-00000000a1 a2=20261125T100100Z-00000000a2 a3=20261125T100200Z-00000000a3 b1=20261125T100300Z-00000000b1
  printf 'png' > "$out/a1-gemini.png"
  printf 'png' > "$out/a3-gemini.png"
  printf 'png' > "$out/b1-gemini.png"
  write_run "$a1" /work/alpha "gemini\tcomplete\t1000\tmodel-a\t$out/a1-gemini.png\n" done
  write_run "$a2" /work/alpha 'gemini\tquerying\t\tmodel-a\t\n'
  write_run "$a3" /work/alpha "gemini\tcomplete\t1000\tmodel-a\t$out/a3-gemini.png\nopenai\tquerying\t\tmodel-b\t\n"
  write_run "$b1" /work/beta "gemini\tcomplete\t1000\tmodel-a\t$out/b1-gemini.png\n" done
  sleep 60 &
  HOLDER_PID=$!
  LC_ALL=C TZ=UTC0 ps -o lstart= -p "$HOLDER_PID" > "$IMAGE_GALLERY_DIR/runs/$a3/active/run-all.$HOLDER_PID"
  start_gallery
  wait_for_snapshot '.runs | length == 4'
  local answer
  answer=$(delete_runs "$(listing "$a1" "$a2" "$a3")")
  [[ "$answer" == "{\"deleted\": [{\"id\": \"$a1\", \"removed\": [\"$out/a1-gemini.png\"], \"missing\": [], \"kept_files\": []}, {\"id\": \"$a2\", \"removed\": [], \"missing\": [], \"kept_files\": []}], \"kept\": [{\"id\": \"$a3\", \"error\": \"run $a3 is still generating\"}]} 200" ]] || {
    echo "$answer"; return 1; }
  [[ "$(ls "$out" | tr '\n' ' ')" == "a3-gemini.png b1-gemini.png " ]] || { ls -la "$out"; return 1; }
  [[ "$(snapshot | jq -r '[.runs[].id] | @tsv')" == "$b1"$'\t'"$a3" ]]
}

@test "deleting a run keeps an image file another run names too, saying which, and the last run naming it removes it" {
  local out="${BATS_TEST_TMPDIR}/out" a=20261125T100000Z-00000000a1 b=20261125T100100Z-00000000b2 \
    c=20261125T100200Z-00000000c3 d=20261125T100300Z-00000000d4
  # The older run's file was deleted by hand and the same path generated again by the newer run.
  printf 'png' > "$out/hero-gemini.png"
  printf 'png' > "$out/hero-openai.png"
  write_run "$a" /work/alpha "gemini\tcomplete\t1000\tmodel-a\t$out/hero-gemini.png\nopenai\tcomplete\t1000\tmodel-b\t$out/hero-openai.png\n" done
  write_run "$b" /work/alpha "gemini\tcomplete\t1000\tmodel-a\t$out/hero-gemini.png\n" done
  start_gallery
  wait_for_snapshot '.runs | length == 2'
  local answer
  answer=$(delete_runs "$(listing "$a")")
  [[ "$answer" == "{\"deleted\": [{\"id\": \"$a\", \"removed\": [\"$out/hero-openai.png\"], \"missing\": [], \"kept_files\": [{\"path\": \"$out/hero-gemini.png\", \"reason\": \"run $b names it too\"}]}], \"kept\": []} 200" ]] || {
    echo "$answer"; return 1; }
  [[ "$(ls "$out" | tr '\n' ' ')" == "hero-gemini.png " ]] || { ls -la "$out"; return 1; }
  answer=$(delete_runs "$(listing "$b")")
  [[ "$answer" == "{\"deleted\": [{\"id\": \"$b\", \"removed\": [\"$out/hero-gemini.png\"], \"missing\": [], \"kept_files\": []}], \"kept\": []} 200" ]] || {
    echo "$answer"; return 1; }
  [[ -z "$(ls "$out")" ]] || { ls -la "$out"; return 1; }
  # Runs deleted together: the file goes with the last of them that names it.
  printf 'png' > "$out/pair-gemini.png"
  write_run "$c" /work/alpha "gemini\tcomplete\t1000\tmodel-a\t$out/pair-gemini.png\n" done
  write_run "$d" /work/alpha "gemini\tcomplete\t1000\tmodel-a\t$out/pair-gemini.png\n" done
  wait_for_snapshot '.runs | length == 2'
  answer=$(delete_runs "$(listing "$c" "$d")")
  [[ "$answer" == "{\"deleted\": [{\"id\": \"$c\", \"removed\": [], \"missing\": [], \"kept_files\": [{\"path\": \"$out/pair-gemini.png\", \"reason\": \"run $d names it too\"}]}, {\"id\": \"$d\", \"removed\": [\"$out/pair-gemini.png\"], \"missing\": [], \"kept_files\": []}], \"kept\": []} 200" ]] || {
    echo "$answer"; return 1; }
  [[ -z "$(ls "$out")" ]] || { ls -la "$out"; return 1; }
}

@test "deleting a run keeps a file another run names by another spelling, through a symlinked folder or a doubled slash" {
  local out="${BATS_TEST_TMPDIR}/out" a=20261125T100000Z-00000000a1 b=20261125T100100Z-00000000b2
  printf 'png' > "$out/hero-gemini.png"
  printf 'png' > "$out/pair-openai.png"
  ln -s "$out" "${BATS_TEST_TMPDIR}/link"
  write_run "$a" /work/alpha "gemini\tcomplete\t1000\tmodel-a\t${BATS_TEST_TMPDIR}/link/hero-gemini.png\nopenai\tcomplete\t1000\tmodel-b\t$out//pair-openai.png\n" done
  write_run "$b" /work/alpha "gemini\tcomplete\t1000\tmodel-a\t$out/hero-gemini.png\nopenai\tcomplete\t1000\tmodel-b\t$out/pair-openai.png\n" done
  start_gallery
  wait_for_snapshot '.runs | length == 2'
  # The page is told each file is one of b's, so its dialog marks both as kept.
  [[ "$(jq -c '[.runs[] | [.id, [.files[].entry]]]' <<< "$SNAPSHOT")" == "[[\"$b\",[0,1]],[\"$a\",[0,1]]]" ]] || {
    echo "$SNAPSHOT"; return 1; }
  local answer
  answer=$(delete_runs "$(listing "$a")")
  [[ "$(ls "$out" | tr '\n' ' ')" == "hero-gemini.png pair-openai.png " ]] || { ls -la "$out"; return 1; }
  [[ "$answer" == "{\"deleted\": [{\"id\": \"$a\", \"removed\": [], \"missing\": [], \"kept_files\": [{\"path\": \"${BATS_TEST_TMPDIR}/link/hero-gemini.png\", \"reason\": \"run $b names it too\"}, {\"path\": \"$out//pair-openai.png\", \"reason\": \"run $b names it too\"}]}], \"kept\": []} 200" ]] || {
    echo "$answer"; return 1; }
}

@test "a delete removes only the files the page listed for each run, and none it lists that the run's records do not name" {
  local out="${BATS_TEST_TMPDIR}/out" a=20261125T100000Z-00000000a1 b=20261125T100100Z-00000000b2
  printf 'png' > "$out/own-gemini.png"
  printf 'png' > "$out/hero-gemini.png"
  printf 'png' > "$out/stray-gemini.png"
  write_run "$a" /work/alpha "gemini\tcomplete\t1000\tmodel-a\t$out/own-gemini.png\ngemini\tcomplete\t1000\tmodel-a\t$out/hero-gemini.png\n" done
  write_run "$b" /work/alpha "gemini\tcomplete\t1000\tmodel-a\t$out/hero-gemini.png\n" done
  start_gallery
  wait_for_snapshot '.runs | length == 2'
  # A body that does not say what to delete deletes nothing.
  [[ "$(delete_runs 'a run')" == '{"error": "the body is not JSON: Expecting value: line 1 column 1 (char 0)"} 400' ]]
  [[ "$(delete_runs '{"runs": {}}')" == \
    '{"error": "the body must be an object with runs, each run'"'"'s id mapped to the paths the page listed for it"} 400' ]]
  [[ "$(delete_runs "{\"runs\": {\"$a\": [1]}}")" == "{\"error\": \"run \\\"$a\\\"'s paths are [1], not a list of paths\"} 400" ]]
  [[ "$(ls "$out" | tr '\n' ' ')" == "hero-gemini.png own-gemini.png stray-gemini.png " ]]
  # The dialog for a, opened now, lists hero-gemini.png as kept since b uses it. Then b is deleted
  # from another tab, which keeps the file for a, so a is the last run naming it when its delete
  # arrives. The page also lists a path a's records do not name, as a hand-made request could.
  delete_runs "$(listing "$b")" > /dev/null
  local answer
  answer=$(delete_runs "{\"runs\": {\"$a\": [\"$out/own-gemini.png\", \"$out/stray-gemini.png\"]}}")
  [[ "$(ls "$out" | tr '\n' ' ')" == "hero-gemini.png stray-gemini.png " ]] || { ls -la "$out"; return 1; }
  [[ "$answer" == "{\"deleted\": [{\"id\": \"$a\", \"removed\": [\"$out/own-gemini.png\"], \"missing\": [], \"kept_files\": [{\"path\": \"$out/hero-gemini.png\", \"reason\": \"the delete did not list it\"}, {\"path\": \"$out/stray-gemini.png\", \"reason\": \"run $a's records do not name it\"}]}], \"kept\": []} 200" ]] || {
    echo "$answer"; return 1; }
  [[ -z "$(ls "$IMAGE_GALLERY_DIR/runs")" ]]
}

@test "a run in the gallery whose status log the server cannot read stops a delete, since it may name the same files" {
  local out="${BATS_TEST_TMPDIR}/out" a=20261125T100000Z-00000000a1 b=20261125T100100Z-00000000b2
  printf 'png' > "$out/hero-gemini.png"
  write_run "$a" /work/alpha "gemini\tcomplete\t1000\tmodel-a\t$out/hero-gemini.png\n" done
  write_run "$b" /work/alpha "gemini\tcomplete\t1000\tmodel-a\t$out/other-gemini.png\n" done
  rm "$IMAGE_GALLERY_DIR/runs/$b/status"
  mkdir "$IMAGE_GALLERY_DIR/runs/$b/status"
  start_gallery
  wait_for_snapshot '.runs | length == 1'
  local answer runs
  runs=$(cd "$IMAGE_GALLERY_DIR/runs" && pwd -P)
  answer=$(delete_runs "$(listing "$a")")
  [[ "$answer" == "{\"error\": \"could not read $runs/$b/status: Is a directory, so which runs share an image is unknown; nothing was deleted\"} 500" ]] || {
    echo "$answer"; return 1; }
  [[ -f "$out/hero-gemini.png" && -d "$IMAGE_GALLERY_DIR/runs/$a" ]]
}

@test "deleting a run keeps an image file another run uses as an input image, by any spelling, saying which" {
  local out="${BATS_TEST_TMPDIR}/out" a=20261125T100000Z-00000000a1 b=20261125T100100Z-00000000b2 answer
  printf 'png' > "$out/hero-gemini.png"
  printf 'png' > "$out/edit-gemini.png"
  write_run "$a" /work/alpha "gemini\tcomplete\t1000\tmodel-a\t$out/hero-gemini.png\n" done
  # b edited a's image, which it names with a doubled slash.
  write_run "$b" /work/alpha "gemini\tcomplete\t1000\tmodel-a\t$out/edit-gemini.png\n" done
  record_arguments "$b" "$out/edit" edit "$out//hero-gemini.png"
  start_gallery
  wait_for_snapshot '.runs | length == 2'
  answer=$(delete_runs "$(listing "$a")")
  [[ "$answer" == "{\"deleted\": [{\"id\": \"$a\", \"removed\": [], \"missing\": [], \"kept_files\": [{\"path\": \"$out/hero-gemini.png\", \"reason\": \"run $b uses it as an input image\"}]}], \"kept\": []} 200" ]] || {
    echo "$answer"; return 1; }
  [[ "$(ls "$out" | tr '\n' ' ')" == "edit-gemini.png hero-gemini.png " ]] || { ls -la "$out"; return 1; }
  # The page was told before it asked, so its dialog listed the file as kept, with the same reason.
  [[ "$(jq -c --arg a "$a" '[.runs[] | select(.id == $a) | .files[] | {path, kept}]' <<< "$SNAPSHOT")" == \
    "[{\"path\":\"$out/hero-gemini.png\",\"kept\":\"run $b uses it as an input image\"}]" ]] || { echo "$SNAPSHOT"; return 1; }
}

@test "a run whose status log or meta.json does not parse stops a delete, naming it, since what it names past that is unknown" {
  local out="${BATS_TEST_TMPDIR}/out" a=20261125T100000Z-00000000a1 b=20261125T100100Z-00000000b2 answer
  printf 'png' > "$out/hero-gemini.png"
  write_run "$a" /work/alpha "gemini\tcomplete\t1000\tmodel-a\t$out/hero-gemini.png\n" done
  # b's second line does not parse, which hides the record after it that names a's image.
  write_run "$b" /work/alpha "gemini\tcomplete\t1000\tmodel-a\t$out/other-gemini.png\ngarbage\nopenai\tcomplete\t1000\tmodel-b\t$out/hero-gemini.png\n" done
  start_gallery
  wait_for_snapshot '.runs | length == 2'
  answer=$(delete_runs "$(listing "$a")")
  [[ "$answer" == "{\"error\": \"run $b's status log is unreadable (status line 2 has 1 fields, not 5), so which images it names is unknown; nothing was deleted\"} 409" ]] || {
    echo "$answer"; return 1; }
  [[ -f "$out/hero-gemini.png" && -d "$IMAGE_GALLERY_DIR/runs/$a" ]]
  # A meta.json that does not parse hides the input images the run uses.
  printf 'openai\tcomplete\t1000\tmodel-b\t%s\n' "$out/other-openai.png" > "$IMAGE_GALLERY_DIR/runs/$b/status"
  printf '{"prompt": ' > "$IMAGE_GALLERY_DIR/runs/$b/meta.json"
  answer=$(delete_runs "$(listing "$a")")
  [[ "$answer" == "{\"error\": \"run $b cannot be read: meta.json is not JSON: Expecting value: line 1 column 12 (char 11), so which images it uses is unknown; nothing was deleted\"} 409" ]] || {
    echo "$answer"; return 1; }
  [[ -f "$out/hero-gemini.png" && -d "$IMAGE_GALLERY_DIR/runs/$a" ]]
}

# resend <run id> <body> — POSTs a resend the way the page's Resend button does, printing the answer
# and then its status.
resend() {
  gallery_curl -w ' %{http_code}' -X POST -H "$(origin)" -H 'Content-Type: application/json' --data-binary "$2" "/resend/$1"
}

@test "Resend on a run of a gallery-mode run-all starts a new run in its project with the edited prompt and the chosen providers, saved beside its images" {
  answer_provider_with "$GEMINI_IMAGE"
  # With no key, openai fails before it starts, as a run's provider can.
  unset OPENAI_API_KEY
  # The server inherits the environment of the run-all that starts it, as in use, and here that
  # run-all works in another folder than the run resent, which is named through a symlink on macOS
  # (/var is /private/var). The new run must record its folder spelled as the resent run did.
  cd "${BATS_TEST_TMPDIR}"
  run bash "${SCRIPTS}/run-all.sh" --mode generate --prompt "a harbour at noon" --output-base out/harbour --providers gemini
  assert_status 0
  cd out
  run bash "${SCRIPTS}/run-all.sh" --mode generate --prompt "a lighthouse at dusk" --output-base picture \
    --providers gemini,openai --gemini-extra "--aspect-ratio 16:9"
  assert_status 1
  wait_for_snapshot '(.runs | length == 2) and .runs[0].status == "done"'
  local first cwd
  first=$(jq -r '.runs[0].id' <<< "$SNAPSHOT")
  cwd=$(jq -r '.runs[0].cwd' <<< "$SNAPSHOT")
  [[ "$cwd" == "$PWD" && "$(jq -r '.runs[0].resendable' <<< "$SNAPSHOT")" == true ]] || { echo "$SNAPSHOT"; return 1; }
  # A run the server did not start records no launch id.
  [[ "$(jq 'has("launch")' "$IMAGE_GALLERY_DIR/runs/$first/meta.json")" == false ]]
  local answer new
  answer=$(resend "$first" '{"prompt": "a lighthouse at dawn", "providers": ["gemini"]}')
  [[ "$answer" =~ ^\{\"run\":\ \"([0-9]{8}T[0-9]{6}Z-[0-9a-f]{10})\"\}\ 200$ ]] || { echo "answer: $answer"; return 1; }
  new=${BASH_REMATCH[1]}
  [[ "$new" != "$first" ]]
  wait_for_snapshot "(.runs | length == 3) and (.runs[0].id == \"$new\") and (.runs[0].status == \"done\")"
  [[ "$(jq -r '.runs[0] | [.prompt, .cwd, ([.providers[].name] | join(",")), .providers[0].state] | @tsv' <<< "$SNAPSHOT")" == \
    "a lighthouse at dawn	$cwd	gemini	complete" ]] || { echo "$SNAPSHOT"; return 1; }
  local saved
  saved=$(jq -r '.runs[0].providers[0].image.path' <<< "$SNAPSHOT")
  [[ "$saved" =~ ^"$PWD"/image-[0-9]{8}-[0-9]{6}-gemini\.png$ && -f "$saved" ]] || { echo "saved: $saved"; ls -la; return 1; }
  # The server cannot know the umask the run it resends had, so the image is readable by this user only.
  [[ "$(stat -c %a "$saved" 2>/dev/null || stat -f %Lp "$saved")" == 600 ]] || { ls -la "$saved"; return 1; }
  [[ "$(ls | wc -l | tr -d ' ')" == 3 && -f picture-gemini.png ]] || { ls -la; return 1; }
  # The first run is as it was, and the resent request carried the run's own extra arguments.
  [[ "$(jq -r '.runs[1] | [.id, .prompt, ([.providers[].name] | join(","))] | @tsv' <<< "$SNAPSHOT")" == \
    "$first	a lighthouse at dusk	gemini,openai" ]] || { echo "$SNAPSHOT"; return 1; }
  grep -qF '"aspectRatio": "16:9"' "$MOCK_DIR/request.raw" || { cat "$MOCK_DIR/request.raw"; return 1; }
  [[ "$(cat "$MOCK_DIR/calls")" == 3 ]]
  [[ -z "$(grep -rIlF --devices=skip "$DUMMY_GEMINI_KEY" "$IMAGE_GALLERY_DIR")" && "$answer" != *"$DUMMY_GEMINI_KEY"* ]]
}

# record_arguments <run-id> <output base> [<mode> <input image>...] — adds to a run write_run wrote
# the arguments a gallery-mode run-all records: generate mode unless one is given.
record_arguments() {
  local meta="$IMAGE_GALLERY_DIR/runs/$1/meta.json" base="$2" mode="${3:-generate}"
  shift 2
  [[ $# -gt 0 ]] && shift
  jq --arg mode "$mode" --arg base "$base" \
    '. + {arguments: {mode: $mode, output_base: $base, input_images: $ARGS.positional,
                      extras: {gemini: "", openai: "", xai: "", openrouter: ""}}}' \
    "$meta" --args "$@" > "$meta.tmp"
  mv "$meta.tmp" "$meta"
}

# write_resendable_run <run-id> <cwd> <image> [<mode> <input image>...] — a finished run whose gemini
# saved image, with the arguments a gallery-mode run-all records: generate mode unless one is given.
write_resendable_run() {
  local id="$1" image="$3"
  write_run "$id" "$2" "gemini\tcomplete\t1000\tmodel-a\t$image\n" done
  shift 3
  record_arguments "$id" "${image%-gemini.png}" "$@"
}

@test "a run that did not record its arguments cannot be resent: the page is told so, and a resend is refused" {
  answer_provider_with "$GEMINI_IMAGE"
  local out="${BATS_TEST_TMPDIR}/out" a=20261125T100000Z-00000000a1
  printf 'png' > "$out/hero-gemini.png"
  write_run "$a" "$out" "gemini\tcomplete\t1000\tmodel-a\t$out/hero-gemini.png\n" done
  start_gallery
  wait_for_snapshot '.runs | length == 1'
  [[ "$(jq -r '.runs[0].resendable' <<< "$SNAPSHOT")" == false ]] || { echo "$SNAPSHOT"; return 1; }
  # Without the page's Origin a resend is refused before its body is read, as every button's post is.
  [[ "$(gallery_curl -w ' %{http_code}' -X POST -H 'Content-Type: application/json' --data-binary '{"prompt": "a kettle", "providers": ["gemini"]}' "/resend/$a")" == \
    '{"error": "wrong Origin header"} 403' ]]
  [[ "$(resend "$a" '{"prompt": "a kettle", "providers": ["gemini"]}')" == \
    "{\"error\": \"run $a did not record the arguments it was started with, so it cannot be resent\"} 409" ]]
  [[ ! -e "$IMAGE_GALLERY_DIR/resend-logs" && ! -e "$MOCK_DIR/calls" && "$(ls "$out")" == hero-gemini.png ]]
}

@test "a resend whose output path is taken, even by a dangling symlink, is refused and starts nothing" {
  answer_provider_with "$GEMINI_IMAGE"
  local out="${BATS_TEST_TMPDIR}/out" a=20261125T100000Z-00000000a1 stamp answer
  printf 'png' > "$out/hero-gemini.png"
  write_resendable_run "$a" "$out" "$out/hero-gemini.png"
  start_gallery
  wait_for_snapshot '.runs[0].resendable'
  # The resend's base is stamped with the second it starts in; every second it could start in is taken.
  for stamp in $(python3 -I -c 'import time; [print(time.strftime("%Y%m%d-%H%M%S", time.localtime(time.time() + s))) for s in range(10)]'); do
    ln -s nowhere "$out/image-$stamp-gemini.png"
  done
  answer=$(resend "$a" '{"prompt": "a kettle", "providers": ["gemini"]}')
  [[ "$answer" =~ ^\{\"error\":\ \"$out/image-[0-9]{8}-[0-9]{6}-gemini\.png\ already\ exists,\ and\ nothing\ is\ overwritten\"\}\ 409$ ]] || {
    echo "answer: $answer"; return 1; }
  [[ ! -e "$IMAGE_GALLERY_DIR/resend-logs" && ! -e "$MOCK_DIR/calls" ]]
  [[ "$(snapshot | jq '.runs | length')" == 1 ]]
}

@test "a resend is refused for an unknown provider, none, a blank prompt, a working folder or input image that is gone" {
  answer_provider_with "$GEMINI_IMAGE"
  local out="${BATS_TEST_TMPDIR}/out" a=20261125T100000Z-00000000a1 b=20261125T100100Z-00000000b2 \
    c=20261125T100200Z-00000000c3
  printf 'png' > "$out/hero-gemini.png"
  printf 'png' > "$out/sketch.png"
  write_resendable_run "$a" "$out" "$out/hero-gemini.png"
  write_resendable_run "$b" "${BATS_TEST_TMPDIR}/gone" "$out/hero-gemini.png"
  write_resendable_run "$c" "$out" "$out/hero-gemini.png" edit "$out/sketch.png" "$out/erased.png"
  start_gallery
  wait_for_snapshot '[.runs[].resendable] == [true, true, true]'
  [[ "$(resend "$a" '{"prompt": "a kettle", "providers": ["gemini", "dalle"]}')" == \
    '{"error": "unknown provider \"dalle\"; choose from gemini, openai, xai, openrouter"} 400' ]]
  [[ "$(resend "$a" '{"prompt": "a kettle", "providers": []}')" == '{"error": "choose at least one provider"} 400' ]]
  [[ "$(resend "$a" '{"prompt": " \n ", "providers": ["gemini"]}')" == '{"error": "the prompt is blank"} 400' ]]
  [[ "$(resend "$b" '{"prompt": "a kettle", "providers": ["gemini"]}')" == \
    "{\"error\": \"run $b's working folder ${BATS_TEST_TMPDIR}/gone is gone\"} 409" ]]
  [[ "$(resend "$c" '{"prompt": "a kettle", "providers": ["gemini"]}')" == \
    "{\"error\": \"run $c's input image $out/erased.png is gone\"} 409" ]]
  [[ ! -e "$IMAGE_GALLERY_DIR/resend-logs" && ! -e "$MOCK_DIR/calls" ]]
  [[ "$(snapshot | jq '.runs | length')" == 3 ]]
}

@test "a resent run-all that exits before it starts a run is answered with its exit status and last lines, keys hidden" {
  answer_provider_with "$GEMINI_IMAGE"
  local out="${BATS_TEST_TMPDIR}/out" a=20261125T100000Z-00000000a1
  printf 'png' > "$out/hero-gemini.png"
  write_resendable_run "$a" "$out" "$out/hero-gemini.png"
  start_gallery
  wait_for_snapshot '.runs[0].resendable'
  # The server finds bash on its PATH when it starts the run; this one fails at once, printing the key.
  printf '#!/bin/sh\necho "using key $GEMINI_API_KEY" >&2\necho "no run today" >&2\nexit 3\n' > "$MOCK_DIR/bash"
  chmod +x "$MOCK_DIR/bash"
  [[ "$(resend "$a" '{"prompt": "a kettle", "providers": ["gemini"]}')" == \
    '{"error": "run-all.sh exited 3 before it started a run: using key [GEMINI_API_KEY]\nno run today"} 502' ]]
  rm "$MOCK_DIR/bash"
  [[ "$(snapshot | jq '.runs | length')" == 1 ]]
}

@test "a resend answers with the run it started, though newer runs record the output base it saves to" {
  answer_provider_with "$GEMINI_IMAGE"
  local out="${BATS_TEST_TMPDIR}/out" a=20261125T100000Z-00000000a1 n=0 stamp answer new
  printf 'png' > "$out/hero-gemini.png"
  write_resendable_run "$a" "$out" "$out/hero-gemini.png"
  # The resend's base is stamped with the second it starts in. Each base it could get in the next ten
  # seconds is recorded by a run whose id sorts after any run it starts.
  for stamp in $(python3 -I -c 'import time; [print(time.strftime("%Y%m%d-%H%M%S", time.localtime(time.time() + s))) for s in range(10)]'); do
    write_run "20991231T23590${n}Z-00000000f${n}" "$out" 'gemini\terror\t\tmodel-a\t\n' done
    record_arguments "20991231T23590${n}Z-00000000f${n}" "$out/image-$stamp"
    n=$((n + 1))
  done
  start_gallery
  wait_for_snapshot '.runs | length == 11'
  answer=$(resend "$a" '{"prompt": "a teapot", "providers": ["gemini"]}')
  [[ "$answer" =~ ^\{\"run\":\ \"([0-9]{8}T[0-9]{6}Z-[0-9a-f]{10})\"\}\ 200$ ]] || { echo "answer: $answer"; return 1; }
  new=${BASH_REMATCH[1]}
  [[ "$(jq -r '[.prompt, (.launch | test("^[0-9a-f]{16}$"))] | @tsv' "$IMAGE_GALLERY_DIR/runs/$new/meta.json")" == $'a teapot\ttrue' ]] || {
    cat "$IMAGE_GALLERY_DIR/runs/$new/meta.json"; return 1; }
  # Once the run is done, its run-all has made its last call to the server, so teardown stops the only one.
  wait_for_snapshot "any(.runs[]; .id == \"$new\" and .status == \"done\")"
}

@test "a resent run-all that starts no run within 15 s is answered 202 with its launch id, and its run shows once it starts" {
  answer_provider_with "$GEMINI_IMAGE"
  local out="${BATS_TEST_TMPDIR}/out" a=20261125T100000Z-00000000a1 real_bash answer launch new
  printf 'png' > "$out/hero-gemini.png"
  write_resendable_run "$a" "$out" "$out/hero-gemini.png"
  start_gallery
  wait_for_snapshot '.runs[0].resendable'
  # The server finds bash on its PATH when it starts the run; this one holds run-all.sh back until the
  # test lets it go, or gives up once the test's folder is gone, and runs every other script at once.
  real_bash=$(command -v bash)
  printf '#!/bin/sh\ncase "$1" in */run-all.sh)\n  while [ -d %q ] && [ ! -e %q ]; do sleep 0.1; done\n  [ -e %q ] || exit 1 ;;\nesac\nexec %q "$@"\n' \
    "$MOCK_DIR" "$MOCK_DIR/go" "$MOCK_DIR/go" "$real_bash" > "$MOCK_DIR/bash"
  chmod +x "$MOCK_DIR/bash"
  answer=$(gallery_curl --max-time 30 -w ' %{http_code}' -X POST -H "$(origin)" -H 'Content-Type: application/json' \
    --data-binary '{"prompt": "a teapot", "providers": ["gemini"]}' "/resend/$a")
  [[ "$answer" =~ ^\{\"pending\":\ true,\ \"launch\":\ \"([0-9a-f]{16})\"\}\ 202$ ]] || { echo "answer: $answer"; return 1; }
  launch=${BASH_REMATCH[1]}
  touch "$MOCK_DIR/go"
  wait_for_snapshot '(.runs | length == 2) and .runs[0].status == "done"'
  new=$(jq -r '.runs[0].id' <<< "$SNAPSHOT")
  [[ "$(jq -r '[.prompt, .launch] | @tsv' "$IMAGE_GALLERY_DIR/runs/$new/meta.json")" == "a teapot	$launch" ]] || {
    cat "$IMAGE_GALLERY_DIR/runs/$new/meta.json"; return 1; }
  rm "$MOCK_DIR/bash"
}

@test "a resend keeps the newest 50 logs in resend-logs, its own among them" {
  answer_provider_with "$GEMINI_IMAGE"
  local out="${BATS_TEST_TMPDIR}/out" a=20261125T100000Z-00000000a1 logs="$IMAGE_GALLERY_DIR/resend-logs" n
  printf 'png' > "$out/hero-gemini.png"
  write_resendable_run "$a" "$out" "$out/hero-gemini.png"
  mkdir -p "$logs"
  for n in $(seq 10 59); do
    : > "$logs/20000101-0000$n-00000000.log"
  done
  start_gallery
  wait_for_snapshot '.runs[0].resendable'
  printf '#!/bin/sh\necho "no run today" >&2\nexit 3\n' > "$MOCK_DIR/bash"
  chmod +x "$MOCK_DIR/bash"
  [[ "$(resend "$a" '{"prompt": "a kettle", "providers": ["gemini"]}')" == \
    '{"error": "run-all.sh exited 3 before it started a run: no run today"} 502' ]]
  rm "$MOCK_DIR/bash"
  [[ "$(ls "$logs" | wc -l | tr -d ' ')" == 50 && ! -e "$logs/20000101-000010-00000000.log" ]] || { ls "$logs"; return 1; }
  [[ "$(cat "$(ls -d "$logs"/* | tail -1)")" == "no run today" ]] || { ls "$logs"; return 1; }
}

@test "a run whose providers all failed can be resent, saving in the folder of its output base" {
  answer_provider_with "$GEMINI_IMAGE"
  local out="${BATS_TEST_TMPDIR}/out" a=20261125T100000Z-00000000a1
  mkdir "$out/art"
  write_run "$a" "$out" 'gemini\terror\t\tmodel-a\t\n' done
  record_arguments "$a" "$out/art/hero"
  start_gallery
  wait_for_snapshot '.runs[0].resendable'
  local answer new saved
  answer=$(resend "$a" '{"prompt": "a kettle", "providers": ["gemini"]}')
  [[ "$answer" =~ ^\{\"run\":\ \"([0-9]{8}T[0-9]{6}Z-[0-9a-f]{10})\"\}\ 200$ ]] || { echo "answer: $answer"; return 1; }
  new=${BASH_REMATCH[1]}
  wait_for_snapshot "(.runs[0].id == \"$new\") and (.runs[0].status == \"done\")"
  saved=$(jq -r '.runs[0].providers[0].image.path' <<< "$SNAPSHOT")
  [[ "$saved" =~ ^"$out"/art/image-[0-9]{8}-[0-9]{6}-gemini\.png$ && -f "$saved" ]] || { echo "saved: $saved"; ls -laR "$out"; return 1; }
}

# retry_frame <run-id> <provider> — POSTs a failed frame's Retry the way its button does, printing the
# answer and then its status.
retry_frame() {
  gallery_curl -w ' %{http_code}' -X POST -H "$(origin)" "/retry/$1/$2"
}

@test "a failed frame offers Retry only once its run has ended with no frame at work and recorded its arguments, and the server refuses any other" {
  answer_provider_with "$GEMINI_IMAGE"
  local out="${BATS_TEST_TMPDIR}/out" a=20261125T100000Z-00000000a1 b=20261125T100100Z-00000000b2 \
    c=20261125T100200Z-00000000c3 d=20261125T100300Z-00000000d4
  printf 'png' > "$out/hero-openai.png"
  # a ended with gemini failed and openai done; b the same, but recorded no arguments.
  write_run "$a" "$out" "gemini\terror\t\tmodel-a\t\nopenai\tcomplete\t1000\tmodel-b\t$out/hero-openai.png\n" done
  record_arguments "$a" "$out/hero"
  write_run "$b" "$out" 'gemini\terror\t\tmodel-a\t\n' done
  # c is still at work, held by a live process; d stopped with openai at work, its process gone.
  write_run "$c" "$out" 'gemini\terror\t\tmodel-a\t\nopenai\tquerying\t\tmodel-b\t\n'
  record_arguments "$c" "$out/held"
  sleep 60 &
  HOLDER_PID=$!
  LC_ALL=C TZ=UTC0 ps -o lstart= -p "$HOLDER_PID" > "$IMAGE_GALLERY_DIR/runs/$c/active/run-all.$HOLDER_PID"
  write_run "$d" "$out" 'gemini\terror\t\tmodel-a\t\nopenai\tquerying\t\tmodel-b\t\n'
  record_arguments "$d" "$out/stopped"
  start_gallery
  wait_for_snapshot '(.runs | length == 4) and .runs[1].status == "live"'
  [[ "$(jq -c '[.runs[] | [.status, [.providers[] | .name, .retryable]]]' <<< "$SNAPSHOT")" == \
    '[["interrupted",["gemini",false,"openai",false]],["live",["gemini",false,"openai",false]],["done",["gemini",false]],["done",["gemini",true,"openai",false]]]' ]] || {
    echo "$SNAPSHOT"; return 1; }
  [[ "$(retry_frame "$b" gemini)" == \
    "{\"error\": \"run $b did not record the arguments it was started with, so its frames cannot be retried\"} 409" ]]
  [[ "$(retry_frame "$c" gemini)" == "{\"error\": \"run $c is still generating\"} 409" ]]
  [[ "$(retry_frame "$d" gemini)" == \
    "{\"error\": \"run $d stopped while its openai frame was at work, so its frames cannot be retried\"} 409" ]]
  [[ "$(retry_frame "$a" openai)" == "{\"error\": \"run $a's openai frame did not fail, so there is nothing to retry\"} 409" ]]
  [[ "$(retry_frame "$a" xai)" == "{\"error\": \"run $a has no xai frame\"} 404" ]]
  [[ "$(retry_frame 20261125T100400Z-00000000e5 gemini)" == '{"error": "no run 20261125T100400Z-00000000e5"} 404' ]]
  [[ ! -e "$IMAGE_GALLERY_DIR/resend-logs" && ! -e "$MOCK_DIR/calls" && ! -e "$out/hero-gemini.png" ]]
}

@test "a failed frame's Retry runs its provider again in the same run, saving where the run meant to, and a second failure shows with no run-level offer" {
  answer_provider_with "$GEMINI_REFUSAL" "$GEMINI_REFUSAL" "$GEMINI_IMAGE"
  start_gallery
  connect_page
  DISPLAY_PANE_RETRY_WAIT=0 run_all_gemini
  assert_status 1
  wait_for_snapshot '.runs[0].status == "done" and .runs[0].providers[0].retryable'
  local id answer
  id=$(jq -r '.runs[0].id' <<< "$SNAPSHOT")
  [[ ! -e "${OUT_BASE}-gemini.png" ]]
  answer=$(retry_frame "$id" gemini)
  [[ "$answer" == "{\"run\": \"$id\"} 200" ]] || { echo "answer: $answer"; return 1; }
  # It fails again. The page is connected, yet the run ends at once with the frame's new error and no
  # offer: the frame's own Retry is the way back.
  wait_for_snapshot '.runs[0].status == "done" and .runs[0].providers[0].round == 1'
  [[ "$(jq -r '[(.runs | length), .runs[0].retry, (.runs[0].providers[0] | .state, .retryable, .error)] | @tsv' <<< "$SNAPSHOT")" == \
    $'1\t\terror\ttrue\tNo image data in response. Model said: no picture today' ]] || { echo "$SNAPSHOT"; return 1; }
  answer=$(retry_frame "$id" gemini)
  [[ "$answer" == "{\"run\": \"$id\"} 200" ]] || { echo "answer: $answer"; return 1; }
  wait_for_snapshot '.runs[0].status == "done" and .runs[0].providers[0].state == "complete"'
  [[ "$(jq -r '[(.runs | length), .runs[0].id, (.runs[0].providers[0] | .round, .image.path, .retryable)] | @tsv' <<< "$SNAPSHOT")" == \
    "1	$id	2	${OUT_BASE}-gemini.png	false" ]] || { echo "$SNAPSHOT"; return 1; }
  # The image is the provider's, saved readable by this user only, as a resend saves its images.
  [[ "$(base64 < "${OUT_BASE}-gemini.png" | tr -d '\n')" == "$PNG_B64" ]]
  [[ "$(ls -l "${OUT_BASE}-gemini.png" | cut -c1-10)" == "-rw-------" ]]
  [[ "$(cat "$MOCK_DIR/calls")" == 3 ]]
}

@test "a failed frame's Retry is refused, starting nothing, while anything is at the path its image would take, a dangling symlink too" {
  answer_provider_with "$GEMINI_IMAGE"
  local out="${BATS_TEST_TMPDIR}/out" a=20261125T100000Z-00000000a1
  write_run "$a" "$out" 'gemini\terror\t\tmodel-a\t\n' done
  record_arguments "$a" "$out/hero"
  ln -s nowhere "$out/hero-gemini.png"
  start_gallery
  wait_for_snapshot '.runs[0].providers[0].retryable'
  [[ "$(retry_frame "$a" gemini)" == "{\"error\": \"$out/hero-gemini.png already exists, and nothing is overwritten\"} 409" ]]
  [[ ! -e "$IMAGE_GALLERY_DIR/resend-logs" && ! -e "$MOCK_DIR/calls" && "$(readlink "$out/hero-gemini.png")" == nowhere ]]
  [[ "$(cat "$IMAGE_GALLERY_DIR/runs/$a/status")" == "$(printf 'gemini\terror\t\tmodel-a\t')" && -e "$IMAGE_GALLERY_DIR/runs/$a/.done" ]]
}

@test "while a frame's Retry is starting, a second click and a delete of its run are refused, so the provider is paid once" {
  answer_provider_with "$GEMINI_IMAGE"
  local out="${BATS_TEST_TMPDIR}/out" a=20261125T100000Z-00000000a1 real_bash i first
  write_run "$a" "$out" 'gemini\terror\t\tmodel-a\t\n' done
  record_arguments "$a" "$out/hero"
  start_gallery
  wait_for_snapshot '.runs[0].providers[0].retryable'
  # The server finds bash on its PATH; this one holds run-all.sh back until the test lets it go, or gives
  # up once the test's folder is gone, so the second click lands before the first run-all holds the run.
  real_bash=$(command -v bash)
  printf '#!/bin/sh\ncase "$1" in */run-all.sh)\n  while [ -d %q ] && [ ! -e %q ]; do sleep 0.1; done\n  [ -e %q ] || exit 1 ;;\nesac\nexec %q "$@"\n' \
    "$MOCK_DIR" "$MOCK_DIR/go" "$MOCK_DIR/go" "$real_bash" > "$MOCK_DIR/bash"
  chmod +x "$MOCK_DIR/bash"
  retry_frame "$a" gemini > "$MOCK_DIR/first.answer" &
  first=$!
  for i in $(seq 1 50); do
    [[ -n "$(ls "$IMAGE_GALLERY_DIR/resend-logs" 2>/dev/null)" ]] && break
    sleep 0.1
  done
  [[ "$(retry_frame "$a" gemini)" == \
    "{\"error\": \"a run saving to $out/hero-<provider>.png is already starting; try again in a second\"} 409" ]]
  # Nor can the run be deleted before its run-all holds it.
  [[ "$(delete_runs "{\"runs\": {\"$a\": []}}")" == \
    "{\"deleted\": [], \"kept\": [{\"id\": \"$a\", \"error\": \"run $a is starting a retry\"}], \"error\": \"run $a is starting a retry\"} 409" ]]
  touch "$MOCK_DIR/go"
  wait "$first"
  [[ "$(cat "$MOCK_DIR/first.answer")" == "{\"run\": \"$a\"} 200" ]] || { cat "$MOCK_DIR/first.answer"; return 1; }
  wait_for_snapshot '.runs[0].status == "done" and .runs[0].providers[0].state == "complete"'
  rm "$MOCK_DIR/bash"
  [[ "$(cat "$MOCK_DIR/calls")" == 1 && -f "$out/hero-gemini.png" ]]
  [[ "$(ls "$IMAGE_GALLERY_DIR/resend-logs" | wc -l | tr -d ' ')" == 1 ]]
}

@test "Delete run removes the image a frame's Retry saved, which the run's records name" {
  answer_provider_with "$GEMINI_IMAGE"
  local out="${BATS_TEST_TMPDIR}/out" a=20261125T100000Z-00000000a1 answer
  printf 'png' > "$out/hero-openai.png"
  write_run "$a" "$out" "gemini\terror\t\tmodel-a\t\nopenai\tcomplete\t1000\tmodel-b\t$out/hero-openai.png\n" done
  record_arguments "$a" "$out/hero"
  start_gallery
  wait_for_snapshot '.runs[0].providers[0].retryable'
  [[ "$(retry_frame "$a" gemini)" == "{\"run\": \"$a\"} 200" ]]
  wait_for_snapshot '.runs[0].status == "done" and .runs[0].providers[0].state == "complete"'
  [[ "$(jq -c '[.runs[0].files[] | [.path, .kept]]' <<< "$SNAPSHOT")" == \
    "[[\"$out/hero-gemini.png\",null],[\"$out/hero-openai.png\",null]]" ]] || { echo "$SNAPSHOT"; return 1; }
  answer=$(delete_runs "$(listing "$a")")
  [[ "$answer" == "{\"deleted\": [{\"id\": \"$a\", \"removed\": [\"$out/hero-gemini.png\", \"$out/hero-openai.png\"], \"missing\": [], \"kept_files\": []}], \"kept\": []} 200" ]] || {
    echo "$answer"; return 1; }
  [[ -z "$(ls "$out")" && ! -e "$IMAGE_GALLERY_DIR/runs/$a" ]]
}
