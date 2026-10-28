# Jido Agent integration

`Jido.Harness.Plugin` lets a Jido V3 Agent control coding-agent runs and
sessions after the Agent turn commits.

## Agent definition

```elixir
defmodule MyApp.CodingAgent do
  use Jido.Agent,
    name: "coding_agent",
    extensions: [Jido.Harness.Plugin]

  harness do
    connection :claude_code do
      provider :claude

      workspace :application do
        root "/srv/my_app"
      end

      workspace :library do
        root "/srv/my_library"
      end

      default_workspace :application
      defaults %{}
      allowed_options [:model, :system_prompt]

      commands [
        Jido.Harness.Action.Run.Start,
        Jido.Harness.Action.Run.Cancel,
        Jido.Harness.Action.Session.Start,
        Jido.Harness.Action.Session.SendMessage,
        Jido.Harness.Action.Session.Close
      ]

      signals ["jido.harness.**"]
    end
  end

  routes do
    route "jido.harness.command.run.start", Jido.Harness.Action.Run.Start
    route "jido.harness.command.run.cancel", Jido.Harness.Action.Run.Cancel
    route "jido.harness.command.session.start", Jido.Harness.Action.Session.Start

    route "jido.harness.command.session.send_message",
          Jido.Harness.Action.Session.SendMessage

    route "jido.harness.command.session.close", Jido.Harness.Action.Session.Close
    route "jido.harness.**", MyApp.RecordHarnessSignal
  end
end
```

The wildcard route is an application Action. It updates application state from
accepted, failed, lifecycle, output, and replay-gap Signals.

## Start a run

```elixir
command =
  Jido.Harness.Signal.Command.Run.Start.new!(%{
    "command_id" => "review-42",
    "connection" => "claude_code",
    "workspace" => "library",
    "path" => "lib",
    "prompt" => "Review this library.",
    "options" => %{"model" => "sonnet"}
  })

{:ok, _agent, [%Jido.Harness.Directive.Run.Start{}]} =
  Jido.AgentServer.call(agent, command)
```

The typed Action validates the command and returns a Directive. The Plugin
starts the CLI only after the state commit. It sends a command accepted or
failed Signal back to the Agent, then streams native Harness Signals.

`command_id` is idempotent. Repeating it returns the stored outcome and does
not start a second resource.

## Start and use a session

Send `Command.Session.Start`, read the `session_id` from the accepted Signal,
then send `Command.Session.SendMessage`. Follow-up, steer, interrupt, approval,
configuration, close, kill, and prune commands use the same pattern.

The connection that starts a resource owns it. Another connection cannot
control it.

## Workspace policy

Commands select a declared workspace name and an optional path inside its
root. Absolute or relative paths that leave the root fail before CLI startup.

To point Claude Code at another repository, declare another named workspace
and select it in the command. Workspace roots are resolved when the Plugin
starts. They are not arbitrary command input. Change the Agent definition or
its installed extension configuration when the allowed root set must change.

## Recovery and Agent control

The Plugin stores command outcomes, resource ownership, Signal cursors, and
terminal state in its owned Agent state. Quiesce stops watchers. Resume starts
them from the last committed cursor, so resource work can continue without a
Signal gap in the Agent projection.

The Harness resource itself is not durable across a BEAM restart. Plugin state
can restore observation only while the Harness run or session still exists.
