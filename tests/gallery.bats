#!/usr/bin/env bats
# ABOUTME: Image runs against the real gallery server, started under the test's temp directory:
# ABOUTME: what its page reads from /events and /img, its request guards, liveness, reuse and retry.

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
  stop_gallery
  cleanup_tmpdir
}

# stop_gallery — ends the server server.json names and waits for it to go.
stop_gallery() {
  local pid i
  pid=$(jq -r .pid "$IMAGE_GALLERY_DIR/server.json" 2>/dev/null) || return 0
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  kill "$pid" 2>/dev/null || return 0
  for i in $(seq 1 30); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
}

server_field() { jq -r ".$1" "$IMAGE_GALLERY_DIR/server.json" 2>/dev/null; }

# gallery_curl [curl args...] <path> — curl at the running server with the page's cookie.
gallery_curl() {
  local path="${*: -1}"
  curl -s --max-time 5 -H "Cookie: gallery_token=$(server_field token)" "${@:1:$#-1}" \
    "http://127.0.0.1:$(server_field port)${path}"
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
  curl -s -N --max-time 60 -H "Cookie: gallery_token=$(server_field token)" \
    "http://127.0.0.1:$(server_field port)/events" > /dev/null &
  EVENTS_PID=$!
  for i in $(seq 1 50); do
    [[ "$(gallery_curl /health | jq -r .clients)" == 1 ]] && return 0
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
  answer_provider_with "$GEMINI_IMAGE"
  run_all_gemini
  assert_status 0
  wait_for_snapshot '.runs[0].status == "done"'
  local run
  run=$(jq -c '.runs[0]' <<< "$SNAPSHOT")
  [[ "$(jq -r '[.prompt, .status, (.providers | length)] | @tsv' <<< "$run")" == $'a lighthouse at dusk\tdone\t1' ]] || {
    echo "run: $run"; return 1; }
  [[ "$(jq -r '.providers[0] | [.name, .state, .model, .image.n, .image.path] | @tsv' <<< "$run")" == \
    "gemini	complete	gemini-3-pro-image	0	${OUT_BASE}-gemini.png" ]] || { echo "run: $run"; return 1; }
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

@test "the server answers 403 to a wrong Host, a missing token and a POST from another Origin" {
  start_gallery
  local port url
  port=$(server_field port)
  url="http://127.0.0.1:${port}"
  [[ "$(gallery_curl -o /dev/null -w '%{http_code}' -H "Host: localhost:${port}" /health)" == 403 ]]
  [[ "$(gallery_curl -o /dev/null -w '%{http_code}' -H "Host: 127.0.0.1" /health)" == 403 ]]
  [[ "$(curl -s -o /dev/null -w '%{http_code}' "${url}/health")" == 403 ]]
  [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "${url}/events")" == 403 ]]
  [[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Cookie: gallery_token=wrong" "${url}/health")" == 403 ]]
  [[ "$(gallery_curl -o /dev/null -w '%{http_code}' -X POST -H "Origin: http://localhost:${port}" /open)" == 403 ]]
  [[ "$(gallery_curl -o /dev/null -w '%{http_code}' -X POST /open)" == 403 ]]
  [[ "$(gallery_curl -o /dev/null -w '%{http_code}' /health)" == 200 ]]
}

@test "the token in the address sets the page's cookie and sends it to the page" {
  start_gallery
  local headers
  headers=$(curl -s -D - -o /dev/null "http://127.0.0.1:$(server_field port)/?t=$(server_field token)" | tr -d '\r')
  [[ "$headers" == *$'\nLocation: /\n'* ]] || { echo "$headers"; return 1; }
  [[ "$headers" == *$'\nSet-Cookie: gallery_token='"$(server_field token)"$'; Path=/; HttpOnly; SameSite=Strict\n'* ]] || {
    echo "$headers"; return 1; }
  [[ "$headers" == *$'\nContent-Security-Policy: default-src \'self\'; frame-ancestors \'none\'; base-uri \'none\'; form-action \'none\'\n'* ]] || {
    echo "$headers"; return 1; }
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
  [[ "$(gallery_curl -o /dev/null -w '%{http_code}' "/img/${id}/..%2F..%2Fserver.json/0")" == 404 ]]
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

@test "runs started together share one server" {
  start_gallery &
  start_gallery &
  wait
  local pid instance i root
  pid=$(server_field pid)
  # The server is started with the root resolved, /var becoming /private/var on macOS.
  root=$(cd "$IMAGE_GALLERY_DIR" && pwd -P)
  instance=$(server_field instance)
  start_gallery
  [[ "$(server_field pid)" == "$pid" && "$(server_field instance)" == "$instance" ]]
  # The racer that lost the lock gives up within its five-second wait.
  for i in $(seq 1 70); do
    [[ "$(pgrep -f "gallery-server.py serve --root ${root}" | tr '\n' ' ')" == "$pid " ]] && return 0
    sleep 0.1
  done
  echo "servers for this root: $(pgrep -f "gallery-server.py serve --root ${root}" | tr '\n' ' '), expected $pid"
  return 1
}

@test "a server of another version is replaced by one of this plugin's version" {
  python3 -I "$GALLERY_PY" serve --root "$IMAGE_GALLERY_DIR" --version 0.0.0-other
  local i old version
  for i in $(seq 1 50); do
    [[ -s "$IMAGE_GALLERY_DIR/server.json" ]] && break
    sleep 0.1
  done
  [[ "$(server_field version)" == 0.0.0-other ]]
  old=$(server_field pid)
  start_gallery
  version=$(jq -r .version "${PLUGIN_ROOT}/.claude-plugin/plugin.json")
  [[ "$(gallery_curl /health | jq -r .version)" == "$version" ]]
  [[ "$(server_field pid)" != "$old" ]]
  ! kill -0 "$old" 2>/dev/null
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
  [[ "$(gallery_curl /health | jq -r .clients)" == 0 ]]
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
  LC_ALL=C ps -o lstart= -p "$HOLDER_PID" > "$IMAGE_GALLERY_DIR/runs/20261125T110000Z-00000000ff/active/test.$HOLDER_PID"
  start_gallery
  wait_for_snapshot '.runs[0].status == "live"'
  # gemini on model-a: median of 1000 3000 2000 4000 5000. openai has no history on model-c, and
  # xai none at all, so theirs is absent; a finished frame carries none.
  [[ "$(jq -c '.runs[0].providers | map({(.name): .usual_ms}) | add' <<< "$SNAPSHOT")" == \
    '{"gemini":3000,"openai":null,"xai":null}' ]] || { echo "$SNAPSHOT"; return 1; }
  [[ "$(jq -c '[.runs[0].providers[] | has("usual_ms")]' <<< "$SNAPSHOT")" == '[true,false,false]' ]]
  [[ "$(jq -c '[.runs[1:][].providers[] | has("usual_ms")] | unique' <<< "$SNAPSHOT")" == '[false]' ]]
}
