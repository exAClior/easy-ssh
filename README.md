# easy-ssh

**Local AI, Remote Execution** — develop locally with your LLM, run on servers via SSH.

A Bash CLI that bridges local AI-assisted development with remote server execution. Edit code with Claude Code / Codex / any LLM locally, sync and run on powerful remote servers, pull results back. No LLM setup on the server. Ever.

## Why this exists

Setting up LLM tools (Claude Code, Codex, etc.) on a remote server is painful — API keys, network config, proxies, firewall rules. But the server has the GPU / CPU / data you need.

**easy-ssh** lets you keep the LLM on your laptop and send only the work to the server:

```
┌──────────────────┐          SSH + rsync          ┌──────────────────┐
│   Your laptop    │  ──────────────────────────▶   │   Remote server  │
│                  │                                │   (e.g. a800)    │
│  • Claude Code   │         push code              │  • GPU           │
│  • Codex         │         run command             │  • Big RAM       │
│  • Any LLM       │         pull results            │  • Your data     │
└──────────────────┘  ◀──────────────────────────   └──────────────────┘
```

The core loop:

```
edit locally (with AI) → push → run remotely → read output → pull results → repeat
```

---

## Install (step by step)

Everything below uses `a800` as the example server. Replace it with your own server name wherever you see it.

### Step 1 — Check prerequisites

You need three tools on your laptop. Open **Terminal** and run each line:

```bash
which ssh          # should print a path like /usr/bin/ssh
which rsync        # should print a path like /usr/bin/rsync
bash --version     # should print "GNU bash, version ..."
```

> **macOS / Linux:** All three are pre-installed. You don't need to install anything.

Also confirm that `rsync` exists on the server:

```bash
ssh a800 'which rsync'
# should print something like /usr/bin/rsync
```

### Step 2 — Check SSH connection

You said you can already run `ssh a800`. Let's verify it works **without typing a password** (easy-ssh needs this):

```bash
ssh a800 echo "ok"
```

- If it prints **`ok`** → you're good, skip to Step 3.
- If it **asks for a password** → you need to set up SSH key auth. Do this:

```bash
# Generate a key (press Enter for all prompts — no passphrase needed)
ssh-keygen -t ed25519

# Copy the key to the server
ssh-copy-id a800

# Now test again — this time no password prompt
ssh a800 echo "ok"
```

### Step 3 — Download easy-ssh

Pick **one** of the three options below.

#### Option A: Git clone (recommended — easiest to update later)

```bash
git clone git@github.com:exAClior/easy-ssh.git ~/.easy-ssh
chmod +x ~/.easy-ssh/easy-ssh
```

Then add it to your PATH so you can type `easy-ssh` from anywhere. Since you use **zsh** (the default macOS shell):

```bash
echo 'export PATH="$HOME/.easy-ssh:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

> **How to update later:** `cd ~/.easy-ssh && git pull`

#### Option B: Copy to a directory already on your PATH

If `~/.local/bin` is already on your PATH (it is on your machine):

```bash
git clone git@github.com:exAClior/easy-ssh.git ~/src/easy-ssh
chmod +x ~/src/easy-ssh/easy-ssh
ln -sf ~/src/easy-ssh/easy-ssh ~/.local/bin/easy-ssh
```

#### Option C: Direct download (no git needed, just one command)

```bash
curl -fsSL https://raw.githubusercontent.com/exAClior/easy-ssh/main/easy-ssh \
  -o ~/.local/bin/easy-ssh
chmod +x ~/.local/bin/easy-ssh
```

### Step 4 — Verify the install

```bash
easy-ssh --help
```

You should see a usage summary starting with `Usage: easy-ssh init ...`. If you get `command not found`, your PATH doesn't include the install location — go back to Step 3.

### Step 5 — Set up your first project

Go into any project you want to run on the server:

```bash
cd ~/my-project        # replace with your actual project folder
easy-ssh init
```

It will ask two questions:

```
SSH host: a800
Remote directory: ~/projects/my-project
```

- **SSH host** — type `a800` (the same name you use with `ssh a800`)
- **Remote directory** — the folder on the server where your code will be synced to. It will be created automatically if it doesn't exist.

This creates a small file called `.easy-ssh.conf` in your project:

```bash
host='a800'
remote_dir='~/projects/my-project'
```

### Step 6 — Test it

```bash
easy-ssh status
```

You should see:

```
host: a800
remote_dir: ~/projects/my-project
ssh: ok
resolved_remote_dir: /home/youruser/projects/my-project
job: no submitted job status found
```

If it says `ssh: ok`, everything is working. 🎉

---

## Usage

All commands below assume you are inside your project directory (the one with `.easy-ssh.conf`).

### Commands

| Command | What it does |
|---------|-------------|
| `easy-ssh init` | Interactive setup → writes `.easy-ssh.conf` |
| `easy-ssh push` | Sync local dir → remote (additive-only, won't delete remote files) |
| `easy-ssh push --clean` | Sync with deletion of remote-only files (preview first, `--force` to execute) |
| `easy-ssh run "<cmd>"` | Push + execute on remote, **wait** for completion, show output |
| `easy-ssh submit "<cmd>"` | Push + launch in background, **return immediately** (for long jobs) |
| `easy-ssh logs` | Tail the remote log from the last `submit` |
| `easy-ssh pull <path>` | Fetch remote files back to your laptop |
| `easy-ssh clean` | Show remote-only files; `--force` to remove them |
| `easy-ssh status` | Show config, test SSH connection, check running jobs |

### Example: quick script

```bash
# You write a script locally (with your LLM helping you)
# Then run it on the server:
easy-ssh run "python generate_data.py"

# Grab the output files:
easy-ssh pull results/
```

`run` does three things in order: (1) syncs your files to the server, (2) runs the command, (3) shows you the output. It **waits** until the command finishes.

### Example: long training job

```bash
# Launch a training run — returns immediately, doesn't block your terminal
easy-ssh submit "python train_model.py --epochs 100"

# Check progress anytime:
easy-ssh logs          # see the last 50 lines of output
easy-ssh status        # see if it's still running or finished

# When done, grab the results:
easy-ssh pull checkpoints/
easy-ssh pull results/metrics.json
```

`submit` launches the job inside **tmux** on the server (or `nohup` if tmux isn't available), so it keeps running even if your laptop disconnects.

### Example: Julia project

```bash
easy-ssh run "julia --project=. -e 'using Pkg; Pkg.instantiate()'"
easy-ssh run "julia --project=. src/main.jl"
easy-ssh pull output/
```

---

## Config

### `.easy-ssh.conf`

Created by `easy-ssh init`. Lives in your project root:

```bash
host='a800'
remote_dir='~/projects/my-project'
```

You can edit this file by hand if you need to change the host or path.

### `.easy-ssh-ignore`

Controls what **doesn't** get synced to the server. Same syntax as `.gitignore`. Create this file in your project root:

```
__pycache__/
*.pyc
.venv/
data/
*.h5
node_modules/
.git/
```

> **Why?** Without this, `easy-ssh push` would upload everything — including huge datasets or virtual environments you don't need on the server (or that already exist there).

### Environment variables

| Variable | Default | What it does |
|----------|---------|-------------|
| `EASY_SSH_SIZE_WARN_KB` | `512000` (~500 MB) | Refuse to sync if local directory is bigger than this |
| `EASY_SSH_CONNECT_TIMEOUT` | `5` seconds | How long to wait for SSH connection |
| `EASY_SSH_LOG_LINES` | `50` | How many lines `easy-ssh logs` shows |

---

## Claude Code Skill

If you use [Claude Code](https://docs.anthropic.com/en/docs/claude-code), you can give it the ability to run `easy-ssh` commands on your behalf — sync files, run remote commands, pull results — all from natural language.

```bash
npx skills add exAClior/easy-ssh --skill easy-ssh
```

Once installed, you can say things like *"run train.py on the server"* and Claude Code will handle the `push`, `run`, and `pull` for you.

---

## Uninstall

```bash
# Remove the binary:
# If you used Option A (git clone to ~/.easy-ssh):
rm -rf ~/.easy-ssh
# Then remove the PATH line from ~/.zshrc

# If you used Option B or C:
rm ~/.local/bin/easy-ssh
rm -rf ~/src/easy-ssh        # if you cloned

# Remove per-project config (optional, in each project):
rm .easy-ssh.conf .easy-ssh-ignore .easy-ssh-log .easy-ssh-status
```

---

## Test

```bash
./tests/integration.sh
```

The integration test boots a temporary localhost `sshd`, points `easy-ssh` at a temp directory, and covers:

- core commands (`init`, `push`, `run`, `submit`, `pull`, `logs`, `status`, `clean`)
- error paths (missing config, bad host, oversized directories)
- push safety (ignore files, `--clean` preview, `--force` execution)

---

## License

MIT
