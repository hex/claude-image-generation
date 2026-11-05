// ABOUTME: Tests the generate tool: buildRun's input rules and argv, and the tool.call hook's
// ABOUTME: refusal of an existing output file, with the file system and process run answered here.

import { describe, expect, mock, test } from 'claude-code/testing'

import { buildRun } from '../hooks/argv'

const ROOT = '/plugin'
const DEFAULTS = { defaultProviders: 'all', outputDir: '.' }
const STAMP = '20260925-120000'
const TOOL = 'mcp__claude-image-generation__generate'

// The engine hands an fs hook the path made absolute under the working directory.
function isAt(path: string, relative: string): boolean {
  return path.endsWith(`/${relative}`)
}

describe('buildRun', () => {
  test('a blank prompt is refused', async () => {
    expect(buildRun({ prompt: '   ' }, DEFAULTS, ROOT, STAMP)).toEqual({ error: 'prompt is required' })
  })

  test('a bare prompt runs the configured providers into the output dir, one argv element per value', async () => {
    const run = buildRun({ prompt: 'a cat; rm -rf "$HOME"' }, { defaultProviders: 'all', outputDir: 'art' }, ROOT, STAMP)
    expect(run).toEqual({
      argv: [
        'bash', '/plugin/scripts/run-all.sh',
        '--mode', 'generate',
        '--prompt', 'a cat; rm -rf "$HOME"',
        '--output-base', 'art/image-20260925-120000',
        '--providers', 'gemini,openai,xai',
      ],
      outputs: [
        'art/image-20260925-120000-gemini.png',
        'art/image-20260925-120000-openai.png',
        'art/image-20260925-120000-xai.png',
      ],
    })
  })

  test('providers and outputBase given in the call win over the options', async () => {
    const run = buildRun({ prompt: 'x', providers: ['gemini', 'openrouter'], outputBase: 'out/hero' }, DEFAULTS, ROOT, STAMP)
    expect(run).toEqual({
      argv: ['bash', '/plugin/scripts/run-all.sh', '--mode', 'generate', '--prompt', 'x', '--output-base', 'out/hero', '--providers', 'gemini,openrouter'],
      outputs: ['out/hero-gemini.png', 'out/hero-openrouter.png'],
    })
  })

  test('an unknown provider is refused by name', async () => {
    expect(buildRun({ prompt: 'x', providers: ['gemini', 'dalle'] }, DEFAULTS, ROOT, STAMP))
      .toEqual({ error: 'unknown provider "dalle"; choose from gemini, openai, xai, openrouter' })
  })

  test('input images switch to edit mode, each its own --input-image', async () => {
    const run = buildRun({ prompt: 'make it blue', providers: ['openai'], outputBase: 'b', inputImages: ['my photo.png', 'ref.jpg'] }, DEFAULTS, ROOT, STAMP)
    expect(run).toEqual({
      argv: ['bash', '/plugin/scripts/run-all.sh', '--mode', 'edit', '--prompt', 'make it blue', '--output-base', 'b', '--providers', 'openai',
        '--input-image', 'my photo.png', '--input-image', 'ref.jpg'],
      outputs: ['b-openai.png'],
    })
  })

  test('an aspect ratio reaches the providers that take one, gemini and xai', async () => {
    const run = buildRun({ prompt: 'x', outputBase: 'b', aspectRatio: '16:9' }, DEFAULTS, ROOT, STAMP)
    expect(run).toEqual({
      argv: ['bash', '/plugin/scripts/run-all.sh', '--mode', 'generate', '--prompt', 'x', '--output-base', 'b', '--providers', 'gemini,openai,xai',
        '--gemini-extra', '--aspect-ratio 16:9', '--xai-extra', '--aspect-ratio 16:9'],
      outputs: ['b-gemini.png', 'b-openai.png', 'b-xai.png'],
    })
  })

  test('an aspect ratio that is not W:H is refused, since run-all splits extras on spaces', async () => {
    expect(buildRun({ prompt: 'x', aspectRatio: '16:9 --model evil' }, DEFAULTS, ROOT, STAMP))
      .toEqual({ error: 'aspectRatio must look like 16:9, got "16:9 --model evil"' })
  })

  test('an outputBase with an image extension is refused, since each provider appends its own', async () => {
    expect(buildRun({ prompt: 'x', outputBase: 'art/hero.png' }, DEFAULTS, ROOT, STAMP))
      .toEqual({ error: 'outputBase is a path without an extension; "art/hero.png" would save as "art/hero.png-gemini.png"' })
  })

  test('a field of the wrong type is refused by name rather than crashing the hook', async () => {
    expect(buildRun({ prompt: 'x', providers: 'gemini' }, DEFAULTS, ROOT, STAMP))
      .toEqual({ error: 'providers must be a list of strings, got "gemini"' })
  })

  test('a provider named twice is refused, since both runs would save to one file', async () => {
    expect(buildRun({ prompt: 'x', providers: ['openai', 'xai', 'openai'] }, DEFAULTS, ROOT, STAMP))
      .toEqual({ error: 'provider "openai" is named twice; each provider runs once and saves one file' })
  })

  test('a blank outputBase is refused rather than saving "-<provider>.png" in the working directory', async () => {
    for (const outputBase of ['', '   ']) {
      expect(buildRun({ prompt: 'x', outputBase }, DEFAULTS, ROOT, STAMP))
        .toEqual({ error: 'outputBase is blank; leave it out to use the configured folder' })
    }
  })

  test('an outputBase that names a folder is refused, since each provider appends to the base', async () => {
    expect(buildRun({ prompt: 'x', outputBase: 'art/' }, DEFAULTS, ROOT, STAMP))
      .toEqual({ error: 'outputBase names a folder, not a file; "art/" would save as "art/-gemini.png"' })
  })

  test('an aspect ratio with a zero side is refused', async () => {
    for (const aspectRatio of ['0:0', '16:0', '0:9']) {
      expect(buildRun({ prompt: 'x', aspectRatio }, DEFAULTS, ROOT, STAMP))
        .toEqual({ error: `aspectRatio must look like 16:9, got "${aspectRatio}"` })
    }
  })

  test('a control character in a path is refused by field, since a newline would forge pane status lines', async () => {
    expect(buildRun({ prompt: 'x', outputBase: 'art/hero\nopenai\tcomplete' }, DEFAULTS, ROOT, STAMP))
      .toEqual({ error: 'outputBase holds a control character (U+000A)' })
    expect(buildRun({ prompt: 'x', inputImages: ['ok.png', 'bad\u007f.png'] }, DEFAULTS, ROOT, STAMP))
      .toEqual({ error: 'inputImages[1] holds a control character (U+007F)' })
  })

  test('a NUL in the prompt is refused, while newlines and tabs pass through', async () => {
    expect(buildRun({ prompt: 'a cat\u0000', outputBase: 'b' }, DEFAULTS, ROOT, STAMP))
      .toEqual({ error: 'prompt holds a NUL character, which no program argument can carry' })
    const run = buildRun({ prompt: 'a cat\n\twith a hat', providers: ['openai'], outputBase: 'b' }, DEFAULTS, ROOT, STAMP)
    expect(run).toEqual({
      argv: ['bash', '/plugin/scripts/run-all.sh', '--mode', 'generate', '--prompt', 'a cat\n\twith a hat', '--output-base', 'b', '--providers', 'openai'],
      outputs: ['b-openai.png'],
    })
  })

  test('a prompt over 100000 bytes of UTF-8 is refused with its size; one at the limit runs', async () => {
    // Each side reports only the error or the outputs, so a failure does not print the prompt.
    const over = buildRun({ prompt: 'é'.repeat(50_001), outputBase: 'b' }, DEFAULTS, ROOT, STAMP)
    expect('error' in over ? over.error : over.outputs)
      .toEqual('prompt is 100002 bytes; the most a prompt can carry to the providers is 100000 bytes')
    const at = buildRun({ prompt: 'é'.repeat(50_000), providers: ['openai'], outputBase: 'b' }, DEFAULTS, ROOT, STAMP)
    expect('error' in at ? at.error : at.outputs).toEqual(['b-openai.png'])
  })
})

describe('generate tool', () => {
  test('an output file that already exists, or a symlink there, refuses the call before anything runs', async ($, on) => {
    mock.clock(on)
    const runs: (readonly string[])[] = []
    // A file at the openai path and a dangling symlink at the xai path, answered as the engine
    // answers them: exists follows the link and says no, stat describes the link itself.
    on('fs.exists', async ($, e) => ({ value: isAt(e.path, 'art/hero-openai.png') }))
    on('fs.stat', async ($, e) => {
      if (isAt(e.path, 'art/hero-openai.png')) return { value: { kind: 'file', size: 9, mtimeMs: 0, isLink: false } }
      if (isAt(e.path, 'art/hero-xai.png')) return { value: { kind: 'other', size: 11, mtimeMs: 0, isLink: true } }
      return { deny: `$.fs.stat(${e.path}) failed: ENOENT` }
    })
    on('process.run', async ($, e) => {
      runs.push(e.argv)
      return { value: { exitCode: 0, stdout: '', stderr: '' } }
    })

    const answer = await $.tool.call({ tool: TOOL, prompt: 'x', providers: ['gemini', 'openai', 'xai'], outputBase: 'art/hero' })

    expect(answer).toEqual({
      deny: 'art/hero-openai.png already exists\nart/hero-xai.png already exists\nnothing is overwritten; choose another outputBase',
    })
    expect(runs).toEqual([])
  })

  test('free output paths run once, and the answer lists what the run saved and what it did not', async ($, on) => {
    mock.clock(on)
    let written = ''
    const runs: (readonly string[])[] = []
    on('fs.exists', async ($, e) => ({ value: written !== '' && isAt(e.path, written) }))
    on('fs.stat', async ($, e) => written !== '' && isAt(e.path, written)
      ? { value: { kind: 'file', size: 4, mtimeMs: 0, isLink: false } }
      : { deny: `$.fs.stat(${e.path}) failed: ENOENT` })
    on('process.run', async ($, e) => {
      runs.push(e.argv)
      written = 'art/hero-openai.png'
      return { value: { exitCode: 1, stdout: '', stderr: 'xAI API returned HTTP 401: bad key' } }
    })

    const answer = await $.tool.call({ tool: TOOL, prompt: 'x', providers: ['openai', 'xai'], outputBase: 'art/hero' })

    expect(answer).toEqual({
      result: 'saved art/hero-openai.png\nmissing art/hero-xai.png\nrun-all.sh exited 1\n\nstderr:\nxAI API returned HTTP 401: bad key',
    })
    expect(runs).toEqual([['bash', expect.any(String), '--mode', 'generate', '--prompt', 'x', '--output-base', 'art/hero', '--providers', 'openai,xai']])
  })
})
