#!/usr/bin/env python3
"""为项目来宾模板设置公开应用选项与英语美国地区，并保存版本及设置回执。

只修改普通用户设置；保留已有 Code JSON 键，格式错误直接失败，不处理应用私有状态。
"""

import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import sys

sys.dont_write_bytecode = True

from desktop_job import require_guest


CODE_SETTINGS = {
    "workbench.welcomePage.experimentalOnboarding": False,
    "workbench.startupEditor": "none",
    "window.restoreWindows": "none",
    "security.workspace.trust.untrustedFiles": "newWindow",
}
SETTING_SOURCES = [
    "https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/welcomeGettingStarted/browser/gettingStarted.contribution.ts",
    "https://github.com/microsoft/vscode/blob/main/src/vs/workbench/electron-browser/desktop.contribution.ts",
    "https://code.visualstudio.com/docs/configure/settings",
    "https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/workspace/browser/workspace.contribution.ts",
    "https://code.visualstudio.com/docs/editing/workspaces/workspace-trust",
]
ITERM_PREFERENCES_DOMAIN = "com.googlecode.iterm2"
ITERM_SETTINGS = {"SUEnableAutomaticChecks": False}
ITERM_SETTING_SOURCES = [
    "https://iterm2.com/python-api/preferences.html",
    "https://iterm2.com/documentation-preferences-general.html",
    "https://sparkle-project.org/documentation/customization/",
    "https://github.com/sparkle-project/Sparkle/blob/1.27.1/Sparkle/SUUpdater.m",
]


def main():
    parser = argparse.ArgumentParser(description="准备项目虚拟机模板的公开应用设置")
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    require_guest()
    project = Path(__file__).resolve().parents[3]
    output = args.output.resolve()
    if not output.is_relative_to(project / ".artifacts/scratch/tests"):
        raise RuntimeError("应用设置回执必须位于来宾项目 scratch/tests 内")
    output.mkdir(parents=True, exist_ok=True)
    receipt = {"version": 1, "status": "running"}
    try:
        available = subprocess.check_output(["/usr/bin/locale", "-a"], text=True).splitlines()
        if "en_US.UTF-8" not in available:
            raise RuntimeError("来宾未提供 en_US.UTF-8，不能封存要求的终端地区设置")
        applications = []
        for name, identifier in (("Visual Studio Code.app", "com.microsoft.VSCode"),
                                 ("iTerm.app", "com.googlecode.iterm2")):
            path = Path.home() / "Applications" / name
            info = plistlib.loads((path / "Contents/Info.plist").read_bytes())
            if info.get("CFBundleIdentifier") != identifier:
                raise RuntimeError("项目模板应用身份不匹配：" + name)
            applications.append({"identifier": identifier, "version": info["CFBundleShortVersionString"],
                                 "build": info["CFBundleVersion"]})
        receipt["applications"] = applications
        settings_path = Path.home() / "Library/Application Support/Code/User/settings.json"
        if settings_path.exists() or settings_path.is_symlink():
            try:
                settings = json.loads(settings_path.read_text())
            except (OSError, ValueError) as error:
                raise RuntimeError("现有 Code settings.json 无法读取或不是有效 JSON；请先修复设置文件") from error
            if not isinstance(settings, dict):
                raise RuntimeError("现有 Code settings.json 必须为 JSON 对象")
        else:
            settings = {}
        settings.update(CODE_SETTINGS)
        settings_path.parent.mkdir(parents=True, exist_ok=True)
        settings_path.write_text(json.dumps(settings, ensure_ascii=False, indent=2) + "\n")
        subprocess.run(["/usr/bin/defaults", "write", ITERM_PREFERENCES_DOMAIN,
                        "SUEnableAutomaticChecks", "-bool", "false"], check=True)
        subprocess.run(["/usr/bin/defaults", "write", "NSGlobalDomain", "AppleLocale", "-string", "en_US"], check=True)
        subprocess.run(["/usr/bin/defaults", "write", "NSGlobalDomain", "AppleLanguages", "-array", "en-US"], check=True)
        actual_settings = json.loads(settings_path.read_text())
        actual_iterm = plistlib.loads(subprocess.check_output([
            "/usr/bin/defaults", "export", ITERM_PREFERENCES_DOMAIN, "-"]))
        actual_locale = plistlib.loads(subprocess.check_output(["/usr/bin/defaults", "export", "NSGlobalDomain", "-"]))
        if (any(actual_settings.get(key) != value for key, value in CODE_SETTINGS.items())
                or actual_iterm.get("SUEnableAutomaticChecks") is not False
                or actual_locale.get("AppleLocale") != "en_US"
                or actual_locale.get("AppleLanguages") != ["en-US"]):
            raise RuntimeError("项目模板公开设置写入后读回不一致")
        receipt.update(status="passed", code={"settingsPath": "~/Library/Application Support/Code/User/settings.json",
            "settings": CODE_SETTINGS, "sources": SETTING_SOURCES},
            iterm={"preferencesDomain": ITERM_PREFERENCES_DOMAIN,
                   "settings": ITERM_SETTINGS, "sources": ITERM_SETTING_SOURCES},
            system={"AppleLocale": "en_US", "AppleLanguages": ["en-US"], "availableLocale": "en_US.UTF-8"})
    except Exception as error:
        receipt.update(status="failed", error=str(error))
        print(str(error), file=sys.stderr)
    (output / "report.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
    return 0 if receipt["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
