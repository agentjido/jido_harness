defmodule JidoV3Contract.MixProject do
  use Mix.Project

  def project do
    [app: :jido_v3_harness_contract, version: "0.1.0", deps: deps()]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [
      {:jido, github: "agentjido/jido", ref: "047bf746330a2fbe7c3b25c045552e0303c97eaf"},
      {:jido_harness, path: "../.."}
    ]
  end
end
