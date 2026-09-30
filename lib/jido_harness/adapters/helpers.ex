defmodule Jido.Harness.Adapters.Helpers do
  @moduledoc false

  alias Jido.Harness.{Capabilities, Error, ProcessInfo, ProcessManager, ProviderStatus}

  @maximum_timeout_ms 2_147_483_647

  @doc "Keeps supported provider options and converts known string keys to atoms."
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

  @doc "Maps an infinite timeout to the largest supported process timer value."
  def finite_timeout(:infinity), do: @maximum_timeout_ms
  def finite_timeout(timeout) when is_integer(timeout), do: timeout

  @doc "Probes CLI installation and compatibility without sending an agent prompt."
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
          with {:ok, output} <- probe(path, version_argv, options),
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

  @doc "Installs an npm package or returns its executable and argv recipe."
  def install_npm(provider, package, options, npm_args \\ []) do
    recipe = %{executable: "npm", argv: ["install", "-g"] ++ npm_args ++ [package], package: package}

    if Keyword.get(options, :dry_run, false) do
      {:ok, %{provider: provider, status: :dry_run, recipe: recipe}}
    else
      with {:ok, output} <-
             run_install_process(
               provider,
               Map.take(recipe, [:executable, :argv]),
               Keyword.get(options, :timeout, 300_000)
             ) do
        {:ok, %{provider: provider, status: :installed, output: output}}
      end
    end
  end

  @doc "Downloads and runs an installer, or returns its recipe in dry-run mode."
  def install_script(provider, url, options) do
    recipe = %{
      source: url,
      steps: [
        %{executable: "curl", argv: ["-fsS", url, "-o", "<temporary-file>"]},
        %{executable: "bash", argv: ["<temporary-file>"]}
      ]
    }

    if Keyword.get(options, :dry_run, false) do
      {:ok, %{provider: provider, status: :dry_run, recipe: recipe}}
    else
      run_script_installer(provider, url, options)
    end
  end

  defp run_script_installer(provider, url, options) do
    directory =
      Path.join(System.tmp_dir!(), "jido-harness-install-#{System.unique_integer([:positive, :monotonic])}")

    script = Path.join(directory, "install.sh")
    timeout = Keyword.get(options, :timeout, 300_000)

    with :ok <- File.mkdir(directory) do
      try do
        with {:ok, download_output} <-
               run_install_process(provider, %{executable: "curl", argv: ["-fsS", url, "-o", script]}, timeout),
             {:ok, install_output} <-
               run_install_process(provider, %{executable: "bash", argv: [script]}, timeout) do
          {:ok, %{provider: provider, status: :installed, output: download_output <> install_output}}
        end
      after
        File.rm_rf(directory)
      end
    else
      {:error, reason} ->
        {:error,
         Error.new(:process, "could not create provider installation directory",
           provider: provider,
           cause: reason
         )}
    end
  end

  defp run_install_process(provider, spec, timeout) do
    case ProcessManager.start_process(spec) do
      {:ok, id} ->
        try do
          with {:ok, info} <- ProcessManager.await_process(id, timeout),
               {:ok, events} <- ProcessManager.replay_process(id, cursor: 0, limit: 10_000) do
            output =
              events
              |> Enum.filter(&(&1.type in [:stdout, :stderr]))
              |> Enum.map_join("", &to_string(&1.data))

            install_process_result(provider, info, output)
          end
        after
          cleanup_install_process(id)
        end

      error ->
        error
    end
  end

  defp install_process_result(_provider, %ProcessInfo{state: :exited}, output), do: {:ok, output}

  defp install_process_result(provider, %ProcessInfo{} = info, output) do
    {:error,
     Error.new(:process, "provider installation failed",
       provider: provider,
       details: %{state: info.state, status: info.exit_status, output: output}
     )}
  end

  defp cleanup_install_process(id) do
    case ProcessManager.prune_process(id) do
      :ok ->
        :ok

      {:error, :running} ->
        ProcessManager.cancel_process(id)

      _error ->
        :ok
    end
  end

  defp probe(path, argv, options) do
    spec = %{
      executable: path,
      argv: argv,
      runtime_timeout_ms: 15_000,
      env: Keyword.get(options, :probe_env, %{}),
      env_mode: Keyword.get(options, :probe_env_mode, :overlay)
    }

    with {:ok, id} <- ProcessManager.start_process(spec),
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
         {:ok, output} <- probe(path, argv, options) do
      if String.contains?(output, pattern), do: :ok, else: {:error, {:incompatible_cli, pattern}}
    else
      nil -> :ok
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_compatibility_probe}
    end
  end

  defp present_env?(name), do: System.get_env(name) not in [nil, ""]
  defp first_line(output), do: output |> String.split("\n", parts: 2) |> List.first() |> String.trim()
end
