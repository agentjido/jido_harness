#!/usr/bin/env python3
"""Check both process-group outcomes in separate, owned Erlang VMs."""

import os
from pathlib import Path
import platform
import signal
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
FILES = ROOT / "test" / "support" / "fixtures" / "process_groups"


def erlang_string(value):
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


def run_vm(ebin, wrapper, library, port, loader, denied):
    environment = [
        ("ERLEXEC_TEST_PORT", port),
        ("ERLEXEC_TEST_LIBRARY", library),
        ("ERLEXEC_TEST_LOADER", loader),
    ]
    if denied:
        environment.append(("ERLEXEC_TEST_DENY_PARENT_GROUP", "1"))
    encoded = ",".join("{" + erlang_string(key) + "," + erlang_string(value) + "}" for key, value in environment)
    expected = (
        '{error,Details} -> 256 = proplists:get_value(exit_status,Details), '
        'undefined = proplists:get_value(stdout,Details), '
        '[<<"Cannot set effective group to 0",_/binary>>] = proplists:get_value(stderr,Details)'
        if denied else
        '{ok,[{stdout,[<<"group-ok\\n">>]}]} -> ok'
    )
    expression = (
        '{ok,_}=exec:start([{portexe,' + erlang_string(wrapper) + '},{env,[' + encoded + ']}]),'
        'case exec:run(["/bin/echo","group-ok"],[sync,stdout,stderr,{group,0},kill_group]) of '
        + expected + '; Other -> io:format("Unexpected process result: ~p~n",[Other]),halt(1) end,'
        'io:format("Process-group check passed.~n"),halt(0).'
    )
    process = subprocess.Popen(
        ["erl", "-pa", str(ebin), "-noshell", "-eval", expression],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True,
    )
    try:
        output, _ = process.communicate(timeout=20)
    except BaseException:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        raise
    print(output.decode(errors="replace"), end="")
    if process.returncode:
        raise RuntimeError(f"The {'wrong-group' if denied else 'assigned-group'} VM check failed.")


def main():
    if platform.system() == "Darwin":
        flags, loader = ["-dynamiclib", "-fPIC"], "DYLD_INSERT_LIBRARIES"
    elif platform.system() == "Linux":
        flags, loader = ["-shared", "-fPIC", "-ldl"], "LD_PRELOAD"
    else:
        raise RuntimeError("These local process checks support macOS and Linux.")
    dependency = ROOT / "deps" / "erlexec"
    candidates = sorted((dependency / "priv").glob("*/exec-port"))
    if len(candidates) != 1:
        raise RuntimeError("Expected one local exec-port executable. Build erlexec first.")
    ebin = ROOT / "_build" / os.environ.get("MIX_ENV", "dev") / "lib" / "erlexec" / "ebin"
    if not (ebin / "exec.beam").is_file():
        raise RuntimeError("The erlexec beam file is missing. Build erlexec first.")
    with tempfile.TemporaryDirectory(prefix="harness-group-check-") as directory:
        library = Path(directory) / "group_failure.so"
        wrapper = Path(directory) / "port_wrapper"
        subprocess.run(["cc", *flags, "-o", str(library), str(FILES / "group_failure.c")], check=True)
        subprocess.run(["cc", "-O2", "-o", str(wrapper), str(FILES / "port_wrapper.c")], check=True)
        for denied in (False, True):
            run_vm(ebin, wrapper, library, candidates[0], loader, denied)
    print("Both outcomes passed. Each check owned a separate Erlang VM; no application server was replaced.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Local erlexec check failed: {error}", file=sys.stderr)
        sys.exit(1)
