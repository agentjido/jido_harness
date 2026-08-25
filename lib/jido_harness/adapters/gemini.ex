defmodule Jido.Harness.Adapters.Gemini do
  @moduledoc "Gemini CLI provider profile using its native ACP mode."
  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{AdapterSpec, Adapters.Helpers, Capabilities}

  @impl true
  def spec do
    %AdapterSpec{
      provider: :gemini,
      name: "Gemini CLI",
      executable: "gemini",
      docs_url: "https://github.com/google-gemini/gemini-cli",
      capabilities: %Capabilities{
        streaming?: true,
        tool_calls?: true,
        tool_results?: true,
        resume?: true,
        usage?: true,
        native_cancel?: true
      },
      acp_agent:
        Jido.Harness.ACPAgentSpec.native("gemini", ["--acp"], %{
          maturity: :experimental,
          capabilities: %{load_session: true, multimodal: true, dynamic_model: true, usage: true},
          turn_options: [:attachments, :content],
          configuration_options: [:model]
        }),
      normalized_options: [:model, :provider_session_id, :mcp_config, :attachments],
      install: %{npm: "@google/gemini-cli"}
    }
  end

  @impl true
  def status(config),
    do:
      Helpers.status(
        :gemini,
        spec().executable,
        ["GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_GENAI_USE_VERTEXAI", "GOOGLE_GENAI_USE_GCA"],
        config,
        cli_path_env: "GEMINI_CLI_PATH",
        capabilities: spec().capabilities
      )

  @impl true
  def install(_config, options), do: Helpers.install_npm(:gemini, "@google/gemini-cli", options)
end
