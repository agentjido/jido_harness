defmodule Jido.Harness.TextTailTest do
  use ExUnit.Case, async: true

  alias Jido.Harness.TextTail

  test "bounds appended text by bytes while preserving valid UTF-8" do
    tail = TextTail.new(7) |> TextTail.append("prefix-") |> TextTail.append("🙂🙂")

    assert tail.truncated?
    assert tail.data == "🙂"
    assert String.valid?(tail.data)
  end

  test "final text replacement resets earlier delta truncation" do
    tail = TextTail.new(8) |> TextTail.append("a much longer delta") |> TextTail.replace("final")

    refute tail.truncated?
    assert tail.data == "final"
  end
end
