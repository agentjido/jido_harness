#!/usr/bin/env python3
"""Apply and build the pinned local erlexec correction."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]
FILES = ROOT / "scripts" / "local_workarounds"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    manifest = json.loads((FILES / "erlexec.json").read_text())
    lock = (ROOT / "mix.lock").read_text()
    expected = f'"erlexec": {{:hex, :erlexec, "{manifest["version"]}",'
    if expected not in lock:
        raise RuntimeError("The lock file does not select erlexec 2.5.0. Review the patch before an upgrade.")

    dependency = ROOT / "deps" / "erlexec"
    source = dependency / manifest["file"]
    if not source.is_file():
        raise RuntimeError("The erlexec source is missing. Run mix deps.get first.")

    current = digest(source)
    if current == manifest["original_sha256"]:
        patch = FILES / "erlexec-2.5.0-process-group.patch"
        command = ["patch", "-p1", "-i", str(patch)]
        subprocess.run(command + ["--dry-run"], cwd=dependency, check=True)
        subprocess.run(command, cwd=dependency, check=True)
        print("Applied the pinned erlexec patch.", flush=True)
    elif current == manifest["patched_sha256"]:
        print("The pinned erlexec patch is already applied.", flush=True)
    else:
        raise RuntimeError("The erlexec source does not match either recorded hash. No file was changed.")

    if digest(source) != manifest["patched_sha256"]:
        raise RuntimeError("The patched source hash does not match the manifest.")

    subprocess.run(["mix", "deps.compile", "erlexec", "--force"], cwd=ROOT, check=True)
    artifacts = sorted(dependency.glob("priv/*/exec-port"))
    if not artifacts:
        raise RuntimeError("The build did not produce an exec-port executable.")
    record = {
        **manifest,
        "artifacts": [{"path": str(path.relative_to(ROOT)), "sha256": digest(path)} for path in artifacts],
    }
    state = ROOT / ".local-workarounds"
    state.mkdir(exist_ok=True)
    (state / "erlexec-build.json").write_text(json.dumps(record, indent=2) + "\n")
    print("Recorded source and executable hashes in .local-workarounds/erlexec-build.json.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"Local erlexec setup failed: {error}", file=sys.stderr)
        sys.exit(1)
