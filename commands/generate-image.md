---
description: Generate or edit images using AI (Gemini/OpenAI/xAI)
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
   - **Gemini** (gemini-2.5-flash-image): Best for aspect ratio control and iterative editing
   - **OpenAI** (gpt-image-1.5): Best for text rendering and transparent backgrounds
   - **xAI** (grok-imagine-image): Flat per-image pricing, prompt revision, diverse styles
   - **All in parallel**: Generate with all available providers and pick the best result

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
   a. Create a task per provider with TaskCreate:
      - "Generate image with Gemini" (activeForm: "Generating image with Gemini...")
      - "Generate image with OpenAI" (activeForm: "Generating image with OpenAI...")
      - "Generate image with xAI" (activeForm: "Generating image with xAI...")
   b. Mark all in_progress with TaskUpdate
   c. Open a streaming display pane (single Bash call, capture the watch directory path):
      ```bash
      source "${CLAUDE_PLUGIN_ROOT}/scripts/display.sh" && display_pane_open
      ```
      This outputs a path like `/tmp/display_pane.XXXXXX` — capture it as `DISPLAY_PANE_DIR`.
   d. Launch Task subagents in parallel (subagent_type: Bash), each running one script.
      Use different output filenames (e.g., `image-gemini.png`, `image-openai.png`, `image-xai.png`).
      Pass `DISPLAY_PANE_DIR` so images appear progressively in the shared pane:
      ```bash
      DISPLAY_PANE_DIR=<captured-path> bash "${CLAUDE_PLUGIN_ROOT}/scripts/<provider>.sh" \
        --mode <generate|edit> --prompt "<prompt>" --output "<output-path>"
      ```
   e. As each subagent returns, mark its corresponding task completed (or note the error)
   f. After all providers complete, close the streaming pane to show interactive controls:
      ```bash
      DISPLAY_PANE_DIR=<captured-path> bash -c \
        'source "${CLAUDE_PLUGIN_ROOT}/scripts/display.sh" && display_pane_close'
      ```

5. After generation completes, confirm the output path(s) to the user.
   If multiple were generated, let the user know all files are available so they can compare.

## Environment Requirements
- `GEMINI_API_KEY` for Gemini provider
- `OPENAI_API_KEY` for OpenAI provider
- `XAI_API_KEY` or `GROK_API_KEY` for xAI provider
