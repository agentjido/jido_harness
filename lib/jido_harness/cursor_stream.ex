defmodule Jido.Harness.CursorStream do
  @moduledoc false

  @doc "Builds a pull stream that replays Signals by cursor until the resource is terminal."
  def build(replay_fun, info_fun, terminal_fun, options \\ []) do
    cursor = Keyword.get(options, :cursor, 0)
    limit = Keyword.get(options, :limit, 100)
    poll_interval = Keyword.get(options, :poll_interval_ms, 25)

    Stream.resource(
      fn -> cursor end,
      fn current ->
        case replay_fun.(current, limit) do
          {:ok, [_ | _] = signals} ->
            next_cursor = signals |> List.last() |> sequence()
            {signals, next_cursor}

          {:ok, []} ->
            case info_fun.() do
              {:ok, info} ->
                if terminal_fun.(info) do
                  replay_after_terminal(replay_fun, current, limit)
                else
                  Process.sleep(poll_interval)
                  {[], current}
                end

              {:error, _reason} ->
                {:halt, current}
            end

          {:error, _reason} ->
            {:halt, current}
        end
      end,
      fn _cursor -> :ok end
    )
  end

  defp replay_after_terminal(replay_fun, current, limit) do
    case replay_fun.(current, limit) do
      {:ok, [_ | _] = signals} ->
        next_cursor = signals |> List.last() |> sequence()
        {signals, next_cursor}

      {:ok, []} ->
        {:halt, current}

      {:error, _reason} ->
        {:halt, current}
    end
  end

  defp sequence(%Jido.Signal{} = signal), do: Jido.Harness.Signal.sequence(signal)
  defp sequence(%{sequence: sequence}), do: sequence
end
