#!/usr/bin/env python3
"""调度项目模板和一次性桌面验收克隆，保存证据并负责完整清理。

源码取自当前工作区；管理员及签名凭据仅经 SSH 标准输入传递，不进入共享目录。
"""

import argparse
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import secrets
import selectors
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import time
from datetime import datetime, timezone
from dataclasses import dataclass
from typing import Optional, Union

ROOT = Path(__file__).resolve().parent.parent
CONFIGURATION_DIRECTORY = ROOT / "Tests/Infrastructure/VirtualMachine"
ACTIONS = ("prepare", "run", "desktop", "integration", "finder", "previews", "readme", "checks")


@dataclass(frozen=True)
class VMConfiguration:
    """公开项目身份与本机执行设置在宿主边界合并，私人设置不随源码归档。"""

    project_id: str
    environment_directory: Path
    template: str
    directory: str
    applications: tuple[Path, ...]

    def guest_project(self):
        return {"version": 1, "projectID": self.project_id, "directory": self.directory,
                "applications": [str(path) for path in self.applications]}


def load_configuration() -> VMConfiguration:
    def definition(name, keys):
        path = CONFIGURATION_DIRECTORY / name
        try:
            value = json.loads(path.read_text())
        except FileNotFoundError:
            if name == "Local.json":
                raise RuntimeError("缺少本机 VM 配置；复制 Tests/Infrastructure/VirtualMachine/Local.example.json 为 Local.json 并填写本机环境") from None
            raise RuntimeError(f"缺少 VM 项目配置 {name}") from None
        except (OSError, ValueError):
            raise RuntimeError(f"VM 配置 {name} 无法读取或 JSON 格式无效") from None
        if (not isinstance(value, dict) or set(value) != keys
                or type(value.get("version")) is not int or value["version"] != 1):
            raise RuntimeError(f"VM 配置 {name} 的字段或版本无效")
        return value

    project = definition("Project.json", {"version", "projectID"})
    local = definition("Local.json", {"version", "environmentDirectory", "template", "directory", "applications"})
    if not isinstance(project["projectID"], str) or re.fullmatch(r"[a-z][a-z0-9-]*", project["projectID"]) is None:
        raise RuntimeError("Project.json 的 projectID 必须是稳定的小写项目标识")
    if any(not isinstance(local[key], str) or not local[key].strip()
           for key in ("environmentDirectory", "template", "directory")):
        raise RuntimeError("Local.json 的环境目录、模板与来宾目录必须为非空字符串")
    environment_directory = Path(local["environmentDirectory"]).expanduser()
    directory = Path(local["directory"])
    if not environment_directory.is_absolute():
        raise RuntimeError("Local.json 的 environmentDirectory 必须为绝对目录或 ~ 开头的目录")
    if directory.is_absolute() or directory == Path(".") or ".." in directory.parts:
        raise RuntimeError("Local.json 的 directory 必须为来宾用户目录内的相对路径")
    applications = local["applications"]
    if (not isinstance(applications, list) or not applications
            or any(not isinstance(path, str) or not path.strip()
                   or not Path(path).expanduser().is_absolute() for path in applications)):
        raise RuntimeError("Local.json 的 applications 必须为宿主应用绝对路径列表")
    return VMConfiguration(project["projectID"], environment_directory,
                           local["template"], directory.as_posix(),
                           tuple(Path(path).expanduser() for path in applications))


@dataclass(frozen=True)
class DisposableClone:
    name: str


@dataclass(frozen=True)
class SealedTemplate:
    name: str


CandidateClone = Union[DisposableClone, SealedTemplate]


@dataclass(frozen=True)
class RenamedTemplate:
    original_name: str
    backup_name: str


def utc():
    return datetime.now(timezone.utc).isoformat()


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def checked(arguments, **options):
    result = subprocess.run(arguments, text=True, capture_output=True, **options)
    if result.returncode:
        raise RuntimeError(f"{Path(arguments[0]).name} 失败 ({result.returncode})：{result.stderr.strip()}")
    return result.stdout


def snapshot(output):
    names = checked(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=ROOT)
    with tarfile.open(output, "w:gz", dereference=False) as archive:
        for name in sorted(set(filter(None, names.split("\0")))):
            if name == "Tests/Infrastructure/VirtualMachine/Local.json":
                continue
            path = ROOT / name
            if path.exists() or path.is_symlink():
                archive.add(path, arcname=name, recursive=False)
    return hashlib.sha256(output.read_bytes()).hexdigest()


def administrator(configuration, user):
    path = configuration.environment_directory / "credentials.json"
    for item, permissions in ((configuration.environment_directory, 0o700), (path, 0o600)):
        information = item.stat()
        if information.st_uid != os.getuid() or stat.S_IMODE(information.st_mode) != permissions:
            raise RuntimeError(f"管理员凭据的所有者或权限不正确：{item}")
    value = json.loads(path.read_text())
    if value.get("user") != user:
        raise RuntimeError("管理员凭据账户与公共封存配置不一致")
    password = value.get("password")
    if password is None:
        raise RuntimeError("管理员凭据尚未填写")
    if not isinstance(password, str) or not password:
        raise RuntimeError("管理员凭据 password 必须为非空字符串")
    return password


def signing(run, configuration, initialize=False):
    teams = set(re.findall(r"DEVELOPMENT_TEAM = ([A-Z0-9]+);", (ROOT / "ECMenu.xcodeproj/project.pbxproj").read_text()))
    if len(teams) != 1:
        raise RuntimeError("项目必须具有唯一的开发签名 Team")
    helper = run / "SigningIdentity"
    with (run / "signing-helper-build.log").open("w") as stream:
        subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(run / "module-cache"),
                        str(ROOT / "Tests/Infrastructure/VirtualMachine/SigningIdentity.swift"), "-o", str(helper)],
                       stdout=stream, stderr=stream, check=True)
    team = next(iter(teams))
    signing_configuration = configuration.environment_directory / "projects" / configuration.project_id / "signing.json"
    if signing_configuration.exists() or signing_configuration.is_symlink():
        def private_file(path):
            for item, permissions, directory in ((path.parent, 0o700, True), (path, 0o600, False)):
                try:
                    information = item.lstat()
                except OSError:
                    raise RuntimeError("签名私有配置或 P12 无法访问") from None
                expected_type = stat.S_ISDIR if directory else stat.S_ISREG
                if information.st_uid != os.getuid() or stat.S_IMODE(information.st_mode) != permissions or not expected_type(information.st_mode):
                    raise RuntimeError("签名私有配置和 P12 必须由当前用户持有，文件权限 0600，直接父目录权限 0700，且不能使用符号链接")

        private_file(signing_configuration)
        try:
            value = json.loads(signing_configuration.read_text())
        except (OSError, ValueError):
            raise RuntimeError("项目 signing.json 无法读取或 JSON 格式无效") from None
        if not isinstance(value, dict) or type(value.get("version")) is not int or value["version"] != 1 or set(value) != {"version", "p12Path", "p12Password"}:
            raise RuntimeError("项目 signing.json 必须包含 version=1、p12Path 和 p12Password")
        path_value, passphrase = value["p12Path"], value["p12Password"]
        if not isinstance(path_value, str) or not Path(path_value).is_absolute() or not isinstance(passphrase, str) or not passphrase:
            raise RuntimeError("项目 signing.json 需要绝对 P12 路径和非空 P12 密码")
        p12_path = Path(path_value)
        private_file(p12_path)
        try:
            p12base64 = base64.b64encode(p12_path.read_bytes()).decode("ascii")
        except OSError:
            raise RuntimeError("私有 P12 文件无法读取") from None
        inspection = json.loads(checked([str(helper), "inspect"], input=json.dumps({"p12base64": p12base64, "passphrase": passphrase, "team": team})))
        exported = {"p12base64": p12base64, **inspection}
    else:
        passphrase = secrets.token_hex(32)
        # stdout contains an encrypted identity: capture in memory, never log it.
        command = "export-authorized" if initialize else "export"
        exported = json.loads(checked([str(helper), command, team], input=json.dumps({"passphrase": passphrase}), timeout=300))
        inspected = json.loads(checked([str(helper), "inspect"], input=json.dumps({"p12base64": exported["p12base64"], "passphrase": passphrase, "team": team}), timeout=60))
        if inspected["fingerprint"] != exported["fingerprint"]:
            raise RuntimeError("导出身份与内存验证身份不一致")
        exported.update(inspected)
        if initialize:
            signing_configuration.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            information = signing_configuration.parent.lstat()
            if (not stat.S_ISDIR(information.st_mode) or information.st_uid != os.getuid()
                    or stat.S_IMODE(information.st_mode) != 0o700):
                raise RuntimeError("项目签名私有目录必须由当前用户持有，权限 0700，且不能使用符号链接")
            p12_path = signing_configuration.parent / "development-identity.p12"
            created = []
            try:
                descriptor = os.open(p12_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                created.append(p12_path)
                with os.fdopen(descriptor, "wb") as stream:
                    stream.write(base64.b64decode(exported["p12base64"], validate=True))
                descriptor = os.open(signing_configuration, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                created.append(signing_configuration)
                with os.fdopen(descriptor, "w") as stream:
                    json.dump({"version": 1, "p12Path": str(p12_path), "p12Password": passphrase}, stream)
                    stream.write("\n")
            except BaseException:
                for path in reversed(created):
                    path.unlink()
                raise
    return {**exported, "passphrase": passphrase, "keychainPassword": secrets.token_hex(32), "team": team}


def main():
    parser = argparse.ArgumentParser(description="在一次性 macOS 虚拟机内执行 ECMenu 验收")
    parser.add_argument("action", choices=ACTIONS)
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.arguments[:1] == ["--"]:
        args.arguments = args.arguments[1:]
    if args.action in ("prepare", "run", "desktop", "checks"):
        if args.arguments in (["--help"], ["-h"]):
            parser.print_help()
            return 0
        if args.arguments:
            parser.error(f"{args.action} 不接受额外参数")
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("需要 Apple Silicon macOS 宿主")
    try:
        configuration = load_configuration()
    except RuntimeError as error:
        parser.error(str(error))
    name = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S") + f"-vm-{args.action}-{os.getpid()}"
    run = ROOT / ".artifacts/scratch/tests" / name
    run.mkdir(parents=True)
    print(f"虚拟机结果目录：{run}", flush=True)
    report = {"version": 1, "action": args.action, "status": "running", "startedAt": utc(), "phases": {}}
    report_path = run / "vm-report.json"
    write_json(report_path, report)
    vm_process = active = environment = lock = ip = None
    candidate: Optional[CandidateClone] = None
    previous_template: Optional[RenamedTemplate] = None
    interrupted = False
    tart_env = {**os.environ, "TART_NO_AUTO_PRUNE": "1"}

    def interruption(number, frame):
        nonlocal interrupted
        interrupted = True

    for number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(number, interruption)

    def phase(label, work):
        if interrupted:
            raise RuntimeError("验收已中断")
        print(f"虚拟机：{label}", flush=True)
        started = time.monotonic()
        item = {"status": "running"}
        report["phases"][label] = item
        write_json(report_path, report)
        try:
            value = work()
            if interrupted:
                raise RuntimeError("验收已中断")
            item["status"] = "passed"
            return value
        except Exception as error:
            item.update(status="failed", error=str(error))
            raise
        finally:
            item["seconds"] = round(time.monotonic() - started, 3)
            write_json(report_path, report)

    def tart(*arguments):
        return checked([environment["tart"], *arguments], env=tart_env, timeout=120)

    def ssh(ip, command):
        return ["/usr/bin/ssh", "-i", str(configuration.environment_directory / "id_ed25519"), "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
                "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=yes", "-o", f"HostKeyAlias={environment['template']}",
                "-o", f"UserKnownHostsFile={configuration.environment_directory / 'known_hosts'}", f"{environment['user']}@{ip}", command]

    try:
        environment = json.loads((configuration.environment_directory / "environment.json").read_text())
        if environment["version"] != 1:
            raise RuntimeError("虚拟机环境配置版本不受支持")
        if configuration.template == environment["template"]:
            raise RuntimeError("项目模板不得与公共模板同名")
        report.update(environment=environment["versions"], baseSealedAt=environment["sealedAt"])
        lock = (configuration.environment_directory / "run.lock").open("a+")
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if interrupted:
                    raise RuntimeError("等待公共测试锁时中断")
                time.sleep(1)
        machines = json.loads(tart("list", "--format", "json"))
        preparing = args.action == "prepare"
        metadata = configuration.environment_directory / "projects" / configuration.project_id / "environment.json"
        existing = next((m for m in machines if m["Name"] == configuration.template and m["Source"] == "local"), None)
        if preparing and existing and existing["State"] != "stopped":
            raise RuntimeError("项目模板正在运行，不能替换")
        prepared = None
        if metadata.exists() or metadata.is_symlink():
            prepared = json.loads(metadata.read_text())
            if (not isinstance(prepared, dict)
                    or set(prepared) != {"version", "template", "baseSealedAt", "sourceSha256", "preparedAt"}
                    or type(prepared["version"]) is not int or prepared["version"] != 1
                    or prepared["template"] != configuration.template
                    or any(not isinstance(prepared[key], str) or not prepared[key].strip()
                           for key in ("baseSealedAt", "sourceSha256", "preparedAt"))
                    or re.fullmatch(r"[0-9a-f]{64}", prepared["sourceSha256"]) is None):
                raise RuntimeError("项目封存元数据结构、版本或项目模板不匹配，请修复封存记录")
        # 准备总是从公共基线建立新候选，避免合并或覆盖已经使用过的应用 bundle。
        source_template = environment["template"] if preparing else configuration.template
        report["template"] = source_template
        write_json(report_path, report)
        source = next((m for m in machines if m["Name"] == source_template and m["Source"] == "local"), None)
        if source is None or source["State"] != "stopped":
            raise RuntimeError(f"模板 {source_template} 不存在或未关机；先执行 ./scripts/prepare-test-vm.sh")
        if not preparing:
            if prepared is None or prepared["baseSealedAt"] != environment["sealedAt"]:
                raise RuntimeError("公共基线已变化或项目封存不匹配，请重新准备项目模板")
        report["sourceSha256"] = phase("source", lambda: snapshot(run / "source.tar.gz"))
        credentials = phase("signing-prepare", lambda: signing(run, configuration))
        if preparing:
            def applications():
                for index, application in enumerate(configuration.applications):
                    path = Path(application)
                    if not path.is_dir():
                        raise RuntimeError(f"缺少打开命令的目标应用：{path}")
                    checked(["/usr/bin/ditto", "-c", "-k", "--keepParent", str(path), str(run / f"application-{index}.zip")], timeout=300)
            phase("applications", applications)
        shutil.copyfile(ROOT / "scripts/test-vm-guest.py", run / "guest.py")
        requested_vm = ("prepare-" if preparing else "test-") + configuration.project_id + "-" + name
        report["machine"] = requested_vm
        def clone():
            nonlocal candidate
            tart("clone", source_template, requested_vm)
            candidate = DisposableClone(requested_vm)
        phase("clone", clone)

        def boot():
            nonlocal vm_process
            with (run / "vm.log").open("w") as stream:
                vm_process = subprocess.Popen([environment["tart"], "run", candidate.name, "--no-graphics", "--no-clipboard", "--no-audio", "--no-usb-accessories", "--dir", f"exchange:{run}"], env=tart_env, stdout=stream, stderr=stream)
            deadline = time.monotonic() + 180
            last_error = "尚未连接"
            while time.monotonic() < deadline:
                if interrupted:
                    raise RuntimeError("启动时中断")
                if vm_process.poll() is not None:
                    raise RuntimeError("虚拟机进程已退出，见 vm.log")
                try:
                    address = tart("ip", candidate.name).strip()
                    output = checked(ssh(address, "stat -f%Su /dev/console; pgrep -x Dock"), timeout=10)
                    if output.splitlines()[0] == environment["user"]:
                        return address
                except Exception as error:
                    last_error = str(error)
                time.sleep(1)
            raise RuntimeError(f"测试桌面未在180秒内就绪：{last_error}")

        ip = phase("boot", boot)
        if not preparing:
            guest_scratch = '"$HOME"/' + shlex.quote(configuration.directory + "/.artifacts/scratch")
            phase("template-clean", lambda: checked(
                ssh(ip, "/bin/test ! -e " + guest_scratch), timeout=10))
        payload = {"action": args.action, "arguments": args.arguments, "name": name, "user": environment["user"], "project": configuration.guest_project(), "sourceSha256": report["sourceSha256"],
                   "xcode": environment["versions"]["xcode"], "signing": credentials}
        write_json(run / "guest-input.json", {key: value for key, value in payload.items() if key != "signing"})

        def guest():
            nonlocal active
            with (run / "guest.log").open("w") as stream:
                command = "/usr/bin/python3 " + shlex.quote("/Volumes/My Shared Files/exchange/guest.py")
                active = subprocess.Popen(ssh(ip, command), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stream)
                active.stdin.write((json.dumps(payload) + "\n").encode())
                active.stdin.flush()
                deadline = time.monotonic() + 2400
                buffer = b""
                selector = selectors.DefaultSelector()
                selector.register(active.stdout, selectors.EVENT_READ)
                while selector.get_map():
                    if interrupted or time.monotonic() >= deadline:
                        raise RuntimeError("guest 验收中断或超过40分钟，见 guest.log")
                    for key, _ in selector.select(timeout=1):
                        chunk = os.read(key.fd, 65536)
                        if not chunk:
                            selector.unregister(key.fileobj)
                            continue
                        buffer += chunk
                        while b"\n" in buffer:
                            line, buffer = buffer.split(b"\n", 1)
                            if line == b"ECMENU_ADMINISTRATOR_REQUIRED":
                                if not preparing:
                                    raise RuntimeError("日常验收意外请求管理员认证")
                                credential = {"user": environment["user"], "password": administrator(configuration, environment["user"])}
                                active.stdin.write((json.dumps(credential) + "\n").encode())
                                active.stdin.flush()
                            else:
                                stream.write(line.decode("utf-8", errors="replace") + "\n")
                                stream.flush()
                                if line.startswith(b"ECMENU_PHASE\t"):
                                    print("来宾：" + line.split(b"\t", 1)[1].decode("utf-8"), flush=True)
                selector.close()
                if buffer:
                    stream.write(buffer.decode("utf-8", errors="replace"))
                active.stdin.close()
                active.wait(timeout=15)
                if active.returncode:
                    raise RuntimeError(f"guest 任务失败 ({active.returncode})，见 guest.log 和 guest-report.json")
                active = None
            result = json.loads((run / "guest-report.json").read_text())
            if (not isinstance(result, dict) or result.get("status") not in ("passed", "review-pending")
                    or any(result.get(key) != "passed" for key in ("exportStatus", "cleanupStatus"))):
                raise RuntimeError("guest 测试、导出或凭据清理未通过")
            reviews = result.get("manualReviews", [])
            if not isinstance(reviews, list):
                raise RuntimeError("guest 人工检查汇总格式无效")
            for item in reviews:
                if (not isinstance(item, dict) or set(item) != {"case", "report", "instructions", "evidence"}
                        or not isinstance(item["case"], str) or not item["case"].strip()
                        or item["report"] != "desktop/report.json"
                        or any(not isinstance(item[key], list) or not item[key]
                               or any(not isinstance(value, str) or not value.strip() for value in item[key])
                               for key in ("instructions", "evidence"))):
                    raise RuntimeError("guest 人工检查汇总缺少案例、说明或证据")
            expected = "review-pending" if reviews else "passed"
            if result["status"] != expected or (reviews and args.action not in ("run", "desktop")):
                raise RuntimeError("guest 顶层状态与人工检查汇总不一致")
            if args.action in ("run", "desktop"):
                desktop_phase = "desktop" if args.action == "run" else "test"
                phases = result.get("phases")
                if (not isinstance(phases, dict) or not isinstance(phases.get(desktop_phase), dict)
                        or phases[desktop_phase].get("status") != expected):
                    raise RuntimeError("guest 桌面阶段状态与人工检查汇总不一致")
            return result
        guest_result = phase("prepare" if preparing else "test", guest)
        report["guestReportPath"] = "guest-report.json"
        if args.action in ("run", "desktop"):
            report["manualReviews"] = guest_result.get("manualReviews", [])
            report["phases"]["test"]["status"] = guest_result["status"]
            write_json(report_path, report)
        if preparing:
            def stop():
                # 正常来宾关机提交模板状态；延后五秒让请求先返回并释放 SSH。
                checked(ssh(ip, "/usr/bin/sudo -S -p '' /sbin/shutdown -h +5s >/dev/null 2>&1"),
                        input=administrator(configuration, environment["user"]) + "\n", timeout=15)
                if interrupted:
                    raise RuntimeError("项目封存前验收已中断")
                if vm_process.wait(timeout=120) != 0:
                    raise RuntimeError("来宾正常关机后虚拟机未成功退出，拒绝封存模板")
            phase("stop", stop)

            def seal():
                nonlocal candidate, previous_template
                assert isinstance(candidate, DisposableClone)
                pending_metadata = metadata.with_name("environment-" + name + ".json")
                try:
                    metadata.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                    write_json(pending_metadata, {"version": 1, "template": configuration.template, "baseSealedAt": environment["sealedAt"], "sourceSha256": report["sourceSha256"], "preparedAt": utc()})
                    if interrupted:
                        raise RuntimeError("项目模板封存已中断")
                    if existing:
                        backup = configuration.template + "-previous-" + name
                        tart("rename", configuration.template, backup)
                        previous_template = RenamedTemplate(configuration.template, backup)
                    if interrupted:
                        raise RuntimeError("项目模板封存已中断")
                    tart("rename", candidate.name, configuration.template)
                    candidate = DisposableClone(configuration.template)
                    if interrupted:
                        raise RuntimeError("项目模板封存已中断")
                    os.replace(pending_metadata, metadata)
                    candidate = SealedTemplate(configuration.template)
                except Exception as original_error:
                    rollback_errors = []
                    if isinstance(candidate, DisposableClone) and candidate.name != requested_vm:
                        try:
                            tart("rename", candidate.name, requested_vm)
                            candidate = DisposableClone(requested_vm)
                        except Exception as error:
                            rollback_errors.append("候选名称恢复失败：" + str(error))
                    if previous_template:
                        try:
                            if candidate and candidate.name == previous_template.original_name:
                                raise RuntimeError("原名称仍由本轮候选占用")
                            tart("rename", previous_template.backup_name, previous_template.original_name)
                            previous_template = None
                        except Exception as error:
                            rollback_errors.append("原模板恢复失败：" + str(error))
                    try:
                        pending_metadata.unlink(missing_ok=True)
                    except Exception as error:
                        rollback_errors.append("候选封存记录清理失败：" + str(error))
                    if rollback_errors:
                        raise RuntimeError(str(original_error) + "；回滚错误：" + "；".join(rollback_errors)) from original_error
                    raise
                # 已提交模板的后续中断或旧备份清理错误不撤销本次提交。
                if previous_template:
                    tart("delete", previous_template.backup_name)
                    previous_template = None
            phase("seal", seal)
        elif args.action == "readme":
            updates = [path for path in (run / "documentation").rglob("*") if path.is_file()]
            with tarfile.open(run / "source.tar.gz", "r:gz") as archive:
                original_files = {member.name: member for member in archive.getmembers() if member.isfile()}
                for path in updates:
                    relative = path.relative_to(run / "documentation")
                    destination = ROOT / relative
                    current = destination.read_bytes() if destination.is_file() else None
                    member = original_files.get(relative.as_posix())
                    original = archive.extractfile(member).read() if member else None
                    if current != original and current != path.read_bytes():
                        raise RuntimeError(f"截图期间工作区文件已变化，生成结果保留在本轮 documentation，未同步：{relative}")
            for path in updates:
                destination = ROOT / path.relative_to(run / "documentation")
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(path, destination)
        if interrupted:
            raise RuntimeError("验收已中断")
        report["status"] = guest_result["status"]
    except Exception as error:
        report.update(status="failed", error=str(error))
        print(str(error), file=sys.stderr)
    finally:
        cleanup_errors = []
        if active and active.poll() is None:
            try:
                if active.stdin and not active.stdin.closed:
                    active.stdin.close()
                process_record = run / "guest-process.json"
                if process_record.exists():
                    guest_pid = json.loads(process_record.read_text())["pid"]
                    if type(guest_pid) is not int or guest_pid <= 1:
                        raise RuntimeError("guest 进程记录无效")
                    terminate = "import os, signal\ntry:\n os.kill(" + str(guest_pid) + ", signal.SIGTERM)\nexcept ProcessLookupError:\n pass\n"
                    checked(ssh(ip, "/usr/bin/python3 -c " + shlex.quote(terminate)), timeout=10)
                else:
                    # 引导尚未登记工作进程时关闭连接；后续仍必须关闭并删除本轮克隆。
                    active.terminate()
                active.wait(timeout=30)
            except Exception as error:
                cleanup_errors.append("guest 中断清理未完成：" + str(error))
                active.terminate()
                try:
                    active.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    active.kill()
                    try:
                        active.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        cleanup_errors.append("SSH 进程强制终止后未退出")
        if vm_process and vm_process.poll() is None:
            try:
                assert candidate is not None
                tart("stop", candidate.name, "--timeout", "15")
                vm_process.wait(timeout=30)
            except Exception as error:
                cleanup_errors.append(str(error))
                vm_process.terminate()
                try:
                    vm_process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    vm_process.kill()
                    try:
                        vm_process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        cleanup_errors.append("虚拟机进程强制终止后未退出")
        if isinstance(candidate, DisposableClone):
            try:
                tart("delete", candidate.name)
                candidate = None
            except Exception as error:
                cleanup_errors.append(str(error))
        if previous_template and not isinstance(candidate, SealedTemplate):
            try:
                if candidate and candidate.name == previous_template.original_name:
                    raise RuntimeError("原名称仍由本轮候选占用")
                tart("rename", previous_template.backup_name, previous_template.original_name)
                previous_template = None
            except Exception as error:
                cleanup_errors.append("原模板恢复失败：" + str(error))
        report["cleanup"] = {"status": "failed" if cleanup_errors else "passed", "errors": cleanup_errors}
        if cleanup_errors:
            report["status"] = "failed"
        report["completedAt"] = utc()
        write_json(report_path, report)
        if lock:
            lock.close()
        if report["status"] == "review-pending":
            print(f"自动执行已完成，人工检查待审（{len(report['manualReviews'])} 项）；报告：{report_path}", flush=True)
        else:
            print(f"虚拟机流程：{report['status']}；报告：{report_path}", flush=True)
    return 0 if report["status"] in ("passed", "review-pending") else 1


if __name__ == "__main__":
    sys.exit(main())
