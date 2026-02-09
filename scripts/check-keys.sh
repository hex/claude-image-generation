#!/usr/bin/env bash
# ABOUTME: Checks for required API keys at session start.
# ABOUTME: Reports which image generation providers are available.

missing=()
available=()

if [[ -n "${GEMINI_API_KEY:-}" ]]; then
  available+=("Gemini")
else
  missing+=("GEMINI_API_KEY")
fi

if [[ -n "${OPENAI_API_KEY:-}" ]]; then
  available+=("OpenAI")
else
  missing+=("OPENAI_API_KEY")
fi

if [[ -n "${XAI_API_KEY:-}" ]]; then
  available+=("xAI")
else
  missing+=("XAI_API_KEY")
fi

message=""

if [[ ${#available[@]} -gt 0 ]]; then
  message="Image generation available: ${available[*]}."
fi

if [[ ${#missing[@]} -gt 0 ]]; then
  message="${message} Missing API keys: ${missing[*]}. Set them as environment variables to enable those providers."
fi

if [[ ${#available[@]} -eq 0 ]]; then
  message="No image generation API keys found. Set GEMINI_API_KEY, OPENAI_API_KEY, and/or XAI_API_KEY to enable image generation."
fi

jq -n --arg msg "$message" '{
  "continue": true,
  "suppressOutput": false,
  "systemMessage": $msg
}'
