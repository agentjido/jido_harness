"""Build a clean source package, its escript, and a consumer with erlexec."""

import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile


def run(arguments, directory, environment):
    subprocess.run(arguments, cwd=directory, env=environment, check=True, timeout=240)


def main():
    archive = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix="harness-package-consumer-") as temporary:
        root = Path(temporary).resolve()
        package = root / "package"
        with tarfile.open(archive) as outer:
            contents = outer.extractfile("contents.tar.gz").read()
        with tarfile.open(fileobj=io.BytesIO(contents), mode="r:gz") as inner:
            names = inner.getnames()
            assert "vendor/erlexec/LICENSE" in names
            assert not any(name.startswith("priv/native/") for name in names)
            for member in inner.getmembers():
                path = Path(member.name)
                if path.is_absolute() or ".." in path.parts or not (member.isfile() or member.isdir()):
                    raise ValueError(f"Unsafe package entry: {member.name}")
            if hasattr(tarfile, "data_filter"):
                inner.extractall(package, filter="data")
            else:
                inner.extractall(package)

        consumer = root / "consumer"
        shutil.copytree(Path(__file__).resolve().parent, consumer)
        executable = root / "fixture"
        environment = dict(os.environ)
        environment.update({
            "MIX_ENV": "prod",
            "MIX_BUILD_PATH": str(root / "build"),
            "MIX_DEPS_PATH": str(root / "deps"),
            "JIDO_HARNESS_PACKAGE_PATH": str(package),
            "JIDO_HARNESS_ESCRIPT_LOCKFILE": str(consumer / "mix.lock"),
            "JIDO_HARNESS_ESCRIPT_PATH": str(executable),
            "JIDO_HARNESS_ESCRIPT_CACHE_DIR": str(root / "cache"),
            "JIDO_HARNESS_PACKAGE_WITH_ERLEXEC": "0",
        })
        run(["mix", "deps.get"], consumer, environment)
        run(["mix", "run", "-e", "JidoHarnessEscriptFixture.verify!()"], consumer, environment)
        run(["mix", "escript.build"], consumer, environment)
        with zipfile.ZipFile(executable) as script:
            assert script.read("jido_harness/priv/native/LICENSE") == (package / "vendor/erlexec/LICENSE").read_bytes()
        run([str(executable)], consumer, environment)
        environment["JIDO_HARNESS_PACKAGE_WITH_ERLEXEC"] = "1"
        run(["mix", "deps.get"], consumer, environment)
        run(["mix", "run", "-e", "JidoHarnessEscriptFixture.verify!()"], consumer, environment)
    print("Clean package, escript, and erlexec coexistence checks passed.")


if __name__ == "__main__":
    main()
