# Streaming pane: resize re-render, auto retry, and retry-from-pane

Date: 2026-09-02. Reference implementation: claude-council (`scripts/lib/retry.sh`,
`scripts/lib/pane-watcher.sh`, `offer_retry` in `scripts/query-council.sh`).

## Why

Two four-provider runs on 2026-09-02 lost images in the streaming pane. One loss
was a pane resize: in iTerm2 tmux control mode a resize resyncs the pane to
tmux's text grid and the inline images, which live outside it, vanish or tear.
The other loss (the last image of a run, twice) did not reproduce in replays.
Separately, a provider that fails today just shows its error; the user has no
way to retry it short of re-running the whole batch, and a transient 429 or
5xx is not retried at all.

Three slices, shipped in this order. Each is independently useful.

## Slice 1: resize re-render (watcher)

The watcher loop in `display.sh` (the heredoc that becomes `watcher.sh`) ticks
every 0.12s. Add width tracking to it:

- `pane_cols` reads the pane's own tty width (`stty size < /dev/tty`, columns
  field). One function so tests can stub it on PATH.
- Per tick: if the width equals the previous reading, `stable_ticks` increments,
  otherwise it resets to 1. When the width differs from `rendered_cols` and
  `stable_ticks >= 4`, redraw. Four ticks is about half a second: a drag never
  holds a width that long, a finished resize always does.
- `redraw_all`: clear screen and scrollback (`\033[2J\033[3J\033[H`), then replay
  every provider in `seen_providers` order from the state maps: a `complete`
  provider gets its banner and `render.sh` on its path, an `error` provider
  gets the red block and its `errors/<p>.txt` lines, a `querying` or
  `retrying` provider draws nothing (the spinner line covers it). Sets
  `rendered_cols`. Because images are rendered at 30% of pane width, a redraw
  is what makes them the right size after a resize, not just visible again.
- The dismiss prompt's blocking `read -n1` becomes a loop of `read -t 1 -n1`
  so the width check runs at the prompt too (bash 3.2 `read -t` is integer
  seconds, so a resize at the prompt reflows within about a second).
- Redraw keeps `any_image_rendered` as is: the spinner stays silent after the
  first image whether or not a redraw happened.

Risk: a redraw emits several images in one burst. In July a burst rendered
nothing, but that was before the tmux passthrough wrap fix, and the burst case
has not been re-verified since. If Alex's eyes show a burst dropping images,
insert a short pause (about 0.3s) between renders inside `redraw_all`.

Tests (`tests/pane_layout.bats`, same harness as the spinner test): a stubbed
`stty` on PATH that returns width A for the first N calls and width B after;
feed one complete provider; assert the image renders twice (once at A, once
after the settle at B) and that a width that flips every tick never triggers
a redraw.

## Slice 2: auto retry (providers)

New `scripts/retry.sh`, sourced by `gemini.sh`, `openai.sh`, `xai.sh`,
`openrouter.sh` after `display.sh`.

`curl_with_retry [curl args...]` replaces `curl` at the five call sites. It
keeps the providers' contract exactly: stdout is the response body followed by
a newline and the HTTP code, so no parsing changes downstream.

- If stdin is not a tty it is spooled to a temp file once and sent with
  `--data-binary @file` on every attempt (the providers stream bodies on stdin
  today; a retry must resend them). openai's multipart edit passes `-F` and no
  stdin, which works unchanged.
- Retry on HTTP 429, 500, 502, 503, 504 and on any non-zero curl exit. Other
  4xx return immediately. Up to `IMAGE_MAX_RETRIES` (default 3) retries with
  `IMAGE_RETRY_DELAY` (default 1) seconds doubling: 1s, 2s, 4s.
- Before each retry the provider writes `display_pane_status <p> retrying
  <attempt> <model>` (the ms column carries the attempt number). The watcher's
  spinner lists a `retrying` provider as pending and appends `(retry 2/3)`.
  After the first image the spinner is silent, so a late retry is visible only
  in the final banner or error text.
- On the last failure the returned body is what the API sent, so the existing
  `provider_die` message is unchanged except the helper appends
  `after N retries` to it.
- No `--max-time` is added: real image calls run up to three minutes today.

Tests (`tests/retry.bats`): a stubbed curl on PATH that records its calls and
returns a scripted sequence of codes. Cases: 503 then 200 succeeds on the
second call; 400 fails on the first call; three 503s exhaust and return the
last body; stdin body is identical on every attempt (compare the recorded
files); attempt count reaches the pane's status file.

## Slice 3: retry from the pane (run-all and watcher)

Council's file handshake, adapted to our pane directory.

Producer side (`run-all.sh`), after the `wait` loop:

- Collect the names whose child exited non-zero (`wait "$pid"` per pid, the
  loop already runs this way).
- If any failed, `DISPLAY_PANE_DIR` is set and still a directory, and
  `DISPLAY_PANE_RETRY_WAIT` (default 45; 0 disables) is above zero: write
  `retry-offer` atomically (temp file then `mv`) containing the seconds on the
  first line and one failed name per line, then poll every 0.2s until either
  `.retry` appears, `retry-offer` is gone, the directory is gone, or the
  seconds elapse.
- On `.retry`: remove it, fork exactly those providers again with the same
  arguments through `spawn_provider`, wait, recompute `overall_status` from
  the second round. Offered once per run: a second failure only shows its
  error.
- Anything else means no retry. A vanished directory is the pane having been
  closed; it must not be an error.
- Then `__pane_release run-all` as today.

Pane side (watcher):

- Each tick, when `retry-offer` exists and `.done` does not, enter the offer
  prompt: read seconds and names from the file, then loop with `read -t 1 -n1`
  drawing `[r] retry failed (xai, openai) · [esc/ctrl-d] close 43s` on the
  bottom line with the remaining seconds, until a key, the file disappears,
  or the seconds run out.
- `r`: `mv retry-offer .retry` (a failed `mv` means the producer withdrew it;
  fall through to the loop). Clear the prompt line. For each named provider
  reset its `rendered` flag so its next `complete` or `error` draws a fresh
  banner and image. Return to the main loop.
- Esc or Ctrl-D: exit the watcher; the existing EXIT trap removes the
  directory, which the producer reads as no retry.
- Timeout: remove `retry-offer` and return to the main loop; the producer
  sees the file gone.
- The final dismiss prompt is unchanged and still gates on `.done`.

Wall time: a run with a failure lasts up to `DISPLAY_PANE_RETRY_WAIT` seconds
longer, plus one provider round if retried. `agents/image-generator.md`,
`commands/generate-image.md`, README and SKILL.md say so.

Tests:

- `tests/run-all.bats` (where the existing run-all tests live): with a stub provider script
  that exits 1 on its first call and 0 on its second, and a stub pane dir,
  assert run-all writes `retry-offer` with that name, then when the test moves
  it to `.retry`, run-all re-forks it once and exits 0; with no `.retry` and
  `DISPLAY_PANE_RETRY_WAIT=1`, run-all exits 1 after about a second; with the
  directory removed during the wait, run-all exits 1 without error output.
- `tests/pane_layout.bats`: feed a `retry-offer` and `r` on stdin, assert the
  prompt text and that `.retry` exists; feed Esc, assert the watcher exits and
  the directory is gone; feed nothing with 1 second, assert `retry-offer` is
  removed and the watcher continues to `.done`.

## Out of scope

- Retrying from the pane after the run has returned.
- Any change to how images are normalized or sized.
- A shell-side proof that an image rendered. There is none in control mode;
  Alex's eyes remain the acceptance test for anything visual.
