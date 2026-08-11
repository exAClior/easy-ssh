---
name: easy-ssh
description: >
  Runs local project code on remote machines through the easy-ssh CLI. Use when
  asked to execute on a server, submit a durable job, use a GPU or CPU cluster,
  sync or pull project files, inspect remote logs, or check remote job status.
---

# easy-ssh — Remote Execution

Run local project code on a remote server through SSH and rsync. Keep editing and
agent work local; submit compute to the configured host.

## Default rule

**Use `easy-ssh submit` for all substantive work. Use `easy-ssh run` only for a
trivial read-only probe that will finish in about 10 seconds.**

Compilation, tests, training, downloads, data processing, file writes, and loops
belong in `submit`, even when they are expected to be quick. A blocking `run` can
outlive the invoking tool timeout and leave an untracked remote process.

```bash
easy-ssh submit "<command>"
easy-ssh monitor
```

The submitted job runs under `nohup`; Ctrl+C or an SSH interruption only detaches
monitoring and does not stop the remote job.

## Prerequisites

- `ssh` and `rsync` are available locally. Check with `command -v ssh` and
  `command -v rsync`. On Debian/Ubuntu, install them with
  `sudo apt-get install openssh-client rsync`; on macOS, `ssh` is included and
  `brew install rsync` installs rsync when needed.
- Key-based, non-interactive SSH works for the configured host.
- The remote machine has `rsync`; verify with
  `ssh <host> 'command -v rsync'` and ask its administrator to install it if
  absent.

If `easy-ssh` is absent from `PATH`, use the canonical repository's HTTPS
download, validate it as Bash, and then install it; never pipe a download to a
shell:

```bash
# Repository: https://github.com/exAClior/easy-ssh
(
  set -eu
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT
  curl -fL https://raw.githubusercontent.com/exAClior/easy-ssh/main/easy-ssh -o "$tmp"
  bash -n "$tmp"
  mkdir -p "$HOME/.local/bin"
  install -m 0755 "$tmp" "$HOME/.local/bin/easy-ssh"
)
export PATH="$HOME/.local/bin:$PATH"
```

Persist that PATH export in the active shell's startup file if necessary, then
verify with `easy-ssh --help`.

## Workflow

### 1. Inspect configuration

```bash
ls .easy-ssh.conf 2>/dev/null
```

A default remote uses:

```bash
host='<ssh-host>'
remote_dir='<remote-path>'
```

Multiple remotes use named sections:

```bash
[a800]
host='a800'
remote_dir='~/projects/mypackage'

[h100]
host='h100'
remote_dir='~/projects/mypackage'
```

- Put `--remote NAME` immediately after `easy-ssh` when selecting a named remote:
  `easy-ssh --remote h100 status`.
- One named remote is selected automatically.
- With multiple named remotes and no default, ask which remote to use before
  destructive or long-running work.
- If configuration is missing, ask for the SSH host, remote directory, and
  optional remote name, then run `easy-ssh init` or
  `easy-ssh --remote <name> init`.

### 2. Choose the operation

| Intent | Command |
|---|---|
| Substantive command | `easy-ssh submit "<cmd>"` |
| Stream submitted output | `easy-ssh monitor` |
| Snapshot recent output | `easy-ssh logs` |
| Check job and SSH state | `easy-ssh status` |
| Trivial read-only probe | `easy-ssh run "<cmd>"` |
| Sync only | `easy-ssh push` |
| Fetch an artifact | `easy-ssh pull <relative-path>` |
| Preview remote cleanup | `easy-ssh clean` |
| Apply remote cleanup | `easy-ssh clean --force` |

### 3. Submit and observe durable work

```bash
easy-ssh submit "python train.py --epochs 10"
easy-ssh monitor
easy-ssh status
easy-ssh logs
```

Treat control-channel and job state separately:

- A failed `status`, `logs`, or `monitor` connection does **not** imply job
  failure. Wait briefly and check again.
- Do not repeat an uncertain submission until `status` confirms whether a job is
  already running.
- Report a job as launched only after `submit` prints its PID.
- Report completion only from a final status/exit code, not from a dropped SSH
  connection.

### 4. Pull results

```bash
easy-ssh pull results/metrics.json
easy-ssh pull checkpoints/
```

Pull paths are relative to `remote_dir`; absolute paths and `..` are rejected.

## Connection behavior

`easy-ssh` waits up to 30 seconds for SSH connection and banner exchange by
default. It uses OpenSSH `ControlMaster=auto` and a 10-minute `ControlPersist` so
the preflight, path resolution, rsync, launch, and monitoring operations can
reuse one authenticated connection.

The control socket is stored in a private local directory. These settings are
configurable:

| Variable | Default | Purpose |
|---|---:|---|
| `EASY_SSH_CONNECT_TIMEOUT` | `30` | SSH connect/banner timeout in seconds |
| `EASY_SSH_CONTROL_PERSIST` | `10m` | Master connection lifetime |
| `EASY_SSH_CONTROL_DIR` | `~/.ssh/easy-ssh-control` | Private control socket directory |
| `EASY_SSH_SIZE_WARN_KB` | `512000` | Effective sync-size refusal threshold |
| `EASY_SSH_LOG_LINES` | `50` | Lines printed by `logs` |

For an intermittent proxied host, prefer a larger timeout over rapid repeated
connections. Do not add blind retries around `run` or `submit`, because their
remote outcome can be ambiguous.

## File exclusions

`.git`, `.venv`, `.easy-ssh.conf`, and `.easy-ssh-ignore` are always excluded.
Add project-specific local-only or generated paths to `.easy-ssh-ignore` using
gitignore-style patterns:

```text
__pycache__/
*.pyc
data/
node_modules/
target/
build/
dist/
```

`clean` is a dry run. Use `clean --force` only after reviewing its deletion list.
Cleanup removes remote-only contents but preserves the configured `remote_dir`
itself. If a disposable remote root must be deleted intentionally, independently
validate the exact host and resolved target before a separate explicit removal;
easy-ssh intentionally provides no broad remote-root removal command.

## Progressive CLI guidance

Load only the focused help needed for the current task:

```bash
easy-ssh --help getting-started
easy-ssh --help jobs
easy-ssh --help configuration
easy-ssh --help troubleshooting
```

`easy-ssh --help skill` emits this complete installable `SKILL.md`. Do not call it
after this skill is already loaded unless verifying or exporting the canonical
skill text.

## Reporting

- `run`: report output and exit code.
- `submit`: report the acknowledged PID and how to inspect it.
- `pull`: report the fetched local path.
- Transport failure: report it as a monitoring/control failure and preserve the
  distinction from detached job state.
