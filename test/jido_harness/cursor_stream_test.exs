defmodule Jido.Harness.CursorStreamTest do
  use ExUnit.Case, async: true

  alias Jido.Harness.CursorStream

  test "replays once more after observing terminal state" do
    replay = fn _cursor, _limit ->
      count = Process.get(:terminal_replay_count, 0)
      Process.put(:terminal_replay_count, count + 1)

      case count do
        0 ->
          {:ok, []}

        1 ->
          {:ok, [%{sequence: 1, value: :trailing}]}

        _ ->
          {:ok, []}
      end
    end

    stream = CursorStream.build(replay, fn -> {:ok, :terminal} end, &(&1 == :terminal))

    assert Enum.to_list(stream) == [%{sequence: 1, value: :trailing}]
    assert Process.get(:terminal_replay_count) == 4
  end

  test "halts after terminal state when the final replay is empty" do
    replay = fn _cursor, _limit ->
      Process.put(:empty_terminal_replay_count, Process.get(:empty_terminal_replay_count, 0) + 1)
      {:ok, []}
    end

    stream = CursorStream.build(replay, fn -> {:ok, :terminal} end, &(&1 == :terminal))

    assert Enum.to_list(stream) == []
    assert Process.get(:empty_terminal_replay_count) == 2
  end
end
