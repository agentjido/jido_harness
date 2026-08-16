defmodule JidoHarnessEscriptFixture.MixProject do
  use Mix.Project

  def project do
    [
      app: :jido_harness_escript_fixture,
      version: "0.0.0",
      elixir: "~> 1.19",
      deps: [{:jido_harness, path: Path.expand("../..", __DIR__)}],
      escript: [
        main_module: JidoHarnessEscriptFixture,
        app: nil,
        include_priv_for: [:erlexec],
        path: System.fetch_env!("JIDO_HARNESS_ESCRIPT_PATH")
      ]
    ]
  end

  def application, do: []
end
