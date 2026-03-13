# Omni-Claw

Omni-Claw is an experimental Zig-based AI agent runtime that integrates with Omni-RLM (Open Model Initiative's Reasoning Language Model) for planning and reasoning capabilities.

**Version**: 0.15.2  
**License**: Apache License 2.0

## Overview

Omni-Claw provides an AI agent architecture where:
- User prompts are processed by an Omni-RLM planner via HTTP API
- The planner selects appropriate tools based on the prompt
- Tools execute via a tool registry (bash execution via `exec` tool)
- Results are returned to the user via an interactive REPL

## Features

- **LLM-powered planning**: Integrates with OpenAI-compatible APIs (OpenAI, Moonshot, etc.) or local endpoints (Ollama)
- **Interactive REPL**: Full-featured terminal interface with line editing, history (↑/↓), and UTF-8 support
- **Tool registry**: Extensible tool system with built-in `exec` and `finish` tools
- **Automatic configuration**: Interactive setup on first run with persistent config storage
- **Secure API key handling**: API keys are masked in display and stored separately

## Architecture

```
src/
├── main.zig              # Entry point
├── omniclaw.zig          # Public API exports
├── core/
│   └── runtime.zig       # Runtime orchestration + configuration
├── agent/
│   ├── mod.zig           # Agent coordinator
│   └── planner.zig       # LLM-based planner with tool selection
├── tools/
│   ├── registry.zig      # Tool registry implementation
│   ├── tools.md          # Tool list (index for planner)
│   └── docs/             # Individual tool documentation
└── channel/
    └── repl.zig          # Interactive REPL interface
```

### Data Flow

```
User Input → REPL → Agent.runPrompt() → Planner.plan()
                                              ↓
                                      Read src/tools/tools.md
                                              ↓
                                      LLM API (Omni-RLM) → JSON Plan
                                              ↓
                                      Tool Registry Lookup
                                              ↓
                                      Tool Execution (bash or final answer)
                                              ↓
                                        Output Result
```

## Requirements

- Zig 0.15.1 (pinned via `.mise.toml`)
- [mise](https://mise.jdx.dev/) (recommended for Zig version management)

## Building

```bash
# Install Zig via mise
mise install

# Build the project
mise exec -- zig build

# Or directly if you have Zig 0.15.1 installed
zig build
```

## Running

```bash
# Run the binary
mise exec -- ./zig-out/bin/omniclaw

# Or use the build run command
mise exec -- zig build run
```

### First Run Configuration

On first startup, Omni-Claw will guide you through LLM configuration:

```text
$ mise exec -- ./zig-out/bin/omniclaw
OmniClaw-Zig-RLM runtime started
No configuration found in .omniclaw/
Use existing .env file from current directory? [y/N]: n

=== LLM Configuration ===
Let's set up your LLM connection.

Select LLM provider type:
  1. Local/Ollama (default: http://127.0.0.1:11435)
  2. OpenAI-compatible API (OpenAI, Moonshot, etc.)
Choice [1/2]: 2

LLM base URL (without /chat/completions):
  Default: https://api.openai.com/v1
  Enter URL (or press Enter for default): https://api.moonshot.cn/v1

API key (required for hosted APIs): sk-your-key

Model name:
  Default: gpt-4
  Enter model (or press Enter for default): kimi-k2.5

Daytona API key (optional, press Enter to skip):

✓ Configuration saved to .omniclaw/.env
```

Configuration is stored in `.omniclaw/.env` and persists across sessions.

## REPL Commands

| Command | Description |
|---------|-------------|
| `<prompt>` | Any text is sent to the planner for tool selection and execution |
| `/config` | Display current LLM configuration (API keys masked) |
| `/tools` | Display list of available tools |
| `/exit` or `/quit` | Exit the REPL |

### REPL Shortcuts

| Key | Action |
|-----|--------|
| `↑` / `↓` | Navigate command history |
| `←` / `→` | Move cursor |
| `Ctrl+A` / `Ctrl+E` | Move to start/end of line |
| `Ctrl+U` | Clear entire line |
| `Ctrl+K` | Clear from cursor to end |
| `Backspace` / `Delete` | Delete characters |
| `Ctrl+C` / `Ctrl+D` | Exit REPL |

## Example Session

```text
$ mise exec -- ./zig-out/bin/omniclaw
OmniClaw-Zig-RLM runtime started
Found existing configuration at .omniclaw/.env
Configuration loaded successfully.

> ls -la
$ ls -la
total 128
drwxr-xr-x  12 user  staff   384 Mar 13 14:30 .
drwxr-xr-x   5 user  staff   160 Mar 13 14:00 ..
...

> /config

=== Current Configuration ===
LLM Provider: OpenAI-compatible API
Base URL: https://api.moonshot.cn/v1
API Key: sk-EF...DuO
Model: kimi-k2.5
=============================

> /tools

=== Available Tools ===

  • exec - Execute bash commands in the current environment
  • finish - Provide final answer and complete the task

=======================

> /exit
```

## Tool System

Omni-Claw uses a tool registry system to manage available tools.

### Built-in Tools

| Tool | Description |
|------|-------------|
| `exec` | Execute bash commands in the current environment (ls, cat, grep, etc.) |
| `finish` | Provide final answer and complete the task (for explanations, analysis) |

### Adding Custom Tools

1. **Update `src/tools/tools.md`** - Add tool to the list
2. **Create `src/tools/docs/<tool>.md`** - Add detailed documentation
3. **Edit `src/tools/registry.zig`**:
   - Implement executor function
   - Register in `createDefaultRegistry()`

## Configuration

Configuration is stored in `.omniclaw/.env`:

```bash
# Omni-RLM backend configuration
OMNIRLM_BASE_URL=https://api.moonshot.cn/v1
OMNIRLM_API_KEY=sk-your-key
OMNIRLM_MODEL_NAME=kimi-k2.5
DAYTONA_API_KEY=           # Optional
```

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `OMNIRLM_BASE_URL` | Base URL for LLM API | `http://127.0.0.1:11435` |
| `OMNIRLM_API_KEY` | API key for hosted services | (none) |
| `OMNIRLM_MODEL_NAME` | Model name | `kimi-k2.5` |
| `DAYTONA_API_KEY` | Daytona sandbox API key | (none) |

## Testing

```bash
# Run all tests
mise exec -- zig build test

# Test with filter
mise exec -- zig build test -- -Dtest-filter=<filter>
```

## Public API

```zig
const omniclaw = @import("omniclaw");

var runtime = try omniclaw.Runtime.init(allocator);
defer runtime.deinit();
try runtime.start();
```

See `src/omniclaw.zig` for the full public API exports.

## Security Considerations

- **API Keys**: Stored in `.omniclaw/.env` (gitignored). Keys are masked when displayed.
- **Bash Execution**: The `exec` tool has full system access. Use with caution.
- **Configuration**: `.env` and `.omniclaw/.env` are gitignored to prevent credential leaks.

## Dependencies

- [Omni-RLM](https://github.com/Open-Model-Initiative/Omni-RLM) - Reasoning language model interface

## License

Apache License 2.0 - See [LICENSE](LICENSE) for details.
