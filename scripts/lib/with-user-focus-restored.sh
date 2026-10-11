#!/bin/zsh

# 包装本机手动开发命令，记录原前台应用并在正常结束或中断后恢复焦点。
# 构建独立恢复工具，管理子进程会话和信号清理，保留恢复诊断。

set -euo pipefail
unsetopt BG_NICE

readonly script_path="${0:A}"
readonly script_directory="${script_path:h}"
readonly project_root="${script_directory:h:h}"
readonly run_timestamp="$(date '+%Y%m%d-%H%M%S')"
readonly run_name="$run_timestamp-user-focus-$$"
readonly probe_directory="$project_root/.artifacts/scratch/probes/$run_name"
readonly log_directory="$project_root/.artifacts/scratch/logs/$run_name"
readonly build_log="$log_directory/build.log"
readonly focus_log="$log_directory/focus.log"
readonly model_source="$project_root/scripts/lib/UserFocusRestoration/Support/UserFocusRestorationModel.swift"
readonly restorer_source="$project_root/scripts/lib/UserFocusRestoration/Support/UserFocusRestorer.swift"
readonly restorer="$probe_directory/UserFocusRestorer"
readonly developer_directory="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if (( $# == 0 )); then
    print -u2 "Usage: with-user-focus-restored.sh <command> [argument ...]"
    exit 64
fi
if [[ -n "${ECMENU_USER_FOCUS_SESSION:-}" ]]; then
    exec "$@"
fi

mkdir -p "$probe_directory/module-cache" "$log_directory"
if DEVELOPER_DIR="$developer_directory" xcrun swiftc \
    -module-cache-path "$probe_directory/module-cache" \
    "$model_source" \
    "$restorer_source" \
    -framework AppKit \
    -o "$restorer" \
    >"$build_log" 2>&1; then
    :
else
    build_status=$?
    print -u2 "User focus helper build failed: $build_log"
    tail -n 200 "$build_log" >&2
    exit "$build_status"
fi

if focus_snapshot="$("$restorer" capture 2>>"$focus_log")"; then
    :
else
    capture_status=$?
    print -u2 "Could not preserve the current user focus: $focus_log"
    exit "$capture_status"
fi
readonly focus_snapshot

restore_user_focus() {
    local exit_status=$?
    local restore_status=0

    trap - EXIT
    trap '' HUP INT TERM
    if [[ -n "$focus_snapshot" ]]; then
        "$restorer" restore "$focus_snapshot" >>"$focus_log" 2>&1 \
            || restore_status=$?
    fi
    if (( restore_status != 0 )); then
        print -u2 "Could not restore the original user focus: $focus_log"
        if (( exit_status == 0 )); then
            exit_status=$restore_status
        fi
    fi
    exit "$exit_status"
}

terminate_child_session() {
    local signal_name="$1"
    local signal_status="$2"

    trap '' HUP INT TERM
    if [[ -n "$child_pid" ]]; then
        if /bin/kill -0 -- "-$child_pid" 2>/dev/null; then
            /bin/kill -s "$signal_name" -- "-$child_pid" \
                2>/dev/null || true
        elif /bin/kill -0 "$child_pid" 2>/dev/null; then
            /bin/kill -s "$signal_name" "$child_pid" \
                2>/dev/null || true
        fi
        wait "$child_pid" 2>/dev/null || true
        child_pid=""
    fi
    exit "$signal_status"
}

trap restore_user_focus EXIT
trap 'terminate_child_session HUP 129' HUP
trap 'terminate_child_session INT 130' INT
trap 'terminate_child_session TERM 143' TERM

child_pid=""
"$restorer" launch \
    /usr/bin/env \
    ECMENU_USER_FOCUS_SESSION="$run_name" \
    "$@" &
child_pid=$!

if wait "$child_pid"; then
    child_status=0
else
    child_status=$?
fi
child_pid=""
exit "$child_status"
