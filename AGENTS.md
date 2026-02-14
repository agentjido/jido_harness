# AGENTS.md - JidoHarness

## Overview

JidoHarness is the core normalization layer for CLI AI coding agents. It defines behaviours, schemas, and error types that provider adapter packages implement.

## Key Modules

- `JidoHarness` — Public facade (`run/3`)
- `JidoHarness.Adapter` — Behaviour for provider adapters
- `JidoHarness.RunRequest` — Zoi schema for run inputs
- `JidoHarness.Event` — Zoi schema for normalized output events
- `JidoHarness.Registry` — Provider lookup from app config
- `JidoHarness.Error` — Splode error types

## Conventions

- Structs use the Zoi schema pattern (`@schema`, `new/1`, `new!/1`)
- Errors use Splode (`JidoHarness.Error`)
- Elixir `~> 1.18`
- Run `mix quality` before committing
- Use conventional commit format

## Commands

- `mix test` — Run tests
- `mix quality` — Full quality check (compile, format, credo, dialyzer, doctor)
