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
| `easy-ssh push` | Sync local dir → remote (rsync, additive-only) |
| `easy-ssh push --clean` | Sync with deletion of remote-only files (dry-run preview, `--force` to execute) |
| `easy-ssh run "<cmd>"` | Push + execute on remote, wait for completion, return output |
| `easy-ssh submit "<cmd>"` | Push + launch in tmux/nohup, return immediately (for long jobs) |
| `easy-ssh logs` | Tail the remote log from the last `submit` |
| `easy-ssh pull <path>` | Fetch remote files back locally |
| `easy-ssh clean` | Show remote-only files; `--force` to remove them |
| `easy-ssh status` | Show config, test SSH connection, check running jobs |

## Quick Start

```bash
# In your project directory:
easy-ssh init                              # set host + remote directory
easy-ssh run "python generate_data.py"     # sync & run (waits for completion)
easy-ssh pull results/                     # grab results

# For long jobs:
easy-ssh submit "python train_model.py"    # launch & return immediately
easy-ssh logs                              # check progress
easy-ssh pull checkpoints/                 # grab outputs when done
```

## Config

`.easy-ssh.conf` (shell-style KEY=VALUE, git-tracked):
```bash
host='myserver'
remote_dir='~/projects/mypackage'
```
Use quotes around `remote_dir` if you want `~` to stay literal for the remote host.

`.easy-ssh-ignore` (controls what rsync skips, same syntax as `.gitignore`):
```
__pycache__/
*.pyc
.venv/
data/
*.h5
```

## Requirements

- `ssh` + `rsync` (already on most systems)
- SSH key-based auth configured (`~/.ssh/config`)
- **Recommended on server:** `tmux` (enables job reattach after disconnect; without it, jobs still survive via `nohup`)

## Install

```bash
# local checkout
chmod +x ./easy-ssh

# optional: put it on your PATH
ln -sf "$PWD/easy-ssh" ~/.local/bin/easy-ssh
```

## Test

```bash
./tests/integration.sh
```

The integration test boots a temporary localhost `sshd`, points `easy-ssh` at a temp remote directory, and covers:
- core commands
- error paths
- push safety

## License

MIT
