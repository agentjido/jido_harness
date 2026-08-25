defmodule Jido.Harness.Adapters.Claude do
  @moduledoc "Claude Code provider profile using claude-agent-acp."
  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{AdapterSpec, Adapters.Helpers, Capabilities}

  @impl true
  def spec do
    %AdapterSpec{
      provider: :claude,
      name: "Claude Code",
      executable: "claude",
      docs_url: "https://docs.anthropic.com/en/docs/claude-code",
      capabilities: %Capabilities{
        streaming?: true,
        tool_calls?: true,
        tool_results?: true,
        thinking?: true,
        resume?: true,
        usage?: true,
        native_cancel?: true
      },
      acp_agent:
        Jido.Harness.ACPAgentSpec.adapter(
          "claude-agent-acp",
          "@agentclientprotocol/claude-agent-acp@0.70.0",
          %{
            capabilities: %{load_session: true, multimodal: true, dynamic_model: true, usage: true},
            turn_options: [:attachments, :content],
            configuration_options: [:model]
          }
        ),
      normalized_options: [:model, :provider_session_id, :mcp_config, :attachments],
      install: %{npm: "@anthropic-ai/claude-code"}
    }
  end

  @impl true
  def status(config),
    do:
      Helpers.status(
        :claude,
        spec().executable,
        ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "CLAUDE_CODE_API_KEY"],
        config,
        capabilities: spec().capabilities
      )

  @impl true
  def install(_config, options), do: Helpers.install_npm(:claude, "@anthropic-ai/claude-code", options)
end
