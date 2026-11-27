# Changelog

This file lists every notable change to claude-image-generation. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses calendar
versioning in `YYYY.M.PATCH` format. [GitHub releases](https://github.com/hex/claude-image-generation/releases)
cover the versions up to 2026.9.1.

## Unreleased

### Fixed
- `openrouter.sh` draws with OpenRouter's models that output only images, such as `openai/gpt-image-2` and `x-ai/grok-imagine-image-2.0`, which chat completions answers with HTTP 404. Every request still goes to chat completions first. When that answer is HTTP 404 with either of the two messages OpenRouter gives such a model, the script sends the same request once to `/api/v1/images`, with any input images as `input_references`. The default model's fallback to `google/gemini-3.1-flash-image` runs before that step, so a run with the default model that drew before sends the same requests.
- `/claude-image-generation:status` reads OpenRouter's image output list (`/api/v1/models?output_modalities=image`). The unfiltered list leaves out the models that output only images, so the status row called `openai/gpt-image-2` unlisted.

## 2026.11.2 - 2026-11-26

### Added
- Browser gallery, the new default display: every image run from every Claude Code session shows on one local page served from 127.0.0.1, newest first, as a section with one frame per provider in that provider's own column. A rail filters the runs by project, a run with a failed provider gets a Retry failed button that counts down the time left, a loupe shows each image large, and a switch picks Auto, Light or Dark. Nothing splits the chat's tmux pane. It needs `python3` 3.9 or later and falls back to the pane without it.
- Deleting from the gallery: a finished run's trash button, a project's trash button in the rail and **Delete project…** remove runs from the page and delete the image files they saved, after a dialog that lists each file. The server deletes only files that the dialog listed and a run's own records name as its images, and only when the name ends in `-<provider>` and an image extension. A file with another name, such as `generated.png` from a single provider script, stays on disk, and the dialog says so and why. It removes a symlink, not its target. It keeps a file that another run in the gallery also names or used as an input image, by any path, and the dialog marks it as kept. It deletes nothing while a run's status log or `meta.json` does not parse, and names that run. It never deletes a run that is still generating. Anyone who has the page's address can now delete those files.
- Resending from the gallery: a run that `run-all.sh` started has **Edit prompt**, which opens its prompt in an editor with a button per provider. **Resend** has the server start `run-all.sh` again with the edited prompt and the chosen providers, keeping the run's mode, input images and extra arguments, and saving as `image-<stamp>-<provider>.png` in the folder of the run's output base, so a run whose providers all failed can be resent too. It refuses, and starts nothing, when one of those files exists. The images are readable by you only. A resend still starting after 15 seconds closes the editor with a note, and its run shows once it begins. The results show only in the gallery. `run-all.sh` now records its arguments in the run's `meta.json` for this; runs from before, or from a single provider script, have no Edit prompt. Anyone who has the page's address can now spend API money on any provider whose key the server holds.
- `IMAGE_DISPLAY` (`gallery`, `pane` or `none`) and the matching **Image display** row in `/config` choose where images show. `pane` keeps the tmux pane and inline drawing as they were.

### Changed
- `run-all.sh` refuses a `--mode` other than `generate` or `edit` before any provider runs, instead of leaving each provider to fail on it.
- `SKIP_DISPLAY=1` also keeps `run-all.sh` and the providers from opening the tmux pane, not only from drawing inline.
- In the gallery, provider output stays on `run-all.sh`'s own stderr instead of going to `$DISPLAY_PANE_DIR/logs/`, so the generate tool's result includes it.

### Fixed
- The record of an image saved under a relative `outputBase` names it under the run's working directory, even with `CDPATH` in the environment. With a `CDPATH` folder of the same name, the run's status record named a file in that other folder, with a newline in its path.
- The record of an image saved under a relative `outputBase` names the folder the file is really in, symlinks resolved. A base such as `out/../hero` behind a symlinked `out/` named the working directory in its record while the file went where the symlink leads.

### Documentation
- `grok-imagine-image-quality` is out of the model lists and examples: the xAI API answered HTTP 404 for it on 2026-11-26. The docs keep its history and say xAI retired it.
- The Gemini model lists name `gemini-nano-banana-2.1`, the plugin's Gemini fallback. The docs date the `gpt-image-1.5` and `gpt-image-1-mini` shutdown (2026-12-01) and suggest `gpt-image-2.6-flare` for drafts and as the model-override example.
- OpenRouter attaches input images in generate mode too, and the docs and `openrouter.sh` help now say so.
- The README names the `/claude-image-generation:generate-image` command correctly and no longer calls `openai/gpt-image-2` OpenAI's flagship. The gallery server's row says it deletes runs and their image files.
- The agent and command describe a run as a section of the gallery page, not a card. The agent reports only the files its own call saved, since the gallery can delete runs and resend prompts without it.
- `TESTING.md` gives the real result of `openai.sh` with an unknown `--mode`, sets `IMAGE_DISPLAY=pane` for the streaming-pane tests, and adds manual tests for the browser gallery (section 3.7).
- `run-all.sh` help lists OpenRouter's indigo banner and its output file. `openrouter.sh` help gives current example models.

## 2026.11.1 - 2026-11-05

### Added
- Model fallback: when a provider says its default model is unknown, retired or not enabled for your key, the script retries once with a named fallback and remembers that for 24 hours (`IMAGE_AVAILABILITY_TTL`). Fallbacks: gemini `gemini-nano-banana-2.1`, openai `gpt-image-2.5-sunburst`, xai `grok-imagine-image`, openrouter `google/gemini-3.1-flash-image`. A model you name with `--model` or a `*_IMAGE_MODEL` variable never falls back.
- `/claude-image-generation:status` shows one row per provider: whether the environment holds its API key, whether the provider accepts it, and whether the model the plugin would use is in the provider's live model list. The model is the script's default, or the `*_IMAGE_MODEL` variable when you set one, and the row names that variable. Gemini and xAI answer a bad key with HTTP 400, which they also send for other faults, so a 400 reads as a rejected key only when the body names the key. On OpenRouter the model has to be one that outputs images. The check sends GET requests only, so it bills nothing, and passes each key to curl on stdin rather than in its arguments. `scripts/check-status.sh` reads each default from its provider script, so the two can't disagree.

### Changed
- Every provider refuses an `--input-image` whose first bytes are not PNG, JPEG, WebP or GIF, or a path that is not a readable file, and exits 1 before any request. A key file passed as an input image used to go out to the API, and Gemini and OpenRouter sent an empty image for a missing path.
- Each input image's type comes from its bytes, not its extension, so a GIF named `.png` goes as `image/gif`.
- Each provider sends a private copy of every input image, taken under `$TMPDIR` when the check runs, and removes the copies on exit. Replacing the file after the check no longer changes what gets sent.
- Default openai model is now gpt-image-2.6-sunburst (was gpt-image-2).
- Default openrouter model is now google/gemini-nano-banana-2.1 (was google/gemini-3.1-flash-image); its fallback is now google/gemini-3.1-flash-image.

### Fixed
- Nothing gets overwritten. The `generate` tool refuses a call when any `<outputBase>-<provider>.png` already exists, before it pays any provider, and the scripts refuse an existing `--output` too. Each script saves the image with `link` from a private temp file, so a save never follows a symlink, never writes into a device or FIFO, and never deletes what someone else put at the path. The tool no longer reports an old file as `saved` after a failed run.
- The `generate` tool refuses a provider named twice, a blank `outputBase` or one ending in `/`, a `0:N` aspect ratio, control characters in paths, and prompts with NUL or over 100,000 bytes.
- Paths with newlines, tabs, quotes, `$` or a trailing `;` display and open correctly in the panes, and the `f`/`p` keys open every image in a shared pane.
- The fallback notice no longer echoes the API's message, which for xAI included the team id.
- Docs: `gpt-image-1` is out of the model lists (shut down 2026-10-23); the gpt-image-1.x replacement is `gpt-image-2.5-sunburst` or `-flare`; Google's earliest shutdown for `gemini-2.5-flash-image` is 2027-03-15, replacement `gemini-3.1-flash-lite-image`; the docs cover sizes, `xhigh`/`max` quality and transparency for the 2.5 and 2.6 models.
- Provider tests no longer call the real APIs with dummy keys, and a curl stub no longer waits on an open stdin and stalls the suite.

### Security
- OpenAI edit mode sends the prompt and every other text field with `--form-string`. Through `-F`, a value starting with `@` or `<` made curl read that local file and upload its contents in place of the text.
- openai.sh quotes image paths for curl, so a comma or semicolon in a file name no longer splits the path: a comma made curl exit 26, and `x.png;headers=@notes.txt` read `notes.txt` into the part headers.
- openai.sh reads an input image named `-` as a file. curl read stdin for it and sent whatever stdin held.
