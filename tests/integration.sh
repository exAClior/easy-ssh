#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
EASY_SSH_BIN=${EASY_SSH_BIN:-$REPO_ROOT/easy-ssh}
TEST_ROOT_OWNED=0
if [[ -z ${TEST_ROOT:-} ]]; then
    TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/easy-ssh test.XXXXXX")
    TEST_ROOT_OWNED=1
fi
CASE_ROOT=$(mktemp -d "/tmp/easy-ssh-cases.XXXXXX")
SSH_TEST_HOST=${EASY_SSH_TEST_HOST:-}
SSH_CONFIG_PATH=${EASY_SSH_TEST_CONFIG:-}
CONTROL_DIR_OWNED=0
if [[ -n ${EASY_SSH_TEST_CONTROL_DIR:-} ]]; then
    CONTROL_DIR=$EASY_SSH_TEST_CONTROL_DIR
else
    CONTROL_DIR="/tmp/easy-ssh 'ctl' $$"
    CONTROL_DIR_OWNED=1
fi
RSYNC_ARGS_LOG="$TEST_ROOT/rsync-args.log"
TEST_PATH=${PATH}
REAL_SSH=""
REAL_RSYNC=""
REAL_SSHD=""
SSHD_PID=""
TOTAL=0
PASSED=0
FAILED=0

LAST_OUTPUT=""
LAST_STATUS=0
PROJECT_DIR=""
REMOTE_DIR=""
CASE_DIR=""

cleanup() {
    if [[ -n ${REAL_SSH:-} && -n ${SSH_TEST_HOST:-} && -n ${SSH_CONFIG_PATH:-} ]]; then
        "$REAL_SSH" -F "$SSH_CONFIG_PATH" \
            -o "ControlPath=\"$CONTROL_DIR/%C\"" \
            -O exit "$SSH_TEST_HOST" >/dev/null 2>&1 || true
    fi
    if [[ -n ${SSHD_PID:-} ]]; then
        kill "$SSHD_PID" >/dev/null 2>&1 || true
        wait "$SSHD_PID" >/dev/null 2>&1 || true
    fi
    if (( TEST_ROOT_OWNED )); then
        rm -rf "$TEST_ROOT"
    fi
    rm -rf "$CASE_ROOT"
    if (( CONTROL_DIR_OWNED )); then
        rm -rf "$CONTROL_DIR"
    fi
}
trap cleanup EXIT

note() {
    printf '%s\n' "$*"
}

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_status() {
    local expected=$1
    [[ $LAST_STATUS -eq $expected ]] || fail "expected exit $expected, got $LAST_STATUS. Output:\n$LAST_OUTPUT"
}

assert_contains() {
    local haystack=$1
    local needle=$2
    [[ $haystack == *"$needle"* ]] || fail "expected output to contain '$needle'. Output:\n$haystack"
}

assert_not_contains() {
    local haystack=$1
    local needle=$2
    [[ $haystack != *"$needle"* ]] || fail "expected output not to contain '$needle'. Output:\n$haystack"
}

assert_file_exists() {
    local path=$1
    [[ -e $path ]] || fail "expected file to exist: $path"
}

assert_file_missing() {
    local path=$1
    [[ ! -e $path ]] || fail "expected file to be absent: $path"
}

assert_file_contains() {
    local path=$1
    local needle=$2
    assert_file_exists "$path"
    local content
    content=$(<"$path")
    assert_contains "$content" "$needle"
}

assert_file_equals() {
    local path=$1
    local expected=$2
    assert_file_exists "$path"
    local content
    content=$(<"$path")
    [[ $content == "$expected" ]] || fail "expected $path to equal '$expected', got '$content'"
}

sha256_stream() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    else
        fail "shasum or sha256sum is required to verify skills-lock.json"
    fi
}

require_tools() {
    local tool
    for tool in bash ssh ssh-keygen sshd rsync mktemp; do
        command -v "$tool" >/dev/null 2>&1 || {
            printf 'missing required test dependency: %s\n' "$tool" >&2
            exit 1
        }
    done

    REAL_SSH=$(command -v ssh)
    REAL_RSYNC=$(command -v rsync)
    REAL_SSHD=$(command -v sshd)
}

start_test_sshd() {
    local ssh_dir wrapper_bin host_key client_key auth_keys ssh_config sshd_config sshd_log port user

    ssh_dir="$TEST_ROOT/ssh"
    wrapper_bin="$TEST_ROOT/bin"
    mkdir -p "$ssh_dir" "$wrapper_bin"
    chmod 700 "$ssh_dir" "$wrapper_bin"

    host_key="$TEST_ROOT/ssh_host_ed25519_key"
    client_key="$ssh_dir/id_ed25519"
    auth_keys="$TEST_ROOT/authorized_keys"
    ssh_config="$ssh_dir/config"
    sshd_config="$TEST_ROOT/sshd_config"
    sshd_log="$TEST_ROOT/sshd.log"
    user=$(id -un)

    ssh-keygen -q -t ed25519 -N '' -f "$host_key" >/dev/null
    ssh-keygen -q -t ed25519 -N '' -f "$client_key" >/dev/null
    cp "$client_key.pub" "$auth_keys"
    chmod 600 "$auth_keys"

    for _ in $(seq 1 20); do
        port=$((20000 + RANDOM % 20000))
        cat > "$sshd_config" <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey "$host_key"
PidFile "$TEST_ROOT/sshd.pid"
AuthorizedKeysFile "$auth_keys"
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin no
UsePAM no
StrictModes no
LogLevel VERBOSE
AllowUsers $user
Subsystem sftp internal-sftp
EOF

        "$REAL_SSHD" -D -f "$sshd_config" -E "$sshd_log" &
        SSHD_PID=$!

        cat > "$ssh_config" <<EOF
Host easy-ssh-localhost-test
    HostName 127.0.0.1
    Port $port
    User $user
    IdentityFile "$client_key"
    IdentitiesOnly yes
    StrictHostKeyChecking yes
    UserKnownHostsFile "$ssh_dir/known_hosts"
    LogLevel ERROR
EOF
        awk -v port="$port" '{print "[127.0.0.1]:" port, $1, $2}' "$host_key.pub" > "$ssh_dir/known_hosts"
        chmod 600 "$ssh_dir/known_hosts"
        chmod 600 "$ssh_config"

        cat > "$wrapper_bin/ssh" <<EOF
#!/usr/bin/env bash
exec $(printf '%q' "$REAL_SSH") -F $(printf '%q' "$ssh_config") "\$@"
EOF
        cat > "$wrapper_bin/rsync" <<EOF
#!/usr/bin/env bash
{
    printf 'call\n'
    for arg in "\$@"; do
        printf 'arg=%s\n' "\$arg"
    done
} >> $(printf '%q' "$RSYNC_ARGS_LOG")
exec $(printf '%q' "$REAL_RSYNC") "\$@"
EOF
        chmod +x "$wrapper_bin/ssh" "$wrapper_bin/rsync"

        for _ in $(seq 1 50); do
            if "$REAL_SSH" -F "$ssh_config" -o BatchMode=yes easy-ssh-localhost-test true >/dev/null 2>&1; then
                SSH_TEST_HOST=easy-ssh-localhost-test
                SSH_CONFIG_PATH=$ssh_config
                TEST_PATH="$wrapper_bin:$PATH"
                return 0
            fi
            sleep 0.1
        done

        kill "$SSHD_PID" >/dev/null 2>&1 || true
        wait "$SSHD_PID" >/dev/null 2>&1 || true
        SSHD_PID=""
    done

    printf 'failed to start test sshd\n' >&2
    [[ -f $sshd_log ]] && cat "$sshd_log" >&2
    exit 1
}

setup_ssh() {
    if [[ -n $SSH_TEST_HOST ]]; then
        TEST_PATH=${PATH}
        return 0
    fi
    start_test_sshd
}

setup_case() {
    CASE_DIR=$(mktemp -d "$CASE_ROOT/case.XXXXXX")
    PROJECT_DIR="$CASE_DIR/project"
    REMOTE_DIR="$CASE_DIR/remote"
    mkdir -p "$PROJECT_DIR" "$REMOTE_DIR"
}

write_config() {
    cat > "$PROJECT_DIR/.easy-ssh.conf" <<EOF
host='$SSH_TEST_HOST'
remote_dir='$REMOTE_DIR'
EOF
}

run_cmd() {
    local dir=$1
    shift
    set +e
    LAST_OUTPUT=$(cd "$dir" && "$@" 2>&1)
    LAST_STATUS=$?
    set -e
}

run_tool() {
    local dir=$1
    shift
    run_cmd "$dir" env \
        PATH="$TEST_PATH" \
        EASY_SSH_CONTROL_DIR="$CONTROL_DIR" \
        EASY_SSH_CONTROL_PERSIST=10m \
        "$EASY_SSH_BIN" "$@"
}

run_tool_input() {
    local dir=$1
    local input=$2
    shift 2
    set +e
    LAST_OUTPUT=$(cd "$dir" && printf '%b' "$input" | env \
        PATH="$TEST_PATH" \
        EASY_SSH_CONTROL_DIR="$CONTROL_DIR" \
        EASY_SSH_CONTROL_PERSIST=10m \
        "$EASY_SSH_BIN" "$@" 2>&1)
    LAST_STATUS=$?
    set -e
}

wait_for_status_prefix() {
    local prefix=$1
    local file="$REMOTE_DIR/.easy-ssh-status"
    local i content
    for i in $(seq 1 50); do
        if [[ -f $file ]]; then
            content=$(<"$file")
            if [[ $content == "$prefix"* ]]; then
                return 0
            fi
        fi
        sleep 0.1
    done
    fail "timed out waiting for status prefix '$prefix'"
}

wait_for_status_value() {
    local expected=$1
    local file="$REMOTE_DIR/.easy-ssh-status"
    local i content
    for i in $(seq 1 80); do
        if [[ -f $file ]]; then
            content=$(<"$file")
            if [[ $content == "$expected" ]]; then
                return 0
            fi
        fi
        sleep 0.1
    done
    fail "timed out waiting for status '$expected'"
}

wait_for_log_contains() {
    local needle=$1
    local file="$REMOTE_DIR/.easy-ssh-log"
    local i content
    for ((i = 0; i < 80; i++)); do
        if [[ -f $file ]]; then
            content=$(<"$file")
            if [[ $content == *"$needle"* ]]; then
                return 0
            fi
        fi
        sleep 0.1
    done
    fail "timed out waiting for log to contain '$needle'"
}

run_test() {
    local name=$1
    shift
    TOTAL=$((TOTAL + 1))
    if ( set -euo pipefail; "$@" ); then
        PASSED=$((PASSED + 1))
        printf 'ok - %s\n' "$name"
    else
        FAILED=$((FAILED + 1))
        printf 'not ok - %s\n' "$name"
    fi
}

help_and_multiplexing_tier() {
    local broken_script broken_status broken_stderr broken_stdout control_mode expected_lock_hash exported_skill socket

    setup_case
    write_config

    run_tool "$PROJECT_DIR" --help
    assert_status 0
    assert_contains "$LAST_OUTPUT" "Focused help (progressive disclosure)"
    assert_contains "$LAST_OUTPUT" "--help skill"
    assert_not_contains "$LAST_OUTPUT" "# easy-ssh — Remote Execution"

    run_tool "$PROJECT_DIR" --help getting-started
    assert_status 0
    assert_contains "$LAST_OUTPUT" "command -v ssh"
    assert_contains "$LAST_OUTPUT" "command -v rsync"
    assert_contains "$LAST_OUTPUT" "https://github.com/exAClior/easy-ssh"
    assert_contains "$LAST_OUTPUT" "set -eu"
    assert_contains "$LAST_OUTPUT" "trap 'rm -f \"\$tmp\"' EXIT"
    assert_contains "$LAST_OUTPUT" "install -m 0755 \"\$tmp\" \"\$HOME/.local/bin/easy-ssh\""
    assert_contains "$LAST_OUTPUT" "export PATH=\"\$HOME/.local/bin:\$PATH\""
    assert_not_contains "$LAST_OUTPUT" "curl |"
    [[ $LAST_OUTPUT == *"curl -fL"*"bash -n"*"install -m 0755"* ]] || \
        fail "expected getting-started help to download, validate, then install"

    run_tool "$PROJECT_DIR" --help jobs
    assert_status 0
    assert_contains "$LAST_OUTPUT" "Detached jobs continue"
    assert_not_contains "$LAST_OUTPUT" "## File exclusions"

    run_tool "$PROJECT_DIR" --help=configuration
    assert_status 0
    assert_contains "$LAST_OUTPUT" "EASY_SSH_CONNECT_TIMEOUT"
    assert_contains "$LAST_OUTPUT" "default: 30 seconds"
    assert_contains "$LAST_OUTPUT" "ControlMaster=auto"

    run_tool "$PROJECT_DIR" --help skill
    assert_status 0
    exported_skill="$CASE_DIR/exported-SKILL.md"
    "$EASY_SSH_BIN" --help skill > "$exported_skill"
    cmp -s "$exported_skill" "$REPO_ROOT/skills/easy-ssh/SKILL.md" || \
        fail "embedded Agent Skill differs byte-for-byte from skills/easy-ssh/SKILL.md"
    cmp -s "$REPO_ROOT/skills/easy-ssh/SKILL.md" "$REPO_ROOT/.agents/skills/easy-ssh/SKILL.md" || \
        fail "skills/easy-ssh/SKILL.md differs byte-for-byte from .agents/skills/easy-ssh/SKILL.md"
    cmp -s "$exported_skill" "$REPO_ROOT/.agents/skills/easy-ssh/SKILL.md" || \
        fail "embedded Agent Skill differs byte-for-byte from .agents/skills/easy-ssh/SKILL.md"
    expected_lock_hash=$({ printf 'SKILL.md'; cat "$REPO_ROOT/.agents/skills/easy-ssh/SKILL.md"; } | sha256_stream)
    assert_file_contains "$REPO_ROOT/skills-lock.json" "\"computedHash\": \"$expected_lock_hash\""

    broken_script="$CASE_DIR/easy-ssh-missing-skill-end"
    broken_stdout="$CASE_DIR/missing-skill-end.stdout"
    broken_stderr="$CASE_DIR/missing-skill-end.stderr"
    sed '/^__EASY_SSH_SKILL_END__$/d' "$EASY_SSH_BIN" > "$broken_script"
    chmod +x "$broken_script"
    set +e
    (cd "$PROJECT_DIR" && "$broken_script" --help skill) > "$broken_stdout" 2> "$broken_stderr"
    broken_status=$?
    set -e
    [[ $broken_status -eq 1 ]] || fail "expected malformed embedded skill to exit 1, got $broken_status"
    [[ ! -s $broken_stdout ]] || fail "malformed embedded skill wrote a partial export to stdout"
    assert_file_contains "$broken_stderr" "embedded Agent Skill markers are incomplete"

    run_tool "$PROJECT_DIR" status
    assert_status 0
    socket=$(find "$CONTROL_DIR" -type s -print -quit 2>/dev/null || true)
    [[ -n $socket ]] || fail "expected a persistent SSH control socket in $CONTROL_DIR"
    control_mode=$(stat -c '%a' "$CONTROL_DIR" 2>/dev/null || stat -f '%Lp' "$CONTROL_DIR")
    [[ $control_mode == 700 ]] || fail "expected $CONTROL_DIR mode 700, got $control_mode"

    run_tool "$PROJECT_DIR" --help unknown-topic
    assert_status 1
    assert_contains "$LAST_OUTPUT" "unknown help topic"
}

core_commands_tier() {
    local authentications_after authentications_before encoded_control_dir

    setup_case

    run_tool_input "$PROJECT_DIR" "$SSH_TEST_HOST\n$REMOTE_DIR\n" init
    assert_status 0
    assert_file_contains "$PROJECT_DIR/.easy-ssh.conf" "host='$SSH_TEST_HOST'"
    assert_file_contains "$PROJECT_DIR/.easy-ssh.conf" "remote_dir='$REMOTE_DIR'"

    cat > "$PROJECT_DIR/.easy-ssh-ignore" <<'EOF'
ignored.tmp
EOF
    printf 'version-1\n' > "$PROJECT_DIR/code.txt"
    printf 'ignore me\n' > "$PROJECT_DIR/ignored.tmp"
    printf 'remote only\n' > "$REMOTE_DIR/remote-only.txt"
    if [[ -n $SSHD_PID ]]; then
        authentications_before=$(grep -c 'Accepted publickey' "$TEST_ROOT/sshd.log" || true)
    fi

    run_tool "$PROJECT_DIR" push
    assert_status 0
    assert_file_equals "$REMOTE_DIR/code.txt" "version-1"
    assert_file_missing "$REMOTE_DIR/ignored.tmp"
    assert_file_equals "$REMOTE_DIR/remote-only.txt" "remote only"

    printf 'version-two\n' > "$PROJECT_DIR/code.txt"
    run_tool "$PROJECT_DIR" run "cat code.txt; printf 'run-finished\\n'; exit 7"
    assert_status 7
    assert_contains "$LAST_OUTPUT" "version-two"
    assert_contains "$LAST_OUTPUT" "run-finished"
    assert_file_equals "$REMOTE_DIR/code.txt" "version-two"

    mkdir -p "$REMOTE_DIR/generated"
    printf 'pulled\n' > "$REMOTE_DIR/generated/result.txt"
    : > "$RSYNC_ARGS_LOG"
    run_tool "$PROJECT_DIR" pull generated/result.txt
    assert_status 0
    assert_file_equals "$PROJECT_DIR/generated/result.txt" "pulled"
    assert_file_contains "$RSYNC_ARGS_LOG" "ControlMaster=auto"
    assert_file_contains "$RSYNC_ARGS_LOG" "ConnectTimeout=30"
    encoded_control_dir=${CONTROL_DIR//\'/\'\'}
    assert_file_contains "$RSYNC_ARGS_LOG" "ControlPath=\"$encoded_control_dir/%C\""
    if [[ -n $SSHD_PID ]]; then
        authentications_after=$(grep -c 'Accepted publickey' "$TEST_ROOT/sshd.log" || true)
        [[ $authentications_after == "$authentications_before" ]] || \
            fail "expected SSH and rsync to reuse the existing master; authenticated connections changed from $authentications_before to $authentications_after"
    fi

    run_tool "$PROJECT_DIR" submit "sleep 2; echo async-line; mkdir -p generated; echo artifact > generated/async.txt"
    assert_status 0
    wait_for_status_prefix "running:"
    run_tool "$PROJECT_DIR" status
    assert_status 0
    assert_contains "$LAST_OUTPUT" "job: running"

    wait_for_log_contains "async-line"
    wait_for_status_value "0"
    run_tool "$PROJECT_DIR" logs
    assert_status 0
    assert_contains "$LAST_OUTPUT" "async-line"

    run_tool "$PROJECT_DIR" status
    assert_status 0
    assert_contains "$LAST_OUTPUT" "job: finished (exit 0)"

    printf 'remote-stale\n' > "$REMOTE_DIR/stale.txt"
    printf 'remote-keep\n' > "$REMOTE_DIR/keep.txt"
    printf 'local-new\n' > "$PROJECT_DIR/keep.txt"

    run_tool "$PROJECT_DIR" clean
    assert_status 0
    assert_contains "$LAST_OUTPUT" "stale.txt"
    assert_file_exists "$REMOTE_DIR/stale.txt"

    run_tool "$PROJECT_DIR" clean --force
    assert_status 0
    assert_file_missing "$REMOTE_DIR/stale.txt"
    assert_file_equals "$REMOTE_DIR/keep.txt" "remote-keep"
}

error_paths_tier() {
    setup_case

    run_tool "$PROJECT_DIR" push
    assert_status 1
    assert_contains "$LAST_OUTPUT" "no .easy-ssh.conf found"

    cat > "$PROJECT_DIR/.easy-ssh.conf" <<EOF
remote_dir='$REMOTE_DIR'
EOF
    run_tool "$PROJECT_DIR" status
    assert_status 1
    assert_contains "$LAST_OUTPUT" "'host' not set"

    cat > "$PROJECT_DIR/.easy-ssh.conf" <<EOF
host='$SSH_TEST_HOST'
EOF
    run_tool "$PROJECT_DIR" status
    assert_status 1
    assert_contains "$LAST_OUTPUT" "'remote_dir' not set"

    cat > "$PROJECT_DIR/.easy-ssh.conf" <<'EOF'
host='no-such-host.invalid'
remote_dir='/tmp/easy-ssh-nowhere'
EOF
    run_tool "$PROJECT_DIR" status
    assert_status 1
    assert_contains "$LAST_OUTPUT" "ssh connection to 'no-such-host.invalid' failed"

    write_config
    dd if=/dev/zero of="$PROJECT_DIR/size-guard.bin" bs=2048 count=1 >/dev/null 2>&1
    run_cmd "$PROJECT_DIR" env PATH="$TEST_PATH" \
        EASY_SSH_CONTROL_DIR="$CONTROL_DIR" EASY_SSH_CONTROL_PERSIST=10m \
        EASY_SSH_SIZE_WARN_KB=1 "$EASY_SSH_BIN" push
    assert_status 1
    assert_contains "$LAST_OUTPUT" "Refusing to sync"
}

default_excludes_tier() {
    setup_case
    write_config

    mkdir -p "$PROJECT_DIR/.git" "$PROJECT_DIR/.venv/bin"
    printf 'ref: refs/heads/main\n' > "$PROJECT_DIR/.git/HEAD"
    printf '#!/usr/bin/env python\n' > "$PROJECT_DIR/.venv/bin/python"
    dd if=/dev/zero of="$PROJECT_DIR/.venv/big.bin" bs=2048 count=2 >/dev/null 2>&1
    printf '# %02048d\n' 0 >> "$PROJECT_DIR/.easy-ssh.conf"
    printf '# %02048d\n' 0 > "$PROJECT_DIR/.easy-ssh-ignore"
    printf 'tracked\n' > "$PROJECT_DIR/tracked.txt"

    run_cmd "$PROJECT_DIR" env PATH="$TEST_PATH" \
        EASY_SSH_CONTROL_DIR="$CONTROL_DIR" EASY_SSH_CONTROL_PERSIST=10m \
        EASY_SSH_SIZE_WARN_KB=1 "$EASY_SSH_BIN" push
    assert_status 0
    assert_file_equals "$REMOTE_DIR/tracked.txt" "tracked"
    assert_file_missing "$REMOTE_DIR/.git"
    assert_file_missing "$REMOTE_DIR/.venv"
    assert_file_missing "$REMOTE_DIR/.easy-ssh.conf"
    assert_file_missing "$REMOTE_DIR/.easy-ssh-ignore"
}

push_safety_tier() {
    setup_case
    write_config

    cat > "$PROJECT_DIR/.easy-ssh-ignore" <<'EOF'
ignored.txt
EOF
    printf 'tracked\n' > "$PROJECT_DIR/tracked.txt"
    printf 'ignore\n' > "$PROJECT_DIR/ignored.txt"
    printf 'remote-only\n' > "$REMOTE_DIR/remote-only.txt"
    mkdir -p "$REMOTE_DIR/.git" "$REMOTE_DIR/.venv/bin"
    printf 'ref: refs/heads/main\n' > "$REMOTE_DIR/.git/HEAD"
    printf '#!/usr/bin/env python\n' > "$REMOTE_DIR/.venv/bin/python"

    run_tool "$PROJECT_DIR" push
    assert_status 0
    assert_file_equals "$REMOTE_DIR/tracked.txt" "tracked"
    assert_file_missing "$REMOTE_DIR/ignored.txt"
    assert_file_missing "$REMOTE_DIR/.easy-ssh.conf"
    assert_file_missing "$REMOTE_DIR/.easy-ssh-ignore"
    assert_file_exists "$REMOTE_DIR/remote-only.txt"

    printf 'legacy remote config\n' > "$REMOTE_DIR/.easy-ssh.conf"
    printf 'legacy remote policy\n' > "$REMOTE_DIR/.easy-ssh-ignore"

    run_tool "$PROJECT_DIR" push --clean
    assert_status 0
    assert_contains "$LAST_OUTPUT" "remote-only.txt"
    assert_contains "$LAST_OUTPUT" ".git"
    assert_contains "$LAST_OUTPUT" ".venv"
    assert_not_contains "$LAST_OUTPUT" ".easy-ssh.conf"
    assert_not_contains "$LAST_OUTPUT" ".easy-ssh-ignore"
    assert_contains "$LAST_OUTPUT" "Preview only"
    assert_file_exists "$REMOTE_DIR/remote-only.txt"
    assert_file_exists "$REMOTE_DIR/.git"
    assert_file_exists "$REMOTE_DIR/.venv"
    assert_file_equals "$REMOTE_DIR/.easy-ssh.conf" "legacy remote config"
    assert_file_equals "$REMOTE_DIR/.easy-ssh-ignore" "legacy remote policy"

    run_tool "$PROJECT_DIR" clean
    assert_status 0
    assert_contains "$LAST_OUTPUT" "remote-only.txt"
    assert_not_contains "$LAST_OUTPUT" ".easy-ssh.conf"
    assert_not_contains "$LAST_OUTPUT" ".easy-ssh-ignore"

    run_tool "$PROJECT_DIR" push --clean --force
    assert_status 0
    assert_file_missing "$REMOTE_DIR/remote-only.txt"
    assert_file_missing "$REMOTE_DIR/ignored.txt"
    assert_file_missing "$REMOTE_DIR/.git"
    assert_file_missing "$REMOTE_DIR/.venv"
    assert_file_equals "$REMOTE_DIR/.easy-ssh.conf" "legacy remote config"
    assert_file_equals "$REMOTE_DIR/.easy-ssh-ignore" "legacy remote policy"

    printf 'clean-only\n' > "$REMOTE_DIR/clean-only.txt"
    run_tool "$PROJECT_DIR" clean --force
    assert_status 0
    assert_file_missing "$REMOTE_DIR/clean-only.txt"
    assert_file_equals "$REMOTE_DIR/.easy-ssh.conf" "legacy remote config"
    assert_file_equals "$REMOTE_DIR/.easy-ssh-ignore" "legacy remote policy"
}

multiple_remotes_tier() {
    local remote_one remote_two remote_updated

    setup_case
    remote_one=$REMOTE_DIR
    remote_two="$CASE_DIR/remote-two"
    mkdir -p "$remote_two"

    cat > "$PROJECT_DIR/.easy-ssh.conf" <<EOF
[one]
host='$SSH_TEST_HOST'
remote_dir='$remote_one'

[two]
host='$SSH_TEST_HOST'
remote_dir='$remote_two'
EOF
    printf 'multi-one\n' > "$PROJECT_DIR/multi.txt"

    run_tool "$PROJECT_DIR" status
    assert_status 1
    assert_contains "$LAST_OUTPUT" "multiple remotes"

    run_tool "$PROJECT_DIR" status --remote one
    assert_status 1
    assert_contains "$LAST_OUTPUT" "usage:"

    run_tool "$PROJECT_DIR" --remote=two status
    assert_status 0
    assert_contains "$LAST_OUTPUT" "remote: two"

    run_tool "$PROJECT_DIR" --remote missing status
    assert_status 1
    assert_contains "$LAST_OUTPUT" "remote 'missing' not found"

    run_tool "$PROJECT_DIR" --remote one push
    assert_status 0
    assert_file_equals "$remote_one/multi.txt" "multi-one"
    assert_file_missing "$remote_two/multi.txt"

    printf 'multi-two\n' > "$PROJECT_DIR/multi.txt"
    run_tool "$PROJECT_DIR" -r two run "cat multi.txt"
    assert_status 0
    assert_contains "$LAST_OUTPUT" "multi-two"
    assert_file_equals "$remote_two/multi.txt" "multi-two"

    setup_case
    remote_two="$CASE_DIR/remote-two"
    mkdir -p "$remote_two"
    cat > "$PROJECT_DIR/.easy-ssh.conf" <<EOF
host='$SSH_TEST_HOST'
remote_dir='$REMOTE_DIR'

[other]
host='no-such-host.invalid'
remote_dir='$remote_two'
EOF
    run_tool "$PROJECT_DIR" status
    assert_status 0
    assert_contains "$LAST_OUTPUT" "host: $SSH_TEST_HOST"

    setup_case
    run_tool_input "$PROJECT_DIR" "$SSH_TEST_HOST\n$REMOTE_DIR\n" --remote gpu init
    assert_status 0
    assert_file_contains "$PROJECT_DIR/.easy-ssh.conf" "[gpu]"
    assert_file_contains "$PROJECT_DIR/.easy-ssh.conf" "host='$SSH_TEST_HOST'"
    assert_file_contains "$PROJECT_DIR/.easy-ssh.conf" "remote_dir='$REMOTE_DIR'"

    remote_updated="$CASE_DIR/remote-updated"
    mkdir -p "$remote_updated"
    run_tool_input "$PROJECT_DIR" "\n$remote_updated\n" --remote gpu init
    assert_status 0
    assert_file_contains "$PROJECT_DIR/.easy-ssh.conf" "host='$SSH_TEST_HOST'"
    assert_file_contains "$PROJECT_DIR/.easy-ssh.conf" "remote_dir='$remote_updated'"

    run_tool "$PROJECT_DIR" status
    assert_status 0
    assert_contains "$LAST_OUTPUT" "remote: gpu"

    setup_case
    cat > "$PROJECT_DIR/.easy-ssh.conf" <<EOF
[dup]
host='$SSH_TEST_HOST'
remote_dir='$REMOTE_DIR'

[dup]
host='$SSH_TEST_HOST'
remote_dir='$REMOTE_DIR'
EOF
    run_tool "$PROJECT_DIR" --remote dup status
    assert_status 1
    assert_contains "$LAST_OUTPUT" "duplicate remote 'dup'"

    cat > "$PROJECT_DIR/.easy-ssh.conf" <<EOF
[bad name]
host='$SSH_TEST_HOST'
remote_dir='$REMOTE_DIR'
EOF
    run_tool "$PROJECT_DIR" status
    assert_status 1
    assert_contains "$LAST_OUTPUT" "invalid remote name"
}

main() {
    require_tools
    [[ -x $EASY_SSH_BIN ]] || {
        printf 'easy-ssh binary not found or not executable: %s\n' "$EASY_SSH_BIN" >&2
        exit 1
    }

    setup_ssh

    note "Using easy-ssh: $EASY_SSH_BIN"
    note "Using SSH host: ${SSH_TEST_HOST}"

    run_test "progressive help and SSH multiplexing" help_and_multiplexing_tier
    run_test "core commands" core_commands_tier
    run_test "error paths" error_paths_tier
    run_test "default excludes" default_excludes_tier
    run_test "push safety" push_safety_tier
    run_test "multiple remotes" multiple_remotes_tier

    printf '\n%d/%d tests passed\n' "$PASSED" "$TOTAL"
    [[ $FAILED -eq 0 ]]
}

main "$@"
