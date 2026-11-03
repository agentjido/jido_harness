#!/usr/bin/env elixir

Code.require_file("support.exs", __DIR__)

alias Jido.Harness.Amp
alias JidoHarnessAmpExamples, as: Example

case System.argv() do
  [thread] ->
    Example.require_amp_token!()
    export = Amp.export_thread(thread) |> Example.result!()
    Example.print_json(export)

  _other ->
    Example.usage!("usage: show.exs THREAD_ID")
end
