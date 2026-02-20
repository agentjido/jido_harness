defmodule Jido.Harness.Exec.Stream do
  @moduledoc """
  Run provider commands in stream-json mode and summarize results.
  """

  alias Jido.Harness.Exec.{Error, ProviderRuntime, Result}

  @doc """
  Runs a provider command via `Jido.Shell.StreamJson` and returns summarized stream results.
  """
  @spec run_stream(atom(), String.t(), String.t(), String.t() | keyword()) ::
          {:ok, map()} | {:error, term()}
  def run_stream(provider, session_id, cwd, command)
      when is_atom(provider) and is_binary(session_id) and is_binary(cwd) and is_binary(command) do
    run_stream(provider, session_id, cwd, command: command)
  end

  def run_stream(provider, session_id, cwd, opts)
      when is_atom(provider) and is_binary(session_id) and is_binary(cwd) and is_list(opts) do
    command = Keyword.get(opts, :command)

    if not is_binary(command) or String.trim(command) == "" do
      {:error, Error.invalid("run_stream requires :command", %{field: :command})}
    else
      shell_agent_mod = Keyword.get(opts, :shell_agent_mod, Jido.Shell.Agent)
      session_server_mod = Keyword.get(opts, :shell_session_server_mod, Jido.Shell.ShellSessionServer)
      timeout = Keyword.get(opts, :timeout, 300_000)
      heartbeat_interval_ms = Keyword.get(opts, :heartbeat_interval_ms, 5_000)
      on_mode = Keyword.get(opts, :on_mode)
      on_event = Keyword.get(opts, :on_event)
      on_raw_line = Keyword.get(opts, :on_raw_line)
      on_heartbeat = Keyword.get(opts, :on_heartbeat)

      with {:ok, contract} <- ProviderRuntime.provider_runtime_contract(provider),
           {:ok, output, events} <-
             Jido.Shell.StreamJson.run(
               shell_agent_mod,
               session_server_mod,
               session_id,
               cwd,
               command,
               timeout: timeout,
               heartbeat_interval_ms: heartbeat_interval_ms,
               on_mode: on_mode,
               on_event: on_event,
               on_raw_line: on_raw_line,
               on_heartbeat: on_heartbeat
             ) do
        success = Result.stream_success?(provider, events, contract.success_markers)
        result_text = Result.extract_result_text(events, output)

        {:ok,
         %{
           provider: provider,
           command: command,
           output: output,
           events: events,
           event_count: length(events),
           success?: success,
           result_text: result_text
         }}
      else
        {:error, reason} ->
          {:error, Error.execution("Stream command failed", %{provider: provider, reason: reason})}
      end
    end
  end
end
