# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2025-02-14

### Added

- Initial release
- `JidoHarness.Adapter` behaviour for CLI agent adapters
- `JidoHarness.RunRequest` Zoi schema for validated run inputs
- `JidoHarness.Event` Zoi schema for normalized events
- `JidoHarness.Provider` Zoi schema for provider metadata
- `JidoHarness.Capabilities` struct for adapter capability declarations
- `JidoHarness.Error` Splode-based error handling
- `JidoHarness.Registry` for provider adapter lookup from application config
- `JidoHarness.run/3` facade for running agents
