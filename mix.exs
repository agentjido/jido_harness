defmodule Jido.Harness.MixProject do
  use Mix.Project

  @version "2.0.0"
  @source_url "https://github.com/agentjido/jido_harness"
  @description "Supervised, normalized Elixir runtime for CLI AI coding agents"

  def project do
    [
      app: :jido_harness,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      # No compatible patched transitive releases are available yet.
      hex: [
        ignore_advisories: [
          "CVE-2026-43969",
          "CVE-2026-43966",
          "CVE-2026-47075",
          "CVE-2026-47076",
          "CVE-2026-47071",
          "CVE-2026-47069"
        ]
      ],
      # Documentation
      name: "Jido.Harness",
      source_url: @source_url,
      homepage_url: @source_url,
      docs: [
        main: "Jido.Harness",
        source_ref: "v#{@version}",
        extras: [
          "README.md",
          "CHANGELOG.md",
          "CONTRIBUTING.md",
          "LICENSE",
          "docs/adapter_contract.md",
          "docs/telemetry.md",
          "docs/dependency_policy.md",
          "docs/process_management.md",
          "docs/integration_testing.md",
          "docs/migration_v2.md"
        ],
        formatters: ["html"]
      ],
      test_coverage: [
        tool: ExCoveralls,
        summary: [threshold: 90],
        export: "cov",
        ignore_modules: [
          Jido.Harness.IntegrationCase,
          Mix.Tasks.JidoHarness.Chat
        ]
      ],
      dialyzer: [plt_add_apps: [:mix, :ex_unit]],
      # Hex packaging
      package: [
        name: :jido_harness,
        description: @description,
        files: [
          ".formatter.exs",
          "CHANGELOG.md",
          "CONTRIBUTING.md",
          "LICENSE",
          "README.md",
          "usage-rules.md",
          "config",
          "docs",
          "lib",
          "priv",
          "mix.exs"
        ],
        maintainers: ["Agent Jido Team"],
        licenses: ["Apache-2.0"],
        links: %{
          "Changelog" => "https://github.com/agentjido/jido_harness/blob/main/CHANGELOG.md",
          "Discord" => "https://jido.run/discord",
          "Documentation" => "https://hexdocs.pm/jido_harness",
          "GitHub" => @source_url,
          "Website" => "https://jido.run"
        }
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.github": :test,
        "coveralls.html": :test,
        "jido_harness.check": :test,
        "jido_harness.chat": :test
      ]
    ]
  end

  def application do
    [
      mod: {Jido.Harness.Application, []},
      extra_applications: [:logger, :erlexec]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Runtime
      {:zoi, "~> 0.18"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.3"},
      {:erlexec, "~> 2.3"},
      # Gemini SDK was retired before migrating to cli_subprocess_core 0.2.
      # Pin the mutually compatible SDK generation so all four SDK backends
      # can coexist in one Mix application.
      {:cli_subprocess_core, "~> 0.1.0"},
      {:amp_sdk, "~> 0.5.0"},
      {:claude_agent_sdk, "~> 0.14.0"},
      {:codex_sdk, "~> 0.10.0"},
      {:gemini_cli_sdk, "~> 0.2.0"},

      # Dev/Test
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:doctor, "~> 0.21", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test]},
      {:git_hooks, "~> 0.8", only: [:dev, :test], runtime: false},
      {:git_ops, "~> 2.9", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      install_hooks: ["git_hooks.install"],
      q: ["quality"],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --min-priority higher",
        "dialyzer",
        "doctor --raise"
      ],
      test: ["test --cover --color"],
      "test.watch": ["watch -c \"mix test\""]
    ]
  end
end
