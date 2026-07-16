defmodule Jido.Harness.Adapters.Codex do
  @moduledoc "Codex SDK-backed harness adapter."
  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{AdapterSpec, Adapters.Helpers, Adapters.SDKMapper, Capabilities, Error, RunRequest}

  @provider_options [
    :cli_path,
    :transport,
    :resume_last,
    :codex_options,
    :thread_options,
    :turn_options,
    :skip_git_repo_check,
    :web_search_enabled,
    :network_access_enabled,
    :model_reasoning_summary
  ]

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
        file_changes?: true
      },
      normalized_options: [
        :model,
        :session_id,
        :max_turns,
        :system_prompt,
        :add_dirs,
        :approval_mode,
        :sandbox_mode,
        :attachments,
        :reasoning_effort
      ],
      provider_options: @provider_options,
      install: %{npm: "@openai/codex"}
    }
  end

  @impl true
  def run(%RunRequest{} = request, context) do
    provider = Helpers.provider_options(request.provider_options, @provider_options)

    codex_options =
      Map.get(context.config, :codex_options, %{})
      |> Map.merge(provider[:codex_options] || %{})
      |> put_if_present(:codex_path_override, provider[:cli_path] || Map.get(context.config, :cli_path))
      |> put_if_present(:reasoning_effort, request.reasoning_effort)
      |> compact()

    normalized_thread_options =
      %{
        working_directory: request.cwd,
        transport: provider[:transport],
        model: request.model,
        developer_instructions: request.system_prompt,
        additional_directories: request.add_dirs || [],
        ask_for_approval: approval(request.approval_mode),
        sandbox: sandbox(request.sandbox_mode),
        stream_idle_timeout_ms: finite(request.idle_timeout_ms),
        skip_git_repo_check: provider[:skip_git_repo_check] || false,
        web_search_enabled: provider[:web_search_enabled] || false,
        network_access_enabled: provider[:network_access_enabled],
        model_reasoning_summary: provider[:model_reasoning_summary],
        shell_environment_policy: env_policy(request.env),
        model_verbosity: request.reasoning_effort
      }
      |> compact()

    thread_options = Map.merge(provider[:thread_options] || %{}, normalized_thread_options)

    normalized_turn_options =
      %{max_turns: request.max_turns, timeout_ms: Helpers.sdk_timeout(request.runtime_timeout_ms), env: request.env}
      |> compact()

    turn_options = Map.merge(provider[:turn_options] || %{}, normalized_turn_options)

    sdk = Map.get(context.config, :sdk_module, Codex)

    thread_module = Map.get(context.config, :thread_module, Codex.Thread)
    streaming_module = Map.get(context.config, :streaming_module, Codex.RunResultStreaming)

    with {:ok, attachments} <- stage_attachments(request.attachments),
         thread_options <- Map.put(thread_options, :attachments, attachments),
         {:ok, options} <- Codex.Options.new(codex_options),
         {:ok, thread} <- thread(request, provider, sdk, options, thread_options),
         {:ok, run_result} <- thread_module.run_streamed(thread, request.prompt, turn_options) do
      {:ok, streaming_module.events(run_result) |> Stream.flat_map(&SDKMapper.codex/1)}
    else
      {:error, reason} -> {:error, Error.execution("Codex SDK could not start", provider: :codex, cause: reason)}
    end
  rescue
    exception ->
      {:error,
       Error.validation("invalid Codex options", provider: :codex, details: %{message: Exception.message(exception)})}
  end

  @impl true
  def status(config),
    do:
      Helpers.status(:codex, spec().executable, ["OPENAI_API_KEY", "CODEX_API_KEY"], config,
        cli_path_env: "CODEX_PATH",
        capabilities: spec().capabilities
      )

  @impl true
  def install(_config, options), do: Helpers.install_npm(:codex, "@openai/codex", options)

  defp thread(_request, %{resume_last: true}, sdk, options, thread_options),
    do: sdk.resume_thread(:last, options, thread_options)

  defp thread(%{session_id: session_id}, _provider, sdk, options, thread_options) when is_binary(session_id),
    do: sdk.resume_thread(session_id, options, thread_options)

  defp thread(_request, _provider, sdk, options, thread_options), do: sdk.start_thread(options, thread_options)

  defp approval(:default), do: nil
  defp approval(:prompt), do: :on_request
  defp approval(:auto_edit), do: :on_failure
  defp approval(:auto_approve), do: :never
  defp sandbox(:default), do: :default
  defp sandbox(:read_only), do: :read_only
  defp sandbox(:workspace_write), do: :workspace_write
  defp sandbox(:unrestricted), do: :danger_full_access
  defp finite(:infinity), do: nil
  defp finite(value), do: value

  defp compact(map),
    do: Map.new(map, fn entry -> entry end) |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp env_policy(env) when map_size(env) == 0, do: nil
  defp env_policy(env), do: %{"set" => env}

  defp stage_attachments(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, attachments} ->
      case Codex.Files.stage(path) do
        {:ok, attachment} -> {:cont, {:ok, attachments ++ [attachment]}}
        {:error, reason} -> {:halt, {:error, {:attachment, path, reason}}}
      end
    end)
  end
end
