#!/bin/zsh

# 批量启动独立预览场景并生成两种语言的窗口截图。
# 依据预览进程的就绪与焦点回执完成捕获，管理本轮会话清理。

set -euo pipefail

readonly script_path="${0:A}"
readonly script_directory="${script_path:h}"
readonly project_root="${script_directory:h}"

source "$script_directory/lib/process-lifecycle.sh"

readonly derived_data_path="$project_root/.derivedData"
readonly run_timestamp="$(date '+%Y%m%d-%H%M%S')"
readonly app_path="$derived_data_path/Build/Products/Debug/ECMenuPreviews.app"
readonly preview_executable="$app_path/Contents/MacOS/ECMenuPreviews"
readonly output_directory="$project_root/.artifacts/scratch/previews/$run_timestamp-localized-previews-$$"
readonly log_directory="$project_root/.artifacts/scratch/logs/$run_timestamp-localized-previews-$$"
readonly build_log="$log_directory/build.log"
readonly capture_log="$log_directory/capture.log"
readonly helper_build_log="$log_directory/helper-build.log"
readonly helper_executable="$derived_data_path/Build/Products/Debug/FinderMenuAutomation.app/Contents/MacOS/FinderMenuAutomation"
readonly desktop_job_runner="$project_root/Tests/Infrastructure/VirtualMachine/run-desktop-job.py"
readonly desktop_job_directory="$project_root/.artifacts/scratch/tests/$run_timestamp-preview-capture-$$/desktop-jobs"
readonly developer_directory="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
readonly destination="${XCODE_DESTINATION:-platform=macOS,arch=arm64}"
readonly -a languages=(en zh-Hans)

active_preview_pid=""
typeset -a requested_preview_ids=()
typeset -a registered_preview_ids=()
typeset -a selected_preview_ids=()

usage() {
    print "Usage: ./scripts/capture-previews.sh [<preview-id> ...]"
}

log() {
    print -r -- "$1"
    print -r -- "$1" >>"$capture_log"
}

fail() {
    local message="$1"

    print -u2 -r -- "$message"
    print -r -- "ERROR: $message" >>"$capture_log"
    print -u2 "Capture log: $capture_log"
    exit 1
}

parse_arguments() {
    if (( $# == 1 )) && [[ "$1" == --help || "$1" == -h ]]; then
        usage
        exit 0
    fi

    while (( $# > 0 )); do
        [[ -n "$1" && "$1" != --* ]] || {
            usage >&2
            exit 64
        }
        requested_preview_ids+=("$1")
        shift
    done
}

load_preview_registry() {
    local preview_ids_text="$1"
    local preview_id
    local -A seen_preview_ids=()

    while IFS= read -r preview_id; do
        [[ -n "$preview_id" ]] || continue
        [[ "$preview_id" != */* ]] \
            || fail "Preview ID cannot be used as a filename: $preview_id"
        if (( ${+seen_preview_ids[$preview_id]} )); then
            fail "A Preview ID was registered more than once: $preview_id"
        fi
        seen_preview_ids[$preview_id]=1
        registered_preview_ids+=("$preview_id")
    done <<<"$preview_ids_text"

    (( ${#registered_preview_ids[@]} > 0 )) \
        || fail "The Preview registry is empty."
}

select_requested_previews() {
    local requested_id
    local registered_id
    local is_registered
    local -A seen_requested_ids=()

    if (( ${#requested_preview_ids[@]} == 0 )); then
        selected_preview_ids=("${registered_preview_ids[@]}")
        return
    fi

    for requested_id in "${requested_preview_ids[@]}"; do
        is_registered=false
        for registered_id in "${registered_preview_ids[@]}"; do
            if [[ "$requested_id" == "$registered_id" ]]; then
                is_registered=true
                break
            fi
        done
        $is_registered || fail "Unknown Preview ID: $requested_id"
        if (( ${+seen_requested_ids[$requested_id]} )); then
            fail "A Preview ID was requested more than once: $requested_id"
        fi
        seen_requested_ids[$requested_id]=1
        selected_preview_ids+=("$requested_id")
    done
}

terminate_active_preview() {
    local attempt
    local process_state
    local pid="${active_preview_pid:-}"

    [[ -n "$pid" ]] || return 0

    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true

        for attempt in {1..30}; do
            process_state="$(ps -p "$pid" -o state= 2>/dev/null || true)"
            if [[ -z "$process_state" || "$process_state" == *Z* ]]; then
                break
            fi
            sleep 0.1
        done

        process_state="$(ps -p "$pid" -o state= 2>/dev/null || true)"
        if [[ -n "$process_state" && "$process_state" != *Z* ]]; then
            kill -KILL "$pid" 2>/dev/null || true
        fi
    fi

    wait "$pid" 2>/dev/null || true
    active_preview_pid=""
}

cleanup() {
    terminate_active_preview
}

terminate_existing_previews() {
    local process_ids="$(process_ids_for_executable "$preview_executable")"
    terminate_process_ids "$process_ids"
    wait_for_process_ids_to_exit "$process_ids" 30 \
        || fail "A previous Preview process did not exit: $preview_executable"
}

wait_for_ready_window() {
    local pid="$1"
    local stdout_log="$2"
    local attempt
    local window_id

    for attempt in {1..300}; do
        window_id="$(
            /usr/bin/awk '
                $1 == "READY" && $2 ~ /^[0-9]+$/ && NF == 2 {
                    print $2
                    exit
                }
            ' "$stdout_log"
        )"
        if [[ -n "$window_id" ]]; then
            print -r -- "$window_id"
            return 0
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            return 1
        fi
        sleep 0.1
    done

    return 1
}

wait_for_capture_verdict() {
    local pid="$1"
    local stdout_log="$2"
    local attempt
    local verdict

    for attempt in {1..100}; do
        verdict="$(
            /usr/bin/awk '
                ($1 == "CAPTURED" || $1 == "FOCUS_LOST") && $2 ~ /^[0-9]+$/ && NF == 2 {
                    print $1 " " $2
                    exit
                }
            ' "$stdout_log"
        )"
        if [[ -n "$verdict" ]]; then
            print -r -- "$verdict"
            return 0
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            return 1
        fi
        sleep 0.1
    done

    return 1
}

png_dimensions() {
    local image_path="$1"
    local metadata
    local metadata_line
    local image_format=""
    local pixel_width=""
    local pixel_height=""

    metadata="$(
        /usr/bin/sips \
            -g format \
            -g pixelWidth \
            -g pixelHeight \
            "$image_path" \
            2>>"$capture_log"
    )" || return 1

    for metadata_line in "${(@f)metadata}"; do
        case "$metadata_line" in
            *"format: "*)
                image_format="${metadata_line##*: }"
                ;;
            *"pixelWidth: "*)
                pixel_width="${metadata_line##*: }"
                ;;
            *"pixelHeight: "*)
                pixel_height="${metadata_line##*: }"
                ;;
        esac
    done

    if [[ "$image_format" != png \
        || "$pixel_width" != <-> \
        || "$pixel_height" != <-> ]] \
        || (( pixel_width <= 0 || pixel_height <= 0 )); then
        return 1
    fi

    print -r -- "${pixel_width}x${pixel_height}"
}

capture_preview() {
    local preview_id="$1"
    local language="$2"
    local preview_name="$preview_id-$language"
    local stdout_log="$log_directory/$preview_name.stdout.log"
    local stderr_log="$log_directory/$preview_name.stderr.log"
    local image_path="$output_directory/$preview_name.png"
    local window_id
    local focus_verdict
    local capture_status
    local image_dimensions

    log "Capturing $preview_id [$language]"
    "$preview_executable" \
        --preview-ui "$preview_id" \
        -AppleLanguages "($language)" \
        >"$stdout_log" \
        2>"$stderr_log" &
    active_preview_pid=$!

    if window_id="$(
        wait_for_ready_window "$active_preview_pid" "$stdout_log"
    )"; then
        :
    else
        fail "Preview did not report a ready window: $preview_name. Details: $stderr_log"
    fi

    if python3 "$desktop_job_runner" "$desktop_job_directory/$preview_name" -- \
        "$helper_executable" window-image "$window_id" "$image_path" \
        >>"$capture_log" 2>&1; then
        :
    else
        capture_status=$?
        fail "Could not capture $preview_name (status $capture_status)."
    fi

    if ! kill -USR1 "$active_preview_pid" 2>/dev/null; then
        /bin/rm -f "$image_path"
        fail "Could not request focus verification: $preview_name. Details: $stderr_log"
    fi
    if focus_verdict="$(
        wait_for_capture_verdict "$active_preview_pid" "$stdout_log"
    )"; then
        :
    else
        /bin/rm -f "$image_path"
        fail "Preview did not verify capture focus: $preview_name. Details: $stderr_log"
    fi
    if [[ "$focus_verdict" != "CAPTURED $window_id" ]]; then
        /bin/rm -f "$image_path"
        fail "Preview lost focus while capturing: $preview_name"
    fi

    if [[ ! -s "$image_path" ]]; then
        fail "Screenshot is empty: $image_path"
    fi
    if image_dimensions="$(png_dimensions "$image_path")"; then
        :
    else
        fail "Screenshot is not a non-empty PNG with valid dimensions: $image_path"
    fi

    terminate_active_preview
    log "Captured $preview_name.png ($image_dimensions)"
}

parse_arguments "$@"

source "$script_directory/lib/test-vm.sh"
ecmenu_run_in_test_vm previews "$@"

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$output_directory" "$log_directory"
cd "$project_root"

terminate_existing_previews

if DEVELOPER_DIR="$developer_directory" xcodebuild \
    -project ECMenu.xcodeproj \
    -scheme ECMenuPreviews \
    -configuration Debug \
    -destination "$destination" \
    -derivedDataPath "$derived_data_path" \
    build -quiet >"$build_log" 2>&1; then
    :
else
    build_status=$?
    print -u2 "Preview build failed. Log: $build_log"
    tail -n 200 "$build_log" >&2
    exit "$build_status"
fi

if DEVELOPER_DIR="$developer_directory" xcodebuild \
    -project ECMenu.xcodeproj -scheme FinderMenuAutomation -configuration Debug \
    -destination "$destination" -derivedDataPath "$derived_data_path" build -quiet \
    >"$helper_build_log" 2>&1; then
    :
else
    fail "Could not build the signed desktop screenshot driver. Details: $helper_build_log"
fi
source "$script_directory/lib/product-paths.sh"
source "$script_directory/lib/code-signing.sh"
ecmenu_resolve_product_paths "$derived_data_path/Build/Products/Debug" \
    || fail "Could not resolve the actual Debug product for screenshot signing."
codesign --verify --strict "$helper_executable" 2>>"$helper_build_log" \
    || fail "Desktop screenshot driver signature is invalid."
readonly helper_team="$(ecmenu_code_signing_value "$helper_executable" TeamIdentifier)"
[[ -n "$helper_team" && "$helper_team" != not\ set \
    && "$(ecmenu_code_signing_value "$helper_executable" Identifier)" == com.axiomace.ecmenu.test.findermenuautomation \
    && "$(ecmenu_code_signing_value "$ECMENU_PRODUCT_APP_PATH" TeamIdentifier)" == "$helper_team" ]] \
    || fail "Desktop screenshot driver requires the actual product's real signing team."
python3 "$desktop_job_runner" "$desktop_job_directory/permissions" -- \
    "$helper_executable" permissions >>"$capture_log" 2>&1 \
    || fail "The project template requires desktop screenshot driver permissions."

if preview_ids_text="$("$preview_executable" --list 2>>"$capture_log")"; then
    :
else
    list_status=$?
    fail "Could not list Preview IDs (status $list_status)."
fi

load_preview_registry "$preview_ids_text"
select_requested_previews

log "Preview IDs: ${(j:, :)selected_preview_ids}"
log "Languages: ${(j:, :)languages}"

for preview_id in "${selected_preview_ids[@]}"; do
    for language in "${languages[@]}"; do
        capture_preview "$preview_id" "$language"
    done
done

print "Localized previews: $output_directory"
print "Capture logs: $log_directory"
