<!-- ABOUTME: Testing guide for the claude-image-generation plugin. -->
<!-- ABOUTME: Covers automated bats tests, script-level tests, feature tests, and edge cases. -->

# Testing Guide

This document describes how to test the claude-image-generation plugin at every level: automated unit tests, direct script validation, feature-level manual tests through the slash command and agent, and edge case handling.

## 1. Automated Tests (bats)

### Installing bats

bats (Bash Automated Testing System) is required for the automated test suite.

**macOS (Homebrew):**

```bash
brew install bats-core
```

**Linux (apt):**

```bash
sudo apt install bats
```

**From source:**

```bash
git clone https://github.com/bats-core/bats-core.git
cd bats-core
sudo ./install.sh /usr/local
```

### Running Tests

```bash
# Run the full suite via wrapper script
./tests/run_tests.sh

# Run bats directly
bats tests/

# Run a single test file
bats tests/gemini.bats
bats tests/openai.bats
```

### Test Coverage

| Test file | Script under test | What it covers |
|-----------|-------------------|----------------|
| `tests/gemini.bats` | `scripts/gemini.sh` | Argument validation, missing API key, required flags, model override, edit mode requires `--input-image` |
| `tests/openai.bats` | `scripts/openai.sh` | Argument validation, missing API key, required flags, model override, edit mode requires `--input-image` |
| `tests/xai.bats` | `scripts/xai.sh` | Argument validation, missing API key (XAI_API_KEY + GROK_API_KEY fallback), model override, edit mode |
| `tests/display.bats` | `scripts/display.sh` | iTerm2/Kitty/Sixel detection, escape sequence format, tmux detection, outer terminal detection, protocol priority, error handling |
| `tests/pane_layout.bats` | `scripts/display.sh`, `scripts/run-all.sh` | Pane orientation (wide/tall split), fixed 30% image sizing + DPI normalization, empty-timing parse, spinner silencing after the first image |
| `tests/edit_payload.bats` | provider scripts | base64 / `--rawfile` edit-payload construction |
| `tests/bash32_compat.bats` | provider + display scripts | bash 3.2 array / associative-array safety |
| `tests/frontmatter.bats` | skill / agent / command | YAML frontmatter validation |

Tests do not make real API calls. They validate argument parsing, error messages, exit codes, and terminal protocol output.

## 2. Script-Level Tests

These are manual tests you can run directly in a terminal to verify script behavior without the plugin framework.

### Argument Validation

Each script should exit with code 1 and print a usage message when required arguments are missing.

```bash
# Missing all required flags
bash scripts/gemini.sh
# Expected: exits 1, prints usage

# Missing --prompt
bash scripts/gemini.sh --mode generate --output /tmp/test.png
# Expected: exits 1, "Error: --mode, --prompt, and --output are required"

# Edit mode without --input-image
bash scripts/gemini.sh --mode edit --prompt "test" --output /tmp/test.png
# Expected: exits 1, "Error: --input-image is required for edit mode"

# Unknown flag
bash scripts/gemini.sh --nonexistent value
# Expected: exits 1, "Unknown option: --nonexistent"
```

Repeat the same checks for `scripts/openai.sh` and `scripts/xai.sh`.

### Environment Variable Checks

```bash
# Gemini without key
unset GEMINI_API_KEY
bash scripts/gemini.sh --mode generate --prompt "test" --output /tmp/test.png
# Expected: exits 1, "Error: GEMINI_API_KEY environment variable is not set"

# OpenAI without key
unset OPENAI_API_KEY
bash scripts/openai.sh --mode generate --prompt "test" --output /tmp/test.png
# Expected: exits 1, "Error: OPENAI_API_KEY environment variable is not set"
```

### Model Override via Environment Variable

```bash
# Gemini model override
export GEMINI_IMAGE_MODEL="gemini-3.1-flash-image-preview"
bash scripts/gemini.sh --mode generate --prompt "test" --output /tmp/test.png
# Expected: stderr includes "model: gemini-3.1-flash-image-preview" (will fail at API call without valid key, but model name is visible in the log)

# OpenAI model override (forcing previous flagship)
export OPENAI_IMAGE_MODEL="gpt-image-1.5"
bash scripts/openai.sh --mode generate --prompt "test" --output /tmp/test.png
# Expected: stderr includes "model: gpt-image-1.5" (not the default gpt-image-2)

# xAI model override
export XAI_IMAGE_MODEL="grok-imagine-image-pro"
bash scripts/xai.sh --mode generate --prompt "test" --output /tmp/test.png
# Expected: stderr includes "model: grok-imagine-image-pro"
```

## 3. Feature Tests (Via Slash Command)

These tests require a running Claude Code session with the plugin loaded. They verify end-to-end behavior.

### 3.1 Basic Generation

**Setup:** At least one API key set.

**Steps:**

1. Run `/generate-image a red fox sitting in snow`
2. When prompted, select a single provider (e.g., Gemini)
3. When prompted for output path, accept the default or specify a path
4. Wait for generation to complete

**Expected:**

- A task is created and marked in_progress
- The script runs and the task is marked completed
- An image file exists at the output path
- The file is a valid PNG (verify with `file <path>`)

### 3.2 Image Editing

**Setup:** An existing image file (e.g., `./test-input.png`).

**Steps:**

1. Run `/generate-image --edit ./test-input.png change the background to a beach`
2. Select a provider
3. Confirm or set the output path

**Expected:**

- Mode is detected as "edit"
- The `--input-image` flag is passed to the script
- Output image reflects the edit instruction
- Original image is not modified

### 3.3 Provider Selection

**Single provider:**

1. Run `/generate-image a simple blue circle`
2. Select "Gemini" only
3. Verify one image is generated

**All providers in parallel:**

1. Run `/generate-image a simple blue circle`
2. Select "All in parallel"
3. Verify a single task is created tracking the parallel run (`run-all.sh` owns parallelism; the agent does not orchestrate per-provider Task subagents)
4. Verify a streaming pane opens (30% of the terminal's longer axis — a right-hand column on a wide terminal, a bottom band on a tall/narrow one) showing a colored banner + rendered image as each provider completes, plus a bottom spinner of pending providers that is shown only until the first image renders
5. Verify three output files are generated with provider-suffixed filenames (e.g., `image-gemini.png`, `image-openai.png`, `image-xai.png`)

### 3.4 Output Location

1. Run `/generate-image a test pattern`
2. When asked for output location, specify a custom path (e.g., `/tmp/custom-dir/output.png`)
3. Verify the directory is created if it did not exist
4. Verify the file is written to the specified path

### 3.5 Parallel Generation via run-all.sh

1. Run `/generate-image a sunset over the ocean` and select "All in parallel"
2. Observe that a single task tracking the parallel run is created and marked in_progress
3. A streaming pane opens, taking 30% of the terminal's longer axis (a right-hand column when the terminal is wide, a bottom band when it is tall/narrow). As each provider finishes, a colored banner appears (gemini blue / openai gray / xai red) with the model name and elapsed timing, followed by the rendered image
4. Until the first image renders, the bottom of the pane shows an animated spinner with the names of pending providers in their accent colors. Once the first image appears the spinner goes silent — further redraws would erase the accumulated inline images in tmux control mode — so later providers appear as banner + image with no spinner
5. When all providers complete, the pane shows interactive controls (`[f]inder [p]review [esc/ctrl-d]`)
6. The task is marked completed and all output paths are reported. If any provider failed, run-all.sh exits with status 1 and the error appears as a red banner inline (with details in `$DISPLAY_PANE_DIR/logs/<provider>.err`)

## 4. Edge Cases

### Missing API Key at Runtime

1. Unset the API key for the selected provider
2. Run `/generate-image a test`
3. Select the provider whose key is missing

**Expected:** The script exits with code 1 and prints "Error: <VAR> environment variable is not set". The task should reflect the error.

### Invalid Arguments

1. Run the script with an unsupported `--mode` value:
   ```bash
   bash scripts/gemini.sh --mode transform --prompt "test" --output /tmp/test.png
   ```
   The script will proceed but the API will reject the request (no client-side mode validation beyond generate/edit).

2. Run with an unreachable output path:
   ```bash
   bash scripts/gemini.sh --mode generate --prompt "test" --output /root/noperm/test.png
   ```
   **Expected:** mkdir fails or write fails, script exits with error.

### API Errors

1. Set an invalid API key (e.g., `export GEMINI_API_KEY="invalid"`)
2. Run a generation
3. **Expected:** Script prints "Error: Gemini API returned HTTP 4xx" and the error message from the API

### Rate Limiting

1. Trigger many requests rapidly (or simulate HTTP 429)
2. **Expected:** Script prints the HTTP 429 error and the API error message. The skill documentation advises switching to the other provider.

### Large Input Image (Gemini)

1. Provide an image larger than 7 MB as `--input-image`
2. **Expected:** The API may reject it. The script reports the HTTP error and API message.

### Nonexistent Input Image

1. Run edit mode with a path that does not exist:
   ```bash
   bash scripts/gemini.sh --mode edit --prompt "test" --input-image ./nonexistent.png --output /tmp/test.png
   ```
2. **Expected:** `base64` command fails, script exits with error due to `set -euo pipefail`.

## 5. Checklist Summary

| Test | Type | What to verify |
|------|------|----------------|
| Missing required flags | Automated / Manual | Exit code 1, usage printed |
| Missing API key env var | Automated / Manual | Exit code 1, clear error message |
| Unknown flag | Manual | Exit code 1, "Unknown option" |
| Model env var override | Manual | Correct model name in stderr |
| `--model` flag override | Manual | Flag takes precedence over env var |
| Single-provider generation | Feature | Image file created, valid PNG |
| Single-provider editing | Feature | Edited image created, original untouched |
| All-providers parallel | Feature | One task tracking the parallel run, three output files, all completed |
| Output directory creation | Feature | Nonexistent directory is created |
| Invalid API key | Edge case | HTTP error reported, script exits 1 |
| Nonexistent input image | Edge case | Script exits with error |
| Unreachable output path | Edge case | Script exits with error |
| Rate limit (HTTP 429) | Edge case | Error reported with API message |
