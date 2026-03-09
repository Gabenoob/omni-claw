
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

Example

    > search zig memory management
