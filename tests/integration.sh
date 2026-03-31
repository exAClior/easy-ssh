#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
EASY_SSH_BIN=${EASY_SSH_BIN:-$REPO_ROOT/easy-ssh}
TEST_ROOT=${TEST_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/easy-ssh-test.XXXXXX")}
SSH_TEST_HOST=${EASY_SSH_TEST_HOST:-}
SSH_CONFIG_PATH=${EASY_SSH_TEST_CONFIG:-}
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
    if [[ -n ${SSHD_PID:-} ]]; then
        kill "$SSHD_PID" >/dev/null 2>&1 || true
        wait "$SSHD_PID" >/dev/null 2>&1 || true
    fi
    rm -rf "$TEST_ROOT"
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
HostKey $host_key
PidFile $TEST_ROOT/sshd.pid
AuthorizedKeysFile $auth_keys
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
    IdentityFile $client_key
    IdentitiesOnly yes
    StrictHostKeyChecking no
    UserKnownHostsFile $ssh_dir/known_hosts
    LogLevel ERROR
EOF
        chmod 600 "$ssh_config"

        cat > "$wrapper_bin/ssh" <<EOF
#!/usr/bin/env bash
exec $(printf '%q' "$REAL_SSH") -F $(printf '%q' "$ssh_config") "\$@"
EOF
        cat > "$wrapper_bin/rsync" <<EOF
#!/usr/bin/env bash
exec $(printf '%q' "$REAL_RSYNC") -e $(printf '%q' "$wrapper_bin/ssh") "\$@"
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
    CASE_DIR=$(mktemp -d "$TEST_ROOT/case.XXXXXX")
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
    run_cmd "$dir" env PATH="$TEST_PATH" "$EASY_SSH_BIN" "$@"
}

run_tool_input() {
    local dir=$1
    local input=$2
    shift 2
    set +e
    LAST_OUTPUT=$(cd "$dir" && printf '%b' "$input" | env PATH="$TEST_PATH" "$EASY_SSH_BIN" "$@" 2>&1)
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
    for i in $(seq 1 80); do
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

core_commands_tier() {
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
    run_tool "$PROJECT_DIR" pull generated/result.txt
    assert_status 0
    assert_file_equals "$PROJECT_DIR/generated/result.txt" "pulled"

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
    run_cmd "$PROJECT_DIR" env PATH="$TEST_PATH" EASY_SSH_SIZE_WARN_KB=1 "$EASY_SSH_BIN" push
    assert_status 1
    assert_contains "$LAST_OUTPUT" "Refusing to sync"
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

    run_tool "$PROJECT_DIR" push
    assert_status 0
    assert_file_equals "$REMOTE_DIR/tracked.txt" "tracked"
    assert_file_missing "$REMOTE_DIR/ignored.txt"
    assert_file_exists "$REMOTE_DIR/remote-only.txt"

    run_tool "$PROJECT_DIR" push --clean
    assert_status 0
    assert_contains "$LAST_OUTPUT" "remote-only.txt"
    assert_contains "$LAST_OUTPUT" "Preview only"
    assert_file_exists "$REMOTE_DIR/remote-only.txt"

    run_tool "$PROJECT_DIR" push --clean --force
    assert_status 0
    assert_file_missing "$REMOTE_DIR/remote-only.txt"
    assert_file_missing "$REMOTE_DIR/ignored.txt"
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

    run_test "core commands" core_commands_tier
    run_test "error paths" error_paths_tier
    run_test "push safety" push_safety_tier

    printf '\n%d/%d tests passed\n' "$PASSED" "$TOTAL"
    [[ $FAILED -eq 0 ]]
}

main "$@"
