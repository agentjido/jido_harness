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
      # Documentation
      name: "Jido.Harness",
      source_url: @source_url,
      homepage_url: @source_url,
      docs: [
        main: "overview",
        source_ref: "v#{@version}",
        extras: [
          "README.md",
          "guides/overview.md",
          "guides/getting_started.md",
          "guides/choosing_a_workflow.md",
          "guides/providers.md",
          "guides/one_shot_requests.md",
          "guides/detached_runs.md",
          "guides/interactive_sessions.md",
          "guides/managed_processes.md",
          "guides/normalization_and_data_model.md",
          "guides/streaming_replay_and_retention.md",
          "guides/ownership_timeouts_and_cancellation.md",
          "guides/security.md",
          "guides/operations.md",
          "guides/testing.md",
          "guides/custom_adapters.md",
          "docs/configuration_reference.md",
          "docs/event_reference.md",
          "CHANGELOG.md",
          "CONTRIBUTING.md",
          "LICENSE",
          "docs/adapter_contract.md",
          "docs/telemetry.md",
          "docs/dependency_policy.md",
          "docs/process_management.md",
          "docs/integration_testing.md",
          "docs/migration_v2.md",
          "livebooks/01_one_shot_requests.livemd",
          "livebooks/02_detached_runs.livemd",
          "livebooks/03_sessions_and_processes.livemd"
        ],
        groups_for_extras: [
          "Start here": [
            "guides/overview.md",
            "guides/getting_started.md",
            "guides/choosing_a_workflow.md",
            "guides/providers.md"
          ],
          "Core workflows": [
            "guides/one_shot_requests.md",
            "guides/detached_runs.md",
            "guides/interactive_sessions.md",
            "guides/managed_processes.md"
          ],
          "Shared concepts": [
            "guides/normalization_and_data_model.md",
            "guides/streaming_replay_and_retention.md",
            "guides/ownership_timeouts_and_cancellation.md",
            "guides/security.md"
          ],
          "Operating and extending": [
            "guides/operations.md",
            "guides/testing.md",
            "guides/custom_adapters.md"
          ],
          Reference: [
            "docs/configuration_reference.md",
            "docs/event_reference.md",
            "docs/adapter_contract.md",
            "docs/process_management.md",
            "docs/integration_testing.md",
            "docs/telemetry.md",
            "docs/dependency_policy.md",
            "docs/migration_v2.md"
          ],
          Livebooks: [
            "livebooks/01_one_shot_requests.livemd",
            "livebooks/02_detached_runs.livemd",
            "livebooks/03_sessions_and_processes.livemd"
          ]
        ],
        groups_for_modules: [
          "Core API": [
            Jido.Harness,
            Jido.Harness.Run,
            Jido.Harness.Session,
            Jido.Harness.Process
          ],
          "Requests and results": [
            Jido.Harness.RunRequest,
            Jido.Harness.RunResult,
            Jido.Harness.RunInfo,
            Jido.Harness.SessionRequest,
            Jido.Harness.TurnRequest,
            Jido.Harness.TurnResult,
            Jido.Harness.SessionInfo,
            Jido.Harness.ApprovalResponse,
            Jido.Harness.ProcessSpec,
            Jido.Harness.ProcessInfo
          ],
          "Events and errors": [
            Jido.Harness.Event,
            Jido.Harness.ProcessEvent,
            Jido.Harness.Error
          ],
          "Providers and extension contracts": [
            Jido.Harness.ProviderStatus,
            Jido.Harness.Capabilities,
            Jido.Harness.InteractionCapabilities,
            Jido.Harness.Adapter,
            Jido.Harness.AdapterSpec,
            Jido.Harness.SessionAdapter,
            Jido.Harness.SessionTransportSpec,
            Jido.Harness.Registry
          ],
          "Built-in adapters": [
            Jido.Harness.Adapters.Amp,
            Jido.Harness.Adapters.Claude,
            Jido.Harness.Adapters.Codex,
            Jido.Harness.Adapters.Gemini,
            Jido.Harness.Adapters.Grok,
            Jido.Harness.Adapters.Kimi,
            Jido.Harness.Adapters.OpenCode,
            Jido.Harness.Adapters.Pi,
            Jido.Harness.Adapters.Zai
          ],
          Testing: [Jido.Harness.IntegrationCase]
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
          "guides",
          "lib",
          "livebooks",
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
