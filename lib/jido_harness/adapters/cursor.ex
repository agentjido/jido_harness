defmodule Jido.Harness.Adapters.Cursor do
  @moduledoc "Cursor CLI provider profile using its native ACP mode."
  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{AdapterSpec, Adapters.Helpers, Capabilities}

  @install_url "https://cursor.com/install"

  @impl true
  def spec do
    %AdapterSpec{
      provider: :cursor,
      name: "Cursor CLI",
      executable: "cursor-agent",
      docs_url: "https://cursor.com/docs/cli/acp",
      capabilities: %Capabilities{
        streaming?: true,
        tool_calls?: true,
        tool_results?: true,
        resume?: true,
        native_cancel?: true
      },
      acp_agent:
        Jido.Harness.ACPAgentSpec.native("cursor-agent", ["acp"], %{
          auth_method: "cursor_login",
          maturity: :experimental,
          capabilities: %{load_session: true}
        }),
      normalized_options: [:provider_session_id, :mcp_config],
      install: %{script: @install_url}
    }
  end

  @impl true
  def status(config) do
    Helpers.status(:cursor, spec().executable, ["CURSOR_API_KEY", "CURSOR_AUTH_TOKEN"], config,
      capabilities: spec().capabilities
    )
  end

  @impl true
  def install(_config, options), do: Helpers.install_script(:cursor, @install_url, options)
end
