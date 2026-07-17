defmodule Jido.Harness.Adapters.Helpers do
  @moduledoc false

  alias Jido.Harness.{Capabilities, Error, Event, ProcessInfo, ProcessManager, ProviderStatus}

  @maximum_timeout_ms 2_147_483_647

  def event(provider, type, provider_session_id, payload, raw \\ nil) do
    Event.new!(%{
      type: type,
      provider: provider,
      provider_session_id: provider_session_id,
      payload: stringify_keys(payload),
      raw: raw
    })
  end

  def provider_options(options, allowed) when is_map(options) do
    strings = Map.new(allowed, &{Atom.to_string(&1), &1})

    Enum.reduce(options, %{}, fn
      {key, value}, acc when is_atom(key) ->
        if(key in allowed, do: Map.put(acc, key, value), else: acc)

      {key, value}, acc when is_binary(key) ->
        case Map.fetch(strings, key) do
          {:ok, atom} -> Map.put(acc, atom, value)
          :error -> acc
        end
    end)
  end

  def finite_timeout(:infinity), do: @maximum_timeout_ms
  def finite_timeout(timeout) when is_integer(timeout), do: timeout

  def merge_env(request, config, additions \\ %{}) do
    config
    |> Map.get(:env, Map.get(config, "env", %{}))
    |> normalize_env()
    |> Map.merge(request.env)
    |> Map.merge(additions)
  end

  defp normalize_env(env) when is_map(env) or is_list(env), do: Map.new(env)
  defp normalize_env(_env), do: %{}

  def cli_path(config, default) do
    Map.get(config, :cli_path) || Map.get(config, "cli_path") || default
  end

  def status(provider, default_executable, auth_env, config, options \\ []) do
    configured = Map.get(config, :cli_path) || Map.get(config, "cli_path")
    env_path = options |> Keyword.get(:cli_path_env) |> then(&if(&1, do: System.get_env(&1)))
    executable = configured || env_path || default_executable
    version_argv = Keyword.get(options, :version_argv, ["--version"])
    authenticated = if Enum.any?(auth_env, &present_env?/1), do: true, else: :unknown
    capabilities = Keyword.get(options, :capabilities, %Capabilities{})

    status =
      case Jido.Harness.ProcessSpec.resolve_executable(executable) do
        {:ok, path} ->
          with {:ok, output} <- probe(path, version_argv),
               :ok <- compatibility_probe(path, options) do
            %ProviderStatus{
              provider: provider,
              installed: true,
              compatible: true,
              authenticated: authenticated,
              capabilities: capabilities,
              version: first_line(output),
              executable: path
            }
          else
            {:error, reason} ->
              %ProviderStatus{
                provider: provider,
                installed: true,
                compatible: false,
                authenticated: authenticated,
                capabilities: capabilities,
                executable: path,
                error: reason
              }
          end

        {:error, reason} ->
          %ProviderStatus{
            provider: provider,
            installed: false,
            compatible: false,
            authenticated: authenticated,
            capabilities: capabilities,
            error: reason
          }
      end

    {:ok, ProviderStatus.finalize(status)}
  end

  def install_npm(provider, package, options, npm_args \\ []) do
    recipe = %{executable: "npm", argv: ["install", "-g"] ++ npm_args ++ [package], package: package}

    if Keyword.get(options, :dry_run, false) do
      {:ok, %{provider: provider, status: :dry_run, recipe: recipe}}
    else
      with {:ok, id} <- ProcessManager.start_process(Map.take(recipe, [:executable, :argv])),
           {:ok, %ProcessInfo{state: :exited}} <-
             ProcessManager.await_process(id, Keyword.get(options, :timeout, 300_000)),
           {:ok, events} <- ProcessManager.replay_process(id, cursor: 0, limit: 10_000) do
        output = events |> Enum.filter(&(&1.type in [:stdout, :stderr])) |> Enum.map_join("", &to_string(&1.data))
        _ = ProcessManager.prune_process(id)
        {:ok, %{provider: provider, status: :installed, output: output}}
      else
        {:ok, %ProcessInfo{} = info} ->
          {:error,
           Error.new(:process, "provider installation failed",
             provider: provider,
             details: %{state: info.state, status: info.exit_status}
           )}

        error ->
          error
      end
    end
  end

  def cancel_cli_run(run_id) do
    ProcessManager.list_processes(states: [:starting, :running, :stopping])
    |> Enum.filter(&(Map.get(&1.metadata, :run_id) == run_id or Map.get(&1.metadata, "run_id") == run_id))
    |> Enum.each(&ProcessManager.cancel_process(&1.process_id))

    :ok
  end

  defp probe(path, argv) do
    with {:ok, id} <- ProcessManager.start_process(%{executable: path, argv: argv, runtime_timeout_ms: 15_000}),
         {:ok, info} <- ProcessManager.await_process(id, 20_000),
         {:ok, events} <- ProcessManager.replay_process(id, cursor: 0, limit: 1_000) do
      output = events |> Enum.filter(&(&1.type in [:stdout, :stderr])) |> Enum.map_join("", &to_string(&1.data))
      _ = ProcessManager.prune_process(id)
      if info.state == :exited, do: {:ok, output}, else: {:error, info.error || {:exit_status, info.exit_status}}
    end
  end

  defp compatibility_probe(path, options) do
    with argv when is_list(argv) <- Keyword.get(options, :compatibility_argv),
         pattern when is_binary(pattern) <- Keyword.get(options, :compatibility_pattern),
         {:ok, output} <- probe(path, argv) do
      if String.contains?(output, pattern), do: :ok, else: {:error, {:incompatible_cli, pattern}}
    else
      nil -> :ok
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_compatibility_probe}
    end
  end

  defp present_env?(name), do: System.get_env(name) not in [nil, ""]
  defp first_line(output), do: output |> String.split("\n", parts: 2) |> List.first() |> String.trim()

  def stringify_keys(%_{} = struct), do: struct |> Map.from_struct() |> stringify_keys()

  def stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)

  def stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  def stringify_keys(value), do: value
end
