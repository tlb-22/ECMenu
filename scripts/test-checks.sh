#!/bin/zsh

# 验证少量已批准的故障注入单测、Preview 构建和捕获定义静态完整性。
# 此入口用于普通 CI，不驱动桌面，也不代表产品端到端验收通过。

set -euo pipefail
readonly project_root="${0:A:h:h}"
readonly run_name="$(date '+%Y%m%d-%H%M%S')-checks-$$"
readonly result="$project_root/.artifacts/scratch/tests/$run_name"
mkdir -p "$result"
cd "$project_root"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcodebuild -project ECMenu.xcodeproj -scheme ECMenu -configuration Debug \
    -destination "${XCODE_DESTINATION:-platform=macOS,arch=arm64}" \
    -parallel-testing-enabled NO \
    -derivedDataPath .derivedData -resultBundlePath "$result/ECMenu.xcresult" \
    test -quiet >"$result/xctest.log" 2>&1 || { tail -n 120 "$result/xctest.log" >&2; exit 1; }
xcodebuild -project ECMenu.xcodeproj -scheme ECMenuPreviews -configuration Debug \
    -destination "${XCODE_DESTINATION:-platform=macOS,arch=arm64}" \
    -derivedDataPath .derivedData build -quiet >"$result/previews.log" 2>&1
.derivedData/Build/Products/Debug/ECMenuPreviews.app/Contents/MacOS/ECMenuPreviews --list >"$result/preview-registry.txt"
[[ -s "$result/preview-registry.txt" ]]
./scripts/capture-finder-menus.sh --check >"$result/finder-definitions.log" 2>&1
print "故障注入例外与构建检查通过；结果：$result"
