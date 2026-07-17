# AGENTS.md - Jido.Harness

## Overview

Jido.Harness is the unified normalization and lifecycle layer for CLI AI coding agents. It owns provider adapters, supervised runs, and direct CLI process management.

## Key Modules

- `Jido.Harness` — Public run and process-management facade
- `Jido.Harness.Adapter` — Behaviour for provider adapters
- `Jido.Harness.RunRequest` — Zoi schema for run inputs
- `Jido.Harness.Event` — Zoi schema for normalized output events
- `Jido.Harness.Registry` — Provider lookup from app config
- `Jido.Harness.ProcessManager` — Harness-local OS process lifecycle management
- `Jido.Harness.RunManager` — Caller-independent provider run lifecycle management
- `Jido.Harness.Error` — Plain normalized exception struct

## Conventions

- Structs use the Zoi schema pattern (`@schema`, `new/1`, `new!/1`)
- Errors use the plain `%Jido.Harness.Error{}` struct
- Built-in adapters reject unsupported normalized and provider-specific options
- Process execution uses executable-plus-argv specifications, never interpolated shell commands
- Elixir `~> 1.19`
- Run `mix quality` before committing
- Use conventional commit format
- Do not modify `CHANGELOG.md`; release notes are generated from Git history during release, so keep changes focused on proper Conventional Commits.

## Commands

- `mix test` — Run tests
- `mix quality` — Full quality check (compile, format, credo, dialyzer, doctor)
- `mix jido_harness.check --inventory --strict` — Run non-billable provider and CLI checks
- `mix jido_harness.query codex "PROMPT"` — Run an explicit live ad hoc query
- `mix jido_harness.integration` — Run explicitly selected live integration profiles
