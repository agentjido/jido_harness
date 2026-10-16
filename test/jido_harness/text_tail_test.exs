defmodule Jido.Harness.TextTailTest do
  use ExUnit.Case, async: true

  alias Jido.Harness.TextTail

  test "bounds appended text by bytes while preserving valid UTF-8" do
    tail = TextTail.new(7) |> TextTail.append("prefix-") |> TextTail.append("🙂🙂")

    assert tail.truncated?
    assert TextTail.text(tail) == "🙂"
    assert String.valid?(TextTail.text(tail))
  end

  test "final text replacement resets earlier delta truncation" do
    tail = TextTail.new(8) |> TextTail.append("a much longer delta") |> TextTail.replace("final")

    refute tail.truncated?
    assert TextTail.text(tail) == "final"
  end

  test "many small deltas retain the same suffix across block boundaries" do
    input = String.duplicate("abc🙂", 10_000)
    tail = for <<byte <- input>>, reduce: TextTail.new(8_195), do: (tail -> TextTail.append(tail, <<byte>>))
    assert tail.bytes == 8_195
    assert byte_size(TextTail.text(tail)) <= 8_195
    assert String.valid?(TextTail.text(tail))
    assert String.ends_with?(input, TextTail.text(tail))
    assert tail.truncated?
  end

  test "a small suffix releases a large original binary" do
    tail = TextTail.new(100) |> TextTail.append(String.duplicate("x", 1_000_000))
    [chunk] = :queue.to_list(tail.chunks)
    assert :binary.referenced_byte_size(chunk) <= 200
    assert TextTail.text(tail) == String.duplicate("x", 100)
  end

  test "an exact-size delta marks discarded earlier text as truncated" do
    tail = TextTail.new(4) |> TextTail.append("old") |> TextTail.append("last")
    assert tail.truncated?
    assert TextTail.text(tail) == "last"
  end

  test "UTF-8 fragments join before validation and invalid prefixes are removed" do
    tail = TextTail.new(100) |> TextTail.append(<<240, 159>>) |> TextTail.append(<<153, 130>>)
    assert TextTail.text(tail) == "🙂"
    assert TextTail.new(100) |> TextTail.append(<<255, 255>> <> "ok") |> TextTail.text() == "ok"
  end
end
