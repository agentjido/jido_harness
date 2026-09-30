defmodule JidoHarnessEscriptFixture.MixProject do
  use Mix.Project

  def project do
    [
      app: :jido_harness_escript_fixture,
      version: "0.0.0",
      elixir: "~> 1.19",
      lockfile: System.get_env("JIDO_HARNESS_ESCRIPT_LOCKFILE") || Path.expand("../../../../mix.lock", __DIR__),
      deps: dependencies(),
      escript: [
        main_module: JidoHarnessEscriptFixture,
        app: nil,
        include_priv_for: [:jido_harness],
        path: System.fetch_env!("JIDO_HARNESS_ESCRIPT_PATH")
      ]
    ]
  end

  def application, do: []

  defp dependencies do
    harness = {:jido_harness, path: System.get_env("JIDO_HARNESS_PACKAGE_PATH") || Path.expand("../../../..", __DIR__)}

    if System.get_env("JIDO_HARNESS_PACKAGE_WITH_ERLEXEC") == "1",
      do: [harness, {:erlexec, "== 2.5.0"}],
      else: [harness]
  end
end
