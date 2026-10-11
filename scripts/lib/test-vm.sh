#!/bin/zsh

# 将自动桌面入口调度到一次性虚拟机，guest 继续执行本地真实流程。
# 宿主只管理输入与结果，不接收自动化键鼠事件。

readonly ecmenu_test_vm_controller="${${(%):-%N}:A:h:h}/test-vm.py"

ecmenu_run_in_test_vm() {
    local action="$1"
    shift
    if [[ "$(/usr/sbin/sysctl -n kern.hv_vmm_present 2>/dev/null || true)" == 1 ]]; then
        return 0
    fi
    exec /usr/bin/python3 "$ecmenu_test_vm_controller" "$action" -- "$@"
}
