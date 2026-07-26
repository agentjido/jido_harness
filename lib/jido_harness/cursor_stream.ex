defmodule Jido.Harness.CursorStream do
  @moduledoc false

  def build(replay_fun, info_fun, terminal_fun, options \\ []) do
    cursor = Keyword.get(options, :cursor, 0)
    limit = Keyword.get(options, :limit, 100)
    poll_interval = Keyword.get(options, :poll_interval_ms, 25)

    Stream.resource(
      fn -> cursor end,
      fn current ->
        case replay_fun.(current, limit) do
          {:ok, [_ | _] = events} ->
            next_cursor = events |> List.last() |> Map.fetch!(:sequence)
            {events, next_cursor}

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
      {:ok, [_ | _] = events} ->
        next_cursor = events |> List.last() |> Map.fetch!(:sequence)
        {events, next_cursor}

      {:ok, []} ->
        {:halt, current}

      {:error, _reason} ->
        {:halt, current}
    end
  end
end
