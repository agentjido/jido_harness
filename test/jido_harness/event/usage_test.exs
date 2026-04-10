defmodule Jido.Harness.Event.UsageTest do
  use ExUnit.Case, async: true

  alias Jido.Harness.Event
  alias Jido.Harness.Event.Usage

  describe "build/3" do
    test "builds a canonical usage event with required fields" do
      event = Usage.build(:claude, "sess-1", input_tokens: 100, output_tokens: 50)

      assert %Event{} = event
      assert event.type == :usage
      assert event.provider == :claude
      assert event.session_id == "sess-1"
      assert event.payload["input_tokens"] == 100
      assert event.payload["output_tokens"] == 50
      assert event.payload["total_tokens"] == 150
      assert event.payload["cached_input_tokens"] == 0
      refute Map.has_key?(event.payload, "cost_usd")
      refute Map.has_key?(event.payload, "duration_ms")
      refute Map.has_key?(event.payload, "model")
    end

    test "includes optional fields when provided" do
      event =
        Usage.build(:codex, "sess-2",
          input_tokens: 200,
          output_tokens: 80,
          cached_input_tokens: 50,
          cost_usd: 0.003,
          duration_ms: 1200,
          model: "o3-mini"
        )

      assert event.payload["cached_input_tokens"] == 50
      assert event.payload["cost_usd"] == 0.003
      assert event.payload["duration_ms"] == 1200
      assert event.payload["model"] == "o3-mini"
    end

    test "computes total_tokens when not provided" do
      event = Usage.build(:gemini, "sess-3", input_tokens: 300, output_tokens: 100)
      assert event.payload["total_tokens"] == 400
    end

    test "allows explicit total_tokens override" do
      event = Usage.build(:gemini, "sess-4", input_tokens: 300, output_tokens: 100, total_tokens: 500)
      assert event.payload["total_tokens"] == 500
    end

    test "passes through raw SDK object" do
      raw = %{"some" => "sdk_data"}
      event = Usage.build(:claude, "sess-5", input_tokens: 1, output_tokens: 2, raw: raw)
      assert event.raw == raw
    end

    test "raises on missing input_tokens" do
      assert_raise ArgumentError, ~r/input_tokens/, fn ->
        Usage.build(:claude, "sess-x", output_tokens: 50)
      end
    end

    test "raises on missing output_tokens" do
      assert_raise ArgumentError, ~r/output_tokens/, fn ->
        Usage.build(:claude, "sess-x", input_tokens: 50)
      end
    end

    test "sets timestamp" do
      event = Usage.build(:claude, "sess-6", input_tokens: 1, output_tokens: 1)
      assert is_binary(event.timestamp)
    end
  end
end
