// ABOUTME: Declares the generate tool's input on the engine's MCP tool table, so a tool.call
// ABOUTME: hook on it is typed; the JSON schema in index.ts is what the model is held to.

export {}

declare module 'claude-code' {
  interface McpToolInputs {
    'mcp__claude-image-generation__generate': {
      prompt: string
      providers?: string[]
      outputBase?: string
      inputImages?: string[]
      aspectRatio?: string
    }
  }
}
