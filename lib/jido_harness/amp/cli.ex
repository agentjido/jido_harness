defmodule Jido.Harness.Amp.CLI do
  @moduledoc false

  alias Jido.Harness.{Error, ProcessInfo, Signal}
  alias Jido.Harness.Amp.CLIConfig
  alias Jido.Harness.Process, as: ManagedProcess

  @type result :: {:ok, String.t()} | {:error, Error.t()}
  @callback run([String.t()], CLIConfig.t()) :: result()

  @spec run([String.t()], CLIConfig.t()) :: result()
  def run(argv, %CLIConfig{} = config) do
    case Application.get_env(:jido_harness, :amp_cli_runner, __MODULE__) do
      __MODULE__ -> execute(argv, config)
      runner when is_atom(runner) -> runner.run(argv, config)
    end
  end

  defp execute(argv, config) do
    read_budget = config.max_output_bytes * 4 + 1_048_576

    spec = %{
      executable: config.cli_path,
      argv: argv,
      cwd: config.cwd,
      env: CLIConfig.command_env(),
      env_mode: :overlay,
      stdin: false,
      runtime_timeout_ms: config.timeout_ms,
      metadata: %{provider: :amp, purpose: :orb_control},
      retention: %{
        memory_bytes: min(read_budget, 8 * 1_024 * 1_024),
        segment_bytes: min(read_budget, 8 * 1_024 * 1_024),
        disk_limit_bytes: read_budget
      }
    }

    case ManagedProcess.start(spec) do
      {:ok, process_id} ->
        try do
          collect(process_id, config, read_budget)
        after
          cleanup(process_id)
        end

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp collect(process_id, config, read_budget) do
    with {:ok, info} <- ManagedProcess.await(process_id, config.timeout_ms + 12_000),
         {:ok, page} <-
           ManagedProcess.replay_page(process_id,
             cursor: 0,
             limit: 10_000,
             max_bytes: read_budget
           ),
         :ok <- complete_output(page, info),
         {stdout, stderr} = output(page.records),
         :ok <- output_size(stdout, stderr, config.max_output_bytes) do
      command_result(info, stdout, stderr)
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, Error.new(:process, "Amp CLI control command failed", provider: :amp, cause: reason)}
    end
  end

  defp complete_output(%{gaps: [], next_cursor: cursor}, %ProcessInfo{output_cursor: cursor}), do: :ok

  defp complete_output(page, info) do
    {:error,
     Error.new(:process, "Amp CLI output exceeded the control response limit",
       provider: :amp,
       details: %{next_cursor: page.next_cursor, output_cursor: info.output_cursor, gaps: page.gaps}
     )}
  end

  defp output(records) do
    {stdout, stderr} =
      Enum.reduce(records, {[], []}, fn signal, {stdout, stderr} ->
        data = get_in(signal.data, ["payload", "data"])

        case Signal.kind(signal) do
          :process_stdout -> {[binary(data) | stdout], stderr}
          :process_stderr -> {stdout, [binary(data) | stderr]}
          _other -> {stdout, stderr}
        end
      end)

    {stdout |> Enum.reverse() |> IO.iodata_to_binary(), stderr |> Enum.reverse() |> IO.iodata_to_binary()}
  end

  defp output_size(stdout, stderr, limit) when byte_size(stdout) + byte_size(stderr) <= limit, do: :ok

  defp output_size(stdout, stderr, limit) do
    {:error,
     Error.new(:process, "Amp CLI output exceeded the configured byte limit",
       provider: :amp,
       details: %{limit: limit, bytes: byte_size(stdout) + byte_size(stderr)}
     )}
  end

  defp command_result(%ProcessInfo{state: :exited}, stdout, _stderr), do: {:ok, stdout}

  defp command_result(%ProcessInfo{state: :timed_out} = info, stdout, stderr) do
    {:error,
     Error.new(:timeout, "Amp CLI control command timed out",
       provider: :amp,
       details: command_details(info, stdout, stderr)
     )}
  end

  defp command_result(%ProcessInfo{} = info, stdout, stderr) do
    {:error,
     Error.new(:provider, "Amp CLI control command failed",
       provider: :amp,
       details: command_details(info, stdout, stderr)
     )}
  end

  defp command_details(info, stdout, stderr) do
    %{
      state: info.state,
      exit_status: info.exit_status,
      stdout: tail(stdout),
      stderr: tail(stderr)
    }
  end

  defp tail(value) when byte_size(value) <= 8_192, do: value
  defp tail(value), do: binary_part(value, byte_size(value) - 8_192, 8_192)
  defp binary(value) when is_binary(value), do: value
  defp binary(value), do: inspect(value)

  defp cleanup(process_id) do
    case ManagedProcess.prune(process_id) do
      :ok -> :ok
      {:error, :running} -> ManagedProcess.cancel(process_id)
      _other -> :ok
    end
  end
end
