# ABOUTME: Bats tests for run-all.sh argument forwarding to per-provider scripts.
# ABOUTME: Tests only local logic -- provider scripts are stubbed, no real API calls are made.

load test_helper

RUN_ALL_SH="${PLUGIN_ROOT}/scripts/run-all.sh"

setup() {
  WORK_DIR="${BATS_TMPDIR}/run_all_$$"
  mkdir -p "$WORK_DIR"
  cp "${PLUGIN_ROOT}/scripts/run-all.sh" "$WORK_DIR/"
  cp "${PLUGIN_ROOT}/scripts/display.sh" "$WORK_DIR/"
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
