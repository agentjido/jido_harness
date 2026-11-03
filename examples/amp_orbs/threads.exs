#!/usr/bin/env elixir

Code.require_file("support.exs", __DIR__)

alias Jido.Harness.Amp
alias JidoHarnessAmpExamples, as: Example

{options, arguments, invalid} =
  OptionParser.parse(System.argv(), strict: [include_archived: :boolean, limit: :integer])

if arguments != [] or invalid != [], do: Example.usage!("usage: threads.exs [--include-archived] [--limit N]")

Example.require_amp_token!()

list_options = [
  include_archived: Keyword.get(options, :include_archived, false),
  limit: Keyword.get(options, :limit, 50)
]

threads = Amp.list_threads(list_options) |> Example.result!()
Example.print_json(threads)
