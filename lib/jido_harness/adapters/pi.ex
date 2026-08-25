defmodule Jido.Harness.Adapters.Pi do
  @moduledoc "Pi provider profile using pi-acp."
  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{AdapterSpec, Adapters.Helpers, Capabilities}

  @auth_envs [
    "AI_GATEWAY_API_KEY",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_OAUTH_TOKEN",
    "AWS_BEARER_TOKEN_BEDROCK",
    "AWS_PROFILE",
    "AZURE_OPENAI_API_KEY",
    "CEREBRAS_API_KEY",
    "CLOUDFLARE_API_KEY",
    "DEEPSEEK_API_KEY",
    "FIREWORKS_API_KEY",
    "GEMINI_API_KEY",
    "GROQ_API_KEY",
    "HF_TOKEN",
    "KIMI_API_KEY",
    "MINIMAX_API_KEY",
    "MISTRAL_API_KEY",
    "MOONSHOT_API_KEY",
    "NVIDIA_API_KEY",
    "OPENAI_API_KEY",
    "OPENCODE_API_KEY",
    "OPENROUTER_API_KEY",
    "TOGETHER_API_KEY",
    "XAI_API_KEY",
    "XIAOMI_API_KEY",
    "XIAOMI_TOKEN_PLAN_AMS_API_KEY",
    "XIAOMI_TOKEN_PLAN_CN_API_KEY",
    "XIAOMI_TOKEN_PLAN_SGP_API_KEY",
    "ZAI_API_KEY",
    "ZAI_CODING_CN_API_KEY"
  ]

  @impl true
  def spec do
    %AdapterSpec{
      provider: :pi,
      name: "Pi",
      executable: "pi",
      docs_url: "https://github.com/earendil-works/pi/tree/main/packages/coding-agent",
      capabilities: %Capabilities{
        streaming?: true,
        tool_calls?: true,
        tool_results?: true,
        thinking?: true,
        resume?: true,
        native_cancel?: true
      },
      acp_agent:
        Jido.Harness.ACPAgentSpec.adapter("pi-acp", "pi-acp@0.0.33", %{
          maturity: :experimental,
          capabilities: %{
            load_session: true,
            dynamic_model: true,
            dynamic_configuration: true,
            mcp: false
          },
          configuration_options: [:model, :reasoning_effort]
        }),
      normalized_options: [:model, :provider_session_id, :reasoning_effort],
      normalized_values: %{reasoning_effort: [nil, :low, :medium, :high]},
      install: %{npm: "@earendil-works/pi-coding-agent", npm_args: ["--ignore-scripts"]}
    }
  end

  @impl true
  def status(config),
    do:
      Helpers.status(:pi, spec().executable, @auth_envs, config,
        capabilities: spec().capabilities,
        compatibility_argv: ["--help"],
        compatibility_pattern: "--mode"
      )

  @impl true
  def install(_config, options),
    do: Helpers.install_npm(:pi, "@earendil-works/pi-coding-agent", options, ["--ignore-scripts"])
end
