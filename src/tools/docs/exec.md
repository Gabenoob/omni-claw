# exec

**Category:** System  
**Description:** Execute bash commands in the current environment with full access to the host system.

## Overview

The `exec` tool allows execution of arbitrary bash commands. This is the primary and only tool for interacting with the system.

## Capabilities

- Execute any valid bash command
- Access to host filesystem
- Run system utilities (ls, cat, grep, find, etc.)
- Run programming language interpreters (python, node, etc.)
- Network operations (curl, wget, ping, etc.)
- File operations (read, write, copy, move, delete)
- Process management (ps, kill, top, etc.)

## Usage

```json
{
  "tool": "exec",
  "argument": "<bash_command>"
}
```

## Examples

**List files:**
```json
{
  "tool": "exec",
  "argument": "ls -la"
}
```

**Read file:**
```json
{
  "tool": "exec",
  "argument": "cat /path/to/file.txt"
}
```

**Search in files:**
```json
{
  "tool": "exec",
  "argument": "grep -r 'pattern' /path/to/search"
}
```

**Run Python:**
```json
{
  "tool": "exec",
  "argument": "python3 -c 'print(2+2)'"
}
```

**Check system info:**
```json
{
  "tool": "exec",
  "argument": "uname -a && pwd"
}
```

## Best Practices

1. **File Reading**: Use `cat`, `head`, `tail`, or `less` for viewing files
2. **File Searching**: Use `find`, `grep`, or `rg` (ripgrep) if available
3. **Text Processing**: Chain commands with pipes: `cat file | grep pattern | wc -l`
4. **Safety**: Quote arguments properly to handle spaces: `ls -la "/path with spaces/"`
5. **Error Handling**: Commands may fail; check exit codes when needed

## Security Warnings

⚠️ **DANGER**: This tool has full system access. Be extremely careful with:
- Destructive commands (`rm -rf`, `dd`, etc.)
- Commands that modify system state
- Commands that expose sensitive information
- Network operations to untrusted hosts

## Common Patterns

| Task | Command |
|------|---------|
| List directory | `ls -la /path` |
| Find files | `find /path -name "*.txt"` |
| Search text | `grep -n "pattern" file.txt` |
| Read file | `cat file.txt` or `head -20 file.txt` |
| Check disk | `df -h` |
| Check memory | `free -h` |
| Current directory | `pwd` |
| System info | `uname -a` |
| Process list | `ps aux` |

## Exit Codes

- `0`: Success
- Non-zero: Error (specific meaning depends on the command)

## Notes

 - Commands run with the working directory set to the `.omniclaw` directory inside the project root (use absolute paths or `..` to access files in the project root)
- Environment variables from `.omniclaw/.env` are available
- Output is displayed directly to the user
- Errors are displayed on stderr
