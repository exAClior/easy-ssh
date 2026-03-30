# easy-ssh

**Local AI, Remote Execution** — develop locally with your LLM, run on servers via SSH.

A Bash CLI that bridges local AI-assisted development with remote server execution. Edit code with Claude Code / Codex / any LLM locally, sync and run on powerful remote servers, pull results back. No LLM setup on the server. Ever.

## Core Loop

```
edit locally (with AI) → push → run remotely → read output → pull results → repeat
```

## Commands

| Command | What it does |
|---------|-------------|
| `easy-ssh init` | Interactive setup → writes `.easy-ssh.conf` |
| `easy-ssh push` | Sync local dir → remote (rsync) |
| `easy-ssh run "<cmd>"` | Execute command on remote, return stdout/stderr |
| `easy-ssh pull <path>` | Fetch remote files back locally |
| `easy-ssh exec "<cmd>"` | Push + run in one shot |
| `easy-ssh status` | Show config, test SSH connection |

## Quick Start

```bash
# In your project directory:
easy-ssh init          # set host + remote directory
easy-ssh exec "python generate_data.py"   # sync & run
easy-ssh pull results/                     # grab results
```

## Requirements

- `ssh` + `rsync` (already on most systems)
- `jq` (for config parsing)
- SSH key-based auth configured (`~/.ssh/config`)

## License

MIT
