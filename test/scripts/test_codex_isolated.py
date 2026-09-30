"""Black-box checks for the local Codex command boundary."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


HELPER = Path(__file__).resolve().parents[2] / "scripts" / "local_workarounds" / "codex_isolated.py"


class IsolatedCodexTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="harness-codex-check-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.cli = self.directory / "codex"

    def fake_cli(self, supported=True):
        options = "--ephemeral --ignore-user-config" if supported else "--ephemeral"
        self.cli.write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys\n"
            "if sys.argv[1:] == ['exec', '--help']:\n"
            f"    print({options!r})\n"
            "else:\n"
            "    print(json.dumps({'argv':sys.argv[1:], 'auth_home':os.environ.get('CODEX_HOME'), 'input':sys.stdin.read()}))\n"
        )
        self.cli.chmod(0o700)

    def run_helper(self, prompt="Write the fixture", *options):
        return subprocess.run(
            [sys.executable, str(HELPER), "--codex-path", str(self.cli), "--cwd", str(self.directory), *options, "--", prompt],
            capture_output=True, text=True, timeout=15,
        )

    def test_preserves_task_text_and_authentication_home(self):
        self.fake_cli()
        prompt = "Write $(touch forbidden); keep `literal` task text"
        result = self.run_helper(prompt, "--model", "test-model", "--effort", "xhigh")
        self.assertEqual(result.returncode, 0, result.stderr)
        output = json.loads(result.stdout)
        argv = output["argv"]
        self.assertEqual(argv[-2:], ["--", prompt])
        self.assertIn("--ephemeral", argv)
        self.assertIn("--ignore-user-config", argv)
        self.assertNotIn("--ignore-rules", argv)
        self.assertNotIn("--dangerously-bypass-approvals-and-sandbox", argv)
        self.assertEqual(argv[argv.index("--sandbox") + 1], "workspace-write")
        self.assertEqual(argv[argv.index("--model") + 1], "test-model")
        self.assertEqual(output["auth_home"], os.environ.get("CODEX_HOME"))
        self.assertFalse((self.directory / "forbidden").exists())

    def test_rejects_an_unsupported_cli_before_execution(self):
        self.fake_cli(supported=False)
        result = self.run_helper()
        self.assertEqual(result.returncode, 2)
        self.assertIn("lacks required options: --ignore-user-config", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_rejects_resume_in_an_ephemeral_task(self):
        self.fake_cli()
        result = self.run_helper("Task", "--resume", "saved-session")
        self.assertEqual(result.returncode, 2)
        self.assertIn("unrecognized arguments", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_finishes_a_literal_task_with_a_supervised_stdin_pipe(self):
        self.fake_cli()
        process = subprocess.Popen(
            [sys.executable, str(HELPER), "--codex-path", str(self.cli), "--cwd", str(self.directory), "Task"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        try:
            self.assertEqual(process.wait(timeout=5), 0)
            output = json.loads(process.stdout.read())
            self.assertEqual(output["input"], "")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            for pipe in (process.stdin, process.stdout, process.stderr):
                pipe.close()

    def test_preserves_stdin_when_the_task_argument_is_a_dash(self):
        self.fake_cli()
        result = subprocess.run(
            [sys.executable, str(HELPER), "--codex-path", str(self.cli), "--cwd", str(self.directory), "--", "-"],
            input="Task from stdin", capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["input"], "Task from stdin")


if __name__ == "__main__":
    unittest.main()
