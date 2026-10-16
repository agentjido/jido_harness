defmodule Jido.Harness.FrameBufferTest do
  use ExUnit.Case, async: true
  alias Jido.Harness.SessionAdapters.ACP.FrameBuffer

  test "preserves frame order across arbitrary byte boundaries and CRLF" do
    input = "  first\r\n\n" <> String.duplicate("🙂", 3_000) <> "\nlast"

    {frames, buffer} =
      for <<byte <- input>>, reduce: {[], %FrameBuffer{}} do
        {frames, buffer} ->
          assert {:ok, next, buffer} = FrameBuffer.feed(buffer, <<byte>>, 16_384)
          {Enum.reverse(next, frames), buffer}
      end

    assert Enum.reverse(frames) == ["first", String.duplicate("🙂", 3_000)]
    assert {:ok, ["last"], %{bytes: 0}} = FrameBuffer.feed(buffer, "\n", 16_384)
  end

  test "checks the raw frame limit before trimming whitespace" do
    assert {:ok, [], buffer} = FrameBuffer.feed(%FrameBuffer{}, "1234", 4)
    assert {:ok, ["1234"], _} = FrameBuffer.feed(buffer, "\n", 4)
    assert {:error, :frame_too_large} = FrameBuffer.feed(buffer, "5", 4)
    assert {:error, :frame_too_large} = FrameBuffer.feed(%FrameBuffer{}, "     \n", 4)
  end

  test "small saved fragments do not retain a large input binary" do
    input = String.duplicate("ok\n", 50_000) <> "tail"
    assert {:ok, frames, buffer} = FrameBuffer.feed(%FrameBuffer{}, input, 1_024)
    assert length(frames) == 50_000
    assert ["tail"] = buffer.pending
    assert :binary.referenced_byte_size(hd(buffer.pending)) <= 4_096
  end
end
