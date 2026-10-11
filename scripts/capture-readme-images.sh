#!/bin/zsh

# 协调生产界面预览和真实 Finder 菜单截图，生成并同步中英文 README 总览图。
# 从预览产物读取版本，更新带版本的图片及 README 引用，保留本轮日志和中间产物。

set -euo pipefail

readonly script_path="${0:A}"
readonly script_directory="${script_path:h}"
readonly project_root="${script_directory:h}"

usage() {
    print "Usage: ./scripts/capture-readme-images.sh"
}

if (( $# != 0 )); then
    usage >&2
    exit 64
fi

source "$script_directory/lib/test-vm.sh"
ecmenu_run_in_test_vm readme "$@"

readonly run_timestamp="$(date '+%Y%m%d-%H%M%S')"
readonly run_name="$run_timestamp-readme-image-capture-$$"
readonly test_directory="$project_root/.artifacts/scratch/tests/$run_name"
readonly composition_directory="$project_root/.artifacts/scratch/previews/$run_name"
readonly log_directory="$project_root/.artifacts/scratch/logs/$run_name"
readonly documentation_image_directory="$project_root/.docs/images"
readonly composer_source="$project_root/Tests/READMEImageCapture/Support/READMEOverviewComposer.swift"
readonly composer_executable="$test_directory/READMEOverviewComposer"
readonly composer_build_log="$log_directory/composer-build.log"
readonly composer_log="$log_directory/composer.log"
readonly finder_capture_stdout="$log_directory/finder-capture.stdout.log"
readonly preview_capture_stdout="$log_directory/preview-capture.stdout.log"
readonly template_fixture_directory="$test_directory/template-fixture"
readonly template_fixture_stdout="$log_directory/template-fixture.stdout.log"
readonly template_fixture_build_log="$log_directory/template-fixture-build.log"
readonly generated_english_image="$composition_directory/overview-en.png"
readonly generated_chinese_image="$composition_directory/overview-zh-Hans.png"
readonly temporary_english_image="$documentation_image_directory/.overview-en.$$.png"
readonly temporary_chinese_image="$documentation_image_directory/.overview-zh-Hans.$$.png"
readonly developer_directory="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
readonly desktop_job_runner="$project_root/Tests/VirtualMachine/run-desktop-job.py"

fail() {
    print -u2 -r -- "$1"
    print -u2 "README image logs: $log_directory"
    exit 1
}

cleanup() {
    /bin/rm -f "$temporary_english_image" "$temporary_chinese_image"
}

capture_output_directory() {
    local output_log="$1"
    local prefix="$2"
    local output_directory

    output_directory="$(
        /usr/bin/awk -v prefix="$prefix" '
            index($0, prefix) == 1 {
                path = substr($0, length(prefix) + 1)
            }
            END {
                if (path != "") print path
            }
        ' "$output_log"
    )"
    [[ "$output_directory" == "$project_root/.artifacts/scratch/previews/"* \
        && -d "$output_directory" ]] || return 1
    print -r -- "$output_directory"
}

require_source_image() {
    local image_path="$1"

    [[ -s "$image_path" ]] \
        || fail "README source screenshot is missing: $image_path"
}

png_dimensions() {
    local image_path="$1"
    local metadata
    local format
    local width
    local height
    local has_alpha

    metadata="$(
        /usr/bin/sips \
            -g format \
            -g pixelWidth \
            -g pixelHeight \
            -g hasAlpha \
            "$image_path" \
            2>>"$composer_log"
    )" || return 1
    format="$(print -r -- "$metadata" | /usr/bin/awk '/format:/ { print $2 }')"
    width="$(print -r -- "$metadata" | /usr/bin/awk '/pixelWidth:/ { print $2 }')"
    height="$(print -r -- "$metadata" | /usr/bin/awk '/pixelHeight:/ { print $2 }')"
    has_alpha="$(print -r -- "$metadata" | /usr/bin/awk '/hasAlpha:/ { print $2 }')"

    [[ "$format" == png \
        && "$width" == <-> \
        && "$height" == <-> \
        && "$has_alpha" == yes ]] \
        || return 1
    (( width > 0 && height > 0 )) || return 1
    print -r -- "${width}x${height}"
}

synchronize_image() {
    local source_path="$1"
    local destination_path="$2"
    local temporary_path="$3"

    if [[ -f "$destination_path" ]] \
        && /usr/bin/cmp -s "$source_path" "$destination_path"; then
        return
    fi
    /bin/cp "$source_path" "$temporary_path"
    /bin/chmod 0644 "$temporary_path"
    /bin/mv -f "$temporary_path" "$destination_path"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p \
    "$test_directory/module-cache" \
    "$composition_directory" \
    "$log_directory" \
    "$documentation_image_directory"

if DEVELOPER_DIR="$developer_directory" xcrun swiftc \
    -module-cache-path "$test_directory/module-cache" \
    "$composer_source" \
    -framework CoreGraphics \
    -framework ImageIO \
    -framework UniformTypeIdentifiers \
    -o "$composer_executable" \
    >"$composer_build_log" 2>&1; then
    :
else
    build_status=$?
    print -u2 "README image composer build failed: $composer_build_log"
    tail -n 200 "$composer_build_log" >&2
    exit "$build_status"
fi

if "$script_directory/capture-previews.sh" \
    readme-status-page-general \
    readme-status-page-context-menu \
    readme-status-page-file-templates \
    | /usr/bin/tee "$preview_capture_stdout"; then
    :
else
    capture_status=$?
    fail "README Preview capture failed with status $capture_status."
fi
preview_output_directory="$(
    capture_output_directory \
        "$preview_capture_stdout" \
        "Localized previews: "
)" || fail "Could not resolve the Preview screenshot directory."

# 真正的 Finder 模板通过用户管理流程准备，与固定 Preview 的三行内容保持对应。
source "$script_directory/lib/product-paths.sh"
ecmenu_resolve_product_paths "$project_root/.derivedData/Build/Products/Debug" \
    || fail "Could not resolve the current Debug product for README templates."
DEVELOPER_DIR="$developer_directory" xcodebuild \
    -project "$project_root/ECMenu.xcodeproj" -scheme FinderMenuAutomation \
    -configuration Debug -destination "${XCODE_DESTINATION:-platform=macOS,arch=arm64}" \
    -derivedDataPath "$project_root/.derivedData" build -quiet \
    >"$template_fixture_build_log" 2>&1 \
    || fail "Could not build the signed README desktop fixture driver."
readonly template_helper="$project_root/.derivedData/Build/Products/Debug/FinderMenuAutomation.app/Contents/MacOS/FinderMenuAutomation"
source "$script_directory/lib/code-signing.sh"
codesign --verify --strict "$template_helper" 2>>"$template_fixture_build_log" \
    || fail "README desktop fixture driver signature is invalid."
readonly template_helper_team="$(ecmenu_code_signing_value "$template_helper" TeamIdentifier)"
[[ -n "$template_helper_team" && "$template_helper_team" != not\ set \
    && "$(ecmenu_code_signing_value "$template_helper" Identifier)" == com.axiomace.ecmenu.test.findermenuautomation \
    && "$(ecmenu_code_signing_value "$ECMENU_PRODUCT_APP_PATH" TeamIdentifier)" == "$template_helper_team" ]] \
    || fail "README fixture driver requires the actual product's real signing team."
mkdir -p "$template_fixture_directory"
python3 "$desktop_job_runner" "$test_directory/desktop-jobs/template-fixture" -- \
    "$template_helper" prepare-readme-templates "$ECMENU_PRODUCT_APP_PATH" "$template_fixture_directory" \
    >"$template_fixture_stdout" 2>"$log_directory/template-fixture.stderr.log" \
    || fail "Could not prepare README templates through the real settings page."

readonly preview_version="$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$project_root/.derivedData/Build/Products/Debug/ECMenuPreviews.app/Contents/Info.plist"
)"
[[ "$preview_version" =~ '^[0-9]+(\.[0-9]+){0,2}$' ]] \
    || fail "Preview has an invalid version: $preview_version"
readonly english_image="$documentation_image_directory/overview-v$preview_version-en.png"
readonly chinese_image="$documentation_image_directory/overview-v$preview_version-zh-Hans.png"

if "$script_directory/capture-finder-menus.sh" \
    --language en \
    --language zh-Hans \
    --expect-template TXT \
    --expect-template Markdown \
    --expect-template Word \
    new-file-submenu \
    | /usr/bin/tee "$finder_capture_stdout"; then
    :
else
    capture_status=$?
    fail "README Finder menu capture failed with status $capture_status."
fi
finder_output_directory="$(
    capture_output_directory \
        "$finder_capture_stdout" \
        "Finder menu screenshots: "
)" || fail "Could not resolve the Finder screenshot directory."

english_general="$preview_output_directory/readme-status-page-general-en.png"
english_context_menu="$preview_output_directory/readme-status-page-context-menu-en.png"
english_templates="$preview_output_directory/readme-status-page-file-templates-en.png"
english_finder_menu="$finder_output_directory/en/new-file-submenu.png"
chinese_general="$preview_output_directory/readme-status-page-general-zh-Hans.png"
chinese_context_menu="$preview_output_directory/readme-status-page-context-menu-zh-Hans.png"
chinese_templates="$preview_output_directory/readme-status-page-file-templates-zh-Hans.png"
chinese_finder_menu="$finder_output_directory/zh-Hans/new-file-submenu.png"

for source_image in \
    "$english_general" \
    "$english_context_menu" \
    "$english_templates" \
    "$english_finder_menu" \
    "$chinese_general" \
    "$chinese_context_menu" \
    "$chinese_templates" \
    "$chinese_finder_menu"; do
    require_source_image "$source_image"
done

if "$composer_executable" \
    "$composition_directory" \
    "$english_general" \
    "$english_context_menu" \
    "$english_templates" \
    "$english_finder_menu" \
    "$chinese_general" \
    "$chinese_context_menu" \
    "$chinese_templates" \
    "$chinese_finder_menu" \
    >"$composer_log" 2>&1; then
    :
else
    composition_status=$?
    fail "README image composition failed with status $composition_status."
fi

english_dimensions="$(png_dimensions "$generated_english_image")" \
    || fail "Generated English README image is invalid."
chinese_dimensions="$(png_dimensions "$generated_chinese_image")" \
    || fail "Generated Chinese README image is invalid."
[[ "$english_dimensions" == "$chinese_dimensions" ]] \
    || fail "Generated README images have different dimensions."

synchronize_image \
    "$generated_english_image" \
    "$english_image" \
    "$temporary_english_image"
synchronize_image \
    "$generated_chinese_image" \
    "$chinese_image" \
    "$temporary_chinese_image"

python3 - "$project_root" "$preview_version" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
version = sys.argv[2]
updates = []
for readme_name, language in [("README.md", "en"), ("README.zh-Hans.md", "zh-Hans")]:
    readme = root / readme_name
    content = readme.read_text(encoding="utf-8")
    references = re.findall(r"\.docs/images/overview-[^\s\"')/]+\.png", content)
    if len(references) != 1:
        raise SystemExit(f"Expected one overview image in {readme_name}, found: {references}")
    current = f".docs/images/overview-v{version}-{language}.png"
    updates.append((readme, content.replace(references[0], current), references[0], current))
for readme, content, previous, current in updates:
    readme.write_text(content, encoding="utf-8")
    if previous != current:
        (root / previous).unlink()
PY
python3 "$script_directory/check-readme-images.py"

print "README images updated ($english_dimensions):"
print "  $english_image"
print "  $chinese_image"
print "Source screenshots:"
print "  $preview_output_directory"
print "  $finder_output_directory"
print "README image logs: $log_directory"
