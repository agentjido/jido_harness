defmodule Jido.Harness.Plugin.Watcher do
  @moduledoc false

  alias Jido.Harness.Plugin.Runtime
  alias Jido.Harness.Signal

  def child_spec(options) do
    %{
      id: {__MODULE__, options.kind, options.id},
      start: {Task, :start_link, [fn -> run(options) end]},
      restart: :temporary
    }
  end

  def run(options) do
    case stream(options.kind, options.id, options.cursor) do
      {:ok, stream} ->
        Enum.each(stream, &deliver(options, &1))
        maybe_mark_terminal(options)

      {:error, _reason} ->
        Process.sleep(100)

        case Runtime.owner(options.runtime, options.kind, options.id) do
          {:ok, resource} -> run(%{options | cursor: resource.cursor})
          {:error, _reason} -> :ok
        end
    end
  end

  defp deliver(options, %Jido.Signal{} = signal) do
    cursor = Signal.sequence(signal)
    signal = enrich(signal, options)

    if Enum.any?(options.signals, &Jido.Agent.Data.matches?(signal.type, &1)) do
      Jido.AgentServer.cast(options.agent_server, signal)
    end

    Runtime.cursor(options.runtime, options.kind, options.id, cursor)
  end

  defp enrich(%Jido.Signal{} = signal, options) do
    plugin_metadata = %{
      "connection" => options.connection,
      "workspace" => options.workspace,
      "command_id" => options.command_id,
      "resource_kind" => Atom.to_string(options.kind),
      "resource_id" => options.id,
      "signals" => options.signals
    }

    metadata = signal.data |> Map.get("metadata", %{}) |> Map.put("jido_harness_plugin", plugin_metadata)
    %{signal | data: Map.put(signal.data, "metadata", metadata)}
  end

  defp stream(:run, id, cursor), do: Jido.Harness.Run.stream(id, cursor: cursor)
  defp stream(:session, id, cursor), do: Jido.Harness.Session.stream(id, cursor: cursor)

  defp maybe_mark_terminal(%{kind: :run} = options) do
    case Jido.Harness.Run.info(options.id) do
      {:ok, info} -> if Jido.Harness.RunInfo.terminal?(info), do: Runtime.terminal(options.runtime, :run, options.id)
      _error -> :ok
    end
  end

  defp maybe_mark_terminal(%{kind: :session} = options) do
    case Jido.Harness.Session.info(options.id) do
      {:ok, info} ->
        if Jido.Harness.SessionInfo.terminal?(info), do: Runtime.terminal(options.runtime, :session, options.id)

      _error ->
        :ok
    end
  end
end
