if Code.ensure_loaded?(Jido.Harness.Plugin) do
  Code.require_file("../../guides/recipes/agent_wrappers.exs", __DIR__)

  defmodule Jido.Harness.AgentWrapperLiveTest do
    use Jido.Harness.AgentCase, async: false

    alias Jido.AgentServer
    alias Jido.Harness.Session
    alias Jido.Harness.Plugin.Command

    @moduletag :integration
    @moduletag :tmp_dir
    @moduletag timeout: 240_000

    for {provider, wrapper} <- [
          {:codex, HarnessAgentExample.Codex},
          {:claude, HarnessAgentExample.Claude},
          {:amp, HarnessAgentExample.Amp}
        ] do
      test "#{provider} keeps context across routed turns and closes its ACP process", %{instance: instance} do
        provider = unquote(provider)
        old_ids = Enum.map(Session.list(providers: [provider]), & &1.session_id)
        agent = start_agent(instance, unquote(wrapper), provider_opts(provider))
        value = "harness-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

        first = "Remember this value for the next turn: #{value}. Reply with only READY. Do not use tools."
        second = "Reply with only the value I asked you to remember. Do not use tools."

        assert String.trim(prompt(agent, "first", first)) == "READY"
        assert String.trim(prompt(agent, "second", second)) == value
        assert [session_id] = Enum.map(Session.list(providers: [provider]), & &1.session_id) -- old_ids
        assert %{process_id: process_id} = process_for(session_id)

        assert :ok = Jido.stop_agent(instance, agent)
        assert_closed(session_id, process_id)
      end
    end

    defp provider_opts(:codex) do
      case System.get_env("HARNESS_AGENT_CODEX_MODEL") do
        nil -> []
        model -> [model: model]
      end
    end

    defp provider_opts(_provider), do: []

    defp prompt(agent, request_id, text) do
      assert {:ok, _} = AgentServer.call(agent, Command.prompt(request_id, text))

      outcome =
        eventually(
          fn ->
            Enum.find(events(agent), fn event ->
              event["type"] in ["jido.harness.turn.finished", "jido.harness.error.command"] and
                event["data"]["request_id"] == request_id
            end)
          end,
          100_000
        )

      assert %{"data" => %{"status" => "completed", "text" => reply, "turn_id" => id}} = outcome
      assert %{"data" => %{"turn_id" => ^id}} = wait_for_event(agent, "turn.delta", request_id)

      assert Enum.count(events(agent), fn event ->
               event["type"] == "jido.harness.turn.finished" and event["data"]["request_id"] == request_id
             end) == 1

      reply
    end
  end
end
