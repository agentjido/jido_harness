#!/usr/bin/env python3
"""Run an isolated, writable Codex task with the existing CLI controls."""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


def command(arguments):
    executable = shutil.which(arguments.codex_path)
    if not executable:
        raise RuntimeError("The selected Codex executable is not available.")
    directory = Path(arguments.cwd).resolve()
    if not directory.is_dir():
        raise RuntimeError("The workspace directory does not exist.")

    help_result = subprocess.run(
        [executable, "exec", "--help"], capture_output=True, text=True, timeout=10,
    )
    if help_result.returncode:
        raise RuntimeError("The selected Codex executable could not report its exec options.")
    missing = [flag for flag in ("--ephemeral", "--ignore-user-config") if flag not in help_result.stdout]
    if missing:
        raise RuntimeError("The selected Codex CLI lacks required options: " + ", ".join(missing))

    argv = [
        executable, "--ask-for-approval", "never", "exec",
        "--ephemeral", "--ignore-user-config", "--sandbox", "workspace-write",
        "--json", "--cd", str(directory),
    ]
    if arguments.model:
        argv.extend(["--model", arguments.model])
    if arguments.effort:
        argv.extend(["--config", "model_reasoning_effort=" + json.dumps(arguments.effort)])
    argv.extend(["--", arguments.prompt])
    return argv


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("prompt", help="Task text, or - to read the task from standard input")
    parser.add_argument("--cwd", default=os.getcwd(), help="Existing fixture workspace")
    parser.add_argument("--model", help="Explicit Codex model")
    parser.add_argument("--effort", choices=["low", "medium", "high", "xhigh"])
    parser.add_argument("--codex-path", default=os.environ.get("CODEX_PATH", "codex"))
    arguments = parser.parse_args()
    try:
        argv = command(arguments)
        if arguments.prompt != "-":
            # A supervised pipe can stay open. Codex also reads nonterminal
            # stdin, so give it EOF when the complete task is already supplied.
            source = os.open(os.devnull, os.O_RDONLY)
            try:
                os.dup2(source, 0)
            finally:
                if source != 0:
                    os.close(source)
        # Replace this helper. Keep the existing authentication environment and
        # let the Codex CLI own its process lifecycle and credential refresh.
        os.execv(argv[0], argv)
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        parser.exit(2, f"Isolated Codex task failed to start: {error}\n")


if __name__ == "__main__":
    main()
