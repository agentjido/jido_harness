defmodule Jido.Harness.Adapters.Zai do
  @moduledoc "Z.AI provider profile using the Claude Code ACP adapter."
  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{
    AdapterSpec,
    Adapters.Helpers,
    Capabilities,
    Error,
    ProviderStatus
  }

  @base_url "https://api.z.ai/api/anthropic"
  @provider_options [:base_url, :api_timeout_ms]

  @impl true
  def spec do
    %AdapterSpec{
      provider: :zai,
      name: "Z.AI",
      executable: "claude",
      docs_url: "https://docs.z.ai/devpack/tool/claude",
      capabilities: %Capabilities{
        streaming?: true,
        tool_calls?: true,
        tool_results?: true,
        thinking?: true,
        resume?: true,
        usage?: true
      },
      acp_agent:
        Jido.Harness.ACPAgentSpec.adapter(
          "claude-agent-acp",
          "@agentclientprotocol/claude-agent-acp@0.70.0",
          %{
            maturity: :experimental,
            capabilities: %{load_session: true, multimodal: true, dynamic_model: true, usage: true},
            turn_options: [:attachments, :content],
            session_provider_options: :adapter,
            configuration_options: [:model]
          }
        ),
      normalized_options: [
        :model,
        :provider_session_id,
        :mcp_config,
        :attachments
      ],
      provider_options: @provider_options,
      install: %{npm: "@anthropic-ai/claude-code"}
    }
  end

  @impl true
  def status(config) do
    with {:ok, status} <-
           Helpers.status(:zai, spec().executable, ["ZAI_API_KEY"], config, capabilities: spec().capabilities) do
      status =
        if configured_credentials?(config) do
          ProviderStatus.finalize(%{status | authenticated: true})
        else
          status
        end

      {:ok, status}
    end
  end

  @impl true
  def install(_config, options), do: Helpers.install_npm(:zai, "@anthropic-ai/claude-code", options)

  @impl true
  def acp_env(request, config) do
    options = Helpers.provider_options(request.provider_options, @provider_options)
    resolve_env(request, config, options)
  end

  @doc false
  def resolve_env(request, config, options) when is_struct(request) do
    config_env = config |> config_value(:env, %{}) |> stringify_env()
    request_env = stringify_env(request.env)

    base_url =
      request_env["ANTHROPIC_BASE_URL"] || options[:base_url] || config_value(config, :base_url) ||
        config_env["ANTHROPIC_BASE_URL"] || @base_url

    timeout =
      request_env["API_TIMEOUT_MS"] || options[:api_timeout_ms] || config_value(config, :api_timeout_ms) ||
        config_env["API_TIMEOUT_MS"] ||
        Map.get(request, :runtime_timeout_ms, Map.get(request, :turn_runtime_timeout_ms, :infinity))

    token =
      resolve_token(request_env, config, config_env, request)

    with {:ok, base_url} <- validate_base_url(base_url),
         {:ok, timeout} <- normalize_timeout(timeout),
         {:ok, token} <- validate_optional_token(token) do
      env =
        config_env
        |> Map.merge(request_env)
        |> Map.put("ZAI_API_KEY", nil)
        |> Map.put("ANTHROPIC_BASE_URL", base_url)
        |> Map.put("API_TIMEOUT_MS", Integer.to_string(timeout))
        |> Map.put("ANTHROPIC_API_KEY", nil)
        |> Map.put("CLAUDE_AGENT_OAUTH_TOKEN", nil)
        |> Map.put("ANTHROPIC_AUTH_TOKEN", token)

      {:ok, env}
    end
  end

  defp validate_base_url(value) when is_binary(value) do
    if String.trim(value) == "" do
      validate_base_url(:invalid)
    else
      {:ok, value}
    end
  end

  defp validate_base_url(_value),
    do: {:error, Error.validation("Z.AI base_url must be a non-empty string", provider: :zai)}

  defp normalize_timeout(:infinity), do: {:ok, Helpers.finite_timeout(:infinity)}
  defp normalize_timeout(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp normalize_timeout(value) when is_binary(value) do
    case Integer.parse(value) do
      {timeout, ""} when timeout > 0 -> {:ok, timeout}
      _ -> normalize_timeout(:invalid)
    end
  end

  defp normalize_timeout(_value),
    do: {:error, Error.validation("Z.AI api_timeout_ms must be :infinity or a positive integer", provider: :zai)}

  defp validate_optional_token(value) when value in [nil, false], do: {:ok, nil}
  defp validate_optional_token(value) when is_binary(value) and value != "", do: {:ok, value}

  defp validate_optional_token(_value),
    do: {:error, Error.validation("Z.AI API key must be a non-empty string", provider: :zai)}

  defp configured_credentials?(config) do
    env = config |> config_value(:env, %{}) |> stringify_env()

    present?(config_value(config, :api_key)) or present?(env["ZAI_API_KEY"]) or
      present?(env["ANTHROPIC_AUTH_TOKEN"])
  end

  defp resolve_token(request_env, config, config_env, request) do
    with :missing <- first_present(request_env, ["ANTHROPIC_AUTH_TOKEN", "ZAI_API_KEY"]),
         :missing <- config_present(config, :api_key),
         :missing <- first_present(config_env, ["ANTHROPIC_AUTH_TOKEN", "ZAI_API_KEY"]) do
      ambient_token(request)
    else
      {:present, value} -> value
    end
  end

  defp first_present(env, keys) do
    Enum.find_value(keys, :missing, fn key ->
      if Map.has_key?(env, key), do: {:present, Map.get(env, key)}
    end)
  end

  defp config_present(config, key) do
    cond do
      Map.has_key?(config, key) -> {:present, Map.get(config, key)}
      Map.has_key?(config, to_string(key)) -> {:present, Map.get(config, to_string(key))}
      true -> :missing
    end
  end

  defp ambient_token(%{env_mode: :overlay}), do: System.get_env("ZAI_API_KEY")
  defp ambient_token(_request), do: nil
  defp stringify_env(env) when is_map(env), do: Map.new(env, fn {key, value} -> {to_string(key), value} end)
  defp stringify_env(_env), do: %{}
  defp config_value(config, key, default \\ nil), do: Map.get(config, key, Map.get(config, to_string(key), default))
  defp present?(value), do: is_binary(value) and value != ""
end
