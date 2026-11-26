# claude-image-generation

Claude Code plugin for generating and editing images using Google Gemini, OpenAI GPT Image, xAI Grok Image, and OpenRouter APIs.

## Features

- **Text-to-image generation** with Google Gemini, OpenAI GPT Image 2, xAI Grok Image, or any image model on OpenRouter
- **OpenRouter gateway** — reach any OpenRouter image model (Gemini, GPT Image, and more) through one key via the chat-completions API
- **Image editing** with text instructions (all providers)
- **Multi-image input** — repeatable `--input-image` for multi-image edits (all providers) and Gemini reference-based generation
- **Parallel generation** across all providers via `scripts/run-all.sh`, shown as one run: a section with one frame per provider on the browser gallery, or one shared streaming pane with council-style colored banners and a `waiting on` line naming the pending providers (animated until the first image renders, then written once under each block)
- **Interactive provider selection** via AskUserQuestion at runtime
- **Generate tool** on Claude Code builds with function hooks, so the model calls one typed tool instead of writing a script line (see [Generate Tool](#generate-tool-function-hooks-early-access))
- **Provider status** via `/claude-image-generation:status`, which checks each key and default model against the provider's live API without billing anything
- **Model fallback** draws with a configured second model when a provider's default is unavailable to your key (see [Model Fallback](#model-fallback))
- **Browser gallery** (the default display) -- every image run from every Claude Code session shows on one local page, newest first, as a section with one frame per provider that fills in as it finishes. A rail filters the runs by project, a run with a failed provider gets a **Retry failed** button, a loupe shows each image large, a trash button deletes a finished run or a project's finished runs with their image files, **Edit prompt** sends a run's prompt again, edited, to the providers you pick, and a switch picks a light or dark page or follows the system. Nothing splits the chat's pane (see [Image Display](#image-display))
- **Inline image preview** -- with `IMAGE_DISPLAY=pane`, generated images display directly in the terminal (iTerm2, Kitty, Ghostty, WezTerm, Sixel terminals)
- **Tmux pane display** -- with `IMAGE_DISPLAY=pane`, opens a split pane for image preview when running inside tmux (works with Claude Code). Providers running at the same time share one pane, however they were launched
- **Streaming display** -- images appear progressively in a shared pane during parallel generation, accumulating as each provider finishes
- **Open in Finder/Preview** -- press 'f' for Finder or 'p' for Preview in the display pane

## Installation

### From marketplace (recommended)

```bash
# Add the hex-plugins marketplace (once)
/plugin marketplace add hex/claude-marketplace

# Install the plugin
/plugin install claude-image-generation
```

### From GitHub

```bash
/plugin install hex/claude-image-generation
```

### Manual

```bash
git clone https://github.com/hex/claude-image-generation.git
claude --plugin-dir /path/to/claude-image-generation
```

## Configuration

### API Keys

Set any of these as environment variables:

| Variable | Provider | Get a key |
|----------|----------|-----------|
| `GEMINI_API_KEY` | Google Gemini | [Google AI Studio](https://aistudio.google.com/apikey) |
| `OPENAI_API_KEY` | OpenAI | [OpenAI Platform](https://platform.openai.com/api-keys) |
| `XAI_API_KEY` or `GROK_API_KEY` | xAI | [xAI Console](https://console.x.ai) |
| `OPENROUTER_API_KEY` | OpenRouter | [OpenRouter Keys](https://openrouter.ai/keys) |

At least one key is required.

### Model Selection

Override the default model per provider via environment variables:

| Variable | Default | Purpose |
|----------|---------|---------|
| `GEMINI_IMAGE_MODEL` | `gemini-3-pro-image` | Gemini model used for generation and editing |
| `OPENAI_IMAGE_MODEL` | `gpt-image-2.6-sunburst` | OpenAI model used for generation and editing |
| `XAI_IMAGE_MODEL` | `grok-imagine-image-2.0` | xAI model used for generation and editing |
| `OPENROUTER_IMAGE_MODEL` | `google/gemini-nano-banana-2.1` | OpenRouter model slug used for generation and editing |

Command-line `--model` flag on the scripts takes precedence over environment variables.

### Image Display

`IMAGE_DISPLAY` chooses where images show while they generate. The generate tool takes it from the **Image display** row in `/config`. An `IMAGE_DISPLAY` already set in Claude Code's environment wins over that row, and the scripts read the variable directly.

| Value | Where images show |
|-------|-------------------|
| `gallery` (default) | One browser page that every Claude Code session shares. Nothing draws in the terminal |
| `pane` | The tmux pane beside the chat, or inline in the terminal outside tmux (see [Terminal Image Display](#terminal-image-display)) |
| `none` | Nowhere; the images are only saved. `SKIP_DISPLAY=1` means the same |

Any other value stops the run before it calls any provider, with `IMAGE_DISPLAY must be gallery, pane or none, got '<value>'`.

The gallery needs `python3` 3.9 or later. Without it the run uses `pane` and says so on stderr. On macOS, `/usr/bin/python3` counts only after you install the Command Line Tools (`xcode-select -p` names a path), because running it before that opens an install dialog.

The first run starts a small server, `scripts/gallery-server.py`, on 127.0.0.1 and opens the page in the default browser (`open -g` on macOS, so the browser does not take focus; `xdg-open` on Linux). The browser gets a one-time address, `/launch/<code>`, which works once within a minute and sends it on to the page, so the page's token never shows up in a command line. The code does, for a moment. If another user on this machine reads it and uses it first, they get the page and your tab shows an error. Later runs reuse that server, and open the page again only when no page is open, at most once every 10 seconds. Over SSH, or where the run cannot open a browser, it prints the page's address on stderr instead: `image gallery: open http://127.0.0.1:<port>/<token>/ to watch the images`. The generate tool's result carries that line. The address holds the token, so don't share it: anyone on this machine who has it can open the gallery and delete the image files it lists. A server that cannot start costs one line on stderr; the images are still saved.

The page lists runs newest first, one section per run, parted by thin lines. A run's top line gives its state, one of Working, Done, Failed (it finished with no image and at least one error) or Stopped (its process died before it finished), then its project (the last folder of its working directory; hover over it for the whole path) and when it started. A run still working also says when it last changed, as in `Updated 10 s ago`. The prompt is under that line, cut to two lines; the loupe shows the whole prompt. Each provider has its own column, in the order Gemini, OpenAI, xAI, OpenRouter, so a provider is always in the same place. When the runs are less than 980 pixels wide, a full-size run shows its frames two by two. Every frame is the same square, with the image fitted inside it. A frame says Waiting until its provider starts, then Generating and the median time of that provider and model's recent runs, while its caption counts the time. When earlier runs of that provider and model finished, a line along the frame's bottom edge fills over their usual time and stops short of the end. A retry shows as Retrying, with the request's number, as in `Attempt 3 of 4`, and a dashed line. When the image arrives, the caption gives the provider, the seconds it took and the model. A failed frame shows the HTTP status in red, with the API's error code when the error text has one (`Error` when the text has no status), then the message, and a **Full error** button that opens the whole error text. A provider whose process died shows a hatched Stopped frame. Runs that started in the last 24 hours show at full size. Older runs show as a row of small frames, with the prompt cut to one line and a failed frame showing only its status. The newest run always shows at full size.

The rail on the left lists the projects, the one with the newest run first, with a dot on the ones generating now. Click one to see only its runs; a reload keeps the choice. The switch at the bottom of the rail picks Auto (follow the system's light or dark mode), Light or Dark, and the browser remembers the choice. When a `run-all.sh` run has a failed provider and a page is open, the run waits up to `DISPLAY_PANE_RETRY_WAIT` seconds (45) for the run's **Retry failed** button, which re-runs only the failed providers. The button counts down the time left. With no page open it makes no offer and returns at once.

A finished run's top line ends with a trash button. A project's row in the rail shows one when you hover over it or tab to it, and with a project selected the top line has **Delete project…**. Each one first opens a dialog that says how many image files it deletes from disk, lists each file by its path, lists each file that stays with the reason, and says this can't be undone. Cancel has the focus; **Delete** removes the runs from the gallery and deletes those files. A run still generating, or one with its retry offer open, has no trash button, and a project's delete leaves those runs where they are and says how many it leaves. The server deletes only the files that the run's own records name as its images, and only if each path is absolute and its file name ends in `-<provider>` and `.png`, `.jpg`, `.jpeg`, `.webp` or `.gif`, as in `hero-gemini.png`. A file that breaks that rule stays on disk while its run leaves the gallery, and so does a path that is relative or holds a null character. The dialog lists each one as kept with the reason before you confirm. A single provider script called with `--output ./generated.png` records such a file. For a symlink it removes the link, not the file the link points to. A file that is already gone counts as deleted. A file that another run in the gallery also names stays, and the dialog marks it as kept: once you delete a file by hand, a newer run can save to the same path, and deleting the older run then leaves the newer image alone. The server compares the files the paths lead to, not the paths' text, so a run that names the file through a symlinked folder, a symlink to it or a doubled slash counts too. When one delete takes every run that names a file, the file goes too. The page sends the paths its dialog listed for each run, and the server deletes only those that the run's records still name. A file that something made worth keeping after the dialog opened, such as a run that names it since, stays, and the dialog then lists each file it kept and why. If the run is still generating, the server deletes nothing of that run, and the dialog names the run and the reason.

A run that `run-all.sh` started (the generate tool and `/claude-image-generation:generate` both use it) has **Edit prompt** on its top line, even when every provider failed. It opens the prompt in an editor, with one button per provider under it and the run's own providers turned on. **Resend** (or ⌘↩, Ctrl+↩ off macOS) has the server start `run-all.sh` again in the run's working folder, with the edited prompt and the providers you turned on. The run's mode, input images and per-provider extra arguments (where an aspect ratio goes) stay as they were. The images go in the folder of the run's own output base, where its images went, as `image-<YYYYMMDD-HHMMSS>-<provider>.png`, and the new run shows on the page as a run of the same project. Its results never reach Claude. The server never overwrites a file: when one of those paths already exists, as a file or a symlink (a dangling one too), it starts nothing and the editor says which path. It also refuses a blank prompt, one over 100,000 bytes or with a null character, no provider, an unknown provider or one named twice, and a run whose working folder, image folder or input image no longer exists, naming it. The editor stays open with the reason. A run from a single provider script, or from an older version of the plugin, recorded no arguments and has no **Edit prompt**. A provider with no API key in the server's environment fails with its usual error frame. The resent `run-all.sh` writes its output to a file in `resend-logs/` in the gallery folder, which keeps the newest 50. If it exits before it starts a run, the editor shows its exit status and last lines of output, with API keys replaced by their variable names.

Hover over an image, or tab to it, for two buttons: one reveals the file in Finder (its folder on Linux), the other opens it full size in a new tab. Click an image or press Enter on it to open the loupe. In the loupe, Left and Right move across the providers of the run, Up and Down move between runs, R reveals the file, and Esc or a click outside the image closes it.

The server binds 127.0.0.1 only. It answers only requests whose Host header is `127.0.0.1:<port>` and whose path starts with its token, as in `/<token>/events`. It sets no cookie, so other servers on 127.0.0.1 never get the token. Buttons must post with the page's own Origin. The page renders run data as text under a `default-src 'self'` Content-Security-Policy. The token stays the same across restarts, so an open page reconnects after one. The server stops after 30 minutes with no image run going, no resend it started still running and no page open. It keeps the newest 200 runs. Removing older runs never removes their image files; only the delete buttons do that. A run folder it cannot read stays off the page, and `server.log` gets one line naming the folder and the reason. After a plugin update, the next run replaces a server of the old version. An open page reconnects to the new server on the same port, so the run opens no second tab. Runs reach the server through `server.sock`, a socket in the gallery folder, so they never send the token to its port. An open tab does. It keeps reconnecting to the same port with the token in its address. If the server stops and another program on this machine takes that port before the tab reconnects, that program receives the token. Anyone who has the page's address can also delete every image file the gallery lists, as the delete buttons do: the Origin check stops other web pages, not a program that sends the token itself. A leaked token puts those files at risk, not only the view of them. It also spends money: anyone who has the address can resend a prompt as often as they like, to any provider whose API key the server holds. The server holds the keys in the environment of the run that started it, and resends use those keys. A key you add or rotate later reaches resends only after the server restarts, which happens once it stops on its own or you end its process.

| Variable | Default | Purpose |
|----------|---------|---------|
| `IMAGE_DISPLAY` | `gallery` | `gallery`, `pane` or `none` |
| `IMAGE_GALLERY_DIR` | `$XDG_STATE_HOME/claude-image-generation/gallery`, else `~/.local/state/claude-image-generation/gallery` | The server's files (`server.sock`, `server.lock`, `token`, `last-port`, `server.log`), the output of each resend under `resend-logs/`, and one folder per run under `runs/`. If a file of yours in that folder has the name `server.sock`, the gallery leaves it alone. The run then saves its images without the gallery and prints a line asking you to move the file. The run makes the default folder, and a folder you name that does not exist yet, readable by you only. A folder you name that already exists keeps its permissions. The run uses it only if you own it and its permission bits let no other user write to it. Otherwise images show as with `pane`, and stderr says so. For a symlink, the check looks at the folder it points to. The check does not read macOS ACLs. It also happens before the run writes to the folder, so another user who can write to the folder that holds yours, such as `/tmp`, can create or swap your folder or link after the check. Name a folder inside one that only you can write to, such as your home folder |
| `IMAGE_GALLERY_NO_OPEN` | unset | `1` never opens the browser and prints no address |

### Display Size

Control the terminal image display dimensions (in pixels):

| Variable | Default | Purpose |
|----------|---------|---------|
| `DISPLAY_IMAGE_WIDTH` | `512` | Max image width in pixels for terminal display |
| `DISPLAY_IMAGE_HEIGHT` | `512` | Max image height in pixels for iTerm2 display |
| `DISPLAY_PANE_IMAGE_PCT` | `30` | Image width in the streaming pane under iTerm2, as a percent of the pane width |
| `DISPLAY_PANE_IMAGE_PX` | `240` | Longest edge, in pixels, of the preview copy the streaming pane draws; sets sharpness, not on-screen size |

The first two apply to inline display (iTerm2, Sixel), to the tmux panes a direct `display_image` or `display_images` call opens, and to Sixel in the streaming pane. Under iTerm2 the streaming pane sizes images with `DISPLAY_PANE_IMAGE_PCT` instead.

### Available Gemini Models

| Model | Characteristics |
|-------|-----------------|
| `gemini-3-pro-image` | Pro tier, premium quality, 10 aspect ratios, up to 14 reference images (default, "Nano Banana Pro", GA since 2026-05-28) |
| `gemini-3.1-flash-image` | 14 aspect ratios (incl. extreme 1:4, 8:1), 512-4K resolution, thinking, Google Search grounding ("Nano Banana 2", GA since 2026-05-28) |
| `gemini-3.1-flash-lite-image` | Cheapest tier ("Nano Banana 2 Lite") |
| `gemini-2.5-flash-image` | Previous generation, 1K only (earliest shutdown 2027-03-15; Google's replacement is `gemini-3.1-flash-lite-image`) |

The `-preview` IDs of the two GA models still answer but passed Google's earliest shutdown date (2026-06-25) and are gone from its model tables; pass the GA IDs.

### Available OpenAI Models

| Model | Characteristics |
|-------|-----------------|
| `gpt-image-2.6-sunburst` | Built for detailed work and precise edits (default) |
| `gpt-image-2.6-flare` | The faster 2.6 model |
| `gpt-image-2.5-sunburst` | The model the plugin falls back to when the default is unavailable to the key |
| `gpt-image-2` | Snapshot `gpt-image-2-2026-04-21` |
| `gpt-image-1.5` | Previous flagship, superior text rendering, transparent backgrounds, quality tiers (shutdown 2026-12-01) |
| `gpt-image-1-mini` | 3-4x cheaper, cost-efficient for drafts and previews (shutdown 2026-12-01) |

OpenAI names `gpt-image-2.5-sunburst` or `gpt-image-2.5-flare` as the replacement for the two models shutting down. `gpt-image-1` shut down on 2026-10-23.

### Available xAI Models

| Model | Characteristics |
|-------|-----------------|
| `grok-imagine-image-2.0` | Flagship since 2026-08-07: `--quality` low/medium/auto, up to 5 reference images, `21:9` and `5:2` ratios (default) |
| `grok-imagine-image-quality` | Quality mode from 2026-05-06; `grok-imagine-image-pro` has redirected here since its 2026-05-15 retirement |
| `grok-imagine-image` | Standard tier, 1K/2K resolution, 300 RPM, same endpoint and parameters |

### Available OpenRouter Models

OpenRouter is a gateway, so `--model` (or `OPENROUTER_IMAGE_MODEL`) accepts any OpenRouter slug that supports image output. A few:

| Model | Characteristics |
|-------|-----------------|
| `google/gemini-nano-banana-2.1` | Flash-tier Gemini image model ("Nano Banana 2.1"), generation + editing (default) |
| `google/gemini-3.1-flash-image` | Fast Gemini image model, generation + editing |
| `google/gemini-3-pro-image` | Pro-tier Gemini image model, premium quality |
| `x-ai/grok-imagine-image-2.0` | xAI's flagship image model via OpenRouter |
| `openai/gpt-image-2` | OpenAI's flagship image model via OpenRouter (`openai/gpt-5-image` and `openai/gpt-5-image-mini` are the older chat-image models) |

Browse the full list at [openrouter.ai/models](https://openrouter.ai/models?fmt=cards&output_modalities=image).

## Usage

### Slash Command

```
/generate-image a golden retriever in a field of sunflowers
/generate-image --edit ./photo.png remove the background and make it transparent
```

Without the generate tool (see Generate Tool under Usage), the command prompts you to select a provider (Gemini, OpenAI, xAI, OpenRouter, or all in parallel) and an output path.

### Provider Status

```
/claude-image-generation:status
```

Shows one row per provider: whether the environment holds its API key, whether the provider accepts the key, and whether the model the plugin would use is in the provider's live model list:

```
provider    key                           model listed  model
gemini      accepted                      yes           gemini-3.1-flash-image (GEMINI_IMAGE_MODEL)
openai      rejected (HTTP 401)           not checked   gpt-image-2.6-sunburst
xai         accepted                      yes           grok-imagine-image-2.0
openrouter  not set (OPENROUTER_API_KEY)  not checked   google/gemini-nano-banana-2.1
```

Claude Code has a `/status` command of its own, so type the full name. The command runs `scripts/check-status.sh`, which you can also run yourself with `bash scripts/check-status.sh`. It sends GET requests only, which bill nothing, and passes each key to curl on stdin, never in its arguments.

| Column | Values |
|--------|--------|
| `key` | `not set (<variable>)`, `accepted`, `rejected (HTTP <code>)`, `no answer (curl exit <code>)`, `unexpected HTTP <code>` |
| `model listed` | `yes`, `no`, `not checked` (no accepted key), `unknown (list has more pages)`, `unreadable model list`, `no answer (curl exit <code>)`, `unexpected HTTP <code>` |
| `model` | The provider script's default model, or the `*_IMAGE_MODEL` override followed by the variable's name |

What the script asks each provider:

- **Gemini**: `GET /v1beta/models?pageSize=1000`. Gemini answers a bad key with HTTP 400, and other faults too, so a 400 counts as a rejected key only when `error.details[].reason` is `API_KEY_INVALID`.
- **OpenAI**: `GET /v1/models`.
- **xAI**: `GET /v1/image-generation-models`. The model may match an id or one of its aliases. xAI also answers a bad key with HTTP 400, which counts as rejected only when the error text names the API key.
- **OpenRouter**: `GET /api/v1/key` proves the key, since the model list answers without one, then `GET /api/v1/models`. The model has to list `image` among its output modalities.

The script reads each default model and its override variable from the provider script's own `MODEL="${VAR:-default}"` line, so the two can't disagree. When that line is missing, or jq is not installed, it stops with an error and exits 1; otherwise it exits 0, whatever the rows say.

### Agent (Automatic)

The `image-generator` agent triggers automatically when conversation context involves image creation. It handles provider selection, parallel generation, and result delivery without requiring the slash command.

### Generate Tool (function hooks, early access)

On Claude Code builds with function hooks, the plugin also registers a tool, `mcp__claude-image-generation__generate`. The model calls it with a typed input instead of writing a `bash scripts/run-all.sh ...` line:

| Field | Required | Meaning |
|-------|----------|---------|
| `prompt` | yes | What to draw, or how to change the input images |
| `providers` | no | Any of `gemini`, `openai`, `xai`, `openrouter`; omitted, the `Default providers` setting |
| `outputBase` | no | Path without extension, anywhere on disk; each provider saves `<outputBase>-<provider>.png`. Omitted, `<Output directory>/image-<timestamp>` |
| `inputImages` | no | Images to edit; any entry switches to edit mode |
| `aspectRatio` | no | Whole-number `W:H` such as `16:9`; passed to gemini and xai only |

The tool runs `scripts/run-all.sh`, so the gallery (or the streaming pane) and the retry offer work as they do for the slash command. It answers with a `saved` or `missing` line per expected file, the exit code, and whatever the providers printed. When no provider saved a file it refuses the call, with the same text. It also refuses a call that fails a field check before anything runs: a blank prompt, a prompt over 100,000 bytes or with a null character (U+0000), a field of the wrong type, an unknown provider or one named twice, an `outputBase` that is blank, ends in `/`, or ends in `.png`, `.jpg`, `.jpeg` or `.webp` (any case), a control character in `outputBase` or an `inputImages` path, or an aspect ratio that is not whole-number `W:H` with both sides above zero (so xAI's `auto`, `19.5:9` and `9:19.5` need the scripts).

The tool never overwrites a file. When any `<outputBase>-<provider>.png` it would save already exists, as a file or as a symlink (a dangling one too), it refuses the call before any provider runs and names each such path. Choose another `outputBase`, or move the old files away first. The scripts keep the same rule on their own (see Direct Script Usage).

A call runs for at most ten minutes, the most the engine allows a process. That covers the slowest provider plus the 45-second retry offer.

With `IMAGE_DISPLAY=pane`, outside tmux the tool shows no inline preview: it sends the providers' terminal image output to `/dev/null` (through `DISPLAY_IMAGE_TARGET`), so the images do not land on Claude Code's own screen. Inside tmux they stream into the pane as usual.

Three rows in `/config` set its defaults:

| Setting | Values | Default |
|---------|--------|---------|
| Default providers | `all` (gemini, openai, xai), `gemini`, `openai`, `xai`, `openrouter` | `all` |
| Image display | `gallery`, `pane`, `none` (see [Image Display](#image-display)) | `gallery` |
| Output directory | any path, relative to the session's working directory | `.` |

The slash command, the agent and the skill use the tool whenever the session offers it, and skip the provider and path questions. They fall back to running the scripts through Bash on builds without it, or when a request needs an option the tool does not take (image size, quality, transparent background, a specific model, or another per-provider flag).

### Direct Script Usage

Scripts are located in `scripts/` and can be invoked directly.

A provider script never overwrites a file. It refuses an `--output` that already exists, as a file or as a symlink (a dangling one too), before it calls the API. It decodes the image into a hidden temp file in the output's folder, then gives that file the output's name with a hard link. The link fails on anything that appeared at the path during the request, and never follows it: a file, a folder, a device, a named pipe, or a symlink to any of them. Such a run exits 1 with `Could not save the image to <path>: File exists`, and a failed save removes only its own temp file. A filesystem without hard links, such as FAT, cannot take the image: the save fails naming the path and the system's error (`Operation not supported` on macOS). `run-all.sh` gives each provider its own `<base>-<provider>.png`, so a provider whose file exists fails with that refusal while the others still run.

#### gemini.sh

```bash
# Generate
bash scripts/gemini.sh \
  --mode generate \
  --prompt "a mountain at sunset" \
  --output ./mountain.png

# Generate with aspect ratio
bash scripts/gemini.sh \
  --mode generate \
  --prompt "a wide landscape" \
  --output ./landscape.png \
  --aspect-ratio 16:9

# Edit
bash scripts/gemini.sh \
  --mode edit \
  --prompt "add snow to the peaks" \
  --input-image ./mountain.png \
  --output ./snowy.png

# Generate at 4K with thinking mode
bash scripts/gemini.sh \
  --mode generate \
  --prompt "a detailed sci-fi cityscape" \
  --output ./city.png \
  --image-size 4K \
  --thinking-level High

# Generate with Google Search grounding
bash scripts/gemini.sh \
  --mode generate \
  --prompt "Search for the latest SpaceX Starship and draw it at sunset on the launch pad" \
  --output ./starship.png \
  --search-grounding

# Use a specific model
bash scripts/gemini.sh \
  --mode generate \
  --prompt "quick sketch" \
  --output ./sketch.png \
  --model gemini-3-pro-image
```

**Flags:**

| Flag | Values | Default | Required |
|------|--------|---------|----------|
| `--mode` | `generate`, `edit` | -- | Yes |
| `--prompt` | text | -- | Yes |
| `--output` | file path | -- | Yes |
| `--input-image` | file path, repeatable (max 14) | -- | Edit mode; optional in generate mode as references |
| `--aspect-ratio` | `1:1`, `16:9`, `9:16`, `4:3`, `3:4`, `3:2`, `2:3`, `4:5`, `5:4`, `21:9` on Pro (default); add `1:4`, `4:1`, `1:8`, `8:1` on `gemini-3.1-flash-image` | `1:1` | No |
| `--image-size` | `512`, `1K`, `2K`, `4K` (UPPERCASE); `512` requires `gemini-3.1-flash-image` | (API default `1K`) | No |
| `--thinking-level` | `minimal`, `High` | unset (API default `minimal`) | No |
| `--image-only` | (flag, no value) | off | No |
| `--search-grounding` | (flag, no value) | off | No |
| `--model` | Gemini model name | `gemini-3-pro-image` | No |

#### openai.sh

```bash
# Generate
bash scripts/openai.sh \
  --mode generate \
  --prompt "a mountain at sunset" \
  --output ./mountain.png

# Generate with options
bash scripts/openai.sh \
  --mode generate \
  --prompt "company logo on transparent background" \
  --output ./logo.png \
  --size 1024x1024 \
  --quality high \
  --background transparent

# Edit
bash scripts/openai.sh \
  --mode edit \
  --prompt "add snow to the peaks" \
  --input-image ./mountain.png \
  --output ./snowy.png
```

**Flags:**

| Flag | Values | Default | Required |
|------|--------|---------|----------|
| `--mode` | `generate`, `edit` | -- | Yes |
| `--prompt` | text | -- | Yes |
| `--output` | file path | -- | Yes |
| `--input-image` | file path, repeatable (max 16; `dall-e-2` allows 1) | -- | Edit mode only |
| `--size` | `auto` or `WxH`. On `gpt-image-2` and the `gpt-image-2.5` models, any size with both edges multiples of 16, longest edge up to 3840, ratio at most 3:1 and 655,360 to 8,294,400 total pixels (such as `2048x1152`, `3840x2160`). OpenAI states no size rules for `gpt-image-2.6-sunburst`, which drew `1536x864` in a 2026-11-05 test. Older models take `1024x1024`, `1536x1024`, `1024x1536` | `1024x1024` | No |
| `--quality` | `auto`, `low`, `medium`, `high`; also `xhigh` and `max` on the `gpt-image-2.5` and `2.6` models | `high` | No |
| `--background` | `auto`, `transparent`, `opaque`; `transparent` needs `--output-format` `png` or `webp` | `auto` | No |
| `--output-format` | `png`, `jpeg`, `webp` | `png` | No |
| `--output-compression` | integer 0-100 (jpeg/webp only) | -- | No |
| `--moderation` | `auto`, `low` | `auto` | No |
| `--input-fidelity` | `low`, `high` (edit only); not accepted with `gpt-image-2` (that model always uses high fidelity) or `gpt-image-2.6-sunburst`, and `openai.sh` refuses the flag for both | unset (API default `low`) | No |
| `--model` | OpenAI model name | `gpt-image-2.6-sunburst` | No |

#### xai.sh

```bash
# Generate
bash scripts/xai.sh \
  --mode generate \
  --prompt "a mountain at sunset" \
  --output ./mountain.png

# Generate with aspect ratio
bash scripts/xai.sh \
  --mode generate \
  --prompt "a wide landscape" \
  --output ./landscape.png \
  --aspect-ratio 16:9

# Edit
bash scripts/xai.sh \
  --mode edit \
  --prompt "add snow to the peaks" \
  --input-image ./mountain.png \
  --output ./snowy.png

# Generate at 2K resolution
bash scripts/xai.sh \
  --mode generate \
  --prompt "a cat in a tree" \
  --output ./cat.png \
  --resolution 2k

# Use the May 2026 quality-mode model instead of the 2.0 default
bash scripts/xai.sh \
  --mode generate \
  --prompt "a cat in a tree" \
  --output ./cat.png \
  --model grok-imagine-image-quality
```

**Flags:**

| Flag | Values | Default | Required |
|------|--------|---------|----------|
| `--mode` | `generate`, `edit` | -- | Yes |
| `--prompt` | text | -- | Yes |
| `--output` | file path | -- | Yes |
| `--input-image` | file path, repeatable (max 5 on `grok-imagine-image-2.0`; older models take 3) | -- | Edit mode only |
| `--aspect-ratio` | `1:1`, `16:9`, `9:16`, `4:3`, `3:4`, `3:2`, `2:3`, `2:1`, `1:2`, `19.5:9`, `9:19.5`, `20:9`, `9:20`, `21:9`, `5:2`, `auto` | (none) | No |
| `--resolution` | `1k`, `2k` (LOWERCASE) | (API default) | No |
| `--quality` | `low`, `medium`, `auto` (`grok-imagine-image-2.0` only) | unset (API `auto`: low for generation, medium for edits; billed as served) | No |
| `--model` | xAI model name | `grok-imagine-image-2.0` | No |

**Note**: For single-image edits, xAI ignores `--aspect-ratio` and uses the input image's ratio. Multi-image edits allow aspect ratio override (up to 5 images).

#### openrouter.sh

OpenRouter is a gateway to many image models through a single key. It uses the chat-completions API, so `--model` accepts any OpenRouter model slug that supports image output.

```bash
# Generate (default model: google/gemini-nano-banana-2.1)
bash scripts/openrouter.sh \
  --mode generate \
  --prompt "a mountain at sunset" \
  --output ./mountain.png

# Generate with a specific model
bash scripts/openrouter.sh \
  --mode generate \
  --prompt "a cat in a tree" \
  --output ./cat.png \
  --model openai/gpt-image-2

# Edit (single or multiple --input-image)
bash scripts/openrouter.sh \
  --mode edit \
  --prompt "add snow to the peaks" \
  --input-image ./mountain.png \
  --output ./snowy.png
```

**Flags:**

| Flag | Values | Default | Required |
|------|--------|---------|----------|
| `--mode` | `generate`, `edit` | -- | Yes |
| `--prompt` | text | -- | Yes |
| `--output` | file path | -- | Yes |
| `--input-image` | file path, repeatable | -- | Edit mode only |
| `--model` | any OpenRouter image model slug | `google/gemini-nano-banana-2.1` | No |
| `--site-url` | URL | (none) | No (sent as `HTTP-Referer` for OpenRouter attribution) |
| `--site-name` | text | (none) | No (sent as `X-Title` for OpenRouter attribution) |

`--site-url` / `--site-name` also default from `OPENROUTER_SITE_URL` / `OPENROUTER_SITE_NAME`.

#### Reference Images and Multi-Image Composition

Each `--input-image` must be a PNG, JPEG, WebP or GIF file. The scripts copy each one into a private temp folder, read the type from the copy's first bytes, not the name, and send that copy as that type, so a file changed after the check is not what gets sent. A path that is not a readable file, or a file of any other kind, exits with code 1 before any API call.

`--input-image` is repeatable on all four scripts. Passing more images than a provider supports exits with code 1 before any API call:

| Provider | Max images | Modes |
|----------|------------|-------|
| Gemini | 14 | `generate` (references for a fresh composition) and `edit` |
| OpenAI | 16 | `edit` only (its generation endpoint takes no images) |
| xAI | 5 on `grok-imagine-image-2.0` (older models take 3) | `edit` only |
| OpenRouter | model-dependent | `edit` only (input images attached as chat image parts) |

```bash
# Gemini: compose a new image from reference images (generate mode)
bash scripts/gemini.sh \
  --mode generate \
  --prompt "a product shot combining the chair from the first image with the fabric of the second" \
  --input-image ./chair.png \
  --input-image ./fabric.png \
  --output ./composite.png

# OpenAI: multi-image edit
bash scripts/openai.sh \
  --mode edit \
  --prompt "place the logo from the second image onto the mug in the first" \
  --input-image ./mug.png \
  --input-image ./logo.png \
  --output ./branded.png

# xAI: multi-image edit
bash scripts/xai.sh \
  --mode edit \
  --prompt "blend both scenes into one panorama" \
  --input-image ./left.png \
  --input-image ./right.png \
  --output ./panorama.png

# All providers in parallel (edit mode only)
bash scripts/run-all.sh \
  --mode edit \
  --prompt "combine these" \
  --input-image ./ref-a.png \
  --input-image ./ref-b.png \
  --output-base ./combined
```

Gemini's flat 14-image budget is best composed as up to 6 object + 5 character-consistency + 3 style-reference images. There is no API field to tag an image's role — the model infers it from the prompt, so state which images are objects, characters, or style references.

**Notes:**

- `run-all.sh` forwards every `--input-image` to each selected provider, but only in `--mode edit`. Gemini's generate-mode reference images are not forwarded through run-all — call `scripts/gemini.sh` directly for generate-with-references.
- `dall-e-2` edits are a known limitation: the script rejects multiple images for `dall-e-2`, but single-image `dall-e-2` edits also do not work — the script sends form fields only the gpt-image models accept.

### Retries

Each provider script retries a transient API error (429 or a 5xx status, or a network failure) up to three times, with a delay that doubles each attempt (1 second, 2 seconds, 4 seconds). `IMAGE_MAX_RETRIES` and `IMAGE_RETRY_DELAY` tune the count and the starting delay. Inside a streaming pane, a retry shows on the `waiting on` line as `(retry 2/3)`; once an image is on the pane that line is only written when the next block lands, so a retry that starts between blocks shows only in the final banner or error text.

When a provider run through `run-all.sh` fails outright, its error shows under a red `✗ provider error` heading, and if any provider failed the pane offers `[r] retry failed (xai) · [esc/ctrl-d] close 45s`. The offer counts down until the first image is on the pane; after that it shows the time budget once, as `[r] retry failed (xai) · [esc/ctrl-d] close (up to 45s)`, because a rewritten line erases the pane's images. Pressing `r` re-runs only the failed providers inside the same run; Esc closes the pane and the run returns with what it has. `DISPLAY_PANE_RETRY_WAIT` sets how long the offer stays open (default 45 seconds; 0 disables it), and a run with a failure can take that much longer plus one more provider round. In the gallery the offer is the run's **Retry failed** button, made only while a page is open (see [Image Display](#image-display)).

### Model Fallback

When a provider's default model is unavailable to your key (unknown, retired, or not enabled for it), the script sends the same request once more with that provider's fallback model:

| Provider | Default | Fallback |
|----------|---------|----------|
| Gemini | `gemini-3-pro-image` | `gemini-nano-banana-2.1` |
| OpenAI | `gpt-image-2.6-sunburst` | `gpt-image-2.5-sunburst` |
| xAI | `grok-imagine-image-2.0` | `grok-imagine-image` |
| OpenRouter | `google/gemini-nano-banana-2.1` | `google/gemini-3.1-flash-image` |

The script sends a model you name with `--model` or a `*_IMAGE_MODEL` variable as named and never falls back from it, so the error names the model to change.

The fallback runs only when the answer blames the model. That means HTTP 404, HTTP 403 (except on OpenRouter, where 403 means its moderation flagged the prompt), or HTTP 400 with a message saying the model does not exist or is not a valid model ID. A bad key, a bad parameter or a refused prompt fails the same way on any model, so it ends the run. The script retries a 429 or 5xx on the same model (see [Retries](#retries)). A run sends at most two models; if the fallback fails too, the script reports the fallback's error.

The switch shows in stderr, for example `gpt-image-2.6-sunburst is unavailable to this key (openai, HTTP 400); drawing with fallback gpt-image-2.5-sunburst`. The line leaves out the API's own message, since xAI's names your account's team ID and stderr reaches pane logs and the tool result. In a streaming pane the provider's banner names the fallback model that drew the image.

Once the fallback answers HTTP 200, the script records that the default is unavailable to that key, even when that answer holds no image. The default's own unavailable answer is the evidence, and the fallback's 200 shows the account and endpoint work. Later runs send the fallback first, printing `gpt-image-2.6-sunburst is remembered as unavailable to this key; drawing with fallback gpt-image-2.5-sunburst`. Verdicts live in `${XDG_CACHE_HOME:-~/.cache}/claude-image-generation/model-verdicts/`, one file per provider, default model and key digest; the key itself never touches disk. A fallback that answers with any other status leaves no verdict, since a refusal that covers the whole account would fail both models.

| Variable | Default | Purpose |
|----------|---------|---------|
| `IMAGE_AVAILABILITY_TTL` | `86400` | Seconds a verdict holds. `0` makes every run try the default first. |

Delete the verdict directory to try the default again before the verdict expires.

## Provider Comparison

| Feature | Gemini | OpenAI | xAI | OpenRouter |
|---------|--------|--------|-----|------------|
| Default model | gemini-3-pro-image | gpt-image-2.6-sunburst | grok-imagine-image-2.0 | google/gemini-nano-banana-2.1 |
| Max resolution | 4K (via `--image-size`) | 3840 px long edge on gpt-image-2 and the 2.5 models (via `--size`); `1536x1024` on older models | 2K (via `--resolution`) | Model-dependent |
| Text rendering | Very good (under 25 chars) | Excellent | Good | Model-dependent |
| Transparent BG | No | Yes (png or webp only; preview on gpt-image-2) | No | Model-dependent |
| Aspect ratios | 10 on Pro / 14 on 3.1 Flash | Any `WxH` up to 3:1 on gpt-image-2 and the 2.5 models; 3 fixed sizes on older models | 16 options (incl. 21:9, 5:2, auto) | Prompt-driven |
| Image editing | Multi-turn, up to 14 refs (generate + edit) | Up to 16 input images | `/v1/images/edits`, up to 5 images | Chat image parts (edit) |
| Quality tiers | N/A | auto / low / medium / high, plus xhigh / max on the 2.5 and 2.6 models | low / medium / auto (2.0 only) | Model-dependent |
| Thinking mode | Yes (`--thinking-level`) | No | No | Model-dependent |
| Search grounding | Yes (Google Search) | No | No | Model-dependent |
| Pricing | Token-based | Token-based | Flat per-image | Per OpenRouter model |
| Prompt revision | No | No | Yes (by chat model) | No |

## Plugin Components

| Component | File | Purpose |
|-----------|------|---------|
| Plugin manifest | `.claude-plugin/plugin.json` | Plugin metadata, version and the /config rows (defaultProviders, display, outputDir) |
| Skill | `skills/image-generation/SKILL.md` | API knowledge, prompting tips, script reference |
| Command | `commands/generate-image.md` | `/generate-image` slash command |
| Status command | `commands/status.md` | `/claude-image-generation:status` slash command |
| Status script | `scripts/check-status.sh` | Per provider: key set, key accepted, model in the live model list |
| Agent | `agents/image-generator.md` | Autonomous image generation |
| Gemini script | `scripts/gemini.sh` | Gemini API call execution |
| OpenAI script | `scripts/openai.sh` | OpenAI API call execution |
| xAI script | `scripts/xai.sh` | xAI API call execution |
| OpenRouter script | `scripts/openrouter.sh` | OpenRouter chat-completions image call execution |
| Retry helper | `scripts/retry.sh` | `curl_with_retry` for transient API failures |
| Model fallback | `scripts/model-fallback.sh` | Sends the request once more with the provider's fallback model when the default is unavailable to the key, and remembers that verdict per key |
| Input image check | `scripts/input-images.sh` | Copies each `--input-image` into a private temp folder, reads the copy's type from its bytes and refuses anything that is not a PNG, JPEG, WebP or GIF file |
| Output image save | `scripts/output-image.sh` | Refuses an `--output` that already exists, decodes the image into a temp file beside it and hard-links that to the output's name, so it never replaces or follows anything at the path |
| Parallel runner | `scripts/run-all.sh` | Forks all providers in parallel as one gallery run or under one streaming pane; holds a token for the batch |
| Display utility | `scripts/display.sh` | Decides the display mode, writes gallery runs, and does multi-protocol terminal image display (iTerm2, Kitty, Sixel, tmux pane, shared streaming pane with colored banners + pending-provider waiting line) |
| Gallery server | `scripts/gallery-server.py` | Serves the gallery's runs on 127.0.0.1, starts `run-all.sh` again for a resend, and starts, reuses or replaces that server for `display.sh` |
| Gallery page | `scripts/gallery/` | The page, script and stylesheet the gallery server serves |
| API reference | `skills/image-generation/references/api-details.md` | Endpoint and payload documentation |
| Skill evals | `skills/image-generation/evals/evals.json` | Trigger prompts for the skill's eval suite |
| Hooks module | `hooks/index.ts` | Registers the `generate` tool and serves its calls through `run-all.sh` |
| Tool input rules | `hooks/argv.ts` | Checks a `generate` call's input and builds `run-all.sh`'s argv |
| Hooks manifest | `hooks/hooks.json` | Points the engine at `hooks/index.ts` |
| Tool input type | `hooks/generate-input.d.ts` | Types the `generate` tool's input for the `tool.call` hook |
| TypeScript config | `tsconfig.json` | Type-checks `hooks/` and `tests/` against `.claude/types` |
| Automated tests | `tests/` | bats test suite for all scripts; `argv.test.ts` for the tool's input rules and its refusal of an existing output file |

## Development

### Versioning

This plugin uses calendar versioning in `YYYY.M.PATCH` format (e.g., `2026.7.1`). The version is tracked in both `.claude-plugin/plugin.json` and `skills/image-generation/SKILL.md`.

### Testing

```bash
# Run all automated tests (requires bats)
./tests/run_tests.sh

# Or run bats directly
bats tests/
```

The hooks module has its own checks. Run `/plugin-types` in a Claude Code session in this directory once, to write `.claude/types`, then:

```bash
tsc -p .                 # type-check hooks/ and tests/argv.test.ts
claude plugin test .     # run tests/argv.test.ts
claude plugin validate . # what the engine sees: the module's hooks and the calls it makes
```

See [TESTING.md](TESTING.md) for the full testing guide, including manual test procedures.

### Architecture

The plugin is organized into Claude Code extension points:

```
.claude-plugin/plugin.json    -- Plugin identity and metadata
commands/                      -- Slash command definitions
agents/                        -- Autonomous agent definitions
skills/                        -- Skill knowledge and references
scripts/                       -- Shell scripts for API calls
hooks/                         -- Function hooks module registering the generate tool
tests/                         -- Automated tests (bats, argv.test.ts)
```

The scripts (`gemini.sh`, `openai.sh`, `xai.sh`, `openrouter.sh`) are standalone bash programs that handle API communication, base64 encoding/decoding, and error reporting. They are invoked by the command, agent, and skill layers. All of them source `display.sh` which auto-detects the terminal and displays generated images using the best available method.

### Terminal Image Display

This section describes `IMAGE_DISPLAY=pane`.

| Terminal | Protocol | Detection |
|----------|----------|-----------|
| iTerm2 | OSC 1337 | `TERM_PROGRAM`, `LC_TERMINAL` |
| Kitty | Kitty graphics | `TERM=xterm-kitty` |
| Ghostty | Kitty graphics | `TERM_PROGRAM=ghostty` |
| WezTerm | Kitty graphics | `TERM_PROGRAM=WezTerm` |
| Sixel terminals | Sixel (via img2sixel/chafa/magick) | Tool + terminal detection |

When running inside **tmux** (including Claude Code sessions), provider images stream into a shared pane taking 30% of the terminal's longer axis, targeting the originating pane (via `$TMUX_PANE`). Every provider generating at that moment renders into that one pane. Direct calls to `display_image` / `display_images` outside a provider run still open a pane of their own: a bottom pane (`-v` split) for a single image, a vertical side pane (`-h` split, 30% width) for several. Panes use `imgcat` (iTerm2), `kitten icat` (Kitty), or a Sixel tool depending on the outer terminal. Press **f** to reveal in Finder, **p** to open in Preview, or **Esc**/**Ctrl+D** to close.

For parallel generation, use `scripts/run-all.sh` — a single shell that joins the streaming pane, exports `DISPLAY_PANE_DIR`, forks all providers with `&`, waits, and releases the pane.

Providers find that pane through a registry entry under `$TMPDIR` keyed by tmux session and window, so a provider launched on its own joins whatever is already streaming instead of splitting a pane of its own. The entry is a directory, making `mkdir` the atomic create-once lock: the winner opens the pane and publishes it, and callers that lose the claim wait briefly for that publication. Each participant holds a token under `active/`, and whoever drops the last one retires the entry and writes `.done`, so the pane closes once — after the last provider sharing it has finished. Sequential runs each get a fresh pane; concurrency is what makes providers share one. The watcher renders per-provider colored banners (blue/gray/red/indigo) with model + timing, plus a bottom `waiting on` line naming the pending providers, clipped to the pane width. It animates until the first image renders; after that it is written once under each new block and never rewritten, since a repeated redraw erases the accumulated inline images in tmux control mode. A resize wipes those images too, so once a new pane width has held for about half a second the watcher clears the pane and replays every image and error block in the order they were drawn. Provider scripts emit status events (`querying` / `complete` / `error`) via `display_pane_status` when running under `DISPLAY_PANE_DIR`; otherwise they fall back to `display_image` for direct terminal rendering.

## Requirements

- `curl` -- HTTP requests to provider APIs
- `jq` -- JSON construction and parsing
- `base64` -- Image data encoding/decoding (included in macOS and most Linux distributions)
- `python3` 3.9 or later -- the browser gallery (without it, images show as with `IMAGE_DISPLAY=pane`)
- At least one API key: `GEMINI_API_KEY`, `OPENAI_API_KEY`, `XAI_API_KEY`, `GROK_API_KEY`, or `OPENROUTER_API_KEY`

**Optional (for Sixel image display):**
- `img2sixel` (from libsixel), `chafa`, or `magick` (ImageMagick 7) -- any one of these enables Sixel terminal display
- Install via: `brew install libsixel`, `brew install chafa`, or `brew install imagemagick`

## License

[MIT](LICENSE). The gallery's icons are others' work, credited in
[THIRD-PARTY-NOTICES](THIRD-PARTY-NOTICES).
