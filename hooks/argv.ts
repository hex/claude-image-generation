// ABOUTME: Turns a generate tool call plus the plugin's options into the argv for run-all.sh,
// ABOUTME: or the reason the call is refused. Pure, so every rule is testable without a run.

export type GenerateOptions = {
  defaultProviders: string
  outputDir: string
}

export type Run = { argv: string[]; outputs: string[] } | { error: string }

type GenerateInput = {
  prompt: string
  providers: string[] | undefined
  outputBase: string | undefined
  inputImages: string[]
  aspectRatio: string | undefined
}

// What run-all.sh runs when no provider is named; openrouter is opt-in there too.
const ALL = ['gemini', 'openai', 'xai']
const PROVIDERS = [...ALL, 'openrouter']
// The providers whose scripts take --aspect-ratio; openai sizes by --size, openrouter by model.
const TAKES_ASPECT_RATIO = ['gemini', 'xai']

export function buildRun(raw: Record<string, unknown>, options: GenerateOptions, root: string, stamp: string): Run {
  const input = parseInput(raw)
  if ('error' in input) return input

  const providers = input.providers?.length
    ? input.providers
    : options.defaultProviders === 'all' ? ALL : [options.defaultProviders]
  const unknown = providers.find(p => !PROVIDERS.includes(p))
  if (unknown !== undefined) return { error: `unknown provider "${unknown}"; choose from ${PROVIDERS.join(', ')}` }
  const ratio = input.aspectRatio
  if (ratio !== undefined && !/^\d+:\d+$/.test(ratio)) return { error: `aspectRatio must look like 16:9, got "${ratio}"` }
  const base = input.outputBase ?? `${options.outputDir}/image-${stamp}`
  if (/\.(png|jpe?g|webp)$/i.test(base)) {
    return { error: `outputBase is a path without an extension; "${base}" would save as "${base}-${providers[0]}.png"` }
  }
  const images = input.inputImages
  const argv = [
    'bash', `${root}/scripts/run-all.sh`,
    '--mode', images.length > 0 ? 'edit' : 'generate',
    '--prompt', input.prompt,
    '--output-base', base,
    '--providers', providers.join(','),
    ...images.flatMap(image => ['--input-image', image]),
    ...(ratio === undefined ? [] : providers
      .filter(p => TAKES_ASPECT_RATIO.includes(p))
      .flatMap(p => [`--${p}-extra`, `--aspect-ratio ${ratio}`])),
  ]
  return { argv, outputs: providers.map(p => `${base}-${p}.png`) }
}

// The model writes the call's input, so every field is checked for its type here, once.
function parseInput(raw: Record<string, unknown>): GenerateInput | { error: string } {
  const prompt = raw.prompt
  if (typeof prompt !== 'string' || prompt.trim() === '') return { error: 'prompt is required' }
  const providers = stringList(raw, 'providers')
  if (isError(providers)) return providers
  const inputImages = stringList(raw, 'inputImages')
  if (isError(inputImages)) return inputImages
  const outputBase = optionalString(raw, 'outputBase')
  if (isError(outputBase)) return outputBase
  const aspectRatio = optionalString(raw, 'aspectRatio')
  if (isError(aspectRatio)) return aspectRatio
  return { prompt, providers, inputImages: inputImages ?? [], outputBase, aspectRatio }
}

function isError<T>(value: T | { error: string }): value is { error: string } {
  return typeof value === 'object' && value !== null && 'error' in value
}

function stringList(raw: Record<string, unknown>, field: string): string[] | undefined | { error: string } {
  const value = raw[field]
  if (value === undefined) return undefined
  if (Array.isArray(value) && value.every(v => typeof v === 'string')) return value
  return { error: `${field} must be a list of strings, got ${JSON.stringify(value)}` }
}

function optionalString(raw: Record<string, unknown>, field: string): string | undefined | { error: string } {
  const value = raw[field]
  if (value === undefined || typeof value === 'string') return value
  return { error: `${field} must be a string, got ${JSON.stringify(value)}` }
}
