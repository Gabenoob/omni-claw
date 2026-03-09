
# Omni-Claw

Omni-Claw is an experimental Zig AI agent runtime that integrates
with Omni-RLM from the Open Model Initiative.

Omni-RLM:
https://github.com/Open-Model-Initiative/Omni-RLM/

This project demonstrates how Omni-Claw can use Omni-RLM as its reasoning
and planning backend.

## Features

- Omni-RLM reasoning engine integration (HTTP API)
- WASM sandbox tool execution
- Omni-RLM planner integration with HTTP fallback behavior
- Interactive startup prompt to configure LLM endpoint/API key (hosted or local)
- Plugin tool architecture via JSON manifests
- WASM tool execution through Wasmtime
- CLI REPL interface with interactive commands (`exit`/`quit`)
- In-process vector cosine similarity utility

## Architecture

User Prompt
    ↓
Omni-RLM Planner
    ↓
Tool Selection
    ↓
WASM Tool Execution
    ↓
Memory Storage

## Running

Requirements

- Zig 0.15.1 (latest available patch in the 0.15 line, pinned via `.mise.toml`)
- Omni-RLM server running (optional; planner has local fallback)
- Wasmtime

Build

    mise install
    mise exec -- zig build

Run

    mise exec -- ./zig-out/bin/omniclaw

On startup, Omni-Claw now optionally asks you to configure an LLM planner connection:
- Local endpoint (default: `http://127.0.0.1:11435`)
- Hosted API endpoint + optional API key

You can still use environment variables (`OMNI_RLM_URL`, `OMNI_RLM_API_KEY`) when preferred.

Interactive prompt example (hosted API)

```text
$ mise exec -- ./zig-out/bin/omniclaw
OmniClaw-Zig-RLM runtime started
Configure LLM connection now? [y/N]: y
Use hosted LLM API? [y/N] (No = local endpoint): y
LLM planner base URL (without /plan): https://api.openai.com/v1
Hosted API key (leave empty to skip): sk-your-key
LLM connection configured.
> search zig memory management
```

Interactive prompt example (local API)

```text
$ mise exec -- ./zig-out/bin/omniclaw
OmniClaw-Zig-RLM runtime started
Configure LLM connection now? [y/N]: y
Use hosted LLM API? [y/N] (No = local endpoint): n
LLM planner base URL (without /plan): http://127.0.0.1:11435
LLM connection configured.
> search zig memory management
```

Example

    > search zig memory management
