defmodule Jido.Harness.Adapters.Codex do
  @moduledoc "Codex provider profile using codex-acp."
  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{AdapterSpec, Adapters.Helpers, Capabilities}

  @impl true
  def spec do
    %AdapterSpec{
      provider: :codex,
      name: "Codex",
      executable: "codex",
      docs_url: "https://github.com/openai/codex",
      capabilities: %Capabilities{
        streaming?: true,
        tool_calls?: true,
        tool_results?: true,
        thinking?: true,
        resume?: true,
        usage?: true,
        file_changes?: true,
        native_cancel?: true
      },
      acp_agent:
        Jido.Harness.ACPAgentSpec.adapter("codex-acp", "@agentclientprotocol/codex-acp@1.6.2", %{
          capabilities: %{
            load_session: true,
            multimodal: true,
            dynamic_model: true,
            dynamic_configuration: true,
            usage: true
          },
          turn_options: [:attachments, :content],
          configuration_options: [:model, :reasoning_effort, :approval_mode, :sandbox_mode]
        }),
      normalized_options: [
        :model,
        :provider_session_id,
        :mcp_config,
        :approval_mode,
        :sandbox_mode,
        :attachments,
        :reasoning_effort
      ],
      normalized_values: %{reasoning_effort: [nil, :low, :medium, :high, :xhigh]},
      install: %{npm: "@openai/codex"}
    }
  end

  @impl true
  def status(config),
    do:
      Helpers.status(:codex, spec().executable, [], config,
        cli_path_env: "CODEX_PATH",
        capabilities: spec().capabilities
      )

  @impl true
  def install(_config, options), do: Helpers.install_npm(:codex, "@openai/codex", options)
end
