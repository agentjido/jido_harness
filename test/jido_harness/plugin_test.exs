defmodule Jido.Harness.PluginTest do
  use ExUnit.Case, async: false

  import Jido.Harness.TestHelpers

  alias Jido.AgentServer
  alias Jido.Harness.Plugin
  alias Jido.Harness.Signal.Command

  defmodule RecordSignal do
    use Jido.Action, name: "harness_plugin_record_signal", schema: Zoi.map()

    @impl Jido.Action
    def run(_params, context) do
      record = %{"type" => context.signal.type, "data" => context.signal.data}
      {:ok, %{context.agent_state | received: context.agent_state.received ++ [record]}}
    end
  end

  defmodule Agent do
    @workspace Path.expand("../..", __DIR__)

    use Jido.Agent,
      name: "harness_plugin_test_agent",
      extensions: [Jido.Harness.Plugin]

    state do
      schema Zoi.object(%{received: Zoi.list(Zoi.map()) |> Zoi.default([])})
    end

    harness do
      connection :primary do
        provider :test

        workspace :repo do
          root @workspace
        end

        default_workspace :repo
        allowed_options [:model]

        commands [
          Jido.Harness.Action.Run.Start,
          Jido.Harness.Action.Session.Start,
          Jido.Harness.Action.Session.SendMessage,
          Jido.Harness.Action.Session.Close
        ]

        signals ["jido.harness.**"]
      end

      connection :secondary do
        provider :test

        workspace :repo do
          root @workspace
        end

        default_workspace :repo
        commands [Jido.Harness.Action.Session.Close]
        signals ["jido.harness.**"]
      end
    end

    routes do
      route "jido.harness.command.run.start", Jido.Harness.Action.Run.Start
      route "jido.harness.command.session.start", Jido.Harness.Action.Session.Start
      route "jido.harness.command.session.send_message", Jido.Harness.Action.Session.SendMessage
      route "jido.harness.command.session.close", Jido.Harness.Action.Session.Close
      route "jido.harness.**", RecordSignal
    end
  end

  setup context do
    journal_dir = Path.join(System.tmp_dir!(), "harness-plugin-#{System.unique_integer([:positive])}")
    configure_test_provider(Map.put(context, :journal_dir, journal_dir))
    {:ok, _applications} = Application.ensure_all_started(:jido)
    instance = Module.concat(__MODULE__, "Instance#{System.unique_integer([:positive])}")
    start_supervised!({Jido, name: instance, namespace: "harness-plugin-test"})
    {:ok, server} = Jido.start_agent(instance, Agent, id: "plugin-#{System.unique_integer([:positive])}")
    :ok = AgentServer.await_ready(server)
    %{server: server}
  end

  test "typed Actions return only their plugin-owned Directive" do
    signal = run_start("typed-action")
    state = %{received: []}

    assert {:ok, ^state, [%Jido.Harness.Directive.Run.Start{signal: ^signal}]} =
             Jido.Harness.Action.Run.Start.run(signal.data, %{agent_state: state, signal: signal})

    assert Jido.Harness.Run.list() == []
  end

  test "a committed command starts one run and duplicate command IDs reuse its outcome", %{server: server} do
    signal = run_start("same-command")
    assert {:ok, _, [%Jido.Harness.Directive.Run.Start{}]} = AgentServer.call(server, signal)
    accepted = await_record(server, "jido.harness.command.accepted", "same-command")
    run_id = accepted["data"]["resource_id"]
    assert await_record(server, "jido.harness.run.completed", run_id, "run_id")

    assert {:ok, _, [%Jido.Harness.Directive.Run.Start{}]} = AgentServer.call(server, signal)
    assert eventually(fn -> command_records(server, "same-command", "jido.harness.command.accepted") == 2 end)
    assert [owned] = Jido.Harness.Run.list()
    assert owned.run_id == run_id

    assert {:ok, state} = AgentServer.plugin_state(server, Plugin)
    assert state.commands["same-command"]["status"] == "accepted"
    assert state.runs[run_id]["terminal"]
  end

  test "named workspaces deny escape paths before CLI startup", %{server: server} do
    signal =
      Command.Run.Start.new!(%{
        "command_id" => "escape",
        "connection" => "primary",
        "workspace" => "repo",
        "path" => "..",
        "prompt" => "fixture",
        "options" => %{}
      })

    assert {:ok, _, _} = AgentServer.call(server, signal)
    failed = await_record(server, "jido.harness.command.failed", "escape")
    assert failed["data"]["code"] == "harness_workspace_denied"
    assert Jido.Harness.Run.list() == []
  end

  test "sessions support turns, ownership, quiesce, cursor replay, and close", %{server: server} do
    start =
      Command.Session.Start.new!(%{
        "command_id" => "session-start",
        "connection" => "primary",
        "workspace" => "repo",
        "options" => %{}
      })

    assert {:ok, _, _} = AgentServer.call(server, start)
    accepted = await_record(server, "jido.harness.command.accepted", "session-start")
    session_id = accepted["data"]["resource_id"]
    assert await_record(server, "jido.harness.session.ready", session_id, "session_id")

    denied =
      Command.Session.Close.new!(%{
        "command_id" => "wrong-owner",
        "connection" => "secondary",
        "session_id" => session_id
      })

    assert {:ok, _, _} = AgentServer.call(server, denied)
    failed = await_record(server, "jido.harness.command.failed", "wrong-owner")
    assert failed["data"]["code"] == "harness_resource_scope_denied"

    assert :ok = AgentServer.quiesce(server)
    assert {:ok, turn_id} = Jido.Harness.Session.send_message(session_id, "fixture")
    assert {:ok, %{status: :completed}} = Jido.Harness.Session.await(session_id, turn_id, 5_000)
    assert :ok = AgentServer.resume(server)
    assert await_record(server, "jido.harness.turn.completed", turn_id, "turn_id")

    send_message =
      Command.Session.SendMessage.new!(%{
        "command_id" => "session-turn",
        "connection" => "primary",
        "session_id" => session_id,
        "prompt" => "fixture",
        "options" => %{}
      })

    assert {:ok, _, _} = AgentServer.call(server, send_message)
    turn = await_record(server, "jido.harness.command.accepted", "session-turn")
    second_turn_id = turn["data"]["result"]["turn_id"]
    assert await_record(server, "jido.harness.turn.completed", second_turn_id, "turn_id")

    close =
      Command.Session.Close.new!(%{
        "command_id" => "session-close",
        "connection" => "primary",
        "session_id" => session_id
      })

    assert {:ok, _, _} = AgentServer.call(server, close)
    assert await_record(server, "jido.harness.command.accepted", "session-close")
    assert await_record(server, "jido.harness.session.closed", session_id, "session_id")

    assert {:ok, state} = AgentServer.plugin_state(server, Plugin)
    assert state.sessions[session_id]["terminal"]
    assert state.sessions[session_id]["cursor"] > 0
  end

  defp run_start(command_id) do
    Command.Run.Start.new!(%{
      "command_id" => command_id,
      "connection" => "primary",
      "workspace" => "repo",
      "prompt" => "fixture",
      "options" => %{}
    })
  end

  defp await_record(server, type, value, key \\ "command_id", attempts \\ 500)

  defp await_record(server, type, value, key, 0) do
    snapshot = AgentServer.snapshot(server)
    flunk("no #{type} record with #{key}=#{value}; received=#{inspect(snapshot.agent.state.received)}")
  end

  defp await_record(server, type, value, key, attempts) do
    record =
      server
      |> AgentServer.snapshot()
      |> then(& &1.agent.state.received)
      |> Enum.find(&(&1["type"] == type and &1["data"][key] == value))

    if record do
      record
    else
      Process.sleep(10)
      await_record(server, type, value, key, attempts - 1)
    end
  end

  defp command_records(server, command_id, type) do
    server
    |> AgentServer.snapshot()
    |> then(& &1.agent.state.received)
    |> Enum.count(&(&1["type"] == type and &1["data"]["command_id"] == command_id))
  end

  defp eventually(function, attempts \\ 500)
  defp eventually(_function, 0), do: false

  defp eventually(function, attempts) do
    if function.() do
      true
    else
      Process.sleep(10)
      eventually(function, attempts - 1)
    end
  end
end
