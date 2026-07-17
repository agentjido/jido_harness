defmodule Jido.Harness.Adapters.Zai do
  @moduledoc "Z.AI GLM Coding Plan adapter using its officially supported Claude Code integration."
  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{
    AdapterSpec,
    Adapters.Claude,
    Adapters.Helpers,
    Capabilities,
    Error,
    ProviderStatus,
    RunRequest
  }

  @base_url "https://api.z.ai/api/anthropic"
  @provider_options [
    :cli_path,
    :fallback_model,
    :max_budget_usd,
    :fork_session,
    :settings,
    :betas,
    :base_url,
    :api_timeout_ms
  ]

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
      default_session_transport: :stream_json_resume,
      session_transports: [Jido.Harness.SessionTransportSpec.managed(:stream_json_resume)],
      normalized_options: [
        :model,
        :provider_session_id,
        :max_turns,
        :system_prompt,
        :allowed_tools,
        :disallowed_tools,
        :add_dirs,
        :mcp_config,
        :approval_mode,
        :sandbox_mode,
        :reasoning_effort
      ],
      provider_options: @provider_options,
      install: %{npm: "@anthropic-ai/claude-code"}
    }
  end

  @impl true
  def run(%RunRequest{} = request, context) do
    options = Helpers.provider_options(request.provider_options, @provider_options)

    with {:ok, env} <- resolve_env(request, context.config, options) do
      request = %{request | env: env}
      claude_config = context.config |> Map.put(:env, %{}) |> Map.delete("env")
      context = %{context | config: claude_config}

      case Claude.run(request, context) do
        {:ok, stream} ->
          {:ok, Stream.map(stream, &remap_event/1)}

        {:error, %Error{} = error} ->
          {:error, %{error | provider: :zai}}
      end
    end
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
      request_env["ANTHROPIC_AUTH_TOKEN"] || request_env["ZAI_API_KEY"] || config_value(config, :api_key) ||
        config_env["ANTHROPIC_AUTH_TOKEN"] || config_env["ZAI_API_KEY"] || System.get_env("ZAI_API_KEY")

    with {:ok, base_url} <- validate_base_url(base_url),
         {:ok, timeout} <- normalize_timeout(timeout),
         {:ok, token} <- validate_optional_token(token) do
      env =
        config_env
        |> Map.merge(request_env)
        |> Map.delete("ZAI_API_KEY")
        |> Map.put("ANTHROPIC_BASE_URL", base_url)
        |> Map.put("API_TIMEOUT_MS", Integer.to_string(timeout))
        |> Map.put("ANTHROPIC_API_KEY", nil)
        |> Map.put("CLAUDE_AGENT_OAUTH_TOKEN", nil)
        |> maybe_put("ANTHROPIC_AUTH_TOKEN", token)

      {:ok, env}
    end
  end

  defp remap_event(%Jido.Harness.Event{} = event), do: %{event | provider: :zai}

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

  defp validate_optional_token(nil), do: {:ok, nil}
  defp validate_optional_token(value) when is_binary(value) and value != "", do: {:ok, value}

  defp validate_optional_token(_value),
    do: {:error, Error.validation("Z.AI API key must be a non-empty string", provider: :zai)}

  defp configured_credentials?(config) do
    env = config |> config_value(:env, %{}) |> stringify_env()

    present?(config_value(config, :api_key)) or present?(env["ZAI_API_KEY"]) or
      present?(env["ANTHROPIC_AUTH_TOKEN"])
  end

  defp stringify_env(env) when is_map(env), do: Map.new(env, fn {key, value} -> {to_string(key), value} end)
  defp stringify_env(_env), do: %{}
  defp config_value(config, key, default \\ nil), do: Map.get(config, key, Map.get(config, to_string(key), default))
  defp present?(value), do: is_binary(value) and value != ""
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
