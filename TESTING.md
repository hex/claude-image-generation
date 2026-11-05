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
| `tests/gemini.bats` | `scripts/gemini.sh` | Argument validation, missing API key, required flags, model override, edit mode requires `--input-image`, more than 14 input images rejected |
| `tests/openai.bats` | `scripts/openai.sh` | Argument validation, missing API key, required flags, model override, edit mode requires `--input-image`, more than 16 input images rejected, multiple images with `dall-e-2` rejected, a prompt starting with `@` passed to curl with `--form-string` |
| `tests/xai.bats` | `scripts/xai.sh` | Argument validation, missing API key (XAI_API_KEY + GROK_API_KEY fallback), model override, edit mode, more than 5 input images rejected and five sent in one edit request, `--quality` validation |
| `tests/openrouter.bats` | `scripts/openrouter.sh` | Argument validation including an invalid `--mode`, missing API key, model override, usage text, a choice-level error on an HTTP 200 response reported by message |
| `tests/check_status.bats` | `scripts/check-status.sh` | A stub curl that answers per URL: a missing key sends no request; each provider's rejected-key answer (Gemini and xAI 400, OpenAI and OpenRouter 401) reads rejected, and a Gemini or xAI 400 that does not name the key does not; a model in the list reads `yes`, through an xAI alias too, and a missing one `no`, as does an OpenRouter model without image output; a Gemini list with more pages reads `unknown`; a request with no answer names curl's exit code, and a non-JSON list, or a 200 with an empty body from any provider, reads unreadable; keys reach curl as a header on stdin, never in its arguments; xAI falls back to `GROK_API_KEY`; each row's model matches the model its provider script sends; a provider script without its `MODEL="${VAR:-default}"` line, or a missing jq, stops the check with exit 1; the check leaves no response body in `$TMPDIR`. Runs under `/bin/bash` (3.2) |
| `tests/model_fallback.bats` | `scripts/model-fallback.sh`, provider scripts | Runtime model fallback under `/bin/bash`: every provider retrying an unavailable default once with its fallback (model read from the gemini URL, the openai edit form field, or the JSON body); the fallback notice naming provider, model and status but none of the API's message (xAI's carries the team ID); the verdict recorded once the fallback answers HTTP 200, an OpenRouter 200 whose choice holds an error and no image included (that run still exits 1 naming the error), honoured by the next run, ignored past `IMAGE_AVAILABILITY_TTL` or with `0`, kept per key, stale when unreadable, its timestamp and the TTL read as decimal despite leading zeros, written through a temp file `mktemp` creates so a symlink planted at a temp path named after the process ID is never followed; a fallback that is unavailable too ending the run after two requests; no fallback for a bad key, a bad parameter, or a model named by `--model` or `*_IMAGE_MODEL`; a 503 retried on the default before a 404 moves to the fallback; the pane's status rows naming the fallback; the classifier over every captured answer in `tests/fixtures/model-fallback/` (`unavailable/` must classify unavailable, `other/` must not) |
| `tests/retry.bats` | `scripts/retry.sh` | `curl_with_retry` on 429/5xx/network failures, delay doubling, `IMAGE_MAX_RETRIES` / `IMAGE_RETRY_DELAY`, attempt count handoff |
| `tests/display.bats` | `scripts/display.sh` | iTerm2/Kitty/Sixel detection, escape sequence format, tmux detection, outer terminal detection, protocol priority, error handling, the single-image and multi-image panes showing and opening a path with quotes, `$` and `\` whole |
| `tests/pane_layout.bats` | `scripts/display.sh`, `scripts/run-all.sh` | Pane orientation (wide/tall split), image normalization to the display box + DPI pinning, empty-timing parse, the `waiting on` line (animated until the first image, then written once per block, clipped to the pane width), resize redraw and its replay order, retry labels on the waiting line, the retry offer (countdown, `r`, expiry, Esc, reprint after a resize), a model or path with tabs and newlines staying one status or manifest record, the close prompt's `f` and `p` keys opening each image whole, and every image a provider completed in a pane two batches share, each path once in the order it arrived |
| `tests/shared_pane.bats` | `scripts/display.sh`, `scripts/run-all.sh` | One pane per batch: registry attach, create-race wait, abandoned-claim takeover, stale/dismissed entries, token refcount, run-all attach + ownership |
| `tests/edit_payload.bats` | provider scripts | base64 / `--rawfile` edit-payload construction; multi-image payload shape (gemini inlineData part count in edit and generate modes, openai repeated `image[]` multipart fields, xai `images` array length, openrouter `image_url` content parts); xai `--quality` in the request body and the reported format; every provider retrying a 503 and reporting it to the pane; every provider refusing an input that is not an image, a missing path and `/dev/zero` before any request; gemini, xai and openrouter sending two different images as their own bytes, each typed by its content (a GIF named `.png` goes as `image/gif`); the openai request sent by the real curl to `tests/one_request_server.py` (needs `python3`): every free-text field set to `@<file>` arrives as typed, and images named with `,` `;` `"` `\` or `-` arrive as their own bytes; an input file replaced after the check still uploads the checked bytes; every provider removing its copies of the input images on exit, refused or not. The multi-megabyte tests skip unless a large PNG named `test-input.png` sits at the repository root (gitignored) |
| `tests/output_image.bats` | `scripts/output-image.sh` through every provider | Never overwriting: each provider refuses an `--output` that is a file, a symlink or a dangling symlink before calling curl, shows the refusal in the pane and leaves the old file and the link's target unchanged; refuses a symlink (to a file, `/dev/null` or a named pipe) or a folder that appears at the path while the request runs, and leaves it unchanged; leaves no file behind, temp file included, when the image data does not decode; keeps a file another process put at the path while the decode ran when the decode fails; saves the image with the mode the umask gives a new file (640 under `027`), under `/bin/bash` |
| `tests/run-all.bats` | `scripts/run-all.sh` | The retry offer: names only the failed providers, re-forks exactly those when the pane answers `.retry`, treats a pane closed mid-offer as no retry, writes no offer with `DISPLAY_PANE_RETRY_WAIT=0`, guards the pane release after a retry succeeds; `--input-image` forwarding (every repeated flag reaches each provider; provider scripts stubbed) |
| `tests/bash32_compat.bats` | provider + display scripts | bash 3.2 array / associative-array safety |
| `tests/frontmatter.bats` | skill / agent / command | YAML frontmatter validation |
| `tests/argv.test.ts` | `hooks/argv.ts`, `hooks/index.ts` | The generate tool's input rules: blank prompt, a null character in the prompt, a prompt over 100,000 bytes (and one at the limit), unknown or repeated provider, wrong field types, `outputBase` that is blank, names a folder or has an extension, a control character in `outputBase` or an `inputImages` path, malformed or zero-sided aspect ratio, config defaults vs. call overrides, edit mode, prompt kept as one argv element. The `tool.call` hook: an existing file or dangling symlink at an output path refuses the call before `run-all.sh` runs; free paths run once and the answer lists what the run saved |

Tests do not make real API calls. They validate argument parsing, error messages, exit codes, and terminal protocol output. The four provider test files call `stub_provider_api` (in `tests/test_helper.bash`) from `setup()`, so a test that runs a script as far as the API call gets an HTTP 401 from a local curl stub instead of sending a request.

`tests/argv.test.ts` runs under `claude plugin test .`, not bats. `tsc -p .` type-checks the hooks module once `/plugin-types` has written `.claude/types`. To try the tool itself, start `claude --plugin-dir .` with `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1`. Saving a hooks file reloads the module, but the tool is registered at `session.start`, so a change to its name, description or schema needs a fresh session.

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

Repeat the same checks for `scripts/openai.sh`, `scripts/xai.sh` and `scripts/openrouter.sh`.

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

The scripts never overwrite an output. With a valid key the first command saves `/tmp/test.png` and the next one refuses it before printing its model line, so delete `/tmp/test.png` between runs.

```bash
# Gemini model override
export GEMINI_IMAGE_MODEL="gemini-3.1-flash-image"
bash scripts/gemini.sh --mode generate --prompt "test" --output /tmp/test.png
# Expected: stderr includes "model: gemini-3.1-flash-image" (will fail at API call without valid key, but model name is visible in the log)

# OpenAI model override (forcing previous flagship)
export OPENAI_IMAGE_MODEL="gpt-image-1.5"
bash scripts/openai.sh --mode generate --prompt "test" --output /tmp/test.png
# Expected: stderr includes "model: gpt-image-1.5" (not the default gpt-image-2)

# xAI model override
export XAI_IMAGE_MODEL="grok-imagine-image-quality"
bash scripts/xai.sh --mode generate --prompt "test" --output /tmp/test.png
# Expected: stderr includes "model: grok-imagine-image-quality"
```

### Multi-Image Input Validation

`--input-image` is repeatable. Over-cap runs exit with code 1 before any API call, so no API key is needed.

```bash
# Gemini: 15 images (cap 14)
args=(); for i in $(seq 1 15); do args+=(--input-image /tmp/x.png); done
bash scripts/gemini.sh --mode edit --prompt "test" --output /tmp/test.png "${args[@]}"
# Expected: exits 1, "Error: at most 14 input images supported for gemini"

# OpenAI: 17 images (cap 16)
args=(); for i in $(seq 1 17); do args+=(--input-image /tmp/x.png); done
bash scripts/openai.sh --mode edit --prompt "test" --output /tmp/test.png "${args[@]}"
# Expected: exits 1, "Error: at most 16 input images supported for openai"

# OpenAI: dall-e-2 rejects multiple images
bash scripts/openai.sh --mode edit --prompt "test" --output /tmp/test.png \
  --model dall-e-2 --input-image /tmp/x.png --input-image /tmp/y.png
# Expected: exits 1, "Error: at most 1 input image for dall-e-2"

# xAI: 6 images (cap 5)
bash scripts/xai.sh --mode edit --prompt "test" --output /tmp/test.png \
  --input-image /tmp/x.png --input-image /tmp/x.png --input-image /tmp/x.png \
  --input-image /tmp/x.png --input-image /tmp/x.png --input-image /tmp/x.png
# Expected: exits 1, "Error: at most 5 input images supported for xai"
```

### Multi-Image Smoke Tests (Real API Calls)

**Setup:** Two existing image files (e.g., `./ref-a.png`, `./ref-b.png`) and API keys for the providers under test. Mirrors the single-image editing test in section 3.2, with repeated `--input-image` flags.

```bash
# Multi-image edit on each provider
bash scripts/gemini.sh --mode edit \
  --prompt "put the subject of the first image into the scene of the second" \
  --input-image ./ref-a.png --input-image ./ref-b.png --output /tmp/multi-gemini.png
bash scripts/openai.sh --mode edit \
  --prompt "put the subject of the first image into the scene of the second" \
  --input-image ./ref-a.png --input-image ./ref-b.png --output /tmp/multi-openai.png
bash scripts/xai.sh --mode edit \
  --prompt "put the subject of the first image into the scene of the second" \
  --input-image ./ref-a.png --input-image ./ref-b.png --output /tmp/multi-xai.png

# Gemini reference-based generation (generate mode with input images)
bash scripts/gemini.sh --mode generate \
  --prompt "a fresh composition in the style of the second image featuring the object from the first" \
  --input-image ./ref-a.png --input-image ./ref-b.png --output /tmp/refs-gemini.png

# Parallel multi-image edit
bash scripts/run-all.sh --mode edit --prompt "combine these" \
  --input-image ./ref-a.png --input-image ./ref-b.png --output-base /tmp/multi
```

**Expected:**

- Each output file exists and draws on both input images
- The Gemini generate-mode run produces a fresh composition, not an edit of either input
- run-all.sh forwards both `--input-image` flags to every provider and produces three output files. Forwarding happens in edit mode only — a run-all `--mode generate` run does not pass input images to Gemini (call `scripts/gemini.sh` directly for generate-with-references)
- xAI edit output is commonly JPEG data even when saved with a `.png` extension (verify with `file /tmp/multi-xai.png`)
- Known limitation: `dall-e-2` edits remain non-functional even with a single image — the script sends form fields only the gpt-image models accept

### Model Fallback Smoke Test (Real API Calls)

**Setup:** API keys for the providers under test. Costs one image per provider. A model named by `*_IMAGE_MODEL` never falls back, so the test pins a model id that does not exist as the default in a copy of the scripts, which is what a retired default looks like to the script.

```bash
work=$(mktemp -d "${TMPDIR:-/tmp}/fallback.XXXXXX")
cp -R scripts "$work/"
sed -i '' 's/:-gemini-3-pro-image}/:-no-such-image-model-x9}/' "$work/scripts/gemini.sh"
sed -i '' 's/:-gpt-image-2}/:-no-such-image-model-x9}/' "$work/scripts/openai.sh"
sed -i '' 's/:-grok-imagine-image-2.0}/:-no-such-image-model-x9}/' "$work/scripts/xai.sh"
sed -i '' 's#:-google/gemini-3.1-flash-image}#:-google/no-such-image-model-x9}#' "$work/scripts/openrouter.sh"
export XDG_CACHE_HOME="$work/cache"
unset GEMINI_IMAGE_MODEL OPENAI_IMAGE_MODEL XAI_IMAGE_MODEL OPENROUTER_IMAGE_MODEL
for p in gemini openai xai openrouter; do
  extra=(); [[ $p == openai ]] && extra=(--quality low)
  env -u TMUX -u TMUX_PANE bash "$work/scripts/$p.sh" --mode generate \
    --prompt "a small red paper boat on calm blue water" --output "$work/$p.png" "${extra[@]}"
done
ls "$work/cache/claude-image-generation/model-verdicts/"
```

**Expected:**

- Each run prints `no-such-image-model-x9 is unavailable to this key (<provider>, HTTP <code>); drawing with fallback <fallback>`, with none of the API's message, and saves an image
- The verdict directory holds one file per provider; running a provider again prints `... is remembered as unavailable to this key; drawing with fallback ...` and sends one request

## 3. Feature Tests (Via Slash Command)

These tests require a running Claude Code session with the plugin loaded. They verify end-to-end behavior.

With the generate tool loaded (a Claude Code build with function hooks), the command skips the provider and path questions and uses the `/config` defaults (Default providers `all`, Output directory `.`). Run the steps below that answer those questions on a build without function hooks, or change the `/config` defaults first.

When a session loads both the marketplace copy and a `--plugin-dir` copy of the plugin, the short name `/generate-image` is ambiguous; use `/claude-image-generation:generate-image`.

### 3.0 Generate Tool

**Setup:** A build with function hooks (see section 1), at least one API key set.

1. Ask for an image that names providers, an output path and an aspect ratio (for example "draw a lighthouse at dusk with gemini and xai, save it as ./out/lighthouse, 16:9"), and check the call carries `providers`, `outputBase` and `aspectRatio`
2. Check the result lists `saved ./out/lighthouse-gemini.png` and `saved ./out/lighthouse-xai.png`, or a `missing` line for any provider that failed, followed by `run-all.sh exited <code>`
3. Trigger each refusal and check the tool refuses before anything runs: a blank prompt, a field of the wrong type (such as `providers` as a string), an unknown provider, a provider named twice, an `outputBase` that is blank, ends in `/`, or ends in `.png`, `.jpg`, `.jpeg` or `.webp`, an `outputBase` holding a newline, and an aspect ratio that is not whole-number `W:H` (such as `auto`, `19.5:9` or `0:0`)
4. Ask for the image from step 1 again with the same output path, and check the tool refuses with `./out/lighthouse-gemini.png already exists` and `./out/lighthouse-xai.png already exists`, runs no provider, and leaves both files as they were. Replace one of them with a symlink to another file (`printf canary > ./out/canary.txt && ln -sf canary.txt ./out/lighthouse-xai.png`), ask again, and check the refusal still names it and `./out/canary.txt` still reads `canary`

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
4. Verify a streaming pane opens (30% of the terminal's longer axis — a right-hand column on a wide terminal, a bottom band on a tall/narrow one) showing a colored banner + rendered image as each provider completes, plus a bottom `waiting on` line naming the pending providers. It animates until the first image renders; after that the watcher writes it once more under each new block, naming the providers still pending, and never rewrites it
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
4. Until the first image renders, the bottom of the pane shows an animated `waiting on` line with the names of pending providers in their accent colors. Once the first image appears the line stops animating: the watcher writes it once more under each new block, naming the providers still pending, and never rewrites it, because a repeated redraw would erase the accumulated inline images in tmux control mode
5. When all providers complete, the pane shows interactive controls (`[f]inder [p]review [esc/ctrl-d]`)
6. The task is marked completed and all output paths are reported. If any provider failed, run-all.sh exits with status 1 and the error appears inline in the pane as a red banner. The per-provider logs under `$DISPLAY_PANE_DIR/logs/` exist only while the pane is open; the pane deletes them when it closes, and `DISPLAY_PANE_DIR` never reaches the caller

### 3.6 One Pane Across Concurrently-Launched Providers

Run inside tmux. Launch two providers directly, at the same time, without run-all.sh:

```bash
bash scripts/gemini.sh --mode generate --prompt "a blue circle" --output /tmp/pane-gemini.png &
bash scripts/xai.sh    --mode generate --prompt "a red square"  --output /tmp/pane-xai.png &
wait
```

1. Verify exactly one pane opens, not one per provider
2. Verify both providers render into it, each under its own colored banner
3. Verify the pane stays open until the slower provider finishes, then shows `[f]inder [p]review [esc/ctrl-d]`
4. Delete `/tmp/pane-gemini.png` and `/tmp/pane-xai.png` (the scripts never overwrite an output), run the same two commands again after you dismiss the pane, and verify a fresh pane opens rather than the images landing in the dismissed one
5. Start a provider in the background, then run `run-all.sh` while it is still generating, and verify both stream into the same pane and that run-all does not dismiss it while the background provider is still working

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
   The scripts handle an unsupported mode differently:
   - `gemini.sh` and `xai.sh` do not check `--mode`; any value other than `edit` runs a normal generation.
   - `openai.sh` exits with an unbound-variable error, since neither its generate nor its edit branch runs.
   - `openrouter.sh` exits 1 with "Error: --mode must be 'generate' or 'edit'".

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
2. **Expected:** The script retries a 429 up to three times first; if it still fails, it prints the HTTP 429 error and the API error message. Try again later or use another provider.

### Large Input Image (Gemini)

1. Provide an image larger than 7 MB as `--input-image`
2. **Expected:** The API may reject it. The script reports the HTTP error and API message.

### Nonexistent or Non-Image Input

1. Run edit mode with a path that does not exist, then with a text file named like an image:
   ```bash
   bash scripts/gemini.sh --mode edit --prompt "test" --input-image ./nonexistent.png --output /tmp/test.png
   printf 'not an image\n' > /tmp/notes.png
   bash scripts/gemini.sh --mode edit --prompt "test" --input-image /tmp/notes.png --output /tmp/test.png
   ```
2. **Expected:** both exit 1 before any API call, with `Error: --input-image is not a readable file: ./nonexistent.png` and then `Error: --input-image is not a PNG, JPEG, WebP or GIF image: /tmp/notes.png`. The API key check runs first, so set `GEMINI_API_KEY` to any value. The output check runs next, so make sure `/tmp/test.png` does not exist.

### Existing Output Path

1. Put a file and a dangling symlink where the scripts would save:
   ```bash
   printf 'OLD IMAGE' > /tmp/taken.png
   ln -sf /tmp/nowhere.txt /tmp/dangling.png
   GEMINI_API_KEY=any bash scripts/gemini.sh --mode generate --prompt "test" --output /tmp/taken.png
   GEMINI_API_KEY=any bash scripts/gemini.sh --mode generate --prompt "test" --output /tmp/dangling.png
   ```
2. **Expected:** both exit 1 before any API call, with `Error: --output already exists, refusing to overwrite it: /tmp/taken.png` and then the same for `/tmp/dangling.png`. `/tmp/taken.png` still reads `OLD IMAGE`, and `/tmp/nowhere.txt` does not exist.

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
| Multi-image edit payloads | Automated | gemini inlineData count, openai `image[]` fields, xai `images` array length |
| Gemini generate with references | Automated / Manual | inlineData parts present in generate-mode payload |
| Input-image caps | Automated / Manual | Exit 1 over cap: 14 gemini / 16 openai / 5 xai / 1 dall-e-2 |
| run-all `--input-image` forwarding | Automated | Every repeated flag reaches each provider (edit mode) |
| All-providers parallel | Feature | One task tracking the parallel run, three output files, all completed |
| Output directory creation | Feature | Nonexistent directory is created |
| Invalid API key | Edge case | HTTP error reported, script exits 1 |
| Nonexistent input image | Edge case | Script exits with error |
| Unreachable output path | Edge case | Script exits with error |
| Existing output path | Automated / Manual | Exit 1 before any API call; the file, the symlink and its target unchanged |
| Rate limit (HTTP 429) | Edge case | Error reported with API message |
