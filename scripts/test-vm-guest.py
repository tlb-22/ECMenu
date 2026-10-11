#!/usr/bin/env python3
"""在虚拟机本地同步当前源码、临时导入签名、运行验收并导出结果。

每轮只保留声明的构建缓存；凭据不落入源码、日志、共享目录或封存模板。
"""

import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import shlex
import signal
import subprocess
import sys
import time

EXCHANGE = Path("/Volumes/My Shared Files/exchange")


def bootstrap():
    """从已验证快照安装桌面作业入口；私有输入直接交给 GUI 会话中的协调进程。"""
    payload = json.loads((EXCHANGE / "guest-input.json").read_text())
    if (subprocess.check_output(["/usr/sbin/sysctl", "-n", "kern.hv_vmm_present"], text=True).strip() != "1"
            or subprocess.check_output(["id", "-un"], text=True).strip() != payload["user"]):
        raise RuntimeError("guest 引导需要配置中的虚拟机测试账户")
    source = EXCHANGE / "source.tar.gz"
    if hashlib.sha256(source.read_bytes()).hexdigest() != payload["sourceSha256"]:
        raise RuntimeError("引导源码归档与宿主记录不一致")
    project = Path.home() / payload["project"]["directory"]
    run = project / ".artifacts/scratch/tests" / payload["name"]
    run.mkdir(parents=True)
    (EXCHANGE / "guest-process.json").write_text(json.dumps({"pid": os.getpid(), "name": payload["name"]}) + "\n")
    with (run / "bootstrap.log").open("w") as log:
        subprocess.run(["/usr/bin/tar", "-xzf", str(source), "-C", str(project),
            "Tests/VirtualMachine/desktop_job.py", "Tests/VirtualMachine/run-desktop-job.py"],
            stdin=subprocess.DEVNULL, stdout=log, stderr=log, check=True)
    # 导入、解锁及 xcodebuild 与其签名服务共用 GUI 安全会话；FIFO 不保存输入。
    runner = project / "Tests/VirtualMachine/run-desktop-job.py"
    result = subprocess.run(["/usr/bin/python3", str(runner), "--timeout", "2400",
        str(run / "coordinator"), "--", "/usr/bin/python3", str(EXCHANGE / "guest.py"), "--gui"],
        cwd=project, stdin=sys.stdin.buffer)
    # 协调作业在 worker 导出后才结束；补齐最终退出码与已清理的作业证据。
    shutil.copytree(run / "coordinator", EXCHANGE / "guest-artifacts/tests" / payload["name"] / "coordinator",
        dirs_exist_ok=True, ignore=shutil.ignore_patterns("stdin.fifo"))
    if payload["action"] == "prepare" and result.returncode == 0:
        # 外层作业已退出、注销并导出最终证据，此时才清除模板中的临时运行内容。
        shutil.rmtree(project / ".artifacts/scratch")
    return result.returncode


def main():
    payload = json.loads(sys.stdin.readline())
    if subprocess.check_output(["/usr/sbin/sysctl", "-n", "kern.hv_vmm_present"], text=True).strip() != "1":
        raise RuntimeError("guest 入口只能在虚拟机中执行")
    if subprocess.check_output(["id", "-un"], text=True).strip() != payload["user"]:
        raise RuntimeError("guest 账户与封存配置不匹配")
    project = Path.home() / payload["project"]["directory"]
    run = project / ".artifacts/scratch/tests" / payload["name"]
    stage = project / ".artifacts/scratch/probes" / (payload["name"] + "-source")
    (EXCHANGE / "guest-process.json").write_text(json.dumps({"pid": os.getpid(), "name": payload["name"]}) + "\n")
    run.mkdir(parents=True, exist_ok=True)
    stage.mkdir(parents=True)
    report = {"version": 1, "action": payload["action"], "status": "running", "phases": {}}
    keychain = run / "signing.keychain-db"
    helper = run / "SigningIdentity"
    active = None
    previous_keychains = None
    interrupted = False
    environment = {**os.environ, "ECMENU_VM_GUEST": "1", "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
                   "PATH": str(Path.home() / ".local/bin") + ":/usr/bin:/bin:/usr/sbin:/sbin"}

    def interrupt(number, frame):
        nonlocal interrupted
        interrupted = True
        if active and active.poll() is None:
            try:
                os.killpg(active.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
    for number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(number, interrupt)

    def command(arguments, label, input=None, capture=False, authentication=False):
        nonlocal active
        if interrupted:
            raise RuntimeError("guest 验收已中断")
        if keychain.exists():
            unlocked = subprocess.run([str(helper), "unlock", str(keychain)], cwd=project,
                env=environment, text=True, capture_output=True, timeout=30,
                input=json.dumps({"keychainPassword": payload["signing"]["keychainPassword"]}))
            if unlocked.returncode:
                raise RuntimeError("构建阶段前无法解锁临时签名钥匙串：" + unlocked.stderr.strip())
        started = time.monotonic()
        log = run / (label + ".log")
        report["phases"][label] = {"status": "running"}
        (run / "guest-report.json").write_text(json.dumps(report, indent=2) + "\n")
        print("ECMENU_PHASE\t" + label, flush=True)
        with log.open("w") as stream:
            active = subprocess.Popen(arguments, cwd=project, env=environment, text=True,
                                      stdin=subprocess.PIPE if input is not None or authentication else subprocess.DEVNULL,
                                      stdout=subprocess.PIPE if capture or authentication else stream, stderr=stream, start_new_session=True)
            if authentication:
                for line in active.stdout:
                    if line.strip() == "ECMENU_ADMINISTRATOR_REQUIRED":
                        print("ECMENU_ADMINISTRATOR_REQUIRED", flush=True)
                        credential = sys.stdin.readline()
                        if interrupted:
                            raise RuntimeError("管理员认证期间验收已中断")
                        if not credential:
                            os.killpg(active.pid, signal.SIGTERM)
                            raise RuntimeError("管理员认证凭据未提供")
                        active.stdin.write(credential)
                        active.stdin.flush()
                    else:
                        stream.write(line)
                        stream.flush()
                active.stdin.close()
                active.wait()
                result = None
            else:
                result, _ = active.communicate(input)
            code = active.returncode
            active = None
        report["phases"][label] = {"status": "passed" if code == 0 else "failed", "seconds": round(time.monotonic() - started, 3), "exitCode": code}
        (run / "guest-report.json").write_text(json.dumps(report, indent=2) + "\n")
        if code:
            raise RuntimeError(f"{label} 失败 ({code})；见 {log.name}")
        return result

    def desktop_result(label):
        """以桌面报告区分自动通过和人工待审；进程退出零不能替代报告验收。"""
        relative = "desktop/report.json"
        try:
            result = json.loads((run / relative).read_text())
            if not isinstance(result, dict) or result.get("status") not in ("passed", "review-pending"):
                raise RuntimeError("桌面报告未完成或未通过")
            cases = result.get("cases")
            if not isinstance(cases, list) or not cases:
                raise RuntimeError("桌面报告缺少已完成案例")
            reviews = []
            for item in cases:
                if (not isinstance(item, dict) or not isinstance(item.get("name"), str) or not item["name"].strip()
                        or item.get("status") not in ("passed", "review-pending")):
                    raise RuntimeError("桌面案例未完成或未通过")
                if item["status"] == "passed":
                    if "manualReview" in item:
                        raise RuntimeError("已通过的桌面案例仍带有人工待审内容")
                    continue
                review = item.get("manualReview")
                if (not isinstance(review, dict) or set(review) != {"instructions", "evidence"}
                        or any(not isinstance(review[key], list) or not review[key]
                               or any(not isinstance(value, str) or not value.strip() for value in review[key])
                               for key in ("instructions", "evidence"))):
                    raise RuntimeError("人工待审案例缺少检查说明或证据")
                reviews.append({"case": item["name"], "report": relative, **review})
            expected = "review-pending" if reviews else "passed"
            if result["status"] != expected:
                raise RuntimeError("桌面报告顶层状态与人工待审案例不一致")
            report["manualReviews"] = reviews
            report["phases"][label]["status"] = expected
            (run / "guest-report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        except (OSError, ValueError, RuntimeError) as error:
            report["phases"][label].update(status="failed", error=str(error))
            raise RuntimeError("桌面报告验收失败：" + str(error)) from error

    def stop_product():
        def call(arguments):
            result = subprocess.run(arguments, capture_output=True, text=True)
            if result.returncode:
                raise RuntimeError("封存清理失败：" + Path(arguments[0]).name)
            return result.stdout

        def stop(executable):
            entries = call(["ps", "-axo", "pid=,comm="])
            pids = [int(parts[0]) for line in entries.splitlines()
                    if len(parts := line.strip().split(None, 1)) == 2 and parts[1] == str(executable)]
            for pid in pids:
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            deadline = time.monotonic() + 10
            while pids:
                alive = []
                for pid in pids:
                    try:
                        os.kill(pid, 0)
                        alive.append(pid)
                    except ProcessLookupError:
                        pass
                pids = alive
                if pids and time.monotonic() >= deadline:
                    raise RuntimeError("封存前当前产品进程未退出")
                if pids:
                    time.sleep(0.1)

        for app in (project / ".derivedData/Build/Products/Debug").glob("*.app"):
            info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            identifier = info.get("CFBundleIdentifier", "")
            if identifier == "com.axiomace.ecmenu.debug" or identifier.startswith("com.axiomace.ecmenu.test."):
                stop(app / "Contents/MacOS" / info["CFBundleExecutable"])
                for extension in (app / "Contents/PlugIns").glob("*.appex"):
                    einfo = plistlib.loads((extension / "Contents/Info.plist").read_bytes())
                    stop(extension / "Contents/MacOS" / einfo["CFBundleExecutable"])
                    registration = subprocess.run(["pluginkit", "-m", "-A", "-D", "-vv", "-i", einfo["CFBundleIdentifier"]], capture_output=True, text=True)
                    if registration.returncode not in (0, 1):
                        raise RuntimeError("封存前无法查询当前扩展登记")
                    paths = [line.split("Path = ", 1)[1] for line in registration.stdout.splitlines() if "Path = " in line]
                    if str(extension) in paths:
                        call(["pluginkit", "-e", "ignore", "-i", einfo["CFBundleIdentifier"]])
                        call(["pluginkit", "-r", str(extension)])
                call(["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", "-u", str(app)])

    try:
        source_hash = hashlib.sha256((EXCHANGE / "source.tar.gz").read_bytes()).hexdigest()
        if source_hash != payload["sourceSha256"]:
            raise RuntimeError("源码归档与宿主记录不一致")
        report["sourceSha256"] = source_hash
        command(["/usr/bin/tar", "-xzf", str(EXCHANGE / "source.tar.gz"), "-C", str(stage)], "source-extract")
        command(["/usr/bin/rsync", "-a", "--delete", "--exclude=.derivedData/", "--exclude=.artifacts/", "--exclude=Tests/VirtualMachine/Bootstrap/node_modules/", str(stage) + "/", str(project) + "/"], "source-sync")
        shutil.rmtree(stage)
        actual_xcode = command(["xcodebuild", "-version"], "tools", capture=True).strip()
        if actual_xcode != payload["xcode"]:
            raise RuntimeError("当前 Xcode 与公共封存版本不一致")
        report["xcode"] = actual_xcode
        command(["xcrun", "swiftc", "-module-cache-path", str(run / "module-cache"), str(project / "Tests/VirtualMachine/SigningIdentity.swift"), "-o", str(helper)], "signing-helper-build")
        previous_keychains = shlex.split(subprocess.check_output(
            ["/usr/bin/security", "list-keychains", "-d", "user"], text=True))
        imported = json.loads(command([str(helper), "import", str(keychain)], "signing-import", input=json.dumps(payload["signing"]), capture=True))
        if imported["fingerprint"] != payload["signing"]["fingerprint"]:
            raise RuntimeError("guest 导入的签名身份与宿主导出不一致")
        report["signingFingerprint"] = imported["fingerprint"]
        configuration = run / "signing.xcconfig"
        configuration.write_text("CODE_SIGN_STYLE = Manual\nCODE_SIGN_IDENTITY = " + imported["codeSigningIdentity"]
            + "\nDEVELOPMENT_TEAM = " + payload["signing"]["team"]
            + '\nOTHER_CODE_SIGN_FLAGS = $(inherited) --keychain "' + str(keychain) + '"\n')
        environment["XCODE_XCCONFIG_FILE"] = str(configuration)
        preparing = payload["action"] == "prepare"
        if preparing:
            applications = []
            for index, application in enumerate(payload["project"]["applications"]):
                command(["/usr/bin/ditto", "-x", "-k", str(EXCHANGE / f"application-{index}.zip"), str(Path.home() / "Applications")], f"application-{index}")
                app = Path.home() / "Applications" / Path(application).name
                information = plistlib.loads((app / "Contents/Info.plist").read_bytes())
                command(["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", "-f", str(app)], f"application-{index}-register")
                applications.append({"identifier": information["CFBundleIdentifier"], "version": information["CFBundleShortVersionString"], "build": information["CFBundleVersion"]})
            report["targetApplications"] = applications
            command(["/usr/bin/python3", "Tests/VirtualMachine/prepare-application-settings.py", str(run / "application-settings")], "application-settings")
            command(["/bin/zsh", "scripts/run-debug.sh", "--build-only"], "build")
            for scheme in ("FinderMenuAutomation", "ECMenuPreviews", "ContextCommandSender"):
                command(["xcodebuild", "-project", "ECMenu.xcodeproj", "-scheme", scheme, "-configuration", "Debug", "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", ".derivedData", "build", "-quiet"], "build-" + scheme)
            command(["/usr/bin/python3", "Tests/VirtualMachine/prepare-permissions.py", str(project / ".derivedData/Build/Products/Debug/FinderMenuAutomation.app/Contents/MacOS/FinderMenuAutomation"), str(run / "permissions")], "permissions", authentication=True)
            command(["/usr/bin/python3", "Tests/VirtualMachine/run-desktop-job.py", "--timeout", "120", str(run / "template-applications-job"), "--",
                     str(project / ".derivedData/Build/Products/Debug/FinderMenuAutomation.app/Contents/MacOS/FinderMenuAutomation"),
                     "prepare-external-applications", str(run / "template-applications")], "template-applications")
            stop_product()
            subprocess.run(["defaults", "delete", "com.axiomace.ecmenu.debug"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            shutil.rmtree(Path.home() / "Library/Application Support/com.axiomace.ecmenu.debug", ignore_errors=True)
        else:
            command(["/bin/zsh", "scripts/run-debug.sh", "--build-only"], "build")
            command(["xcodebuild", "-project", "ECMenu.xcodeproj", "-scheme", "FinderMenuAutomation", "-configuration", "Debug", "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", ".derivedData", "build", "-quiet"], "build-driver")
            command(["/usr/bin/open", "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"], "capture-settings")
            command(["/usr/bin/python3", "Tests/VirtualMachine/run-desktop-job.py", "--timeout", "60", str(run / "capture-permission-job"), "--",
                     str(project / ".derivedData/Build/Products/Debug/FinderMenuAutomation.app/Contents/MacOS/FinderMenuAutomation"),
                     "prepare-capture", str(run / "capture-ready.png")], "capture-permission")
            command(["/usr/bin/pkill", "-x", "System Settings"], "capture-settings-close")
            action = payload["action"]
            if action == "run":
                failures = []
                def acceptance(arguments, label):
                    try:
                        command(arguments, label)
                        if label == "desktop":
                            desktop_result(label)
                    except RuntimeError as error:
                        if interrupted:
                            raise
                        failures.append({"phase": label, "error": str(error)})
                acceptance(["/bin/zsh", "scripts/capture-finder-menus.sh"], "finder")
                acceptance(["/bin/zsh", "scripts/test-desktop-guest.sh", str(run / "desktop")], "desktop")
                acceptance(["/bin/zsh", "scripts/test-integration.sh"], "integration")
                stop_product()
                acceptance(["/bin/zsh", "scripts/test-checks.sh"], "checks")
                if failures:
                    report["failures"] = failures
                    raise RuntimeError("必要验收阶段失败：" + "、".join(item["phase"] for item in failures))
            else:
                scripts = {"integration": "test-integration.sh", "finder": "capture-finder-menus.sh", "previews": "capture-previews.sh", "readme": "capture-readme-images.sh"}
                if action == "desktop":
                    arguments = ["/bin/zsh", "scripts/test-desktop-guest.sh", str(run / "desktop")]
                else:
                    arguments = ["/bin/zsh", "scripts/" + scripts[action], *payload["arguments"]]
                command(arguments, "test")
                if action == "desktop":
                    desktop_result("test")
        report["status"] = "review-pending" if report.get("manualReviews") else "passed"
    except Exception as error:
        report.update(status="failed", error=str(error))
        print(str(error), file=sys.stderr)
    finally:
        cleanup_errors = []
        if active and active.poll() is None:
            try:
                if active.stdin and not active.stdin.closed:
                    active.stdin.close()
                os.killpg(active.pid, signal.SIGTERM)
                active.wait(timeout=15)
            except ProcessLookupError:
                pass
            except Exception:
                cleanup_errors.append("guest 子进程未在中断后退出")
                try:
                    os.killpg(active.pid, signal.SIGKILL)
                    active.wait(timeout=5)
                except (ProcessLookupError, subprocess.TimeoutExpired):
                    pass
        if helper.exists() and keychain.exists():
            removal = subprocess.run([str(helper), "remove", str(keychain)], cwd=project, env=environment, text=True, capture_output=True)
            if removal.returncode:
                cleanup_errors.append("临时签名钥匙串移除失败：" + removal.stderr.strip())
        if previous_keychains is not None:
            restored = subprocess.run(["/usr/bin/security", "list-keychains", "-d", "user", "-s", *previous_keychains],
                stdin=subprocess.DEVNULL, text=True, capture_output=True)
            if restored.returncode:
                cleanup_errors.append("原钥匙串搜索列表恢复失败")
        report["cleanupStatus"] = "failed" if cleanup_errors else "passed"
        report["cleanupErrors"] = cleanup_errors
        if cleanup_errors:
            report["status"] = "failed"
        # Failures still export all available evidence. Never export private keychain files.
        try:
            if keychain.exists():
                raise RuntimeError("凭据未清理，拒绝将私有签名文件导出")
            report["exportStatus"] = "passed"
            (run / "guest-report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
            shutil.copyfile(run / "guest-report.json", EXCHANGE / "guest-report.json")
            shutil.copytree(project / ".artifacts/scratch", EXCHANGE / "guest-artifacts", dirs_exist_ok=True,
                            ignore=shutil.ignore_patterns("*.keychain*", "*-source", "stdin.fifo"))
            if payload["action"] == "readme" and report["status"] == "passed":
                documentation = EXCHANGE / "documentation"
                for filename in ("README.md", "README.zh-Hans.md"):
                    if (project / filename).is_file():
                        documentation.mkdir(exist_ok=True)
                        shutil.copyfile(project / filename, documentation / filename)
                shutil.copytree(project / ".docs/images", documentation / ".docs/images", dirs_exist_ok=True)
        except Exception as error:
            report.update(status="failed", exportStatus="failed", exportError=str(error))
            (EXCHANGE / "guest-report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    return 0 if (report["status"] in ("passed", "review-pending")
                 and report["cleanupStatus"] == "passed" and report["exportStatus"] == "passed") else 1


if __name__ == "__main__":
    sys.exit(main() if sys.argv[1:] == ["--gui"] else bootstrap())
