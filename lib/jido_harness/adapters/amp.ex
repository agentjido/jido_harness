defmodule Jido.Harness.Adapters.Amp do
  @moduledoc "Amp provider profile using the amp-acp adapter."
  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{AdapterSpec, Adapters.Helpers, Capabilities}

  @impl true
  def spec do
    %AdapterSpec{
      provider: :amp,
      name: "Amp",
      executable: "amp",
      docs_url: "https://ampcode.com/manual",
      capabilities: %Capabilities{streaming?: true, usage?: true},
      acp_agent:
        Jido.Harness.ACPAgentSpec.adapter("amp-acp", "amp-acp@0.9.0", %{
          maturity: :experimental,
          capabilities: %{load_session: false, multimodal: true, usage: true},
          turn_options: [:attachments, :content]
        }),
      normalized_options: [:provider_session_id, :mcp_config, :attachments],
      install: %{npm: "@sourcegraph/amp"}
    }
  end

  @impl true
  def status(config),
    do:
      Helpers.status(:amp, spec().executable, ["AMP_API_KEY"], config,
        cli_path_env: "AMP_CLI_PATH",
        capabilities: spec().capabilities
      )

  @impl true
  def install(_config, options), do: Helpers.install_npm(:amp, "@sourcegraph/amp", options)
end
