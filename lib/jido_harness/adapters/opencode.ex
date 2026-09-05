defmodule Jido.Harness.Adapters.OpenCode do
  @moduledoc "OpenCode provider profile using its native ACP mode."
  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{AdapterSpec, Adapters.Helpers, Capabilities}

  @impl true
  def spec do
    %AdapterSpec{
      provider: :opencode,
      name: "OpenCode",
      executable: "opencode",
      docs_url: "https://opencode.ai/docs",
      capabilities: %Capabilities{streaming?: true, resume?: true, usage?: true, native_cancel?: true},
      acp_agent:
        Jido.Harness.ACPAgentSpec.native("opencode", ["acp"], %{
          capabilities: %{load_session: true, multimodal: true, usage: true},
          turn_options: [:attachments, :content]
        }),
      normalized_options: [:provider_session_id, :mcp_config, :attachments],
      install: %{npm: "opencode-ai"}
    }
  end

  @impl true
  def status(config),
    do:
      Helpers.status(:opencode, spec().executable, ["OPENCODE_API_KEY", "ZAI_API_KEY"], config,
        capabilities: spec().capabilities
      )

  @impl true
  def install(_config, options), do: Helpers.install_npm(:opencode, "opencode-ai", options)
end
