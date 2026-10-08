Code.require_file("vendor/erlexec/compiler.exs", __DIR__)

defmodule Jido.Harness.MixProject do
  use Mix.Project

  @version "3.0.0-rc.1"
  @source_url "https://github.com/agentjido/jido_harness"
  @description "Supervised, normalized Elixir runtime for CLI AI coding agents"

  @project_docs ["README.md", "CONTRIBUTING.md", "CHANGELOG.md", "LICENSE"]
  @guide_groups [
    {"Start here",
     [
       "guides/overview.md",
       "guides/getting_started.md",
       "guides/providers.md"
     ]},
    {"Workflows",
     [
       "guides/runs.md",
       "guides/interactive_sessions.md",
       "guides/managed_processes.md",
       "guides/recipes/policy_jobs.md"
     ]},
    {"Shared concepts",
     [
       "guides/normalization_and_data_model.md",
       "guides/streaming_replay_and_retention.md",
       "guides/ownership_timeouts_and_cancellation.md",
       "guides/security.md"
     ]},
    {"Operating and extending",
     [
       "guides/operations.md",
       "guides/escripts.md",
       "guides/testing.md",
       "guides/custom_adapters.md"
     ]},
    {"Reference",
     [
       "guides/reference/configuration_reference.md",
       "guides/reference/event_reference.md",
       "guides/reference/telemetry.md",
       "guides/reference/architecture.md",
       "guides/reference/dependencies.md"
     ]},
    {"Migration",
     [
       "guides/migrations/migration_v3.md"
     ]},
    {"Livebooks",
     [
       "guides/livebooks/01_one_shot_requests.livemd",
       "guides/livebooks/02_detached_runs.livemd",
       "guides/livebooks/03_sessions_and_processes.livemd"
     ]}
  ]

  def project do
    [
      app: :jido_harness,
      version: @version,
      elixir: "~> 1.19",
      hex: [
        ignore_advisories: [
          "EEF-CVE-2026-43966",
          "EEF-CVE-2026-43969"
        ]
      ],
      elixirc_paths: elixirc_paths(Mix.env()),
      erlc_paths: ["vendor/erlexec/src"],
      erlc_include_path: "vendor/erlexec/include",
      erlc_options: [:debug_info, :warnings_as_errors],
      compilers: [:harness_native] ++ Mix.compilers(),
      test_ignore_filters: [&String.starts_with?(&1, "test/support/fixtures/")],
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
        extras: @project_docs ++ Enum.flat_map(@guide_groups, &elem(&1, 1)),
        groups_for_extras: @guide_groups ++ [{"Project", @project_docs}],
        assets: %{"guides/recipes" => "."},
        groups_for_modules: [
          "Core API": [
            Jido.Harness,
            Jido.Harness.Run,
            Jido.Harness.Session,
            Jido.Harness.Process,
            Jido.Harness.Escript
          ],
          "Requests and results": [
            Jido.Harness.RunRequest,
            Jido.Harness.StructuredOutput,
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
            Jido.Harness.SessionCapabilities,
            Jido.Harness.ACPAgentSpec,
            Jido.Harness.Adapter,
            Jido.Harness.AdapterSpec,
            Jido.Harness.SessionAdapter,
            Jido.Harness.Registry
          ],
          "Built-in adapters": [
            Jido.Harness.Adapters.Amp,
            Jido.Harness.Adapters.Antigravity,
            Jido.Harness.Adapters.Claude,
            Jido.Harness.Adapters.Codex,
            Jido.Harness.Adapters.Cursor,
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
      test_coverage: [tool: ExCoveralls, export: "cov"],
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
          "guides",
          "lib",
          "priv/acp",
          "vendor/erlexec",
          "mix.exs"
        ],
        maintainers: ["Agent Jido Team"],
        licenses: ["Apache-2.0", "BSD-3-Clause"],
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
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support/modules"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Runtime
      {:zoi, "~> 0.18.11"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.3"},
      {:ex_mcp, "~> 1.3"},

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
