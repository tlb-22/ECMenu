#!/bin/zsh

# 从公共基线重新派生 ECMenu 项目模板，准备应用、构建缓存及桌面驱动权限。
# 公共模板保持不变，签名私钥在封存前从 guest 移除。

set -euo pipefail
exec /usr/bin/python3 "${0:A:h}/test-vm.py" prepare "$@"
