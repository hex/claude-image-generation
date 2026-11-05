# Changelog

This file lists every notable change to claude-image-generation. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses calendar
versioning in `YYYY.M.PATCH` format. [GitHub releases](https://github.com/hex/claude-image-generation/releases)
cover the versions up to 2026.9.1.

## Unreleased

### Added
- `/claude-image-generation:status` shows one row per provider: whether the environment holds its API key, whether the provider accepts it, and whether the model the plugin would use is in the provider's live model list. The model is the script's default, or the `*_IMAGE_MODEL` variable when you set one, and the row names that variable. Gemini and xAI answer a bad key with HTTP 400, which they also send for other faults, so a 400 reads as a rejected key only when the body names the key. On OpenRouter the model has to be one that outputs images. The check sends GET requests only, so it bills nothing, and passes each key to curl on stdin rather than in its arguments. `scripts/check-status.sh` reads each default from its provider script, so the two can't disagree.

### Changed
- Every provider refuses an `--input-image` whose first bytes are not PNG, JPEG, WebP or GIF, or a path that is not a readable file, and exits 1 before any request. A key file passed as an input image used to go out to the API, and Gemini and OpenRouter sent an empty image for a missing path.
- Each input image's type comes from its bytes, not its extension, so a GIF named `.png` goes as `image/gif`.
- Each provider sends a private copy of every input image, taken under `$TMPDIR` when the check runs, and removes the copies on exit. Replacing the file after the check no longer changes what gets sent.

### Security
- OpenAI edit mode sends the prompt and every other text field with `--form-string`. Through `-F`, a value starting with `@` or `<` made curl read that local file and upload its contents in place of the text.
- openai.sh quotes image paths for curl, so a comma or semicolon in a file name no longer splits the path: a comma made curl exit 26, and `x.png;headers=@notes.txt` read `notes.txt` into the part headers.
- openai.sh reads an input image named `-` as a file. curl read stdin for it and sent whatever stdin held.
