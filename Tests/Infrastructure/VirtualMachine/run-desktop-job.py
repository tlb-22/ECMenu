#!/usr/bin/env python3
"""来宾桌面工具统一入口：GUI launchd 直接启动、透传输入输出、记录退出码并清理超时作业。"""

import argparse
from pathlib import Path
import signal
import subprocess
import sys

sys.dont_write_bytecode = True

from desktop_job import DesktopJob, DesktopJobFailure


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output_directory", type=Path)
    parser.add_argument("--timeout", type=float, default=300)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or args.timeout <= 0:
        parser.error("需要桌面工具命令和正数超时")
    job = None
    failure = None
    code = 1
    def interrupt(_signal, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupt)
    try:
        job = DesktopJob(command, args.output_directory, input_stream=sys.stdin.buffer)
        job.start()
        code = job.wait(args.timeout, stdout=sys.stdout.buffer, stderr=sys.stderr.buffer)
    except KeyboardInterrupt:
        code = 130
        failure = "桌面作业已中断"
    except (DesktopJobFailure, OSError, ValueError, subprocess.SubprocessError) as error:
        failure = str(error) if isinstance(error, DesktopJobFailure) else type(error).__name__
        print(failure, file=sys.stderr)
    finally:
        if job:
            try:
                job.stop()
            except (DesktopJobFailure, OSError, subprocess.SubprocessError) as error:
                code = 1
                failure = str(error) if isinstance(error, DesktopJobFailure) else type(error).__name__
            job.write_report(failure)
    return code


if __name__ == "__main__":
    sys.exit(main())
