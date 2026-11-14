#!/usr/bin/env elixir

Code.require_file("support.exs", __DIR__)

alias Jido.Harness.Amp
alias JidoHarnessAmpExamples, as: Example

{options, arguments, invalid} = OptionParser.parse(System.argv(), strict: [restore: :boolean])

if invalid != [], do: Example.usage!("usage: archive.exs [--restore] THREAD_ID")

case arguments do
  [thread] ->
    Example.require_amp_token!()

    action =
      if Keyword.get(options, :restore, false) do
        Amp.unarchive_thread(thread)
        |> Example.result!()

        "restored"
      else
        Amp.archive_thread(thread)
        |> Example.result!()

        "archived"
      end

    Example.print_json(%{status: action, thread: thread})

  _other ->
    Example.usage!("usage: archive.exs [--restore] THREAD_ID")
end
