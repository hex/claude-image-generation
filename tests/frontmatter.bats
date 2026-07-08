#!/usr/bin/env bats
# ABOUTME: Verifies plugin agent, command, and skill frontmatter is strict YAML that Claude Code can load.
# ABOUTME: Guards against frontmatter that silently parses to an empty mapping, dropping tools and model.

load test_helper

CHECK="python3 ${PLUGIN_ROOT}/tests/frontmatter_check.py"

# The markdown files Claude Code reads frontmatter from. References and docs are excluded because
# the loader never parses them.
plugin_definition_files() {
  find "${PLUGIN_ROOT}/agents" "${PLUGIN_ROOT}/commands" -maxdepth 1 -name '*.md' -type f
  find "${PLUGIN_ROOT}/skills" -name 'SKILL.md' -type f
}

@test "every plugin definition file has strict-YAML frontmatter" {
  local failures=""
  local file
  while read -r file; do
    if ! run_output=$($CHECK "$file" 2>&1); then
      failures+="  ${run_output}"$'\n'
    fi
  done < <(plugin_definition_files)

  if [[ -n "$failures" ]]; then
    echo "Frontmatter must parse on the first strict YAML pass."
    echo "Claude Code falls back to a lenient repair pass, and when that also fails it silently"
    echo "loads an EMPTY frontmatter -- dropping description, tools, and model with no error."
    echo "$failures"
    return 1
  fi
}

@test "every plugin definition file declares a string description" {
  local file
  while read -r file; do
    run $CHECK "$file"
    assert_status 0

    local kind
    kind=$(echo "$output" | jq -r 'if has("description") then (.description | type) else "missing" end')
    if [[ "$kind" != "string" ]]; then
      echo "$file: description is '${kind}', expected 'string'"
      echo "Claude Code omits any description that is not a string, number, or boolean."
      return 1
    fi
  done < <(plugin_definition_files)
}

@test "agent frontmatter preserves its declared tools and model" {
  local file
  while read -r file; do
    run $CHECK "$file"
    assert_status 0

    local tools_type model_type
    tools_type=$(echo "$output" | jq -r 'if has("tools") then (.tools | type) else "missing" end')
    model_type=$(echo "$output" | jq -r 'if has("model") then (.model | type) else "missing" end')

    if [[ "$tools_type" != "array" ]]; then
      echo "$file: tools is '${tools_type}', expected 'array'"
      echo "A dropped tools list silently grants the agent every tool in the session."
      return 1
    fi
    if [[ "$model_type" != "string" ]]; then
      echo "$file: model is '${model_type}', expected 'string'"
      echo "A dropped model means 'model: inherit' is lost and the agent runs on the default model."
      return 1
    fi
  done < <(find "${PLUGIN_ROOT}/agents" -maxdepth 1 -name '*.md' -type f)
}
