#!/bin/zsh

# 在一次性虚拟机内构建稳定签名的桌面驱动，准备当前 Debug Finder 环境并执行真实用户验收。
# 输出由调用方指定在仓库 scratch 内；账户、权限和签名不满足时立即失败。

set -euo pipefail
readonly script_path="${0:A}"
readonly project_root="${script_path:h:h}"
readonly developer_directory="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
readonly destination="${XCODE_DESTINATION:-platform=macOS,arch=arm64}"
readonly helper_identifier="com.axiomace.ecmenu.test.findermenuautomation"
readonly desktop_job_runner="$project_root/Tests/Infrastructure/VirtualMachine/run-desktop-job.py"

if (( $# != 1 )); then
    print -u2 'Usage: ./scripts/test-desktop-guest.sh <absolute-scratch-result-directory>'
    exit 64
fi
[[ "$(/usr/sbin/sysctl -n kern.hv_vmm_present 2>/dev/null)" == 1 \
    && "$(id -u)" == "$(/usr/bin/stat -f %u /dev/console)" ]] || {
    print -u2 'Desktop acceptance must run as the logged-in desktop account inside a virtual machine.'
    exit 1
}
readonly output_directory="${1:A}"
[[ "$output_directory" == "$project_root/.artifacts/scratch/tests/"* ]] || {
    print -u2 'Desktop evidence must stay inside the project scratch/tests directory.'
    exit 64
}
mkdir -p "$output_directory"
cd "$project_root"
source "$project_root/scripts/lib/product-paths.sh"
source "$project_root/scripts/lib/code-signing.sh"
source "$project_root/scripts/lib/process-lifecycle.sh"

DEVELOPER_DIR="$developer_directory" xcodebuild \
    -project "$project_root/ECMenu.xcodeproj" -scheme FinderMenuAutomation \
    -configuration Debug -destination "$destination" \
    -derivedDataPath "$project_root/.derivedData" build -quiet \
    >"$output_directory/helper-build.log" 2>&1
readonly helper_path="$project_root/.derivedData/Build/Products/Debug/FinderMenuAutomation.app/Contents/MacOS/FinderMenuAutomation"
codesign --verify --strict "$helper_path" 2>"$output_directory/helper-signature.log"
[[ "$(ecmenu_code_signing_value "$helper_path" Identifier)" == "$helper_identifier" ]] || {
    print -u2 'Desktop helper has an unexpected signing identifier.'
    exit 1
}
python3 "$desktop_job_runner" "$output_directory/desktop-jobs/permissions" -- \
    "$helper_path" permissions >"$output_directory/permissions.log" 2>&1 || {
    print -u2 "Project template requires Accessibility and Screen Recording for $helper_identifier. See $output_directory/permissions.log"
    exit 1
}
ecmenu_resolve_product_paths "$project_root/.derivedData/Build/Products/Debug"
readonly app_path="$ECMENU_PRODUCT_APP_PATH"
readonly app_identifier="$ECMENU_PRODUCT_APPLICATION_BUNDLE_IDENTIFIER"
[[ "$app_identifier" == *.debug ]] || exit 1
readonly helper_team="$(ecmenu_code_signing_value "$helper_path" TeamIdentifier)"
[[ -n "$helper_team" && "$helper_team" != not\ set \
    && "$(ecmenu_code_signing_value "$app_path" TeamIdentifier)" == "$helper_team" ]] || {
    print -u2 'Product and desktop helper require the same real development signing team.'
    exit 1
}

# 每轮 clone 中只清理当前 Debug 身份的数据，令用例从可重复的空配置开始。
readonly previous_main_pids="$(process_ids_for_executable "$ECMENU_PRODUCT_MAIN_EXECUTABLE_PATH")"
terminate_process_ids "$previous_main_pids"
wait_for_process_ids_to_exit "$previous_main_pids" 100
/usr/bin/defaults delete "$app_identifier" >/dev/null 2>&1 || true
/bin/rm -rf "$HOME/Library/Application Support/$app_identifier/FileTemplates"
/usr/bin/defaults write "$app_identifier" AppleLanguages -array en
/usr/bin/defaults write com.apple.finder AppleLanguages -array en
"$project_root/scripts/run-debug.sh" --no-build --refresh-finder --no-open-finder-window \
    >"$output_directory/product-launch.log" 2>&1

python3 "$desktop_job_runner" --timeout 900 "$output_directory/desktop-jobs/suite" -- \
    "$helper_path" desktop-suite "$app_path" "$output_directory" \
    >"$output_directory/desktop.stdout.log" 2>"$output_directory/desktop.stderr.log"
print "Desktop acceptance evidence: $output_directory"
