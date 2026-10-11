#!/usr/bin/env python3
"""通过来宾系统设置为原生 Finder 驱动准备权限；凭据只经标准输入进入认证控件。

仅用于项目模板准备。Appium/Mac2 在来宾回环地址临时运行，日常 Swift 验收不依赖它。
"""

import argparse
import base64
import pwd
import json
import plistlib
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True

from desktop_job import DesktopJob, DesktopJobFailure, require_guest


ELEMENT_KEY = "element-6066-11e4-a52e-4f735466cecf"
SETTINGS_BUNDLE = "com.apple.systempreferences"
HELPER_IDENTIFIER = "com.axiomace.ecmenu.test.findermenuautomation"
APP_NAME = "FinderMenuAutomation"


class PreparationFailure(Exception):
    """可报告的准备失败，消息不包含控件输入或 WebDriver 原始响应。"""


class Desktop:
    """最小 WebDriver 客户端；不记录请求正文，认证失败也不回显服务端消息。"""

    def __init__(self, base_url, wda_url=None):
        self.base_url = base_url
        self.wda_url = wda_url
        self.session = None
        self.last_request = None

    def request(self, method, path, body=None):
        self.last_request = {"method": method, "action": path.rsplit("/", 1)[-1]}
        if path.endswith("/elements") and body:
            self.last_request["using"] = body["using"]
            self.last_request["selector"] = body["value"]
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(
            self.base_url + path, data=data, method=method,
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=180) as response:
                result = json.load(response)
        except urllib.error.HTTPError as error:
            # 原始错误可能包含输入正文；只返回请求动作与 HTTP 状态。
            action = path.rsplit("/", 1)[-1]
            try:
                failure = json.load(error).get("value", {})
                code = failure.get("error")
                if code in {"invalid argument", "invalid selector", "invalid session id", "no such window", "unknown error", "unsupported operation", "stale element reference"}:
                    self.last_request["errorCode"] = code
                # 只记录固定诊断标签，不保存服务端消息、stacktrace 或控件输入。
                message = str(failure.get("message", "")).lower()
                self.last_request["diagnostic"] = [phrase for phrase in
                    ["not running", "frontmost", "snapshot", "xpath", "secure input", "keyboard", "no application", "cannot get", "timed out"]
                    if phrase in message]
            except (ValueError, OSError):
                pass
            raise PreparationFailure(f"WebDriver {method} {action} 请求失败（HTTP {error.code}）") from None
        except (urllib.error.URLError, TimeoutError):
            raise PreparationFailure("WebDriver 连接不可用或等待超时") from None
        value = result.get("value")
        if isinstance(value, dict) and "error" in value:
            raise PreparationFailure("WebDriver 未完成请求动作")
        return value

    def start(self):
        capabilities = {
            "platformName": "mac",
            "appium:automationName": "mac2",
            "appium:bundleId": SETTINGS_BUNDLE,
            "appium:noReset": True,
            "appium:skipAppKill": True,
            "appium:showServerLogs": False,
            "appium:serverStartupTimeout": 180000,
        }
        if self.wda_url:
            capabilities["appium:webDriverAgentMacUrl"] = self.wda_url
        value = self.request("POST", "/session", {"capabilities": {"alwaysMatch": capabilities}})
        self.session = value["sessionId"]

    def command(self, method, path, body=None):
        return self.request(method, f"/session/{self.session}{path}", body)

    def execute(self, name, arguments=None):
        return self.command("POST", "/execute/sync", {
            "script": "macos: " + name,
            "args": [] if arguments is None else [arguments],
        })

    def source(self):
        return self.command("GET", "/source")

    def elements(self, value, using="xpath"):
        return self.command("POST", "/elements", {"using": using, "value": value})

    def named_elements(self, types, names):
        kinds = ", ".join(json.dumps("XCUIElementType" + kind) for kind in types)
        matches = " OR ".join(
            f"{attribute} == {json.dumps(name, ensure_ascii=False)}"
            for name in names for attribute in ["identifier", "label", "title"]
        )
        return self.elements(f"amType IN {{{kinds}}} AND ({matches})", "predicate string")

    def click(self, element):
        self.execute("click", {"elementId": element[ELEMENT_KEY]})

    def type(self, element, text):
        self.command("POST", f"/element/{element[ELEMENT_KEY]}/value", {"text": text})

    def keys(self, *keys):
        self.execute("keys", {"keys": list(keys)})

    def stop(self):
        if self.session:
            self.request("DELETE", f"/session/{self.session}")
            self.session = None


def await_value(action, description, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = action()
        if result:
            return result
        time.sleep(0.3)
    raise PreparationFailure(description + "未在截止时间前就绪")


def xpath_literal(text):
    if "'" not in text:
        return "'" + text + "'"
    if '"' not in text:
        return '"' + text + '"'
    raise PreparationFailure("控件定位文字包含不支持的引号组合")


class HelperJob:
    """由来宾 GUI launchd 独立启动驱动，令 TCC 归属驱动自身而非 SSH 父进程。"""

    def __init__(self, helper, output):
        self.helper = helper
        self.output = output
        self.counter = 0
        self.jobs = []

    def start(self, command, *arguments):
        self.counter += 1
        directory = self.output / "helper-queries" / f"{os.getpid()}-{self.counter}"
        directory.parent.mkdir(parents=True, exist_ok=True)
        # DesktopJob 创建唯一目录并直接启动实际 Mach-O；不经 SSH shell 或 Python 子进程。
        job = DesktopJob([str(self.helper), command, *arguments], directory)
        self.jobs.append(job)
        job.start()
        return job

    def state(self):
        job = self.start("permissions")
        try:
            job.wait(10)
            match = re.search(r"^PREFLIGHT\t([01])\t([01])$", job.stdout_path.read_text(), re.M)
            if not match:
                raise PreparationFailure("原生驱动权限查询没有返回可识别结果")
            return {"accessibility": match[1] == "1", "screenCapture": match[2] == "1"}
        finally:
            job.stop()
            self.jobs.remove(job)
            job.write_report()

    def stop(self):
        for job in reversed(self.jobs):
            job.stop()
            job.write_report()
        self.jobs.clear()


def helper_switch(desktop):
    root = ET.fromstring(desktop.source())
    for node in root.iter():
        if node.tag not in {"XCUIElementTypeSwitch", "XCUIElementTypeCheckBox"}:
            continue
        identifier = node.attrib.get("identifier", "")
        if identifier != APP_NAME + "_Toggle":
            continue
        elements = desktop.elements(f"//{node.tag}[@identifier={xpath_literal(identifier)}]")
        if elements:
            return elements[0], node.attrib.get("value", "")
    return None


def authenticate_if_needed(desktop, load_credentials, record):
    fields = desktop.elements("//XCUIElementTypeSecureTextField")
    if not fields:
        return False
    record["authenticationInProgress"] = True
    record["administratorAuthenticationRequested"] = True
    password = load_credentials()
    desktop.click(fields[0])
    desktop.type(fields[0], password)
    buttons = desktop.named_elements(["Button"], ["OK", "Unlock", "Allow", "Use Password", "Modify Settings", "解锁", "允许", "好", "修改设置"])
    if not buttons:
        raise PreparationFailure("管理员认证窗口没有可识别的提交按钮")
    desktop.click(buttons[-1])
    await_value(lambda: not desktop.elements("//XCUIElementTypeSecureTextField"), "管理员认证完成", 20)
    record["authenticationInProgress"] = False
    return True


def add_helper(desktop, helper, load_credentials, record):
    permission_target = helper.parent.parent.parent
    add = await_value(lambda: desktop.named_elements(
        ["Button"], ["Add", "Add application", "Add Application", "Add…", "+", "添加", "添加应用程序", "添加应用"]
    ), "权限列表添加按钮")
    # 录屏页面后面还有仅系统音频的添加入口；目标为排在前面的完整录屏列表。
    desktop.click(add[0])
    time.sleep(1)
    authenticate_if_needed(desktop, load_credentials, record)
    await_value(lambda: desktop.elements("//XCUIElementTypeDialog[@title='Open']"), "系统文件选择窗口")
    desktop.keys({"key": "g", "modifierFlags": (1 << 4) | (1 << 1)})
    fields = await_value(lambda: desktop.elements("//XCUIElementTypeTextField"), "前往文件夹路径字段")
    desktop.click(fields[-1])
    desktop.keys({"key": "a", "modifierFlags": 1 << 4})
    desktop.type(fields[-1], str(permission_target))
    desktop.keys("XCUIKeyboardKeyReturn")
    time.sleep(0.5)
    choose = await_value(lambda: desktop.named_elements(
        ["Button"], ["Open", "Choose", "打开", "选取"]
    ), "文件选择确认按钮")
    desktop.click(choose[-1])
    authenticate_if_needed(desktop, load_credentials, record)


def prepare_category(desktop, helper, category, load_credentials, report):
    report["permissionCategory"] = category
    report["permissionOperation"] = "navigate"
    subprocess.run(["/usr/bin/open", "x-apple.systempreferences:com.apple.preference.security?" + category], check=True)
    desktop.execute("activateApp", {"bundleId": SETTINGS_BUNDLE})
    time.sleep(1)
    report["permissionOperation"] = "authentication-check"
    authenticate_if_needed(desktop, load_credentials, report)
    report["permissionOperation"] = "locate-helper"
    current = helper_switch(desktop)
    if current is None:
        report["permissionOperation"] = "add-helper"
        add_helper(desktop, helper, load_credentials, report)
        current = await_value(lambda: helper_switch(desktop), "原生驱动权限列表行")
    element, value = current
    if value not in {"1", "true", "on"}:
        report["permissionOperation"] = "enable-helper"
        desktop.click(element)
        time.sleep(1)
        authenticate_if_needed(desktop, load_credentials, report)
    report["steps"].append({"action": category, "completed": True})
    # 屏幕录制授权有时要求退出已有进程；下一次权限检查启动全新的 helper。
    restart = desktop.named_elements(["Button"], ["Quit & Reopen", "Quit and Reopen", "退出并重新打开", "退出并重新启动"])
    if restart:
        desktop.click(restart[0])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("helper", type=Path)
    parser.add_argument("output_directory", type=Path)
    args = parser.parse_args()
    project = Path(__file__).resolve().parents[3]
    output = args.output_directory.resolve()
    report = {"version": 1, "status": "running", "steps": [],
              "administratorAuthenticationRequested": False, "authenticationInProgress": False}
    desktop = None
    server = None
    wda = None
    wda_data = project / ".derivedData" / "PermissionBootstrap"
    activity = output / "wda-activity.xcresult"
    helper_job = None
    error = None
    try:
        require_guest()
        if not output.is_relative_to(project):
            raise PreparationFailure("权限报告目录必须位于来宾项目仓库内")
        output.mkdir(parents=True, exist_ok=True)
        helper = args.helper.resolve()
        if not helper.is_file() or not args.helper.is_absolute():
            raise PreparationFailure("需要已构建原生驱动的绝对路径")
        bundle = helper.parent.parent.parent
        if (bundle.suffix != ".app" or helper.parent.name != "MacOS"
                or helper.parent.parent.name != "Contents"):
            raise PreparationFailure("需要 FinderMenuAutomation.app 内实际可执行文件的绝对路径")
        info = plistlib.loads((bundle / "Contents" / "Info.plist").read_bytes())
        if (info.get("CFBundleIdentifier") != HELPER_IDENTIFIER
                or info.get("CFBundleExecutable") != helper.name
                or info.get("CFBundleName") != APP_NAME):
            raise PreparationFailure("原生驱动应用身份与项目配置不一致")
        subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(bundle)],
                       stdin=subprocess.DEVNULL, capture_output=True, check=True)
        signing = subprocess.run(["/usr/bin/codesign", "-dv", str(helper)], capture_output=True, text=True)
        if f"Identifier={HELPER_IDENTIFIER}" not in signing.stderr.splitlines():
            raise PreparationFailure("原生驱动签名 identifier 与项目配置不一致")
        report["helper"] = str(helper)
        report["helperBundle"] = str(bundle)
        signing_values = dict(line.split("=", 1) for line in signing.stderr.splitlines() if "=" in line)
        report["helperSigning"] = {"identifier": signing_values["Identifier"],
                                   "teamIdentifier": signing_values.get("TeamIdentifier"),
                                   "adHoc": signing_values.get("Signature") == "adhoc"}
        if (report["helperSigning"]["adHoc"]
                or report["helperSigning"]["teamIdentifier"] in {None, "not set"}):
            raise PreparationFailure("项目模板权限准备需要实际开发 Team 签名")
        report["macOS"] = subprocess.check_output(["/usr/bin/sw_vers", "-productVersion"],
                                                 stdin=subprocess.DEVNULL, text=True).strip()
        report["macOSBuild"] = subprocess.check_output(["/usr/bin/sw_vers", "-buildVersion"],
                                                      stdin=subprocess.DEVNULL, text=True).strip()
        helper_job = HelperJob(helper, output)
        report["before"] = helper_job.state()
        if all(report["before"].values()):
            report["status"] = "passed"
            report["after"] = report["before"]
            return 0

        credentials = None
        def load_credentials():
            nonlocal credentials
            if credentials is None:
                try:
                    print("ECMENU_ADMINISTRATOR_REQUIRED", flush=True)
                    credentials = json.loads(sys.stdin.readline())
                except (ValueError, OSError):
                    raise PreparationFailure("管理员认证需要有效的标准输入凭据 JSON") from None
            if (not isinstance(credentials, dict)
                    or credentials.get("user") != pwd.getpwuid(os.getuid()).pw_name
                    or not isinstance(credentials.get("password"), str) or not credentials["password"]):
                raise PreparationFailure("管理员认证需要当前桌面账户及其非空密码")
            return credentials["password"]

        bootstrap = Path(__file__).resolve().parent / "Bootstrap"
        node_version = json.loads((bootstrap / "package.json").read_text())["engines"]["node"]
        runtime = Path.home() / ".nvm" / "versions" / "node" / ("v" + node_version) / "bin"
        environment = dict(os.environ)
        environment["PATH"] = str(runtime) + os.pathsep + environment.get("PATH", "")
        actual_node = subprocess.check_output(["node", "--version"], env=environment, text=True).strip()
        if actual_node != "v" + node_version:
            raise PreparationFailure("权限准备所需 Node 版本不符")
        report["nodeVersion"] = actual_node
        expected = {"appium": "3.8.0", "appium-mac2-driver": "4.3.6"}
        installed = all((bootstrap / "node_modules" / name / "package.json").exists()
                        and json.loads((bootstrap / "node_modules" / name / "package.json").read_text())["version"] == version
                        for name, version in expected.items())
        if not installed:
            with (output / "npm-install.log").open("wb") as log:
                subprocess.run(["npm", "ci", "--no-audit", "--no-fund", "--cache", str(output / "npm-cache")],
                               cwd=bootstrap, env=environment, stdin=subprocess.DEVNULL,
                               stdout=log, stderr=subprocess.STDOUT, check=True)
        report["bootstrapVersions"] = expected
        # Mac2 的官方附着入口允许明确管理 WDA 的 Xcode Derived Data 与活动结果。
        with socket.socket() as address:
            address.bind(("127.0.0.1", 0))
            wda_port = address.getsockname()[1]
        wda_url = f"http://127.0.0.1:{wda_port}"
        wda_environment = dict(environment, USE_HOST="127.0.0.1", USE_PORT=str(wda_port))
        wda_root = bootstrap / "node_modules/appium-mac2-driver/WebDriverAgentMac"
        wda = subprocess.Popen(["/usr/bin/xcodebuild", "build-for-testing", "test-without-building",
                                "-project", str(wda_root / "WebDriverAgentMac.xcodeproj"),
                                "-scheme", "WebDriverAgentRunner", "-derivedDataPath", str(wda_data),
                                "-resultBundlePath", str(activity), "-parallel-testing-enabled", "NO",
                                "COMPILER_INDEX_STORE_ENABLE=NO"], cwd=wda_root, env=wda_environment,
                               stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, start_new_session=True)
        agent = Desktop(wda_url)
        def agent_ready():
            if wda.poll() is not None:
                raise PreparationFailure("仓库内 WDA 未能启动")
            try:
                return agent.request("GET", "/status")
            except PreparationFailure:
                return None
        await_value(agent_ready, "仓库内 WDA", 180)
        with socket.socket() as address:
            address.bind(("127.0.0.1", 0))
            port = address.getsockname()[1]
        environment.pop("APPIUM_HOME", None)
        # 完全关闭驱动输出，避免第三方错误日志回显认证请求；报告仅写受控步骤。
        server = subprocess.Popen([str(bootstrap / "node_modules/.bin/appium"),
                                   "--address", "127.0.0.1", "--port", str(port),
                                  "--log-level", "warn", "--log-no-colors"], cwd=bootstrap,
                                  env=environment, stdin=subprocess.DEVNULL,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        desktop = Desktop(f"http://127.0.0.1:{port}", wda_url)
        def ready():
            if server.poll() is not None:
                raise PreparationFailure("权限准备服务未能启动")
            try:
                return desktop.request("GET", "/status")
            except PreparationFailure:
                return None
        await_value(ready, "权限准备服务", 30)
        desktop.start()
        desktop.keys("XCUIKeyboardKeyEscape")
        # 系统设置的添加入口直接选择驱动，避免请求弹窗阻塞后续权限列表操作。
        if not report["before"]["accessibility"]:
            prepare_category(desktop, helper, "Privacy_Accessibility", load_credentials, report)
        if not report["before"]["screenCapture"]:
            # 通过系统设置添加实际应用，再由新进程查询系统授权结果。
            prepare_category(desktop, helper, "Privacy_ScreenCapture", load_credentials, report)
        helper_job.stop()
        report["after"] = await_value(
            lambda: (state if all((state := helper_job.state()).values()) else None),
            "原生驱动辅助功能和屏幕录制授权", 20,
        )
        if desktop.elements("//XCUIElementTypeSecureTextField"):
            raise PreparationFailure("管理员认证未结束，禁止开始捕获准备")
        capture = helper_job.start("prepare-capture", str(output / "capture-ready.png"))
        if capture.wait(60) != 0:
            raise PreparationFailure("原生驱动实际捕获及持续授权准备失败；见 helper-queries")
        match = re.search(r"^CAPTURE_CONSENT\t(approved|not-present)$", capture.stdout_path.read_text(), re.M)
        if not match or not (output / "capture-ready.png").is_file():
            raise PreparationFailure("原生驱动捕获准备没有生成回执与图像")
        report["captureConsent"] = match[1]
        report["status"] = "passed"
        image = desktop.command("GET", "/screenshot")
        (output / "permissions-ready.png").write_bytes(base64.b64decode(image))
        return 0
    except (PreparationFailure, DesktopJobFailure, OSError, subprocess.SubprocessError, ValueError) as failure:
        error = str(failure) if isinstance(failure, (PreparationFailure, DesktopJobFailure)) else type(failure).__name__
        report["status"] = "failed"
        report["failure"] = error
        if desktop:
            report["webdriverLastRequest"] = desktop.last_request
        return 1
    finally:
        if helper_job:
            try:
                helper_job.stop()
            except (DesktopJobFailure, OSError, subprocess.SubprocessError):
                report["cleanupFailure"] = "原生权限查询作业未能清理"
                report["status"] = "failed"
        if desktop and desktop.session:
            try:
                desktop.stop()
            except PreparationFailure:
                report["cleanupFailure"] = "权限准备会话未能关闭"
                report["status"] = "failed"
        if server:
            server.terminate()
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
        if wda:
            if wda.poll() is None:
                os.killpg(wda.pid, signal.SIGTERM)
                try:
                    wda.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(wda.pid, signal.SIGKILL)
                    wda.wait()
            # XCTest 可能记录 UI 活动，认证活动与附件不进入报告或项目模板。
            shutil.rmtree(activity, ignore_errors=True)
            shutil.rmtree(wda_data / "Logs" / "Test", ignore_errors=True)
            report["webdriverActivityRemoved"] = not activity.exists() and not (wda_data / "Logs" / "Test").exists()
            if not report["webdriverActivityRemoved"]:
                report["status"] = "failed"
                report["cleanupFailure"] = "WDA 活动产物未能删除"
        report.pop("authenticationInProgress", None)
        if output.exists() and output.is_relative_to(project):
            (output / "permissions.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        print(json.dumps({"status": report["status"], "report": str(output / "permissions.json"), "failure": error}, ensure_ascii=False))
        if report["status"] != "passed":
            return 1


if __name__ == "__main__":
    sys.exit(main())
