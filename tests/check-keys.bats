# ABOUTME: Bats tests for check-keys.sh API key detection and JSON output.
# ABOUTME: Verifies all combinations of present/absent API keys produce correct output.

setup() {
  load test_helper
  CHECK_KEYS_SH="${PLUGIN_ROOT}/scripts/check-keys.sh"
  # Start each test with a clean slate
  unset GEMINI_API_KEY 2>/dev/null || true
  unset OPENAI_API_KEY 2>/dev/null || true
  unset XAI_API_KEY 2>/dev/null || true
}

@test "check-keys: all keys set reports all available" {
  export GEMINI_API_KEY="$DUMMY_GEMINI_KEY"
  export OPENAI_API_KEY="$DUMMY_OPENAI_KEY"
  export XAI_API_KEY="$DUMMY_XAI_KEY"
  run "$CHECK_KEYS_SH"
  assert_status 0
  assert_valid_json
  assert_output_contains "Gemini"
  assert_output_contains "OpenAI"
  assert_output_contains "xAI"
  assert_output_contains "Image generation available"
  assert_output_not_contains "Missing API keys"
}

@test "check-keys: only GEMINI_API_KEY set" {
  export GEMINI_API_KEY="$DUMMY_GEMINI_KEY"
  run "$CHECK_KEYS_SH"
  assert_status 0
  assert_valid_json
  assert_output_contains "Gemini"
  assert_output_contains "Image generation available"
  assert_output_contains "OPENAI_API_KEY"
  assert_output_contains "XAI_API_KEY"
  assert_output_contains "Missing API keys"
}

@test "check-keys: only OPENAI_API_KEY set" {
  export OPENAI_API_KEY="$DUMMY_OPENAI_KEY"
  run "$CHECK_KEYS_SH"
  assert_status 0
  assert_valid_json
  assert_output_contains "OpenAI"
  assert_output_contains "Image generation available"
  assert_output_contains "GEMINI_API_KEY"
  assert_output_contains "XAI_API_KEY"
  assert_output_contains "Missing API keys"
}

@test "check-keys: only XAI_API_KEY set" {
  export XAI_API_KEY="$DUMMY_XAI_KEY"
  run "$CHECK_KEYS_SH"
  assert_status 0
  assert_valid_json
  assert_output_contains "xAI"
  assert_output_contains "Image generation available"
  assert_output_contains "GEMINI_API_KEY"
  assert_output_contains "OPENAI_API_KEY"
  assert_output_contains "Missing API keys"
}

@test "check-keys: no keys set reports no keys found" {
  run "$CHECK_KEYS_SH"
  assert_status 0
  assert_valid_json
  assert_output_contains "No image generation API keys found"
}

@test "check-keys: output has continue field set to true" {
  run "$CHECK_KEYS_SH"
  assert_status 0
  local continue_val
  continue_val=$(echo "$output" | jq -r '.continue')
  [[ "$continue_val" == "true" ]]
}

@test "check-keys: output has suppressOutput field" {
  run "$CHECK_KEYS_SH"
  assert_status 0
  local suppress_val
  suppress_val=$(echo "$output" | jq -r '.suppressOutput')
  [[ "$suppress_val" == "false" ]]
}

@test "check-keys: output has systemMessage field" {
  export GEMINI_API_KEY="$DUMMY_GEMINI_KEY"
  run "$CHECK_KEYS_SH"
  assert_status 0
  local msg
  msg=$(echo "$output" | jq -r '.systemMessage')
  [[ -n "$msg" && "$msg" != "null" ]]
}

@test "check-keys: output contains exactly three JSON fields" {
  run "$CHECK_KEYS_SH"
  assert_status 0
  local key_count
  key_count=$(echo "$output" | jq 'keys | length')
  [[ "$key_count" -eq 3 ]]
}
