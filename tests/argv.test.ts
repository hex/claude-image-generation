import { describe, expect, test } from 'claude-code/testing'

import { buildRun } from '../hooks/argv'

const ROOT = '/plugin'
const DEFAULTS = { defaultProviders: 'all', outputDir: '.' }
const STAMP = '20260925-120000'

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
})
