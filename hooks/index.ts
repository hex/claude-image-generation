// ABOUTME: Registers the generate tool, which runs scripts/run-all.sh from a typed input
// ABOUTME: and answers with the files it saved; the defaults come from the plugin's /config rows.

import type { Register } from 'claude-code'

import { buildRun } from './argv'

const TOOL = 'mcp__claude-image-generation__generate'
// run-all.sh can wait on a slow provider for minutes and then hold a 45 s retry offer open;
// ten minutes is the most $.process.run allows.
const RUN_TIMEOUT_MS = 600_000

const DESCRIPTION = `Generate or edit images with Gemini, OpenAI, xAI and OpenRouter in parallel. \
Each provider saves <outputBase>-<provider>.png; the result lists the files that exist. \
Omit providers and outputBase to use the person's /config defaults. \
Providers: gemini (gemini-3-pro-image, professional assets, many reference images), \
openai (gpt-image-2, text rendering, transparent backgrounds), \
xai (grok-imagine-image-2.0, prompt revision, flat per-image pricing), \
openrouter (google/gemini-3.1-flash-image by default, opt-in). \
Pass inputImages to edit instead of generate. aspectRatio (W:H) applies to gemini and xai only.`

const INPUT_SCHEMA = {
  type: 'object',
  properties: {
    prompt: { type: 'string', description: 'What to draw, or how to change the input images.' },
    providers: {
      type: 'array',
      items: { type: 'string', enum: ['gemini', 'openai', 'xai', 'openrouter'] },
      description: 'Which providers to run; omitted, the configured default.',
    },
    outputBase: {
      type: 'string',
      description: 'Path without extension, e.g. "art/hero"; omitted, <configured dir>/image-<timestamp>.',
    },
    inputImages: { type: 'array', items: { type: 'string' }, description: 'Images to edit; switches to edit mode.' },
    aspectRatio: { type: 'string', description: 'W:H such as 16:9; gemini and xai only.' },
  },
  required: ['prompt'],
  additionalProperties: false,
}

export const register: Register = (on, options) => {
  const defaults = {
    defaultProviders: stringOption(options, 'defaultProviders'),
    outputDir: stringOption(options, 'outputDir'),
  }

  on('session.start', async ($, e, next) => {
    await $.tool.register({ name: 'generate', description: DESCRIPTION, inputSchema: INPUT_SCHEMA })
    return next(e)
  })

  on('tool.call', { tool: TOOL }, async ($, e) => {
    const run = buildRun(e, defaults, $.plugin.root, timestamp(await $.clock.now()))
    if ('error' in run) return { deny: run.error }

    // Outside a tmux pane the providers draw inline images to /dev/tty, which is Claude Code's own screen.
    const { exitCode, stdout, stderr } = await $.process.run(run.argv, {
      timeoutMs: RUN_TIMEOUT_MS,
      env: { DISPLAY_IMAGE_TARGET: '/dev/null' },
    })

    const saved: string[] = []
    const missing: string[] = []
    for (const path of run.outputs) {
      ;((await $.fs.exists(path)) ? saved : missing).push(path)
    }
    const lines = [
      ...saved.map(path => `saved ${path}`),
      ...missing.map(path => `missing ${path}`),
      `run-all.sh exited ${exitCode}`,
    ]
    if (stdout.trim() !== '') lines.push('', stdout.trim())
    if (stderr.trim() !== '') lines.push('', 'stderr:', stderr.trim())
    const text = lines.join('\n')
    if (saved.length === 0) return { deny: text }
    return { result: text }
  })
}

// plugin.json declares both fields as strings with defaults, so the engine always fills them in.
function stringOption(options: Parameters<Register>[1], field: string): string {
  const value = options[field]
  if (typeof value !== 'string') throw new Error(`option ${field} should be a string from plugin.json userConfig, got ${JSON.stringify(value)}`)
  return value
}

function timestamp(ms: number): string {
  const d = new Date(ms)
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}-${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`
}
