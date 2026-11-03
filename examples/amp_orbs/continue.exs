#!/usr/bin/env elixir

Code.require_file("support.exs", __DIR__)

alias Jido.Harness.Amp
alias JidoHarnessAmpExamples, as: Example

case System.argv() do
  [thread | prompt_parts] when prompt_parts != [] ->
    Example.require_amp_token!()
    prompt = Enum.join(prompt_parts, " ")
    orb = Amp.continue_orb(thread, prompt) |> Example.result!()
    Example.print_json(orb)

  _other ->
    Example.usage!("usage: continue.exs THREAD_ID PROMPT")
end
