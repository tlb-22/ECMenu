#!/usr/bin/env python3
"""一次性通过宿主系统授权初始化 VM 签名来源，密码与私钥只保存在用户私有配置中。"""

import argparse
import fcntl
import importlib
import json
import os
from pathlib import Path
import platform
import signal
import sys
from datetime import datetime, timezone

sys.dont_write_bytecode = True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("需要 Apple Silicon macOS 宿主")
    # 复用同一精确身份选择、内存检查与私有配置契约，初始化不操作虚拟机。
    controller = importlib.import_module("test-vm")
    try:
        configuration = controller.load_configuration()
    except RuntimeError as error:
        parser.error(str(error))
    root = Path(__file__).resolve().parent.parent
    name = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S") + f"-signing-setup-{os.getpid()}"
    run = root / ".artifacts/scratch/probes" / name
    run.mkdir(parents=True)
    report = {"version": 1, "action": "signing-setup", "status": "running"}
    report_path = run / "report.json"
    print(f"签名初始化结果：{report_path}", flush=True)

    def interrupt(_signal, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupt)
    signal.signal(signal.SIGHUP, interrupt)
    try:
        with (configuration.environment_directory / "run.lock").open("a+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            print("正在检查现有身份；系统可能请求钥匙串授权，请在系统窗口允许本次访问。", flush=True)
            identity = controller.signing(run, configuration, initialize=True)
            report.update(status="passed", fingerprint=identity["fingerprint"], team=identity["team"])
    except KeyboardInterrupt:
        report.update(status="failed", error="签名初始化已中断")
    except Exception as error:
        # 受控签名错误不包含输入正文；超时不输出子进程已产生的敏感 stdout。
        report.update(status="failed", error=str(error))
    report["completedAt"] = datetime.now(timezone.utc).isoformat()
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(f"签名初始化：{report['status']}；报告：{report_path}", flush=True)
    if report.get("error"):
        print(report["error"], file=sys.stderr)
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
