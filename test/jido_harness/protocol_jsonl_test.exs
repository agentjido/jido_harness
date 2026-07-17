defmodule Jido.Harness.Protocol.JSONLTest do
  use ExUnit.Case, async: true

  alias Jido.Harness.Protocol.JSONL

  test "retains fragmented records until the newline arrives" do
    assert {[], buffer} = JSONL.push("", ~s({"type":"del))
    assert {[{:ok, %{"type" => "delta"}}], ""} = JSONL.push(buffer, ~s(ta"}\n))
  end

  test "returns invalid frames without dropping subsequent records" do
    {records, ""} = JSONL.push("", "not-json\n{\"ok\":true}\n")
    assert [{:error, "not-json", %Jason.DecodeError{}}, {:ok, %{"ok" => true}}] = records
  end

  test "flush decodes a final non-newline record" do
    assert [{:ok, %{"done" => true}}] = JSONL.flush(~s({"done":true}))
    assert JSONL.encode(%{"type" => "ping"}) == "{\"type\":\"ping\"}\n"
  end
end
