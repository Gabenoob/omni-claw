# Omni-Claw Tool Registry

This document lists all available tools in the Omni-Claw system.

## Available Tools

| Tool Name | Category | Description | Doc Path |
|-----------|----------|-------------|----------|
| exec | system | Execute bash commands in the current environment | tools/docs/exec.md |
| finish | control | Provide final answer and complete the task | tools/docs/finish.md |

---

## Tool Selection Guide

When analyzing a user request, consider:

1. What does the user want to accomplish?
2. Which tool's capabilities match this need?
3. Select the most appropriate tool from the table above.

## Tool Categories

- **system**: Tools that interact with the system (exec)
- **control**: Tools that control execution flow (finish)

## Response Format

Respond with ONLY a JSON object:

 {"tool":"<tool_name>","argument":"<brief explanation or arguments>"}

