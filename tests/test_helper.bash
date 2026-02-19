# ABOUTME: Shared test setup for bats tests of image-generation plugin scripts.
# ABOUTME: Provides PLUGIN_ROOT, dummy API keys, and common assertion helpers.

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Dummy API keys for tests that need them (no real calls are made)
export DUMMY_GEMINI_KEY="test-gemini-key-not-real"
export DUMMY_OPENAI_KEY="test-openai-key-not-real"
export DUMMY_XAI_KEY="test-xai-key-not-real"

# Assert that output contains a substring
# Usage: assert_output_contains "expected substring"
assert_output_contains() {
  local expected="$1"
  if [[ "$output" != *"$expected"* ]]; then
    echo "Expected output to contain: $expected"
    echo "Actual output: $output"
    return 1
  fi
}

# Assert that output does NOT contain a substring
# Usage: assert_output_not_contains "unexpected substring"
assert_output_not_contains() {
  local unexpected="$1"
  if [[ "$output" == *"$unexpected"* ]]; then
    echo "Expected output to NOT contain: $unexpected"
    echo "Actual output: $output"
    return 1
  fi
}

# Assert exit status equals expected value
# Usage: assert_status 1
assert_status() {
  local expected="$1"
  if [[ "$status" -ne "$expected" ]]; then
    echo "Expected exit status: $expected"
    echo "Actual exit status: $status"
    return 1
  fi
}

# Assert a file contains a substring
# Usage: assert_output_contains_file "/path/to/file" "expected substring"
assert_output_contains_file() {
  local file="$1"
  local expected="$2"
  local content
  content=$(cat "$file")
  if [[ "$content" != *"$expected"* ]]; then
    echo "Expected file to contain: $expected"
    echo "Actual content: $content"
    return 1
  fi
}

# Assert output is valid JSON
# Usage: assert_valid_json
assert_valid_json() {
  if ! echo "$output" | jq . >/dev/null 2>&1; then
    echo "Expected valid JSON output"
    echo "Actual output: $output"
    return 1
  fi
}
