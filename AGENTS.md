# AGENTS.md - Jido.Harness

## Overview

Jido.Harness is the core normalization layer for CLI AI coding agents. It defines behaviours, schemas, and error types that provider adapter packages implement.

## Key Modules

- `Jido.Harness` — Public facade (`run/3`)
- `Jido.Harness.Adapter` — Behaviour for provider adapters
- `Jido.Harness.RunRequest` — Zoi schema for run inputs
- `Jido.Harness.Event` — Zoi schema for normalized output events
- `Jido.Harness.Registry` — Provider lookup from app config
- `Jido.Harness.Error` — Splode error types

## Conventions

- Structs use the Zoi schema pattern (`@schema`, `new/1`, `new!/1`)
- Errors use Splode (`Jido.Harness.Error`)
- Elixir `~> 1.18`
- Run `mix quality` before committing
- Use conventional commit format

## Commands

- `mix test` — Run tests
- `mix quality` — Full quality check (compile, format, credo, dialyzer, doctor)
