defmodule Jido.Harness.Adapters.Kimi do
  @moduledoc "Kimi Code provider profile using its native ACP mode."
  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{AdapterSpec, Adapters.Helpers, Capabilities, Error}

  @impl true
  def spec do
    %AdapterSpec{
      provider: :kimi,
      name: "Kimi Code",
      executable: "kimi",
      docs_url: "https://www.kimi.com/code/docs/en/",
      capabilities: %Capabilities{
        streaming?: true,
        tool_calls?: true,
        tool_results?: true,
        resume?: true,
        native_cancel?: true
      },
      acp_agent:
        Jido.Harness.ACPAgentSpec.native("kimi", ["acp"], %{
          env: %{"KIMI_CODE_NO_AUTO_UPDATE" => "1"},
          capabilities: %{load_session: true, multimodal: true},
          session_options: [:provider_session_id, :mcp_config, :model, :reasoning_effort],
          turn_options: [:attachments, :content]
        }),
      normalized_options: [:model, :provider_session_id, :mcp_config, :attachments, :reasoning_effort],
      normalized_values: %{reasoning_effort: [nil, :low, :medium, :high]},
      install: %{npm: "@moonshot-ai/kimi-code"}
    }
  end

  @impl true
  def status(config),
    do: Helpers.status(:kimi, spec().executable, ["KIMI_MODEL_API_KEY"], config, capabilities: spec().capabilities)

  @impl true
  def install(_config, options), do: Helpers.install_npm(:kimi, "@moonshot-ai/kimi-code", options)

  @doc false
  def prepare_request(%{env: _env} = request, config \\ %{}) do
    request_env = request.env
    config_env = configured_env(config)
    request = %{request | env: Map.merge(config_env, request_env)}
    env_name = env_value(request_env, config_env, request.env_mode, "KIMI_MODEL_NAME")
    requested_name = request.model || env_name
    api_key = env_value(request_env, config_env, request.env_mode, "KIMI_MODEL_API_KEY")

    cond do
      present?(env_name) and not present?(api_key) ->
        {:error,
         Error.validation("KIMI_MODEL_NAME requires KIMI_MODEL_API_KEY",
           provider: :kimi,
           details: %{field: :env}
         )}

      present?(api_key) and present?(requested_name) ->
        {:ok, %{request | env: managed_env(request, requested_name, api_key)}}

      present?(api_key) ->
        {:error,
         Error.validation("KIMI_MODEL_API_KEY requires a model or KIMI_MODEL_NAME",
           provider: :kimi,
           details: %{field: :env}
         )}

      true ->
        {:ok, %{request | env: managed_env(request, nil, nil)}}
    end
  end

  @impl true
  def acp_env(request, config) do
    with {:ok, prepared} <- prepare_request(request, config) do
      {:ok, prepared.env}
    end
  end

  defp managed_env(request, model_name, api_key) do
    request.env
    |> Map.put("KIMI_CODE_NO_AUTO_UPDATE", "1")
    |> Map.put("KIMI_DISABLE_CRON", "1")
    |> Map.put("KIMI_CODE_BACKGROUND_KEEP_ALIVE_ON_EXIT", "0")
    |> maybe_put("KIMI_MODEL_NAME", model_name)
    |> maybe_put("KIMI_MODEL_API_KEY", api_key)
    |> maybe_put("KIMI_MODEL_THINKING_EFFORT", request.reasoning_effort)
  end

  defp env_value(request_env, config_env, mode, name) do
    cond do
      Map.has_key?(request_env, name) -> Map.get(request_env, name)
      Map.has_key?(config_env, name) -> Map.get(config_env, name)
      mode == :overlay -> System.get_env(name)
      true -> nil
    end
  end

  defp configured_env(config) do
    case Map.get(config, :env, Map.get(config, "env", %{})) do
      env when is_map(env) or is_list(env) -> Map.new(env)
      _other -> %{}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, to_string(value))
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
