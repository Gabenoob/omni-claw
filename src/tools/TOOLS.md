# Omni-Claw Tool Registry

This document lists all available tools in the Omni-Claw system.

## Available Tools

| Tool Name | Category  | Description                                         | Doc Path                 |
| --------- | --------- | --------------------------------------------------- | ------------------------ |
| exec      | system    | Execute bash commands in the current environment    | src/tools/docs/exec.md   |
| finish    | control   | Provide final answer and complete the task          | src/tools/docs/finish.md |
| rlm       | reasoning | Process ultra-long material with grounded reasoning | src/tools/docs/rlm.md    |

---

## Tool Selection Guide

When analyzing a user request, consider:

1. What does the user want to accomplish?
2. Which tool's capabilities match this need?
3. Select the most appropriate tool from the table above.

## Tool Categories

- **system**: Tools that interact with the system (exec)
- **control**: Tools that control execution flow (finish)
- **reasoning**: Tools that perform grounded reasoning over long material (rlm)

## Tool Parameters

### exec

- `arguments[0]`: the shell command to run (e.g. `"ls"`, `"cat file.txt"`, `"grep -r foo ."`)

### finish

- `arguments[0]`: the final answer or response text to return to the user

### rlm

- `arguments[0]`: **root_question** — the precise question or task, including desired output format. Be specific (e.g. "Based on this API reference, explain how X works in 3 sentences." or "Return a minimal executable Zig example for Y. Return code only, no explanation.")
- `arguments[1]`: **material source** — a file path to the long document to reason over (e.g. `"API_reference.md"`, `"logs/report.txt"`)

## Response Format

Respond with ONLY a JSON object:

{"tool":"<tool_name>","arguments":["<arg0>","<arg1>",...]}
