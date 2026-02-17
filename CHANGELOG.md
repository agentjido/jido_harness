# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Expanded `Jido.Harness` facade into a multi-provider wrapper layer:
  - `run/2` (default provider dispatch)
  - `run_request/2` and `run_request/3`
  - `providers/0`
  - `default_provider/0`
  - `capabilities/1`
  - `cancel/2`
- Provider result normalization so non-native result payloads are wrapped into
  normalized `Jido.Harness.Event` streams.
- Registry auto-discovery for known provider module candidates (`codex`, `amp`,
  `claude`, `gemini`) with explicit config override support.
- Comprehensive unit coverage for registry resolution, dispatch fallbacks,
  capability lookup, cancellation behavior, and schema/error constructors.

## [0.1.0] - 2025-02-14

### Added

- Initial release
- `Jido.Harness.Adapter` behaviour for CLI agent adapters
- `Jido.Harness.RunRequest` Zoi schema for validated run inputs
- `Jido.Harness.Event` Zoi schema for normalized events
- `Jido.Harness.Provider` Zoi schema for provider metadata
- `Jido.Harness.Capabilities` struct for adapter capability declarations
- `Jido.Harness.Error` Splode-based error handling
- `Jido.Harness.Registry` for provider adapter lookup from application config
- `Jido.Harness.run/3` facade for running agents
