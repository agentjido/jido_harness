defmodule Jido.Harness.Adapters.Omp do
  @moduledoc "Oh My Pi provider profile using its native ACP mode and existing local credentials."
  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{AdapterSpec, Adapters.Helpers, Capabilities}

  @install_url "https://omp.sh/install"

  @auth_envs [
    "AIAND_API_KEY",
    "AIMLAPI_API_KEY",
    "AI_GATEWAY_API_KEY",
    "ALIBABA_CODING_PLAN_API_KEY",
    "ALIBABA_TOKEN_PLAN_API_KEY",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_FOUNDRY_API_KEY",
    "ANTHROPIC_OAUTH_TOKEN",
    "AWS_BEARER_TOKEN_BEDROCK",
    "AZURE_OPENAI_API_KEY",
    "BAILIAN_TOKEN_PLAN_API_KEY",
    "BASETEN_API_KEY",
    "CEREBRAS_API_KEY",
    "CLOUDFLARE_AI_GATEWAY_API_KEY",
    "CLOUDSDK_AUTH_ACCESS_TOKEN",
    "COPILOT_GITHUB_TOKEN",
    "COREWEAVE_API_KEY",
    "CURSOR_ACCESS_TOKEN",
    "DEEPSEEK_API_KEY",
    "DEVIN_API_KEY",
    "FIREPASS_API_KEY",
    "FIREWORKS_API_KEY",
    "FUGU_API_KEY",
    "GEMINI_API_KEY",
    "GITLAB_TOKEN",
    "GMI_API_KEY",
    "GOOGLE_CLOUD_ACCESS_TOKEN",
    "GOOGLE_CLOUD_API_KEY",
    "GROQ_API_KEY",
    "HF_TOKEN",
    "HUGGINGFACE_HUB_TOKEN",
    "KILO_API_KEY",
    "KIMI_API_KEY",
    "LITELLM_API_KEY",
    "LLAMA_CPP_API_KEY",
    "LM_STUDIO_API_KEY",
    "META_API_KEY",
    "MINIMAX_API_KEY",
    "MINIMAX_CODE_API_KEY",
    "MINIMAX_CODE_CN_API_KEY",
    "MISTRAL_API_KEY",
    "MODEL_API_KEY",
    "MOONSHOT_API_KEY",
    "NANO_GPT_API_KEY",
    "NOVITA_API_KEY",
    "NVIDIA_API_KEY",
    "OLLAMA_API_KEY",
    "OLLAMA_CLOUD_API_KEY",
    "OPENAI_API_KEY",
    "OPENAI_CODEX_OAUTH_TOKEN",
    "OPENCODE_API_KEY",
    "OPENROUTER_API_KEY",
    "QIANFAN_API_KEY",
    "QWEN_OAUTH_TOKEN",
    "QWEN_PORTAL_API_KEY",
    "SAKANA_API_KEY",
    "SILICONFLOW_API_KEY",
    "SILICONFLOW_CN_API_KEY",
    "SYNTHETIC_API_KEY",
    "TOGETHER_API_KEY",
    "UMANS_AI_CODING_PLAN_API_KEY",
    "VENICE_API_KEY",
    "VLLM_API_KEY",
    "WAFER_SERVERLESS_API_KEY",
    "WANDB_API_KEY",
    "XAI_API_KEY",
    "XAI_OAUTH_TOKEN",
    "XIAOMI_API_KEY",
    "XIAOMI_TOKEN_PLAN_AMS_API_KEY",
    "XIAOMI_TOKEN_PLAN_CN_API_KEY",
    "XIAOMI_TOKEN_PLAN_SGP_API_KEY",
    "ZAI_API_KEY",
    "ZENMUX_API_KEY",
    "ZHIPU_API_KEY"
  ]

  @impl Jido.Harness.Adapter
  def spec do
    %AdapterSpec{
      provider: :omp,
      name: "Oh My Pi",
      executable: "omp",
      docs_url: "https://omp.sh/docs/acp",
      capabilities: %Capabilities{
        streaming?: true,
        tool_calls?: true,
        tool_results?: true,
        thinking?: true,
        resume?: true,
        native_cancel?: true
      },
      acp_agent:
        Jido.Harness.ACPAgentSpec.native("omp", ["acp"], %{
          maturity: :experimental,
          attachment_link_name: :uri,
          capabilities: %{
            load_session: true,
            multimodal: true,
            dynamic_model: true,
            dynamic_configuration: true
          },
          configuration_options: [:model, :reasoning_effort],
          turn_options: [:attachments, :content]
        }),
      normalized_options: [:model, :provider_session_id, :mcp_config, :attachments, :reasoning_effort],
      normalized_values: %{reasoning_effort: [nil, :off, :auto, :low, :medium, :high, :xhigh, :max]},
      install: %{script: @install_url}
    }
  end

  @impl Jido.Harness.Adapter
  def status(config),
    do: Helpers.status(:omp, spec().executable, @auth_envs, config, capabilities: spec().capabilities)

  @impl Jido.Harness.Adapter
  def install(_config, options), do: Helpers.install_script(:omp, @install_url, options)

  @impl Jido.Harness.Adapter
  def acp_configuration(changes) do
    case Map.pop(changes, :reasoning_effort) do
      {nil, changes} -> changes
      {effort, changes} -> Map.put(changes, :thinking, effort)
    end
  end
end
