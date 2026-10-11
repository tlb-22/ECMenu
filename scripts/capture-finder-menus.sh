#!/bin/zsh

# 协调真实 Finder 菜单的场景选择、语言切换、隔离 fixture 和定向截图。
# 构建自动化工具并核对菜单与截图；桌面操作限制在虚拟机内。

set -euo pipefail

readonly script_path="${0:A}"
readonly script_directory="${script_path:h}"
readonly project_root="${script_directory:h}"
readonly definitions_path="$project_root/Tests/FinderMenuCapture/FinderMenuCaptureComposition.sh"
readonly language_definitions_path="$project_root/Tests/FinderMenuCapture/Languages/CaptureLanguages.sh"
readonly derived_data_path="$project_root/.derivedData"
readonly debug_products_directory="$derived_data_path/Build/Products/Debug"
readonly developer_directory="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
readonly destination="${XCODE_DESTINATION:-platform=macOS,arch=arm64}"
readonly helper_bundle_identifier="com.axiomace.ecmenu.test.findermenuautomation"
readonly desktop_job_runner="$project_root/Tests/VirtualMachine/run-desktop-job.py"
readonly finder_bundle_identifier="com.apple.finder"
readonly finder_app_path="/System/Library/CoreServices/Finder.app"
readonly finder_executable="$finder_app_path/Contents/MacOS/Finder"
readonly finder_launch_service="com.apple.Finder"
typeset -ra original_arguments=("$@")

source "$definitions_path"
source "$language_definitions_path"
source "$script_directory/lib/process-lifecycle.sh"
source "$script_directory/lib/product-paths.sh"
source "$script_directory/lib/code-signing.sh"

typeset -a registered_scenario_ids=()
typeset -a selected_scenario_ids=()
typeset -a registered_language_ids=()
typeset -a requested_language_ids=()
typeset -a selected_language_ids=()
typeset -a expected_template_titles=()
typeset mode=capture
typeset run_name=""
typeset test_directory=""
typeset output_directory=""
typeset log_directory=""
typeset build_log=""
typeset build_settings_log=""
typeset capture_log=""
typeset helper_executable=""
typeset app_path=""
typeset extension_path=""
typeset main_executable=""
typeset extension_executable=""
typeset main_bundle_identifier=""
typeset extension_bundle_identifier=""

usage() {
    print "Usage: ./scripts/capture-finder-menus.sh [--language <id>]... [--expect-template <title>]... [<scenario-id> ...]"
    print "       ./scripts/capture-finder-menus.sh --check"
    print "       ./scripts/capture-finder-menus.sh --list"
    print "       ./scripts/capture-finder-menus.sh --list-languages"
}

fail() {
    local message="$1"

    print -u2 -r -- "$message"
    if [[ -n "$capture_log" ]]; then
        print -r -- "ERROR: $message" >>"$capture_log"
        print -u2 "Capture log: $capture_log"
    fi
    exit 1
}

load_registry() {
    local scenario_id
    local scenario_ids_text
    local -A seen_ids=()

    if scenario_ids_text="$(finder_menu_capture_scenario_ids)"; then
        :
    else
        fail "Finder menu capture could not load its scenario registry."
    fi
    if [[ -n "$scenario_ids_text" ]]; then
        for scenario_id in "${(@f)scenario_ids_text}"; do
            [[ -n "$scenario_id" ]] \
                || fail "Finder menu capture registered an empty scenario ID."
            [[ "$scenario_id" =~ '^[a-z0-9]+(-[a-z0-9]+)*$' ]] \
                || fail "Finder menu capture registered an invalid scenario ID: $scenario_id"
            if (( ${+seen_ids[$scenario_id]} )); then
                fail "Finder menu capture registered a scenario twice: $scenario_id"
            fi
            seen_ids[$scenario_id]=1
            registered_scenario_ids+=("$scenario_id")
        done
    fi

    (( ${#registered_scenario_ids[@]} > 0 )) \
        || fail "The Finder menu capture registry is empty."
}

load_language_registry() {
    local language_id
    local language_ids_text
    local finder_resource_name
    local finder_marker_title
    local -A seen_ids=()

    if language_ids_text="$(finder_menu_capture_language_ids)"; then
        :
    else
        fail "Finder menu capture could not load its language registry."
    fi
    if [[ -n "$language_ids_text" ]]; then
        for language_id in "${(@f)language_ids_text}"; do
            [[ "$language_id" =~ '^[A-Za-z0-9]+([_-][A-Za-z0-9]+)*$' ]] \
                || fail "Finder menu capture registered an invalid language ID: $language_id"
            if (( ${+seen_ids[$language_id]} )); then
                fail "Finder menu capture registered a language twice: $language_id"
            fi
            seen_ids[$language_id]=1
            registered_language_ids+=("$language_id")

            finder_resource_name="$(
                finder_menu_capture_finder_resource_name "$language_id"
            )" || fail "Finder language has no resource mapping: $language_id"
            finder_marker_title="$(
                finder_menu_capture_finder_marker_title "$language_id"
            )" || fail "Finder language has no menu marker: $language_id"
            [[ -n "$finder_resource_name" && -n "$finder_marker_title" ]] \
                || fail "Finder language definition is incomplete: $language_id"
            [[ -d "$finder_app_path/Contents/Resources/$finder_resource_name.lproj" ]] \
                || fail "Finder does not contain the mapped localization for $language_id: $finder_resource_name.lproj"
        done
    fi

    (( ${#registered_language_ids[@]} > 0 )) \
        || fail "The Finder menu capture language registry is empty."
}

select_requested_languages() {
    local requested_id
    local registered_id
    local is_registered
    local -A seen_requested_ids=()

    if (( ${#requested_language_ids[@]} == 0 )); then
        selected_language_ids=("${registered_language_ids[@]}")
        return
    fi

    for requested_id in "${requested_language_ids[@]}"; do
        is_registered=false
        for registered_id in "${registered_language_ids[@]}"; do
            if [[ "$requested_id" == "$registered_id" ]]; then
                is_registered=true
                break
            fi
        done
        $is_registered || fail "Unsupported Finder menu capture language: $requested_id"
        if (( ${+seen_requested_ids[$requested_id]} )); then
            fail "Finder menu capture language was requested twice: $requested_id"
        fi
        seen_requested_ids[$requested_id]=1
        selected_language_ids+=("$requested_id")
    done
}

select_requested_scenarios() {
    local requested_id
    local registered_id
    local is_registered
    local -A seen_requested_ids=()

    if (( $# == 0 )); then
        selected_scenario_ids=("${registered_scenario_ids[@]}")
        return
    fi

    for requested_id in "$@"; do
        is_registered=false
        for registered_id in "${registered_scenario_ids[@]}"; do
            if [[ "$requested_id" == "$registered_id" ]]; then
                is_registered=true
                break
            fi
        done
        $is_registered || fail "Unknown Finder menu capture scenario: $requested_id"
        if (( ${+seen_requested_ids[$requested_id]} )); then
            fail "Finder menu capture scenario was requested twice: $requested_id"
        fi
        seen_requested_ids[$requested_id]=1
        selected_scenario_ids+=("$requested_id")
    done
}

parse_arguments() {
    local -a requested_scenario_ids=()

    if (( $# == 1 )); then
        case "$1" in
            --help|-h)
                usage
                exit 0
                ;;
            --list)
                print -l -- "${registered_scenario_ids[@]}"
                exit 0
                ;;
            --list-languages)
                print -l -- "${registered_language_ids[@]}"
                exit 0
                ;;
            --check)
                mode=check
                select_requested_languages
                select_requested_scenarios
                return
                ;;
        esac
    fi

    while (( $# > 0 )); do
        case "$1" in
            --language)
                if (( $# < 2 )) || [[ "$2" == --* ]]; then
                    usage >&2
                    exit 64
                fi
                requested_language_ids+=("$2")
                shift 2
                ;;
            --expect-template)
                if (( $# < 2 )) || [[ -z "$2" || "$2" == --* ]]; then
                    usage >&2
                    exit 64
                fi
                expected_template_titles+=("$2")
                shift 2
                ;;
            --*)
                usage >&2
                exit 64
                ;;
            *)
                requested_scenario_ids+=("$1")
                shift
                ;;
        esac
    done

    select_requested_languages
    select_requested_scenarios "${requested_scenario_ids[@]}"
    if (( ${#expected_template_titles[@]} > 0 )) \
        && (( ! ${selected_scenario_ids[(Ie)new-file-submenu]} )); then
        fail "--expect-template requires the new-file-submenu capture scenario."
    fi
}

initialize_run_directories() {
    local language_id
    local run_timestamp

    run_timestamp="$(date '+%Y%m%d-%H%M%S')"
    run_name="$run_timestamp-finder-menu-capture-$$"
    test_directory="$project_root/.artifacts/scratch/tests/$run_name"
    output_directory="$project_root/.artifacts/scratch/previews/$run_name"
    log_directory="$project_root/.artifacts/scratch/logs/$run_name"
    build_log="$log_directory/build.log"
    build_settings_log="$log_directory/helper-build-settings.json"
    capture_log="$log_directory/capture.log"
    helper_executable="$derived_data_path/Build/Products/Debug/FinderMenuAutomation.app/Contents/MacOS/FinderMenuAutomation"

    mkdir -p "$test_directory/fixtures" "$log_directory"
    if [[ "$mode" == capture ]]; then
        mkdir -p "$output_directory"
        for language_id in "${selected_language_ids[@]}"; do
            mkdir -p \
                "$output_directory/$language_id" \
                "$log_directory/$language_id"
        done
    fi
}

build_automation_helper() {
    local build_status
    local resolved_product_type
    local resolved_bundle_identifier
    local resolved_info_plist_setting
    local resolved_team_identifier
    local actual_bundle_identifier
    local signing_identifier
    local team_identifier
    local helper_bundle_path="$debug_products_directory/FinderMenuAutomation.app"
    local helper_info_path="$helper_bundle_path/Contents/Info.plist"
    local -a build_overrides=()

    if [[ "$mode" == check ]]; then
        build_overrides+=(CODE_SIGNING_ALLOWED=NO)
    else
        build_overrides+=(CODE_SIGNING_ALLOWED=YES)
    fi

    if DEVELOPER_DIR="$developer_directory" xcodebuild \
        -project "$project_root/ECMenu.xcodeproj" \
        -scheme FinderMenuAutomation \
        -configuration Debug \
        -destination "$destination" \
        -derivedDataPath "$derived_data_path" \
        "${build_overrides[@]}" \
        build -quiet \
        >"$build_log" 2>&1; then
        :
    else
        build_status=$?
        print -u2 "Finder automation helper build failed. Log: $build_log"
        tail -n 200 "$build_log" >&2
        exit "$build_status"
    fi

    [[ -x "$helper_executable" ]] \
        || fail "Finder automation helper is missing after the build."

    if DEVELOPER_DIR="$developer_directory" xcodebuild \
        -project "$project_root/ECMenu.xcodeproj" \
        -scheme FinderMenuAutomation \
        -configuration Debug \
        -destination "$destination" \
        -derivedDataPath "$derived_data_path" \
        "${build_overrides[@]}" \
        -showBuildSettings -json \
        >"$build_settings_log" 2>>"$build_log"; then
        :
    else
        fail "Could not resolve Finder automation helper build settings."
    fi
    resolved_product_type="$(/usr/bin/plutil \
        -extract 0.buildSettings.PRODUCT_TYPE raw -o - "$build_settings_log")" \
        || fail "Finder automation helper has no resolved product type."
    resolved_bundle_identifier="$(/usr/bin/plutil \
        -extract 0.buildSettings.PRODUCT_BUNDLE_IDENTIFIER raw -o - "$build_settings_log")" \
        || fail "Finder automation helper has no resolved bundle identifier."
    resolved_info_plist_setting="$(/usr/bin/plutil \
        -extract 0.buildSettings.GENERATE_INFOPLIST_FILE raw -o - "$build_settings_log")" \
        || fail "Finder automation helper has no generated bundle Info.plist setting."
    resolved_team_identifier="$(/usr/bin/plutil \
        -extract 0.buildSettings.DEVELOPMENT_TEAM raw -o - "$build_settings_log")" \
        || fail "Finder automation helper has no Development Team."

    [[ "$resolved_product_type" == com.apple.product-type.application \
        && "$resolved_bundle_identifier" == "$helper_bundle_identifier" \
        && "$resolved_info_plist_setting" == YES \
        && -n "$resolved_team_identifier" ]] \
        || fail "Finder automation helper does not have a stable TCC identity configuration."

    actual_bundle_identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$helper_info_path")" \
        || fail "Finder automation helper has no readable bundle Info.plist."
    [[ "$actual_bundle_identifier" == "$helper_bundle_identifier" \
        && "$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$helper_info_path")" == FinderMenuAutomation \
        && "$(/usr/bin/plutil -extract LSUIElement raw -o - "$helper_info_path")" == true ]] \
        || fail "Finder automation helper has unexpected application bundle metadata."

    if [[ "$mode" == capture ]]; then
        codesign --verify --strict "$helper_bundle_path" 2>>"$build_log" \
            || fail "Finder automation helper application signature is invalid."
        codesign --verify --strict "$helper_executable" 2>>"$build_log" \
            || fail "Finder automation helper signature is invalid."
        signing_identifier="$(ecmenu_code_signing_value "$helper_executable" Identifier)"
        team_identifier="$(ecmenu_code_signing_value "$helper_executable" TeamIdentifier)"
        [[ "$signing_identifier" == "$helper_bundle_identifier" \
            && "$team_identifier" == "$resolved_team_identifier" ]] \
            || fail "Finder automation helper does not have its stable Development identity."
    fi
}

localized_command_title() {
    finder_menu_capture_command_title "$1" "$2"
}

prepare_and_validate_fixtures() {
    local scenario_id
    local fixture_directory
    local context_kind
    local basename
    local command_key
    local language_id
    local localized_title
    local selected_basenames_text
    local required_command_keys_text
    local -a selected_basenames=()
    local -a required_command_keys=()
    local -a fixture_items=()

    for scenario_id in "${selected_scenario_ids[@]}"; do
        fixture_directory="$test_directory/fixtures/$scenario_id"
        finder_menu_capture_create_fixture \
            "$scenario_id" \
            "$fixture_directory"
        [[ -d "$fixture_directory" ]] \
            || fail "Scenario did not create its fixture directory: $scenario_id"

        context_kind="$(finder_menu_capture_context_kind "$scenario_id")"
        [[ "$context_kind" == container || "$context_kind" == items ]] \
            || fail "Scenario has an invalid Finder context kind: $scenario_id"

        if selected_basenames_text="$(
            finder_menu_capture_selected_basenames "$scenario_id"
        )"; then
            :
        else
            fail "Scenario could not resolve selected items: $scenario_id"
        fi
        selected_basenames=()
        if [[ -n "$selected_basenames_text" ]]; then
            for basename in "${(@f)selected_basenames_text}"; do
                [[ -n "$basename" && "$basename" != */* ]] \
                    || fail "Scenario has an invalid selected basename: $scenario_id"
                [[ -e "$fixture_directory/$basename" ]] \
                    || fail "Scenario selected item does not exist: $scenario_id/$basename"
                selected_basenames+=("$basename")
            done
        fi

        if [[ "$context_kind" == container ]]; then
            (( ${#selected_basenames[@]} == 0 )) \
                || fail "Container scenario selects Finder items: $scenario_id"
            fixture_items=("$fixture_directory"/*(ND))
            (( ${#fixture_items[@]} > 0 )) \
                || fail "Container scenario has no opening item: $scenario_id"
        else
            (( ${#selected_basenames[@]} > 0 )) \
                || fail "Items scenario has no Finder selection: $scenario_id"
        fi

        if required_command_keys_text="$(
            finder_menu_capture_required_command_keys "$scenario_id"
        )"; then
            :
        else
            fail "Scenario could not resolve required commands: $scenario_id"
        fi
        required_command_keys=()
        if [[ -n "$required_command_keys_text" ]]; then
            for command_key in "${(@f)required_command_keys_text}"; do
                [[ -n "$command_key" ]] \
                    || fail "Scenario has an empty command key: $scenario_id"
                for language_id in "${registered_language_ids[@]}"; do
                    localized_title="$(
                        localized_command_title "$command_key" "$language_id"
                    )" || fail "Scenario references an incomplete localized command: $scenario_id/$command_key/$language_id"
                    [[ -n "$localized_title" ]] \
                        || fail "Scenario references an empty localized command: $scenario_id/$command_key/$language_id"
                done
                required_command_keys+=("$command_key")
            done
        fi
        (( ${#required_command_keys[@]} > 0 )) \
            || fail "Scenario has no required ECMenu commands: $scenario_id"
    done
}

helper_error_description() {
    local stdout_log="$1"
    local error_line
    local record
    local error_code
    local encoded_message
    local message

    error_line="$(/usr/bin/awk -F '\t' '$1 == "ERROR" && NF == 3 {
        print
        exit
    }' "$stdout_log")"
    [[ -n "$error_line" ]] || return 1
    IFS=$'\t' read -r record error_code encoded_message <<<"$error_line"
    message="$(print -rn -- "$encoded_message" | /usr/bin/base64 -D)" \
        || return 1
    print -r -- "$error_code: $message"
}

menu_titles_from_log() {
    local stdout_log="$1"
    local expected_record="${2:-ITEM}"
    local encoded_title

    while IFS=$'\t' read -r record encoded_title; do
        [[ "$record" == "$expected_record" && -n "$encoded_title" ]] || continue
        print -rn -- "$encoded_title" | /usr/bin/base64 -D
        print
    done <"$stdout_log"
}

require_expected_menu_titles() {
    local language_id="$1"
    local scenario_id="$2"
    local stdout_log="$3"
    local image_path="$4"
    local command_key
    local expected_title
    local finder_marker_title
    local actual_title
    local found
    local menu_titles_text
    local required_command_keys_text
    local -a menu_titles=()

    menu_titles_text="$(menu_titles_from_log "$stdout_log")" \
        || fail "Could not decode Finder menu titles: $scenario_id"
    if [[ -n "$menu_titles_text" ]]; then
        menu_titles=("${(@f)menu_titles_text}")
    fi

    finder_marker_title="$(
        finder_menu_capture_finder_marker_title "$language_id"
    )" || fail "Finder language has no menu marker: $language_id"
    found=false
    for actual_title in "${menu_titles[@]}"; do
        if [[ "$actual_title" == "$finder_marker_title" ]]; then
            found=true
            break
        fi
    done
    if ! $found; then
        print -u2 "Finder menu items observed for $scenario_id [$language_id]:"
        for actual_title in "${menu_titles[@]}"; do
            print -u2 -r -- "  $actual_title"
        done
        /bin/rm -f "$image_path"
        fail "Finder menu did not use the requested language: $language_id"
    fi

    if required_command_keys_text="$(
        finder_menu_capture_required_command_keys "$scenario_id"
    )"; then
        :
    else
        fail "Scenario could not resolve required commands: $scenario_id"
    fi
    if [[ -n "$required_command_keys_text" ]]; then
        for command_key in "${(@f)required_command_keys_text}"; do
            expected_title="$(
                localized_command_title "$command_key" "$language_id"
            )"
            found=false
            for actual_title in "${menu_titles[@]}"; do
                if [[ "$actual_title" == "$expected_title" ]]; then
                    found=true
                    break
                fi
            done
            if ! $found; then
                print -u2 \
                    "Finder menu items observed for $scenario_id [$language_id]:"
                for actual_title in "${menu_titles[@]}"; do
                    print -u2 -r -- "  $actual_title"
                done
                /bin/rm -f "$image_path"
                fail "Required ECMenu command is absent in $language_id: $command_key"
            fi
        done
    fi
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

capture_scenario() {
    local language_id="$1"
    local scenario_id="$2"
    local fixture_directory="$test_directory/fixtures/$scenario_id"
    local stdout_log="$log_directory/$language_id/$scenario_id.stdout.log"
    local stderr_log="$log_directory/$language_id/$scenario_id.stderr.log"
    local image_path="$output_directory/$language_id/$scenario_id.png"
    local context_kind
    local basename
    local image_dimensions
    local helper_status=0
    local helper_error
    local selected_basenames_text
    local submenu_title
    local -a selected_paths=()
    local -a desktop_command=(python3 "$desktop_job_runner" "$test_directory/desktop-jobs/$language_id-$scenario_id" -- "$helper_executable")

    context_kind="$(finder_menu_capture_context_kind "$scenario_id")"
    if selected_basenames_text="$(
        finder_menu_capture_selected_basenames "$scenario_id"
    )"; then
        :
    else
        fail "Scenario could not resolve selected items: $scenario_id"
    fi
    if [[ -n "$selected_basenames_text" ]]; then
        for basename in "${(@f)selected_basenames_text}"; do
            selected_paths+=("$fixture_directory/$basename")
        done
    fi

    print -r -- "Capturing $scenario_id [$language_id]" \
        | tee -a "$capture_log"
    if [[ "$scenario_id" == new-file-submenu ]]; then
        submenu_title="$(localized_command_title command.newFile "$language_id")"
        "${desktop_command[@]}" submenu "$image_path" "$fixture_directory" "$submenu_title" \
            >"$stdout_log" 2>"$stderr_log" || helper_status=$?
    elif [[ "$context_kind" == container ]]; then
        "${desktop_command[@]}" container "$image_path" "$fixture_directory" \
            >"$stdout_log" 2>"$stderr_log" || helper_status=$?
    else
        "${desktop_command[@]}" items "$image_path" "${selected_paths[@]}" \
            >"$stdout_log" 2>"$stderr_log" || helper_status=$?
    fi
    if (( helper_status != 0 )); then
        /bin/rm -f "$image_path"
        helper_error="$(helper_error_description "$stdout_log" || true)"
        fail "Finder menu capture failed: $scenario_id${helper_error:+ ($helper_error)}. Logs: $stdout_log, $stderr_log"
    fi

    if ! /usr/bin/grep -qx CAPTURED "$stdout_log"; then
        /bin/rm -f "$image_path"
        fail "Finder helper did not confirm a stable capture: $scenario_id"
    fi
    require_expected_menu_titles \
        "$language_id" \
        "$scenario_id" \
        "$stdout_log" \
        "$image_path"
    if [[ "$scenario_id" == new-file-submenu ]] && (( ${#expected_template_titles[@]} > 0 )); then
        local actual_templates="$(menu_titles_from_log "$stdout_log" SUBITEM)"
        local expected_templates="$(print -l -- "${expected_template_titles[@]}")"
        if [[ "$actual_templates" != "$expected_templates" ]]; then
            /bin/rm -f "$image_path"
            fail "Actual Finder template submenu differs from the independent expected rows for $language_id. Logs: $stdout_log"
        fi
    fi

    if [[ -s "$image_path" ]] \
        && image_dimensions="$(png_dimensions "$image_path")"; then
        :
    else
        /bin/rm -f "$image_path"
        fail "Screenshot is not a non-empty PNG: $image_path"
    fi

    print -r -- "Captured $language_id/$scenario_id.png ($image_dimensions)" \
        | tee -a "$capture_log"
}

resolve_debug_products() {
    local language_id

    if ! ecmenu_resolve_product_paths "$debug_products_directory"; then
        fail "Could not uniquely resolve the built Debug products."
    fi

    app_path="$ECMENU_PRODUCT_APP_PATH"
    extension_path="$ECMENU_PRODUCT_EXTENSION_PATH"
    main_executable="$ECMENU_PRODUCT_MAIN_EXECUTABLE_PATH"
    extension_executable="$ECMENU_PRODUCT_EXTENSION_EXECUTABLE_PATH"
    main_bundle_identifier="$ECMENU_PRODUCT_APPLICATION_BUNDLE_IDENTIFIER"
    extension_bundle_identifier="$ECMENU_PRODUCT_EXTENSION_BUNDLE_IDENTIFIER"

    [[ "$main_bundle_identifier" == *.debug \
        && "$extension_bundle_identifier" \
            == "$main_bundle_identifier.finderext" ]] \
        || fail "Finder menu capture resolved a product outside the Debug identity tree."

    for language_id in "${registered_language_ids[@]}"; do
        [[ -f "$extension_path/Contents/Resources/$language_id.lproj/Localizable.strings" ]] \
            || fail "Built Finder Extension lacks localization: $language_id"
    done
}

finder_window_count() {
    local label="$1"
    local stdout_log="$log_directory/finder-windows-$label.stdout.log"
    local stderr_log="$log_directory/finder-windows-$label.stderr.log"
    local report
    local record
    local count

    if python3 "$desktop_job_runner" "$test_directory/desktop-jobs/finder-windows-$label" -- \
        "$helper_executable" finder-windows \
        >"$stdout_log" 2>"$stderr_log"; then
        :
    else
        print -u2 \
            "Could not inspect Finder windows. Logs: $stdout_log, $stderr_log"
        return 1
    fi
    report="$(
        /usr/bin/awk -F '\t' '$1 == "FINDER_WINDOWS" && NF == 2 {
            print
            exit
        }' "$stdout_log"
    )"
    [[ -n "$report" ]] || return 1
    IFS=$'\t' read -r record count <<<"$report"
    [[ "$count" == <-> ]] || return 1
    print -r -- "$count"
}

wait_for_no_finder_windows() {
    local label="$1"
    local maximum_attempts="${2:-1}"
    local count=""
    local last_count=""
    local attempt
    local consecutive_zeroes=0
    local last_probe_succeeded=false

    for (( attempt = 1; attempt <= maximum_attempts; attempt++ )); do
        if count="$(finder_window_count "$label-$attempt")"; then
            last_probe_succeeded=true
            last_count="$count"
            if (( count == 0 )); then
                (( consecutive_zeroes += 1 ))
                if (( maximum_attempts == 1 || consecutive_zeroes == 2 )); then
                    return 0
                fi
            else
                consecutive_zeroes=0
            fi
        else
            last_probe_succeeded=false
            consecutive_zeroes=0
        fi
        if (( attempt < maximum_attempts )); then
            sleep 0.1
        fi
    done

    $last_probe_succeeded || return 2
    (( last_count != 0 )) || return 2
    print -r -- "$last_count"
    return 1
}

require_no_finder_windows() {
    local label="$1"
    local maximum_attempts="${2:-1}"
    local remaining_count=""
    local probe_status

    if remaining_count="$(
        wait_for_no_finder_windows "$label" "$maximum_attempts"
    )"; then
        return
    else
        probe_status=$?
    fi
    (( probe_status != 2 )) \
        || fail "Could not determine the current Finder window count."
    fail "Guest Finder window leak at $label. Current count: $remaining_count"
}

restart_debug_finder_environment() {
    local label="$1"
    local lifecycle_log="$log_directory/$label-processes.log"
    local previous_main_pids
    local previous_extension_pids
    local previous_finder_pids
    local current_main_pids_text
    local current_extension_pids_text
    local extension_command_line
    local -a current_main_pids=()
    local -a current_extension_pids=()

    previous_main_pids="$(process_ids_for_executable "$main_executable")"
    previous_extension_pids="$(
        process_ids_for_executable "$extension_executable"
    )"
    previous_finder_pids="$(process_ids_for_executable "$finder_executable")"
    {
        print -r -- "previous-main-pids=${previous_main_pids//$'\n'/,}"
        print -r -- \
            "previous-extension-pids=${previous_extension_pids//$'\n'/,}"
        print -r -- "previous-finder-pids=${previous_finder_pids//$'\n'/,}"
    } >>"$lifecycle_log"

    terminate_process_ids "$previous_extension_pids"

    restart_gui_launch_service "$finder_launch_service" \
        >>"$lifecycle_log" 2>&1 \
        || return 1

    wait_for_process_ids_to_exit "$previous_extension_pids" 150 \
        || return 1
    wait_for_process_ids_to_exit "$previous_finder_pids" 150 \
        || return 1

    wait_for_process "$finder_executable" 150 || return 1

    wait_for_process "$extension_executable" 150 || return 1

    current_main_pids_text="$(process_ids_for_executable "$main_executable")"
    current_extension_pids_text="$(
        process_ids_for_executable "$extension_executable"
    )"
    if [[ -n "$current_main_pids_text" ]]; then
        current_main_pids=("${(@f)current_main_pids_text}")
    fi
    if [[ -n "$current_extension_pids_text" ]]; then
        current_extension_pids=("${(@f)current_extension_pids_text}")
    fi
    (( ${#current_main_pids[@]} == 1 \
        && ${#current_extension_pids[@]} == 1 )) \
        || return 1
    [[ "$current_main_pids_text" == "$previous_main_pids" ]] \
        || return 1

    extension_command_line="$(
        ps -ww -p "$current_extension_pids[1]" -o command=
    )" || return 1
    {
        print -r -- "current-main-pid=$current_main_pids[1]"
        print -r -- "current-extension-pid=$current_extension_pids[1]"
        print -r -- "extension-command=$extension_command_line"
    } >>"$lifecycle_log"
}

apply_capture_language() {
    local language_id="$1"

    print -r -- "Activating Finder menu language: $language_id" \
        | tee -a "$capture_log"
    /usr/bin/defaults write "$main_bundle_identifier" AppleLanguages -array "$language_id" \
        || fail "Could not set Debug app language: $language_id"
    /usr/bin/defaults write "$finder_bundle_identifier" AppleLanguages -array "$language_id" \
        || fail "Could not set Finder language: $language_id"
    restart_debug_finder_environment "$language_id" \
        || fail "Could not restart Finder and the Debug Extension for $language_id."
    require_no_finder_windows "$language_id-before-capture" 30
}

load_registry
load_language_registry
parse_arguments "$@"

if [[ "$mode" == capture ]]; then
    source "$script_directory/lib/test-vm.sh"
    ecmenu_run_in_test_vm finder "${original_arguments[@]}"
fi

initialize_run_directories
build_automation_helper
prepare_and_validate_fixtures

if [[ "$mode" == check ]]; then
    print "Finder menu capture definitions and helper build passed."
    print "Check artifacts: $test_directory"
    print "Check logs: $log_directory"
    exit 0
fi

readonly preflight_stdout_log="$log_directory/preflight.stdout.log"
readonly preflight_stderr_log="$log_directory/preflight.stderr.log"
if python3 "$desktop_job_runner" "$test_directory/desktop-jobs/permissions" -- \
    "$helper_executable" permissions \
    >"$preflight_stdout_log" \
    2>"$preflight_stderr_log"; then
    :
else
    preflight_line="$(/usr/bin/awk -F '\t' '$1 == "PREFLIGHT" && NF == 3 {
        print
        exit
    }' "$preflight_stdout_log")"
    fail "Finder menu capture requires Accessibility and Screen Recording permission. Current status: ${preflight_line:-unavailable}. Logs: $preflight_stdout_log, $preflight_stderr_log"
fi

require_no_finder_windows initial

if "$script_directory/run-debug.sh" \
    --refresh-finder \
    --no-open-finder-window \
    >"$log_directory/run-debug.log" 2>&1; then
    :
else
    run_debug_status=$?
    print -u2 "Debug Finder Extension setup failed. Log: $log_directory/run-debug.log"
    tail -n 200 "$log_directory/run-debug.log" >&2
    exit "$run_debug_status"
fi

resolve_debug_products
require_no_finder_windows after-debug-start
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

for language_id in "${selected_language_ids[@]}"; do
    apply_capture_language "$language_id"
    for scenario_id in "${selected_scenario_ids[@]}"; do
        capture_scenario "$language_id" "$scenario_id"
        require_no_finder_windows "$language_id-after-$scenario_id"
    done
done

require_no_finder_windows completed

print "Finder menu screenshots: $output_directory"
print "Capture logs: $log_directory"
