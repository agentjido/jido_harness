#!/usr/bin/env elixir

defmodule Jido.Harness.Fixture.StreamCLI do
  @codex [
    ~s({"type":"thread.started","thread_id":"codex-fixture-session"}),
    ~s({"type":"item.completed","thread_id":"codex-fixture-session","item":{"type":"agent_message","text":"codex-ok"}}),
    ~s({"type":"turn.completed","thread_id":"codex-fixture-session","status":"completed",) <>
      ~s("usage":{"input_tokens":2,"output_tokens":1}})
  ]

  @gemini [
    ~s({"type":"init","session_id":"gemini-fixture-session","model":"fixture"}),
    ~s({"type":"message","role":"assistant","content":"gemini-ok","delta":true}),
    ~s({"type":"result","status":"success","stats":{"input_tokens":2,"output_tokens":1}})
  ]

  @claude [
    ~s({"type":"system","subtype":"init","session_id":"claude-fixture-session","model":"fixture","tools":[]}),
    ~s({"type":"stream_event","session_id":"claude-fixture-session",) <>
      ~s("event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"claude-ok"}}}),
    ~s({"type":"result","subtype":"success","session_id":"claude-fixture-session",) <>
      ~s("result":"claude-ok","usage":{"input_tokens":2,"output_tokens":1}})
  ]

  @amp [
    ~s({"type":"system","subtype":"init","session_id":"amp-fixture-session","tools":[]}),
    ~s({"type":"assistant","session_id":"amp-fixture-session","message":{"content":[{"type":"text","text":"amp-ok"}]}}),
    ~s({"type":"result","subtype":"success","session_id":"amp-fixture-session",) <>
      ~s("result":"amp-ok","usage":{"input_tokens":2,"output_tokens":1}})
  ]

  def run(args) do
    cond do
      "exec" in args and "--json" in args -> emit(@codex)
      "--prompt" in args -> emit(@gemini)
      "--print" in args -> emit(@claude)
      "--execute" in args -> emit(@amp)
      true -> unsupported()
    end
  end

  defp emit(events), do: Enum.each(events, &IO.puts/1)

  defp unsupported do
    IO.puts(:stderr, "unsupported fixture invocation")
    System.halt(2)
  end
end

Jido.Harness.Fixture.StreamCLI.run(System.argv())
