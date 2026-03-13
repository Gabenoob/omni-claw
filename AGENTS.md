# Omni-Claw Agent Guide

Omni-Claw is an experimental Zig-based AI agent runtime that integrates with Omni-RLM (Open Model Initiative's Reasoning Language Model) for planning and reasoning capabilities.

## Project Overview

Omni-Claw provides an AI agent architecture where:
- User prompts are processed by an Omni-RLM planner via HTTP API
- The planner selects appropriate tools based on the prompt
- Tools execute via a tool registry (bash execution via `exec` tool)
- Results are returned to the user via an interactive REPL

**Repository**: Standalone Zig project  
**Version**: 0.15.2  
**License**: Apache License 2.0  
**Language**: Zig 0.15.1

## Technology Stack

- **Language**: Zig 0.15.1 (pinned via `.mise.toml`)
- **Build System**: Zig build system (`build.zig` + `build.zig.zon`)
- **External Dependencies**:
  - `Omni_RLM` (v0.1.0) - Planning/reasoning library from Open-Model-Initiative
- **HTTP Client**: Via Omni-RLM library (OpenAI-compatible API)
- **Tool Execution**: Direct bash execution (via `std.process.Child`)

## Architecture

```
src/
├── main.zig              # Entry point - initializes runtime
├── omniclaw.zig          # Root module - public API exports
├── test.zig              # Test module - verifies compilation
├── core/
│   └── runtime.zig       # Runtime orchestration + configuration
├── agent/
│   ├── mod.zig           # Agent coordinator (planner + registry)
│   └── planner.zig       # LLM-based planner with tool selection
├── tools/
│   ├── registry.zig      # Tool registry implementation
│   ├── tools.md          # Tool list (index for planner)
│   └── docs/             # Individual tool documentation
│       ├── exec.md       # Bash execution tool docs
│       └── finish.md     # Final answer tool docs
└── channel/
    └── repl.zig          # Interactive REPL interface
```

### Module Organization

| Module | Purpose | Key Types/Functions |
|--------|---------|---------------------|
| `omniclaw.zig` | Public API root | `Runtime`, `Config`, `Agent`, `Planner`, `Plan`, `ToolRegistry`, `Tool`, `ToolExecutor`, `VERSION` |
| `core/runtime.zig` | Core runtime | `Runtime` (init, deinit, start), `Config`, configuration handling |
| `agent/mod.zig` | Agent coordinator | `Agent` (init, deinit, configureLlmConnection, runPrompt, printConfig, printTools) |
| `agent/planner.zig` | LLM-based planning | `Planner`, `Plan`, tool selection via LLM API |
| `tools/registry.zig` | Tool definitions | `ToolRegistry`, `Tool`, `ToolExecutor`, `createDefaultRegistry` |
| `channel/repl.zig` | User interface | `Repl`, `run(agent)` - interactive REPL loop |

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

## Build Commands

**Prerequisites**:
- [mise](https://mise.jdx.dev/) (for Zig version management)
- Zig 0.15.1

**Install Zig**:
```bash
mise install
```

**Build**:
```bash
mise exec -- zig build
```

**Run**:
```bash
mise exec -- ./zig-out/bin/omniclaw
# Or:
mise exec -- zig build run
```

**Test**:
```bash
mise exec -- zig build test
```

**Direct build without mise** (if you have Zig 0.15.1 installed):
```bash
zig build
zig build run    # Build and run
zig build test   # Run tests
```

## Configuration

Configuration is stored in `.omniclaw/.env`. The runtime automatically manages this directory and file.

### First Run / Configuration Flow

On startup, the runtime checks for existing configuration:

```
OmniClaw-Zig-RLM runtime started
No configuration found in .omniclaw/
Use existing .env file from current directory? [y/N]:
```

**Option 1: Use existing `.env` file**
- If you have a `.env` file in the current directory, answer `y`
- The runtime will copy it to `.omniclaw/.env`

**Option 2: Create new configuration (interactive)**
- Answer `n` to create a fresh configuration
- The runtime will guide you through:

```
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

### Configuration File Format

The `.omniclaw/.env` file contains:

```bash
# Omni-RLM backend configuration
# Auto-generated by Omni-Claw runtime

OMNIRLM_BASE_URL=https://api.moonshot.cn/v1

OMNIRLM_API_KEY=sk-your-key

# Model name served by your backend
OMNIRLM_MODEL_NAME=kimi-k2.5

# Daytona API key (optional)
DAYTONA_API_KEY=
```

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `OMNIRLM_BASE_URL` | Base URL for LLM API endpoint | `http://127.0.0.1:11435` |
| `OMNIRLM_API_KEY` | API key for hosted LLM services | (none) |
| `OMNIRLM_MODEL_NAME` | Model name to use | `kimi-k2.5` |
| `DAYTONA_API_KEY` | Daytona sandbox API key | (none) |

## REPL Commands

When running Omni-Claw, you enter an interactive REPL:

| Command | Description |
|---------|-------------|
| `<prompt>` | Any text is sent to the planner for tool selection and execution |
| `/config` | Display current LLM configuration |
| `/tools` | Display list of available tools |
| `/exit` or `/quit` | Exit the REPL |

Example session:
```
OmniClaw-Zig-RLM runtime started
Found existing configuration at .omniclaw/.env
Configuration loaded successfully.

> ls -la
$ ls -la
[directory listing...]

> /config

=== Current Configuration ===
LLM Provider: OpenAI-compatible API
Base URL: https://api.moonshot.cn/v1
API Key: sk-EF...DuO
Model: moonshot-v1-8k
=============================

> /tools

=== Available Tools ===

  • exec - Execute bash commands in the current environment
  • finish - Provide final answer and complete the task

=======================

> /exit
```

## Code Style Guidelines

- **Imports**: Standard library first (`std`), then project modules, then external dependencies
- **Module Structure**: Each logical component has its own directory with entry point file
- **Naming Conventions**:
  - `snake_case` for functions, variables, and files
  - `PascalCase` for structs, types, and public functions
  - `UPPER_SNAKE_CASE` for constants
- **Error Handling**: Use Zig's error union pattern (`try`, `catch`, `errdefer`)
- **Memory Management**: Use `GeneralPurposeAllocator` at top level; pass `Allocator` to components
- **Comments**: Doc comments (`//!` and `///`) for public API; minimal inline comments

## Testing Instructions

The project uses Zig's built-in test framework:

**Run all tests**:
```bash
mise exec -- zig build test
```

**Test with filter**:
```bash
mise exec -- zig build test -- -Dtest-filter=<filter>
```

The `src/test.zig` module imports all other modules to verify compilation:
- Core modules: runtime
- Agent modules: agent/mod, planner
- Tool modules: registry
- Channel: repl
- Root module: omniclaw
- Main entry point

Manual testing in the REPL:
- `ls -la` - Tests exec tool (bash command)
- `pwd` - Tests exec tool
- `cat filename` - Tests file reading via exec
- `/config` - Display current LLM configuration
- `/tools` - Display available tools
- `/exit` or `/quit` - Exit the REPL

## Tool System

Omni-Claw uses a tool registry system (`src/tools/registry.zig`) to manage available tools.

### Tool Documentation Structure

Tool documentation is split into two levels:

1. **Tool List** (`src/tools/tools.md`) - Contains only the list of available tools with brief descriptions
2. **Tool Details** (`src/tools/docs/<tool>.md`) - Individual markdown files with detailed documentation

The planner reads `tools.md` to understand available tools, then generates a plan with tool name and argument.

### Built-in Tools

**`exec`** - Execute bash commands in the current environment
- Executes any valid bash command via `std.process.Child`
- Has full access to the host system (use with caution)
- Examples: `ls`, `cat`, `grep`, `python`, `curl`, etc.
- Full documentation in `src/tools/docs/exec.md`

**`finish`** - Provide final answer and complete the task
- Used when no system commands are needed
- Provides direct answers to questions
- For explanations, analysis, or conversational responses
- Full documentation in `src/tools/docs/finish.md`

### Tool Registry Structure

```zig
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    executor: ToolExecutor,
};

pub const ToolExecutor = *const fn (allocator: std.mem.Allocator, argument: []const u8) anyerror!void;
```

### Adding New Tools

To add a new tool:

1. **Update `src/tools/tools.md`** - Add tool to the table:
```markdown
| new_tool | category | Description here | src/tools/docs/new_tool.md |
```

2. **Create `src/tools/docs/new_tool.md`** with detailed documentation

3. **Open `src/tools/registry.zig`** and add executor function:
```zig
fn newToolExecutor(allocator: std.mem.Allocator, argument: []const u8) !void {
    // Implement tool logic here
}
```

4. **Register it in `createDefaultRegistry`**:
```zig
try registry.register(.{
    .name = "new_tool",
    .description = "Description",
    .executor = newToolExecutor,
});
```

## Planner System

The planner (`src/agent/planner.zig`) uses an LLM to select tools based on user input:

1. **System Prompt**: Built dynamically from `src/tools/tools.md`
2. **Request Format**: OpenAI-compatible chat completions API
3. **Response Format**: JSON with `tool` and `argument` fields
4. **Model Handler**: Configured with base_url, api_key, model_name

Example plan response:
```json
{
    "tool": "exec",
    "argument": "ls -la"
}
```

## Security Considerations

1. **API Keys**: 
   - The `.env` file contains sensitive credentials
   - `.omniclaw/.env` and `.env` are gitignored
   - Never commit actual API keys to version control

2. **Bash Execution**: 
   - The `exec` tool has full system access via `bash -c`
   - Be careful with destructive commands (`rm -rf`, `dd`, etc.)
   - Commands run with the privileges of the Omni-Claw process

3. **Configuration Display**:
   - API keys are masked when displayed via `/config`
   - Only first 4 and last 4 characters shown: `sk-EF...DuO`

4. **Input Validation**:
   - Prompt length is implicitly limited by buffer sizes
   - Tool names are validated against registry before execution

## Dependencies

### `build.zig.zon`

```zig
.{
    .name = .omni_claw,
    .version = "0.15.2",
    .dependencies = .{
        .Omni_RLM = .{
            .url = "https://github.com/Open-Model-Initiative/Omni-RLM/archive/refs/tags/v_temp.tar.gz",
            .hash = "Omni_RLM-0.0.0-wUWNVFpjAgCSN4UJ1GaQ_iZpq6bUYpwMPl1Dm3EICPpN",
        },
    },
    .paths = .{""},
    .fingerprint = 0xbad50a515fdbda8a,
}
```

### External Library: Omni-RLM

Provides:
- `RLM` - Reasoning language model interface
- `RLMLogger` - Logging utilities
- `ModelHandler` - HTTP API client for LLM requests
- `Message` - Chat message structure

## Common Development Tasks

**Add a new tool**:
1. Open `src/tools/registry.zig`
2. Implement a new executor function
3. Register it in `createDefaultRegistry()`
4. Update `src/tools/tools.md` with the new tool
5. Create documentation in `src/tools/docs/<tool>.md`

**Modify planner behavior**:
- Edit `src/agent/planner.zig`
- Update `STAGE1_SYSTEM_PROMPT` constant for different instructions
- The `plan()` function processes LLM responses and returns a `Plan`

**Update Omni-RLM dependency**:
- Edit `build.zig.zon` with new URL and hash
- Run `zig build` to fetch and verify

**Using the public API**:
```zig
const omniclaw = @import("omniclaw.zig");

var runtime = try omniclaw.Runtime.init(allocator);
defer runtime.deinit();
try runtime.start();
```

## Known Limitations

- Single-threaded execution
- No persistent memory/storage
- HTTP communication via Omni-RLM library (not native Zig HTTP)
- Tool execution is direct bash (no WASM sandbox currently active)
- Limited to two built-in tools: `exec` and `finish`

## File Structure Reference

```
.omni-claw/
├── .omniclaw/
│   └── .env              # Runtime configuration (gitignored)
├── .env                  # Optional source config (gitignored)
├── .gitignore            # Git ignore rules
├── .mise.toml            # Zig version pinning (0.15.1)
├── build.zig             # Zig build script
├── build.zig.zon         # Dependency manifest
├── LICENSE               # Apache 2.0 license
├── README.md             # Human-readable project overview
├── AGENTS.md             # This file - AI agent documentation
├── logs/                 # Runtime logs (gitignored)
├── src/
│   ├── main.zig          # Entry point
│   ├── omniclaw.zig      # Public API
│   ├── test.zig          # Test module
│   ├── agent/
│   │   ├── mod.zig       # Agent coordinator
│   │   └── planner.zig   # LLM planner
│   ├── core/
│   │   └── runtime.zig   # Runtime + config
│   ├── tools/
│   │   ├── registry.zig  # Tool registry
│   │   ├── tools.md      # Tool list
│   │   └── docs/
│   │       ├── exec.md   # Exec tool docs
│   │       └── finish.md # Finish tool docs
│   └── channel/
│       └── repl.zig      # REPL interface
└── zig-out/
    └── bin/
        └── omniclaw      # Compiled binary
```
