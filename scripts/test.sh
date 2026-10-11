#!/bin/zsh

# 在一次性 macOS 虚拟机中构建当前代码，验收真实桌面流程及少量故障注入例外。
# 宿主只调度与保存结果，应用、Finder 和输入操作均发生在 guest。

set -euo pipefail
exec /usr/bin/python3 "${0:A:h}/test-vm.py" run "$@"
