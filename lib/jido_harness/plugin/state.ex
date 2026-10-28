defmodule Jido.Harness.Plugin.State do
  @moduledoc false

  alias Jido.Harness.Signal

  @schema Zoi.object(%{
            commands: Zoi.map() |> Zoi.default(%{}),
            runs: Zoi.map() |> Zoi.default(%{}),
            sessions: Zoi.map() |> Zoi.default(%{})
          })
          |> Zoi.default(%{commands: %{}, runs: %{}, sessions: %{}})

  def schema, do: @schema

  def reduce(reduction, opts) do
    state = Enum.reduce(reduction.directives, reduction.plugin_state, &record_directive/2)
    state = record_signal(state, reduction.signal)
    {:ok, trim_commands(state, Keyword.get(opts, :command_history_limit, 256))}
  end

  defp record_directive(%{signal: %Jido.Signal{} = signal}, state) do
    data = signal.data

    entry = %{
      "operation" => signal.type,
      "connection" => data["connection"],
      "status" => "committed"
    }

    put_in(state, [:commands, data["command_id"]], entry)
  end

  defp record_directive(_directive, state), do: state

  defp record_signal(state, %Jido.Signal{type: "jido.harness.command.accepted", data: data}) do
    update_command(state, data["command_id"], "accepted", data)
  end

  defp record_signal(state, %Jido.Signal{type: "jido.harness.command.failed", data: data}) do
    update_command(state, data["command_id"], "failed", data)
  end

  defp record_signal(state, %Jido.Signal{} = signal) do
    metadata = get_in(signal.data, ["metadata", "jido_harness_plugin"])

    if is_map(metadata) and metadata["resource_kind"] in ["run", "session"] do
      key = if metadata["resource_kind"] == "run", do: :runs, else: :sessions
      id = metadata["resource_id"]

      current = get_in(state, [key, id]) || %{}

      entry =
        Map.merge(current, %{
          "connection" => metadata["connection"],
          "workspace" => metadata["workspace"],
          "command_id" => metadata["command_id"],
          "signals" => metadata["signals"],
          "cursor" => Signal.sequence(signal),
          "last_type" => signal.type,
          "terminal" => Signal.terminal?(signal)
        })

      put_in(state, [key, id], entry)
    else
      state
    end
  end

  defp record_signal(state, _signal), do: state

  defp update_command(state, command_id, status, data) do
    current = get_in(state, [:commands, command_id]) || %{}
    put_in(state, [:commands, command_id], Map.merge(current, Map.put(data, "status", status)))
  end

  defp trim_commands(state, limit) when is_integer(limit) and limit > 0 do
    overflow = map_size(state.commands) - limit

    if overflow > 0 do
      keys = state.commands |> Map.keys() |> Enum.sort() |> Enum.take(overflow)
      %{state | commands: Map.drop(state.commands, keys)}
    else
      state
    end
  end

  defp trim_commands(state, _limit), do: state
end
