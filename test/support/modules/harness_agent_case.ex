if Code.ensure_loaded?(Jido.Agent.Extension) do
  defmodule Jido.Harness.AgentCase do
    @moduledoc false

    use ExUnit.CaseTemplate

    alias Jido.AgentServer
    alias Jido.Harness.{Process, Session}

    using do
      quote do
        import Jido.Harness.AgentCase
      end
    end

    setup context do
      {:ok, _} = Application.ensure_all_started(:jido)
      workspace = context.tmp_dir
      previous_cwd = System.get_env("HARNESS_AGENT_EXAMPLE_CWD")
      System.put_env("HARNESS_AGENT_EXAMPLE_CWD", workspace)
      instance = context.module
      start_supervised!({Jido, name: instance})

      on_exit(fn ->
        if previous_cwd,
          do: System.put_env("HARNESS_AGENT_EXAMPLE_CWD", previous_cwd),
          else: System.delete_env("HARNESS_AGENT_EXAMPLE_CWD")

        File.rm_rf!(workspace)
      end)

      {:ok, instance: instance, workspace: workspace}
    end

    def start_agent(instance, wrapper, opts \\ []) do
      definition = wrapper.definition()

      [plugin] = definition.plugins
      config = Map.merge(plugin.data, Map.new(opts))
      definition = %{definition | plugins: [%{plugin | data: config}]}

      {:ok, agent} = Jido.start_agent(instance, definition, id: "agent-#{System.unique_integer([:positive])}")
      :ok = AgentServer.await_ready(agent)
      agent
    end

    def events(agent), do: AgentServer.snapshot(agent).agent.state.events

    def wait_for_event(agent, type, request_id, timeout \\ 5_000) do
      eventually(
        fn ->
          Enum.find(events(agent), fn event ->
            event["type"] == "jido.harness." <> type and event["data"]["request_id"] == request_id
          end)
        end,
        timeout
      )
    end

    def process_for(session_id) do
      Enum.find(Process.list(), &(&1.metadata[:session_id] == session_id))
    end

    def assert_closed(session_id, process_id) do
      assert eventually(fn -> match?({:ok, %{state: :closed}}, Session.info(session_id)) end, 10_000)
      assert {:ok, %{state: state}} = Process.await(process_id, 5_000)
      assert state in [:cancelled, :exited]
    end

    def eventually(fun, timeout) do
      deadline = System.monotonic_time(:millisecond) + timeout
      wait_until(fun, deadline)
    end

    defp wait_until(fun, deadline) do
      case fun.() do
        value when value not in [nil, false] ->
          value

        _ ->
          if System.monotonic_time(:millisecond) >= deadline do
            flunk("Harness Agent condition timed out")
          else
            Elixir.Process.sleep(25)
            wait_until(fun, deadline)
          end
      end
    end
  end
end
