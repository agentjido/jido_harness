# Private native process engine

This directory contains erlexec 2.5.0 source from the verified Hex archive.
The upstream commit, archive checksum, and original file hashes are recorded
in `UPSTREAM.json`. The original license is in `LICENSE`. Its text includes
three BSD conditions; retain the full text in source and binary distributions.

Harness compiles the Erlang modules under private `jido_harness_exec*` names
and starts their supervisor as part of its application. The configuration is
stored under `:jido_harness, :native_process`. Another application's erlexec
modules and registered processes remain separate.

`compiler.exs` builds the C++17 port from `c_src/` during `mix compile`. Objects
stay in the Mix build directory. The generated executable is placed in the
ignored `priv/native/SYSTEM_ARCH/` directory for release and escript packaging.
The Hex archive contains source and the compiler, not a host-specific binary.
The compiler also copies `LICENSE` into `priv/native/` so releases and escripts
retain the upstream license with the generated helper.

## Local changes

- `patches/process-group-startup.patch` checks the actual process group after
  a failed child assignment. Startup succeeds only when that group is correct.
  This matches [upstream PR #210](https://github.com/saleyn/erlexec/pull/210).
- `patches/group-diagnostics.patch` adds process and group IDs to the startup
  error so a failed assignment can be diagnosed from retained stderr.
- `patches/private-runtime.patch` records the private module names,
  configuration scope, asset directory, and hidden internal documentation.
- `patches/native-build.patch` removes obsolete macOS linker flags. The Mix task
  selects the current Erlang library, builds in a private directory, and copies
  the executable into the application assets. It replaces the executable with
  an atomic rename so macOS does not retain a stale code-signature cache.

## Update the source

Fetch and verify the new upstream source before importing it. Review the
recorded patches against that version and update the file hashes. Keep the
native source changes small so that an upstream comparison stays useful.

Run `mix quality`, the full tests, and the macOS/Linux native CI jobs. Those
jobs force both process-group outcomes and test startup, cancellation, PTY,
environment policy, and escript execution. Build the Hex archive and verify
that a clean consumer can compile it and run a managed process. Verify a
consumer that also depends on erlexec to check the private names.
