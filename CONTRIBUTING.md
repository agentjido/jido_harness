# Contributing to JidoHarness

Thank you for your interest in contributing!

## Development Setup

```bash
git clone https://github.com/agentjido/jido_harness.git
cd jido_harness
mix setup
```

## Running Tests

```bash
mix test
```

## Quality Checks

```bash
mix quality
```

This runs: compile, format check, credo, dialyzer, and doctor.

## Commit Messages

Use [Conventional Commits](https://www.conventionalcommits.org/):

```
feat(adapter): add streaming support
fix(registry): handle missing provider config
docs: update README examples
```

## Pull Requests

1. Fork the repository
2. Create a feature branch (`git checkout -b feat/my-feature`)
3. Make your changes and ensure `mix quality` passes
4. Submit a pull request

## License

By contributing, you agree that your contributions will be licensed under the Apache-2.0 License.
