#!/bin/zsh

# 为本机手动开发入口接入最外层用户焦点恢复会话。
# 通过重执行包装原命令，让嵌套脚本共用一次前台应用快照与最终恢复。

ecmenu_reexec_preserving_user_focus() {
    local script_path="$1"
    shift

    [[ "$(/usr/sbin/sysctl -n kern.hv_vmm_present 2>/dev/null || true)" == 1 ]] && return 0
    [[ -n "${ECMENU_USER_FOCUS_SESSION:-}" ]] && return 0
    exec "${script_path:A:h}/lib/with-user-focus-restored.sh" \
        "$script_path" \
        "$@"
}
