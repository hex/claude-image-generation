---
description: Generate or edit images using AI (Gemini/OpenAI/xAI/OpenRouter)
allowed-tools: Bash, Read, AskUserQuestion, Task, TaskCreate, TaskUpdate, TaskList
argument-hint: <prompt> [--edit <image-path>]
---

Generate or edit an image based on the user's request.

## Process

1. Parse the arguments:
   - The main text is the image prompt
   - If `--edit` is present, the next argument is the path to an input image for editing
   - Determine mode: "edit" if --edit flag is present, otherwise "generate"

2. Ask the user which provider to use with AskUserQuestion:
   - **Gemini** (gemini-3-pro-image): Premium quality, professional asset production, up to 14 reference images
   - **OpenAI** (gpt-image-2): Best for text rendering and transparent backgrounds
   - **xAI** (grok-imagine-image-2.0): Flagship, quality tiers, flat per-image pricing
   - **OpenRouter** (google/gemini-3.1-flash-image): Gateway to many image models through one key; pass any OpenRouter model slug via `--model`
   - **All in parallel**: Generate with the default providers (Gemini, OpenAI, xAI) and pick the best result. OpenRouter is opt-in — include it explicitly with `--providers gemini,openai,xai,openrouter` if the user wants it in the parallel run.

3. Ask the user where to save the output with AskUserQuestion:
   - Current directory (e.g., `./generated-image.png`)
   - Custom path (let them type)

4. Execute the generation using tasks for progress tracking:

   **If single provider selected:**
   a. Create a task with TaskCreate:
      - subject: "Generate image with <Provider>"
      - activeForm: "Generating image with <Provider>..."
   b. Mark it in_progress with TaskUpdate
   c. Run the script via Bash:
      ```bash
      bash "${CLAUDE_PLUGIN_ROOT}/scripts/<provider>.sh" \
        --mode <generate|edit> \
        --prompt "<prompt>" \
        --output "<output-path>" \
        [--input-image "<input-path>"]
      ```
   d. Mark the task completed (or note the error if it failed)

   **If multiple providers selected:**
   a. Create one task tracking the whole parallel run with TaskCreate:
      - subject: "Generate image with all providers in parallel"
      - activeForm: "Generating with Gemini, OpenAI, and xAI..."
   b. Mark it in_progress with TaskUpdate.
   c. Run `scripts/run-all.sh` in a single Bash call — it opens the streaming pane, forks all
      providers in parallel, captures their stdio under `$DISPLAY_PANE_DIR/logs/`, and closes
      the pane when every provider has returned:
      ```bash
      bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-all.sh" \
        --mode <generate|edit> \
        --prompt "<prompt>" \
        --output-base "<base>" \
        [--input-image "<input-path>"]
      ```
      Each provider produces `<base>-<provider>.png` (e.g. `<base>-gemini.png`). The default set
      is `gemini,openai,xai`; add `openrouter` explicitly to include it. To run a subset, pass
      `--providers gemini,openai`. To pass per-provider tuning, use `--gemini-extra "..."`,
      `--openai-extra "..."`, `--xai-extra "..."`, `--openrouter-extra "..."` (e.g.
      `--openrouter-extra "--model openai/gpt-5-image"`).
   d. Mark the task completed when run-all.sh exits. Its exit status reports whether any
      provider failed; per-provider error details are in `$DISPLAY_PANE_DIR/logs/<provider>.err`
      and shown inline in the streaming pane as a red error banner.
      When a provider fails, the pane offers a retry for up to 45 seconds, so the call can
      return later than the slowest provider.

5. After generation completes, confirm the output path(s) to the user.
   If multiple were generated, let the user know all files are available so they can compare.

## Environment Requirements
- `GEMINI_API_KEY` for Gemini provider
- `OPENAI_API_KEY` for OpenAI provider
- `XAI_API_KEY` or `GROK_API_KEY` for xAI provider
- `OPENROUTER_API_KEY` for OpenRouter provider
