---
description: Generate or edit images using AI (Gemini/OpenAI)
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
   - **Gemini** (gemini-3-pro-image-preview): Best for aspect ratio control and iterative editing
   - **OpenAI** (gpt-image-1.5): Best for text rendering and transparent backgrounds
   - **Both in parallel**: Generate with both and pick the best result

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

   **If both providers selected:**
   a. Create two tasks with TaskCreate:
      - "Generate image with Gemini" (activeForm: "Generating image with Gemini...")
      - "Generate image with OpenAI" (activeForm: "Generating image with OpenAI...")
   b. Mark both in_progress with TaskUpdate
   c. Launch two Task subagents in parallel (subagent_type: Bash), each running one script.
      Use different output filenames (e.g., `image-gemini.png` and `image-openai.png`).
   d. As each subagent returns, mark its corresponding task completed (or note the error)

5. After generation completes, confirm the output path(s) to the user.
   If both were generated, let the user know both files are available so they can compare.

## Environment Requirements
- `GEMINI_API_KEY` for Gemini provider
- `OPENAI_API_KEY` for OpenAI provider
