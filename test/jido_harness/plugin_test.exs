if Code.ensure_loaded?(Jido.Harness.Plugin) do
  Code.require_file("../../guides/recipes/agent_wrappers.exs", __DIR__)

  defmodule Jido.Harness.PluginTest.Reject do
    use Jido.Action, name: "reject_harness_turn", schema: Jido.Joi.map()

    @impl true
    def run(_params, _context) do
      signal = Jido.Harness.Plugin.Command.prompt("rejected", "do not submit")
      directive = %Jido.Harness.Plugin.Dispatch{signal: signal}
      {:ok, %{events: :invalid}, [directive]}
    end
  end

  defmodule Jido.Harness.PluginTest.RejectingAgent do
    use Jido.Agent, name: "harness_reject", plugins: [Jido.Harness.Plugin]

    state do
      schema(Jido.Joi.object(%{events: Jido.Joi.array(Jido.Joi.map()) |> Jido.Joi.default([])}))
    end

    harness do
      provider(:codex)
      cwd(env("HARNESS_AGENT_EXAMPLE_CWD"))
    end

    routes do
      route("test.harness.reject", Jido.Harness.PluginTest.Reject)
    end
  end

  defmodule Jido.Harness.PluginTest do
    use Jido.Harness.AgentCase, async: false

    alias Jido.AgentServer
    alias Jido.Harness.{Session, TestHelpers}
    alias Jido.Harness.Plugin.Command

    @moduletag :tmp_dir

    setup context do
      config = Application.get_env(:jido_harness, :provider_config, %{})
      fixture = TestHelpers.fixture_path("fake_acp_cli.py")

      fixture_options = %{
        acp_path: Map.get(context, :acp_path, fixture),
        env: Map.get(context, :provider_env, %{}),
        retention: Map.get(context, :retention, %{})
      }

      Application.put_env(:jido_harness, :provider_config, Map.put(config, :codex, fixture_options))
      on_exit(fn -> Application.put_env(:jido_harness, :provider_config, config) end)
    end

    test "starts on the first committed prompt, queues follow-ups and owns the ACP process", %{instance: instance} do
      old_ids = Enum.map(Session.list(), & &1.session_id)
      agent = start_agent(instance, HarnessAgentExample.Codex)
      assert Enum.map(Session.list(), & &1.session_id) == old_ids

      assert {:ok, _} = AgentServer.call(agent, Command.prompt("one", "slow"))
      assert {:ok, _} = AgentServer.call(agent, Command.prompt("two", "second"))

      for id <- ["one", "two"] do
        assert %{"data" => %{"turn_id" => turn, "status" => "completed", "text" => "fixture-ok"}} =
                 wait_for_event(agent, "turn.finished", id)

        assert %{"data" => %{"turn_id" => ^turn, "text" => "fixture-ok"}} =
                 wait_for_event(agent, "turn.delta", id)
      end

      assert ["two", "one"] ==
               for(%{"type" => "jido.harness.turn.finished", "data" => %{"request_id" => id}} <- events(agent), do: id)

      assert {:ok, _} = AgentServer.call(agent, Command.prompt("one", "duplicate"))
      assert %{"data" => %{"code" => "duplicate_request"}} = wait_for_event(agent, "error.command", "one")

      assert [session_id] = Enum.map(Session.list(), & &1.session_id) -- old_ids
      assert %{process_id: process_id} = process_for(session_id)

      second = start_agent(instance, HarnessAgentExample.Codex)
      assert {:ok, _} = AgentServer.call(second, Command.prompt("one", "separate agent"))
      assert %{"data" => %{"status" => "completed"}} = wait_for_event(second, "turn.finished", "one")
      assert [other_session] = Enum.map(Session.list(), & &1.session_id) -- [session_id | old_ids]
      assert %{process_id: other_process} = process_for(other_session)

      assert :ok = Jido.stop_agent(instance, agent)
      assert_closed(session_id, process_id)
      assert {:ok, %{state: :idle}} = Session.info(other_session)
      assert :ok = Jido.stop_agent(instance, second)
      assert_closed(other_session, other_process)
    end

    test "interrupts by turn ID and answers a provider permission through the Agent", %{instance: instance} do
      agent = start_agent(instance, HarnessAgentExample.Codex)
      assert {:ok, _} = AgentServer.call(agent, Command.prompt("wait", "wait"))
      assert %{"data" => %{"turn_id" => turn_id}} = wait_for_event(agent, "turn.accepted", "wait")
      assert eventually(fn -> Enum.any?(Session.list(), &(&1.active_turn_id == turn_id)) end, 5_000)
      assert {:ok, _} = AgentServer.call(agent, Command.interrupt("cancel", turn_id))
      assert %{"data" => %{"status" => "interrupted"}} = wait_for_event(agent, "turn.finished", "wait")
      assert {:ok, _} = AgentServer.call(agent, Command.interrupt("stale", turn_id))
      assert %{"data" => %{"code" => "no_active_turn"}} = wait_for_event(agent, "error.command", "stale")

      assert {:ok, _} = AgentServer.call(agent, Command.prompt("permission", "approval"))
      assert %{"data" => %{"approval_id" => approval}} = wait_for_event(agent, "approval.requested", "permission")

      assert %{"data" => %{"status" => "completed", "text" => "denied"}} =
               wait_for_event(agent, "turn.finished", "permission")

      assert [session] = Session.list(providers: [:codex], states: [:idle])
      assert {:ok, journal} = Session.replay(session.session_id, limit: 100)

      assert Enum.any?(
               journal,
               &(&1.type == :approval_resolved and &1.payload == %{"decision" => "deny", "scope" => "once"})
             )

      assert {:ok, _} = AgentServer.call(agent, Command.respond_approval("late", approval, :approve))
      assert %{"data" => %{"code" => "stale_approval"}} = wait_for_event(agent, "error.command", "late")
    end

    test "a rejected Agent commit never submits its directive", %{instance: instance} do
      before = Session.list()
      agent = start_agent(instance, Jido.Harness.PluginTest.RejectingAgent)
      signal = Jido.Signal.new!("test.harness.reject", %{}, source: "/harness/test")
      assert {:ok, %{status: :failed, effects: :none}} = AgentServer.call(agent, signal)
      assert Session.list() == before
    end

    @tag provider_env: %{"HARNESS_FIXTURE_INITIALIZE_DELAY" => "1.0"}
    test "keeps Agent routes responsive during startup and bounds queued commands", %{instance: instance} do
      agent = start_agent(instance, HarnessAgentExample.Codex, max_queued_turns: 1)
      assert {:ok, _} = AgentServer.call(agent, Command.prompt("one", "slow"), 500)
      assert {:ok, _} = AgentServer.call(agent, Command.prompt("two", "second"), 500)
      assert {:ok, _} = AgentServer.call(agent, Command.prompt("three", "over limit"), 500)
      assert %{"data" => %{"code" => "queue_full"}} = wait_for_event(agent, "error.command", "three")
      assert %{"data" => %{"status" => "completed"}} = wait_for_event(agent, "turn.finished", "one")
      assert %{"data" => %{"status" => "completed"}} = wait_for_event(agent, "turn.finished", "two")
    end

    @tag retention: %{memory_bytes: 2_048, disk_limit_bytes: 4_096}
    test "returns retained results when its replay cursor crosses a gap", %{instance: instance} do
      agent = start_agent(instance, HarnessAgentExample.Codex)
      assert {:ok, _} = AgentServer.call(agent, Command.prompt("large", "large"))

      assert %{"data" => %{"status" => "completed", "truncated" => true}} =
               wait_for_event(agent, "turn.finished", "large")

      assert [session] = Session.list(providers: [:codex], states: [:idle])
      assert {:ok, page} = Session.replay_page(session.session_id, cursor: 0)
      assert page.gaps != []

      assert {:ok, _} = AgentServer.call(agent, Command.prompt("next", "next"))
      assert %{"data" => %{"status" => "completed"}} = wait_for_event(agent, "turn.finished", "next")
    end

    test "reports provider failure and accepts a later turn", %{instance: instance} do
      agent = start_agent(instance, HarnessAgentExample.Codex)
      assert {:ok, _} = AgentServer.call(agent, Command.prompt("fail", "terminal-fail"))
      assert %{"data" => %{"status" => "failed", "code" => _}} = wait_for_event(agent, "turn.finished", "fail")
      assert {:ok, _} = AgentServer.call(agent, Command.prompt("next", "next"))
      assert %{"data" => %{"status" => "completed"}} = wait_for_event(agent, "turn.finished", "next")
    end
  end
end
