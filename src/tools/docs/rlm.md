# rlm

Use this tool to process ultra-long material from a file path with grounded reasoning.

The tool reads the file content internally, traverses it chunk by chunk, maintains a running summary, and returns a final answer grounded in the full material.

## Purpose

Use rlm when the answer should come from a large file that is too long to reliably reason over in a single short context.

This tool is designed for evidence-grounded reasoning over long material.

## Argument Convention

The tool arguments must follow this order:

- arguments[0]:
  root_question

- arguments[1]:
  material_path

Example:

```json
{
  "tool": "rlm",
  "arguments": [
    "Based on this API reference, explain how buildFinalPrompt works in 3 concise sentences.",
    "API_reference.md"
  ]
}
```
