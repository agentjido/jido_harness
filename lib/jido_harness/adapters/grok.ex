defmodule Jido.Harness.Adapters.Grok do
  @moduledoc "Grok CLI provider profile using its native ACP mode."
  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{AdapterSpec, Adapters.Helpers, Capabilities}

  @impl true
  def spec do
    %AdapterSpec{
      provider: :grok,
      name: "Grok",
      executable: "grok",
      docs_url: "https://docs.x.ai/build/cli/reference",
      capabilities: %Capabilities{streaming?: true, resume?: true, usage?: true, native_cancel?: true},
      acp_agent:
        Jido.Harness.ACPAgentSpec.native("grok", ["agent", "stdio"], %{
          capabilities: %{load_session: true, usage: true}
        }),
      normalized_options: [:provider_session_id, :mcp_config],
      install: %{npm: "@xai-official/grok"}
    }
  end

  @impl true
  def status(config),
    do:
      Helpers.status(:grok, spec().executable, ["XAI_API_KEY"], config,
        version_argv: ["version"],
        capabilities: spec().capabilities
      )

  @impl true
  def install(_config, options), do: Helpers.install_npm(:grok, "@xai-official/grok", options)
end
