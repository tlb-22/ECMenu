"""在来宾 GUI launchd 域启动桌面工具，隔离 SSH 的 TCC 责任链并管理进程与证据。

只接受来宾仓库内的产物目录；标准输入通过 FIFO 传递，标准输出和错误保留为可检查日志。
"""

import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import threading
import time
import uuid


class DesktopJobFailure(Exception):
    """桌面作业准备或生命周期失败。"""


def require_guest():
    virtual = subprocess.check_output(["/usr/sbin/sysctl", "-n", "kern.hv_vmm_present"],
                                      stdin=subprocess.DEVNULL, text=True).strip()
    if virtual != "1" or os.stat("/dev/console").st_uid != os.getuid():
        raise DesktopJobFailure("桌面作业只能由虚拟机当前登录桌面账户执行")


class DesktopJob:
    """原始可执行文件直接成为 GUI launchd 子进程，输入转发器不介入其责任归属。"""

    def __init__(self, command, output, input_stream=None, environment=None):
        require_guest()
        executable = Path(command[0])
        if not executable.is_absolute() or not executable.is_file():
            raise DesktopJobFailure("桌面作业需要现存可执行文件的绝对路径")
        project = Path(__file__).resolve().parents[3]
        self.output = Path(output).resolve()
        if not self.output.is_relative_to(project):
            raise DesktopJobFailure("桌面作业产物必须位于来宾项目仓库内")
        self.output.mkdir(parents=True, exist_ok=False, mode=0o700)
        self.command = command
        self.input_stream = input_stream
        self.environment = environment
        self.label = f"com.axiomace.ecmenu.test.desktop-{os.getpid()}-{uuid.uuid4().hex[:12]}"
        self.domain = f"gui/{os.getuid()}"
        self.path = self.output / "job.plist"
        self.stdout_path = self.output / "stdout.log"
        self.stderr_path = self.output / "stderr.log"
        self.stdout_path.touch()
        self.stderr_path.touch()
        self.loaded = False
        self.input_failure = None
        self.exit_code = None
        self.timed_out = False

    def start(self):
        definition = {"Label": self.label, "ProgramArguments": self.command, "RunAtLoad": True,
                      "StandardOutPath": str(self.stdout_path), "StandardErrorPath": str(self.stderr_path),
                      "StandardInPath": "/dev/null", "WorkingDirectory": str(Path(__file__).resolve().parents[3])}
        if self.environment:
            definition["EnvironmentVariables"] = self.environment
        if self.input_stream is not None:
            pipe = self.output / "stdin.fifo"
            os.mkfifo(pipe, 0o600)
            definition["StandardInPath"] = str(pipe)
            # FIFO 本身不保存输入。先建立写端等待，launchd 为驱动打开读端时完成配对。
            def forward_input():
                try:
                    with pipe.open("wb", buffering=0) as destination:
                        # 直接读标准输入描述符，等待外部认证时不持有 BufferedReader 的关闭锁。
                        while block := os.read(self.input_stream.fileno(), 65536):
                            destination.write(block)
                except (BrokenPipeError, OSError):
                    # 驱动可以不读取输入就结束；断开的写端不改变驱动结果。
                    self.input_failure = "输入转发结束"
            threading.Thread(target=forward_input, daemon=True).start()
        self.path.write_bytes(plistlib.dumps(definition))
        # bootstrap 可在客户端收到回复前完成登记；从尝试开始即负责唯一 label 的清理。
        self.loaded = True
        result = subprocess.run(["/bin/launchctl", "bootstrap", self.domain, str(self.path)],
                                stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
        if result.returncode:
            raise DesktopJobFailure("GUI launchd 未能启动桌面作业")

    def poll(self):
        result = subprocess.run(["/bin/launchctl", "print", f"{self.domain}/{self.label}"],
                                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10)
        if result.returncode:
            raise DesktopJobFailure("GUI launchd 桌面作业登记丢失")
        state = re.search(r"^\s*state = (.+)$", result.stdout, re.M)
        if state and state[1].strip() == "running":
            return None
        status = re.search(r"^\s*last exit code = (-?\d+)\s*$", result.stdout, re.M)
        if status:
            self.exit_code = int(status[1])
            return self.exit_code
        signal = re.search(r"^\s*last terminating signal = .*?(\d+)\s*$", result.stdout, re.M)
        if signal:
            self.exit_code = 128 + int(signal[1])
            return self.exit_code
        return None

    def wait(self, timeout, stdout=None, stderr=None):
        deadline = time.monotonic() + timeout
        with self.stdout_path.open("rb") as out, self.stderr_path.open("rb") as err:
            def forward():
                for source, destination in [(out, stdout), (err, stderr)]:
                    block = source.read()
                    if block and destination is not None:
                        destination.write(block)
                        destination.flush()
            while True:
                forward()
                code = self.poll()
                if code is not None:
                    forward()
                    return code
                if time.monotonic() >= deadline:
                    self.timed_out = True
                    self.exit_code = 124
                    return self.exit_code
                time.sleep(0.15)

    def stop(self):
        try:
            if self.loaded:
                subprocess.run(["/bin/launchctl", "bootout", self.domain, str(self.path)],
                               stdin=subprocess.DEVNULL, capture_output=True, timeout=20)
                remaining = subprocess.run(["/bin/launchctl", "print", f"{self.domain}/{self.label}"],
                                           stdin=subprocess.DEVNULL, capture_output=True, timeout=10)
                if remaining.returncode == 0:
                    raise DesktopJobFailure("GUI launchd 桌面作业未能清理")
                self.loaded = False
        finally:
            pipe = self.output / "stdin.fifo"
            if pipe.exists():
                pipe.unlink()

    def write_report(self, failure=None):
        report = {"version": 1, "status": "passed" if self.exit_code == 0 and failure is None else "failed",
                  "executable": self.command[0], "label": self.label, "exitCode": self.exit_code,
                  "timedOut": self.timed_out, "stdout": str(self.stdout_path), "stderr": str(self.stderr_path)}
        if failure:
            report["failure"] = failure
        (self.output / "desktop-job.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
