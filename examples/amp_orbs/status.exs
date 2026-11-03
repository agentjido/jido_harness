#!/usr/bin/env elixir

Code.require_file("support.exs", __DIR__)

alias Jido.Harness.Amp
alias JidoHarnessAmpExamples, as: Example

status = Amp.status() |> Example.result!()

Example.print_json(%{
  amp: status,
  github_repository: Example.github_repo(),
  note: "ready checks token format; use threads.exs for a live authentication check"
})
