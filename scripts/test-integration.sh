#!/bin/zsh

# 通过独立签名进程验收认证、坏帧和断开后的真实 IPC 服务。
# 以隔离文件检查命令实际效果，在虚拟机中管理 Debug 进程并保存逐项证据。

set -euo pipefail

readonly script_path="${0:A}"
readonly script_directory="${script_path:h}"
readonly project_root="${script_directory:h}"
readonly derived_data_path="$project_root/.derivedData"
readonly debug_products_directory="$derived_data_path/Build/Products/Debug"
readonly run_timestamp="$(date '+%Y%m%d-%H%M%S')"
readonly log_directory="$project_root/.artifacts/scratch/logs"
readonly integration_log="$log_directory/$run_timestamp-ipc-integration-$$.log"
readonly fixture_root="$project_root/.artifacts/scratch/tests/$run_timestamp-ipc-integration-$$"
readonly resident_fixture="$fixture_root/resident-host"
readonly visibility_fixture="$resident_fixture/visible-item"
readonly integration_report="$fixture_root/report.json"
readonly rejected_sender_path="$fixture_root/WrongIdentifierSender"
readonly sender_path="$derived_data_path/Build/Products/Debug/ContextCommandSender"
readonly developer_directory="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
readonly destination="${XCODE_DESTINATION:-platform=macOS,arch=arm64}"

source "$script_directory/lib/product-paths.sh"
source "$script_directory/lib/code-signing.sh"
source "$script_directory/lib/process-lifecycle.sh"
source "$script_directory/lib/test-vm.sh"
ecmenu_run_in_test_vm integration "$@"

fail() {
    print -u2 "$1"
    print -u2 "Integration log: $integration_log"
    tail -n 200 "$integration_log" >&2
    exit 1
}

finalize_report() {
    local final_status=$?
    python3 - "$integration_report" "$final_status" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
report = json.loads(path.read_text())
report["status"] = "passed" if sys.argv[2] == "0" else "failed"
report["passedCount"] = len(report["scenarios"])
path.write_text(json.dumps(report, indent=2) + "\n")
PY
    return "$final_status"
}

record_success() {
    python3 - "$integration_report" "$1" "$2" "${3:-}" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
report = json.loads(path.read_text())
result = {"scenario": sys.argv[2], "status": "passed", "observation": sys.argv[3]}
if sys.argv[4]:
    evidence = json.loads(Path(sys.argv[4]).read_text())
    if evidence["status"] != "passed" or evidence["scenario"] != result["scenario"]:
        raise SystemExit("IPC fault evidence does not match the requested scenario")
    result.update(evidence)
    result["serviceAfterFault"] = "authenticated-configuration-response-from-same-host-process"
report["scenarios"].append(result)
path.write_text(json.dumps(report, indent=2) + "\n")
PY
}

assert_host_responsive() {
    local scenario="$1"
    if [[ "$(process_ids_for_executable "$debug_main_executable")" != "$host_pid" ]]; then
        fail "The original Debug host process changed after $scenario."
    fi
    if ! "$sender_path" --menu-configuration \
        >"$fixture_root/$scenario-configuration.txt" 2>>"$integration_log"; then
        fail "The host did not answer a new authenticated configuration query after $scenario."
    fi
    cat "$fixture_root/$scenario-configuration.txt" >>"$integration_log"
    if [[ "$(process_ids_for_executable "$debug_main_executable")" != "$host_pid" ]]; then
        fail "The Debug host changed during the recovery query after $scenario."
    fi
}

run_connection_fault() {
    local scenario="$1"
    local result_path="$fixture_root/$scenario.json"
    if ! "$sender_path" --connection-fault "$scenario" \
        >"$result_path" 2>>"$integration_log"; then
        fail "The real connection fault did not produce its expected observation: $scenario."
    fi
    cat "$result_path" >>"$integration_log"
    assert_host_responsive "$scenario"
    record_success "$scenario" "peer-connection-observation" "$result_path"
}

assert_hidden_file() {
    python3 - "$1" <<'PY'
import os
import stat
import sys
import time

path = sys.argv[1]
deadline = time.monotonic() + 5
while True:
    information = os.stat(path, follow_symlinks=False)
    if not stat.S_ISREG(information.st_mode):
        raise SystemExit("The visibility fixture is no longer a regular file")
    if information.st_flags & stat.UF_HIDDEN:
        break
    if time.monotonic() >= deadline:
        raise SystemExit("The visibility fixture did not acquire UF_HIDDEN")
    time.sleep(0.05)
PY
}


mkdir -p "$log_directory" "$resident_fixture"
: >"$integration_log"
python3 - "$integration_report" <<'PY'
import json
from pathlib import Path
import sys

Path(sys.argv[1]).write_text(json.dumps({"version": 1, "status": "running", "scenarios": []}, indent=2) + "\n")
PY
trap finalize_report EXIT
cd "$project_root"

if ! "$script_directory/run-debug.sh" --build-only >>"$integration_log" 2>&1; then
    fail "Could not build and validate the Debug products."
fi

if ! DEVELOPER_DIR="$developer_directory" xcodebuild \
    -project ECMenu.xcodeproj \
    -scheme ContextCommandSender \
    -configuration Debug \
    -destination "$destination" \
    -derivedDataPath "$derived_data_path" \
    build -quiet >>"$integration_log" 2>&1; then
    fail "Could not build ContextCommandSender."
fi

if ! debug_build_settings="$(
    DEVELOPER_DIR="$developer_directory" xcodebuild \
        -project ECMenu.xcodeproj \
        -scheme ECMenu \
        -configuration Debug \
        -destination "$destination" \
        -derivedDataPath "$derived_data_path" \
        -showBuildSettings 2>>"$integration_log"
)"; then
    fail "Could not read the Debug application build settings."
fi
readonly expected_app_wrapper_name="$(
    print -r -- "$debug_build_settings" \
        | ecmenu_target_build_setting_value \
            ECMenu \
            FULL_PRODUCT_NAME
)"
if [[ -z "$expected_app_wrapper_name" ]]; then
    fail "The Debug application FULL_PRODUCT_NAME is missing."
fi

if ! ecmenu_resolve_product_paths \
    "$debug_products_directory" \
    "$expected_app_wrapper_name" \
    >>"$integration_log" 2>&1; then
    fail "Could not uniquely resolve the built Debug products."
fi

readonly debug_extension_path="$ECMENU_PRODUCT_EXTENSION_PATH"
readonly debug_app_path="$ECMENU_PRODUCT_APP_PATH"
readonly debug_main_executable="$ECMENU_PRODUCT_MAIN_EXECUTABLE_PATH"

extension_bundle_id="$(
    ecmenu_plist_value \
        "$debug_extension_path/Contents/Info.plist" \
        CFBundleIdentifier
)"
extension_signing_identifier="$(
    ecmenu_code_signing_value "$debug_extension_path" Identifier
)"
extension_team="$(
    ecmenu_code_signing_value "$debug_extension_path" TeamIdentifier
)"
sender_signing_identifier="$(ecmenu_code_signing_value "$sender_path" Identifier)"
sender_team="$(ecmenu_code_signing_value "$sender_path" TeamIdentifier)"

if [[ -z "$extension_bundle_id" \
    || -z "$extension_signing_identifier" \
    || -z "$extension_team" ]]; then
    fail "Could not read the built Debug Finder Extension signing identity."
fi
if [[ "$extension_signing_identifier" != "$extension_bundle_id" ]]; then
    fail "The Debug Finder Extension signing identifier does not match its Info.plist."
fi
if [[ "$sender_signing_identifier" != "$extension_signing_identifier" ]]; then
    fail "ContextCommandSender does not have the Debug Finder Extension signing identifier."
fi
if [[ "$sender_team" != "$extension_team" ]]; then
    fail "ContextCommandSender does not have the Debug Finder Extension signing Team."
fi

# 只改变副本的 signing identifier；证书、Team 和真实 App Group entitlement 保持对应。
readonly rejected_sender_identifier="$extension_signing_identifier.rejected-peer"
if ! codesign -d --extract-certificates="$fixture_root/sender-certificate-" "$sender_path" \
    >>"$integration_log" 2>&1; then
    fail "Could not read the signed sender's public certificate."
fi
readonly signing_certificate_hash="$(shasum -a 1 "$fixture_root/sender-certificate-0" | awk '{print $1}')"
if [[ ! "$signing_certificate_hash" =~ '^[0-9a-fA-F]{40}$' ]]; then
    fail "The sender signing certificate fingerprint is invalid."
fi
cp "$sender_path" "$rejected_sender_path"
if ! codesign --force --sign "$signing_certificate_hash" \
    --identifier "$rejected_sender_identifier" \
    --preserve-metadata=entitlements,flags,runtime "$rejected_sender_path" \
    >>"$integration_log" 2>&1 \
    || ! codesign --verify --strict "$rejected_sender_path" >>"$integration_log" 2>&1; then
    fail "Could not create the real same-Team wrong-identifier peer fixture."
fi
if [[ "$(ecmenu_code_signing_value "$rejected_sender_path" Identifier)" != "$rejected_sender_identifier" \
    || "$(ecmenu_code_signing_value "$rejected_sender_path" TeamIdentifier)" != "$extension_team" ]]; then
    fail "The rejected peer fixture does not have the expected same-Team different-identifier signature."
fi

previous_main_pids="$(process_ids_for_executable "$debug_main_executable")"
terminate_process_ids "$previous_main_pids"
if ! wait_for_process_ids_to_exit "$previous_main_pids"; then
    fail "The previous Debug application did not exit."
fi
if ! open -n "$debug_app_path" >>"$integration_log" 2>&1; then
    fail "Could not open the current Debug application."
fi
if ! wait_for_process "$debug_main_executable" 100; then
    fail "The current Debug application did not start."
fi
readonly host_pid="$(process_ids_for_executable "$debug_main_executable")"
if [[ ! "$host_pid" =~ '^[0-9]+$' ]]; then
    fail "The integration scenarios require exactly one Debug host process."
fi
python3 - "$integration_report" "$host_pid" "$extension_team" "$extension_signing_identifier" "$rejected_sender_identifier" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
report = json.loads(path.read_text())
report.update(hostPID=int(sys.argv[2]), team=sys.argv[3], acceptedIdentifier=sys.argv[4], rejectedIdentifier=sys.argv[5])
path.write_text(json.dumps(report, indent=2) + "\n")
PY

if ! "$sender_path" --wait-for-menu-configuration >>"$integration_log" 2>&1; then
    fail "The new Debug host did not provide an authenticated menu configuration."
fi
record_success "authenticated-menu-configuration" "production-host-returned-configuration"

if ! "$rejected_sender_path" --expect-identity-rejection \
    >"$fixture_root/wrong-signing-identifier.json" 2>>"$integration_log"; then
    fail "The wrong-identifier signed process was not rejected before its authentication acknowledgment."
fi
cat "$fixture_root/wrong-signing-identifier.json" >>"$integration_log"
assert_host_responsive "wrong-signing-identifier"
record_success "wrong-signing-identifier" "authentication-acknowledgment-denied" "$fixture_root/wrong-signing-identifier.json"

for scenario in malformed-json frame-length-overflow truncated-header truncated-body disconnect partial-frame-timeout; do
    run_connection_fault "$scenario"
done

print -r -- "IPC visibility fixture" >"$visibility_fixture"
if ! "$sender_path" --hide-items "$visibility_fixture" >>"$integration_log" 2>&1; then
    fail "The authenticated one-way hide-items command send failed."
fi
if ! assert_hidden_file "$visibility_fixture" >>"$integration_log" 2>&1; then
    fail "The one-way command did not set the fixture's UF_HIDDEN flag."
fi
record_success "authenticated-hide-items" "external-regular-file-acquired-UF_HIDDEN"

print "Authenticated IPC integration scenarios passed: 9"
print "Fixtures: $fixture_root"
print "Report: $integration_report"
print "Integration log: $integration_log"
