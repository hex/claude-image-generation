# ABOUTME: Bats tests for run-all.sh argument forwarding to per-provider scripts.
# ABOUTME: Tests only local logic -- provider scripts are stubbed, no real API calls are made.

load test_helper

RUN_ALL_SH="${PLUGIN_ROOT}/scripts/run-all.sh"

setup() {
  WORK_DIR="${BATS_TMPDIR}/run_all_$$"
  mkdir -p "$WORK_DIR"
  cp "${PLUGIN_ROOT}/scripts/run-all.sh" "$WORK_DIR/"
  cp "${PLUGIN_ROOT}/scripts/display.sh" "$WORK_DIR/"
  disable_display
}

teardown() {
  rm -rf "$WORK_DIR" 2>/dev/null || true
}

# Installs a fake provider script (in place of gemini.sh/openai.sh/xai.sh) that dumps
# its argv, one arg per line, to $WORK_DIR/<name>.argv.
stub_provider() {
  local name="$1"
  cat > "$WORK_DIR/${name}.sh" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" >> "$(dirname "$0")/NAME.argv"
STUB
  sed -i.bak "s/NAME/${name}/" "$WORK_DIR/${name}.sh"
  rm -f "$WORK_DIR/${name}.sh.bak"
  chmod +x "$WORK_DIR/${name}.sh"
}

# stub_flaky_provider <name> — fails with exit 1 on its first call, succeeds after.
stub_flaky_provider() {
  local name="$1"
  cat > "$WORK_DIR/${name}.sh" <<'STUB'
#!/bin/bash
d="$(dirname "$0")"
printf '%s\n' "$@" >> "$d/NAME.argv"
n=$(cat "$d/NAME.calls" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$d/NAME.calls"
[ "$n" -eq 1 ] && { echo "NAME: boom" >&2; exit 1; }
exit 0
STUB
  sed -i.bak "s/NAME/${name}/g" "$WORK_DIR/${name}.sh"
  rm -f "$WORK_DIR/${name}.sh.bak"
  chmod +x "$WORK_DIR/${name}.sh"
}

# stub_flaky_provider_closes_pane <name> — fails with exit 1 on its first call; on the second
# it succeeds but also removes DISPLAY_PANE_DIR itself, as its very last act before exiting.
# Models a pane that closes at the exact instant a retry finishes, deterministically rather
# than through a background process racing run-all's own timing.
stub_flaky_provider_closes_pane() {
  local name="$1"
  cat > "$WORK_DIR/${name}.sh" <<'STUB'
#!/bin/bash
d="$(dirname "$0")"
printf '%s\n' "$@" >> "$d/NAME.argv"
n=$(cat "$d/NAME.calls" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$d/NAME.calls"
if [ "$n" -eq 1 ]; then echo "NAME: boom" >&2; exit 1; fi
[ -n "$DISPLAY_PANE_DIR" ] && rm -rf "$DISPLAY_PANE_DIR"
exit 0
STUB
  sed -i.bak "s/NAME/${name}/g" "$WORK_DIR/${name}.sh"
  rm -f "$WORK_DIR/${name}.sh.bak"
  chmod +x "$WORK_DIR/${name}.sh"
}

# A pane dir the way display_pane_attach_or_open would hand one over, without tmux.
fake_pane() {
  PANE="$WORK_DIR/pane"
  mkdir -p "$PANE/active" "$PANE/logs"
  export DISPLAY_PANE_DIR="$PANE"
}

@test "run-all offers a retry naming only the providers that failed, then withdraws it" {
  stub_provider gemini
  stub_flaky_provider xai
  fake_pane
  # Watch for the offer and keep a copy; nobody answers it, so it must expire.
  ( for i in $(seq 1 50); do
      if [[ -f "$PANE/retry-offer" ]]; then cp "$PANE/retry-offer" "$WORK_DIR/offer.copy"; break; fi
      sleep 0.1
    done ) &
  DISPLAY_PANE_RETRY_WAIT=1 run bash "$WORK_DIR/run-all.sh" --mode generate --prompt "p" \
    --output-base "$WORK_DIR/out" --providers gemini,xai
  wait
  assert_status 1
  [[ -f "$WORK_DIR/offer.copy" ]] || { echo "no retry-offer was ever written"; return 1; }
  [[ "$(sed -n 1p "$WORK_DIR/offer.copy")" == "1" ]] || { echo "offer line 1 should be the seconds"; cat "$WORK_DIR/offer.copy"; return 1; }
  [[ "$(sed -n 2p "$WORK_DIR/offer.copy")" == "xai" ]] || { echo "offer should name xai"; cat "$WORK_DIR/offer.copy"; return 1; }
  [[ "$(wc -l < "$WORK_DIR/offer.copy" | tr -d ' ')" -eq 2 ]] || { echo "offer named more than the failed provider"; return 1; }
  [[ ! -f "$PANE/retry-offer" ]] || { echo "offer left behind after the wait"; return 1; }
  [[ "$(cat "$WORK_DIR/xai.calls")" -eq 1 ]] || { echo "xai ran again without an answer"; return 1; }
  # Provider stderr is routed to the pane's log when a pane is live.
  grep -q "xai: boom" "$PANE/logs/xai.err" || { echo "provider stderr missing from the pane log"; return 1; }
}

@test "run-all re-forks exactly the failed providers when the pane answers .retry" {
  stub_provider gemini
  stub_flaky_provider xai
  fake_pane
  # Answer the offer the way the watcher does: rename it to .retry.
  ( for i in $(seq 1 50); do
      if [[ -f "$PANE/retry-offer" ]]; then
        cp "$PANE/retry-offer" "$WORK_DIR/offer.copy"
        mv "$PANE/retry-offer" "$PANE/.retry"; break
      fi
      sleep 0.1
    done ) &
  DISPLAY_PANE_RETRY_WAIT=5 run bash "$WORK_DIR/run-all.sh" --mode generate --prompt "p" \
    --output-base "$WORK_DIR/out" --providers gemini,xai
  assert_status 0
  [[ "$(sed -n 1p "$WORK_DIR/offer.copy")" == "5" ]] || { echo "offer line 1 should be the seconds"; cat "$WORK_DIR/offer.copy"; return 1; }
  [[ "$(sed -n 2p "$WORK_DIR/offer.copy")" == "xai" ]] || { echo "offer should name xai"; cat "$WORK_DIR/offer.copy"; return 1; }
  [[ "$(wc -l < "$WORK_DIR/offer.copy" | tr -d ' ')" -eq 2 ]] || { echo "offer named more than the failed provider"; return 1; }
  [[ "$(cat "$WORK_DIR/xai.calls")" -eq 2 ]] || { echo "xai should have run twice"; return 1; }
  [[ "$(grep -c '^--prompt$' "$WORK_DIR/gemini.argv")" -eq 1 ]] || { echo "gemini must not be re-run"; return 1; }
  # The retried call got the same arguments as the first.
  [[ "$(grep -c '^--prompt$' "$WORK_DIR/xai.argv")" -eq 2 ]] || { echo "retry lacked --prompt"; cat "$WORK_DIR/xai.argv"; return 1; }
}

@test "run-all treats a pane that closed during the offer as no retry" {
  stub_provider gemini
  stub_flaky_provider xai
  fake_pane
  ( for i in $(seq 1 50); do
      if [[ -f "$PANE/retry-offer" ]]; then rm -rf "$PANE"; break; fi
      sleep 0.1
    done ) &
  DISPLAY_PANE_RETRY_WAIT=5 run bash "$WORK_DIR/run-all.sh" --mode generate --prompt "p" \
    --output-base "$WORK_DIR/out" --providers gemini,xai
  assert_status 1
  [[ "$output" != *"No such file"* ]] || { echo "a closed pane must not produce errors:"; echo "$output"; return 1; }
  [[ "$(cat "$WORK_DIR/xai.calls")" -eq 1 ]] || { echo "xai must not be re-run"; return 1; }
}

@test "run-all with DISPLAY_PANE_RETRY_WAIT=0 never writes an offer" {
  stub_flaky_provider xai
  fake_pane
  DISPLAY_PANE_RETRY_WAIT=0 run bash "$WORK_DIR/run-all.sh" --mode generate --prompt "p" \
    --output-base "$WORK_DIR/out" --providers xai
  assert_status 1
  [[ ! -f "$PANE/retry-offer" && ! -f "$PANE/.retry" ]] || { echo "an offer was written with the wait disabled"; return 1; }
}

@test "run-all guards __pane_release when a pane it opened itself is closed by the retry that just succeeded" {
  stub_provider gemini
  stub_flaky_provider_closes_pane xai
  local mock="${WORK_DIR}/mock" tmp_root
  tmp_root="${mock}/tmp"
  mkdir -p "$mock/.iterm2" "$tmp_root"
  printf '#!/bin/bash\necho "DISPLAYED:${@: -1}"\n' > "$mock/.iterm2/imgcat"
  cat > "$mock/tmux" <<'STUB'
#!/bin/bash
[ "$1" = "display-message" ] && { echo "200 50"; exit 0; }
exit 0
STUB
  chmod +x "$mock/.iterm2/imgcat" "$mock/tmux"

  # No fake_pane here: DISPLAY_PANE_DIR is left unset so run-all must self-attach through
  # display_pane_attach_or_open the way a real invocation does. That is what actually runs
  # __pane_acquire and sets __PANE_SELF_ATTACHED -- fake_pane's pre-set DISPLAY_PANE_DIR never
  # reaches that path, so the -d guard before __pane_release below it never runs. Answer the
  # offer the way the watcher does; the retried xai (stub_flaky_provider_closes_pane) removes
  # DISPLAY_PANE_DIR itself as its last act, so the pane's disappearance lands deterministically
  # right where run-all is about to release its own token, with no background process racing
  # run-all's own timing.
  ( for i in $(seq 1 50); do
      pane_dir=$(ls -d "$tmp_root"/display_pane.*/ 2>/dev/null | head -n1)
      if [[ -n "$pane_dir" && -f "${pane_dir}retry-offer" ]]; then
        mv -f "${pane_dir}retry-offer" "${pane_dir}.retry"
        break
      fi
      sleep 0.1
    done ) &

  TMPDIR="$tmp_root" HOME="$mock" PATH="$mock:$PATH" TMUX="fake,1,0" TMUX_PANE="%0" \
    LC_TERMINAL="iTerm2" TERM_PROGRAM="iTerm.app" DISPLAY_PANE_RETRY_WAIT=5 \
    run bash "$WORK_DIR/run-all.sh" --mode generate --prompt "p" \
    --output-base "$WORK_DIR/out" --providers gemini,xai
  wait

  [[ "$(cat "$WORK_DIR/xai.calls")" -eq 2 ]] || { echo "xai should have run twice"; return 1; }
  # Without the -d guard, __pane_release still runs on the vanished directory and aborts
  # run-all under set -e partway through -- silently, before ever reaching its own final `exit
  # "$overall_status"` -- which corrupts a successful retry's exit code from 0 to 1.
  assert_status 0
}

@test "run-all forwards every --input-image to each provider" {
  stub_provider gemini
  stub_provider openai
  stub_provider xai

  run bash "$WORK_DIR/run-all.sh" --mode edit --prompt "combine these" \
    --output-base "$WORK_DIR/out" \
    --input-image /tmp/x.png --input-image /tmp/y.png

  assert_status 0

  local p count
  for p in gemini openai xai; do
    count=$(grep -c '^--input-image$' "$WORK_DIR/${p}.argv")
    [[ "$count" -eq 2 ]] || {
      echo "Expected provider ${p} to receive 2 --input-image flags, got: $count"
      cat "$WORK_DIR/${p}.argv"
      return 1
    }
  done
}
