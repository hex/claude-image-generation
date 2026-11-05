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
// A prompt travels as one program argument at every step down to curl, and macOS caps a
// program's arguments plus environment at 1048576 bytes. openai.sh sends its JSON body as an
// argument, where a control character escapes to six bytes, so the largest prompt measured to
// get through was 173059 bytes. This keeps clear of that, and of Linux's 131072-byte cap on
// any single argument.
const PROMPT_LIMIT_BYTES = 100_000
// Below U+0020, and DEL: a newline in a path would split the pane's one-line status records,
// and a NUL cannot be passed in a program argument at all.
const CONTROL_CHARACTER = /[\u0000-\u001f\u007f]/

export function buildRun(raw: Record<string, unknown>, options: GenerateOptions, root: string, stamp: string): Run {
  const input = parseInput(raw)
  if ('error' in input) return input

  const providers = input.providers?.length
    ? input.providers
    : options.defaultProviders === 'all' ? ALL : [options.defaultProviders]
  const unknown = providers.find(p => !PROVIDERS.includes(p))
  if (unknown !== undefined) return { error: `unknown provider "${unknown}"; choose from ${PROVIDERS.join(', ')}` }
  const repeated = providers.find((p, i) => providers.indexOf(p) !== i)
  if (repeated !== undefined) return { error: `provider "${repeated}" is named twice; each provider runs once and saves one file` }
  const ratio = input.aspectRatio
  if (ratio !== undefined && !/^[1-9]\d*:[1-9]\d*$/.test(ratio)) return { error: `aspectRatio must look like 16:9, got "${ratio}"` }
  if (input.outputBase?.trim() === '') return { error: 'outputBase is blank; leave it out to use the configured folder' }
  const base = input.outputBase ?? `${options.outputDir}/image-${stamp}`
  if (/\.(png|jpe?g|webp)$/i.test(base)) {
    return { error: `outputBase is a path without an extension; "${base}" would save as "${base}-${providers[0]}.png"` }
  }
  if (base.endsWith('/')) return { error: `outputBase names a folder, not a file; "${base}" would save as "${base}-${providers[0]}.png"` }
  const baseControl = controlCharacter(base)
  if (baseControl !== undefined) return { error: `outputBase holds a control character (${baseControl})` }
  const images = input.inputImages
  for (const [i, image] of images.entries()) {
    const imageControl = controlCharacter(image)
    if (imageControl !== undefined) return { error: `inputImages[${i}] holds a control character (${imageControl})` }
  }
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
  if (prompt.includes('\u0000')) return { error: 'prompt holds a NUL character, which no program argument can carry' }
  const promptBytes = new TextEncoder().encode(prompt).length
  if (promptBytes > PROMPT_LIMIT_BYTES) {
    return { error: `prompt is ${promptBytes} bytes; the most a prompt can carry to the providers is ${PROMPT_LIMIT_BYTES} bytes` }
  }
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

// The first control character in the value as U+XXXX, or undefined when it has none.
function controlCharacter(value: string): string | undefined {
  const found = CONTROL_CHARACTER.exec(value)?.[0]
  return found === undefined ? undefined : `U+${found.charCodeAt(0).toString(16).toUpperCase().padStart(4, '0')}`
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
