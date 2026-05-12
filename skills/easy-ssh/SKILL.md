---
name: easy-ssh
description: >
  Use the easy-ssh CLI to run computations on a remote server using local project files.
  Trigger when the user asks to run code remotely, execute on a server, submit a job,
  sync files to a remote machine, pull results from a server, check remote job status,
  or mentions "easy-ssh", "remote run", "server-side", "GPU server", or "cluster".
  Also trigger when the user has a local project and wants to execute it somewhere
  with more compute (GPU, RAM, CPU cores).
---

# easy-ssh — Remote Execution Skill

Run local project code on a remote server via SSH. No agent or daemon needed on the server — just SSH access and rsync.

## ⚠️ Default rule — read first

**Default to `easy-ssh submit`. Use `easy-ssh run` only for trivial read-only probes that provably finish in under ~10 seconds** (e.g. `ls`, `cat`, `nvidia-smi`, `git status`, `which python`).

Anything that **writes files, trains, downloads, compiles, runs tests, or loops over data** → `submit`, no exceptions. Do not try to predict whether a command will take "a few minutes" — you cannot, and being wrong is unrecoverable (see below).

`run` blocks the agent's bash tool until completion. If the agent's bash timeout (typically 2–10 min) fires first, the SSH client is killed but the **remote process keeps running orphaned**, the agent loses all output, and the user's terminal hangs. Prefer `submit` whenever in doubt.

`easy-ssh submit "<cmd>" && easy-ssh monitor` is the **drop-in replacement** for `easy-ssh run "<cmd>"`: same live output, same Ctrl+C semantics for the user, but the remote job survives if your bash tool times out.

## When to use

- User wants to run a command on a remote server using local files
- User mentions "run this on the server", "submit a job", "GPU", "cluster", "remote"
- User wants to sync code, pull results, or check job status
- Project already has `.easy-ssh.conf` (check with `ls .easy-ssh.conf`)

## Prerequisites

- `easy-ssh` CLI must be on PATH (check: `which easy-ssh`)
- SSH key-based auth configured in `~/.ssh/config` for the target host
- `rsync` available locally and on the server

## Workflow

### Step 0 — Detect setup state

```bash
ls .easy-ssh.conf 2>/dev/null
```

- **File exists**: read it to learn `host` and `remote_dir`, then skip to the relevant command.
- **File missing**: the project hasn't been initialized yet. Ask the user for:
  1. SSH host (as configured in `~/.ssh/config`)
  2. Remote directory path (e.g., `~/projects/mypackage`)

  Then run `easy-ssh init` interactively, or create `.easy-ssh.conf` directly:

  ```bash
  cat > .easy-ssh.conf <<'EOF'
  host='<user-provided-host>'
  remote_dir='<user-provided-path>'
  EOF
  ```

### Step 1 — Determine the right command

| User intent | Command |
|---|---|
| **Default: run anything substantive** | `easy-ssh submit "<cmd>"` then `easy-ssh monitor` |
| Trivial read-only probe (<10s, no writes) | `easy-ssh run "<cmd>"` |
| Sync files only | `easy-ssh push` |
| Check running job output | `easy-ssh logs` |
| Live-stream job output | `easy-ssh monitor` |
| Check if job finished | `easy-ssh status` |
| Fetch result files locally | `easy-ssh pull <relative-path>` |
| Remove stale remote files | `easy-ssh clean --force` |
| Preview what clean would delete | `easy-ssh clean` |

⚠️ Reminder: `run` blocks the agent's bash tool. If the bash timeout fires before the remote command finishes, the remote process is orphaned and the agent loses all output. Use `submit` unless you are certain the command is trivial.

### Step 2 — Execute

#### Sync + submit (default for all substantive work)

```bash
easy-ssh submit "<command>"
```

Pushes local files, launches the command via `nohup`, returns immediately.
Use for **training, inference, tests, compilation, downloads, data processing, batch jobs** — anything that writes files or loops over data.

After submitting, monitor with:

```bash
easy-ssh monitor  # live-stream output, auto-stops when job ends (Ctrl+C to detach safely)
easy-ssh status   # job state: running/finished + exit code
easy-ssh logs     # last 50 lines of output (configurable via EASY_SSH_LOG_LINES)
```

`submit + monitor` gives the user the same experience as `run` (live output, Ctrl+C works), but the remote job survives an agent bash-tool timeout.

#### Sync + run (trivial read-only probes only)

```bash
easy-ssh run "<command>"
```

Pushes local files, runs the command synchronously, waits, returns stdout/stderr and exit code.
**Only safe for one-shot read-only checks** like `nvidia-smi`, `ls`, `cat`, `git status`, `which python`, `nvcc --version`. If the command writes files, trains, downloads, compiles, or could exceed ~10 seconds, use `submit` instead.

#### Pull results back

```bash
easy-ssh pull <path>
```

`<path>` is relative to the remote project directory. Examples:

```bash
easy-ssh pull results/model.pkl
easy-ssh pull output/                  # whole directory
easy-ssh pull checkpoints/epoch_10.pt
```

**Constraints**: path must be relative, no `../` allowed.

### Step 3 — Report to user

- For `run`: show the command output and exit code.
- For `submit`: confirm job launched, remind user to check `easy-ssh status` / `easy-ssh logs`.
- For `pull`: confirm files fetched, show local path.
- On failure: show the error message. Common issues:
  - `ssh connection failed` → check host in `~/.ssh/config`, key auth
  - `directory is XXXmb` → add patterns to `.easy-ssh-ignore` or use `--force`
  - `job already running` → wait for it or kill via `easy-ssh run "kill <pid>"`

## File exclusions

`easy-ssh` already skips `.git` and `.venv` automatically.

If the project has other large local-only files that shouldn't sync (datasets, build artifacts, caches), create `.easy-ssh-ignore` with gitignore-style patterns:

```
__pycache__/
*.pyc
data/
node_modules/
```

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `EASY_SSH_SIZE_WARN_KB` | 512000 | Warn if effective sync size exceeds this (KB) |
| `EASY_SSH_CONNECT_TIMEOUT` | 5 | SSH timeout (seconds) |
| `EASY_SSH_LOG_LINES` | 50 | Lines shown by `logs` |

## Common patterns

### Edit locally → run remotely → pull results

```bash
# 1. User edits code locally (you help with this)
# 2. Submit on server (default for anything substantive)
easy-ssh submit "python train.py --epochs 10"
easy-ssh monitor                       # live output, Ctrl+C detaches safely
easy-ssh status                        # confirm finished + exit code
# 3. Pull output
easy-ssh pull results/metrics.json
```

### Trivial probe (the only legitimate `run` use)

```bash
easy-ssh run "nvidia-smi"              # one-shot read-only check
easy-ssh run "which python && python --version"
```

### Long training with checkpoints

```bash
easy-ssh submit "python train.py --epochs 100 --save-every 10"
# ... later ...
easy-ssh logs                          # check progress
easy-ssh status                        # check if done
easy-ssh pull checkpoints/             # grab all checkpoints
```

### Julia project

```bash
easy-ssh submit "julia --project=. -e 'using Pkg; Pkg.instantiate()'"
easy-ssh monitor
easy-ssh submit "julia --project=. src/main.jl"
easy-ssh monitor
easy-ssh pull output/
```

### Clean remote state

```bash
easy-ssh clean           # dry-run: shows what would be deleted
easy-ssh clean --force   # actually delete remote-only files
```
