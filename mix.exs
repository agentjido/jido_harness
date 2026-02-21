defmodule Jido.Harness.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/agentjido/jido_harness"
  @description "Normalized Elixir protocol for CLI AI coding agents"

  def project do
    [
      app: :jido_harness,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      # Documentation
      name: "Jido.Harness",
      source_url: @source_url,
      homepage_url: @source_url,
      docs: [
        main: "Jido.Harness",
        extras: [
          "README.md",
          "CHANGELOG.md",
          "CONTRIBUTING.md",
          "docs/telemetry.md",
          "docs/dependency_policy.md"
        ],
        formatters: ["html"]
      ],
      test_coverage: [
        tool: ExCoveralls,
        summary: [threshold: 90],
        ignore_modules: [
          Jido.Harness.Error.Invalid,
          Jido.Harness.Error.Execution,
          Jido.Harness.Error.Config,
          Jido.Harness.Error.Internal,
          Jido.Harness.Error.Internal.UnknownError,
          Jido.Harness.Test.AdapterStub,
          Jido.Harness.Test.PromptRunnerStub,
          Jido.Harness.Test.StreamRunnerStub,
          Jido.Harness.Test.RunRequestRunnerStub,
          Jido.Harness.Test.ExecuteRunnerStub,
          Jido.Harness.Test.NoCancelStub,
          Jido.Harness.Test.AtomMapStreamRunnerStub,
          Jido.Harness.Test.UnsupportedRunnerStub
        ]
      ],
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
          "mix.exs"
        ],
        licenses: ["Apache-2.0"],
        links: %{"GitHub" => @source_url}
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.github": :test,
        "coveralls.html": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Runtime
      {:zoi, "~> 0.17"},
      {:splode, "~> 0.3.0"},
      {:jason, "~> 1.4"},
      {:jido, "~> 2.0.0-rc.5"},
      {:jido_shell, github: "agentjido/jido_shell", branch: "main", override: true},
      {:sprites, git: "https://github.com/mikehostetler/sprites-ex.git", override: true},

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
      setup: ["deps.get", "git_hooks.install"],
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
