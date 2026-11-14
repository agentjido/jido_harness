defmodule HarnessV3Contract.Action do
  use Jido.Action,
    name: "harness_event_contract",
    schema: Jido.Joi.object(%{event: Jido.Joi.any()})

  @impl true
  def run(%{event: %Jido.Harness.Event{} = event}, _context) do
    {:ok, %{run_id: event.run_id, sequence: event.sequence, text: event.payload["text"]}}
  end
end

defmodule HarnessV3Contract.Agent do
  use Jido.Agent, name: "harness_contract"

  state do
    schema(Jido.Joi.object(%{}))
  end

  routes do
    route "host.harness.output", HarnessV3Contract.Action do
      state(:unchanged)
    end
  end
end

defmodule HarnessV3ContractTest do
  use ExUnit.Case, async: false

  test "host routes a Harness Event through a core Signal and Action" do
    event =
      Jido.Harness.Event.new!(%{
        type: :output_text_final,
        provider: :codex,
        run_id: "contract-run",
        sequence: 7,
        payload: %{"text" => "offline result"}
      })

    signal = Jido.Signal.new!("host.harness.output", %{event: event}, source: "/host/harness")

    assert {:ok, %{run_id: "contract-run", sequence: 7, text: "offline result"}} =
             Jido.Exec.run(HarnessV3Contract.Action, signal.data, %{}, max_attempts: 1)

    start_supervised!({Jido, name: HarnessV3Contract.Runtime})
    assert {:ok, agent} = Jido.start_agent(HarnessV3Contract.Runtime, HarnessV3Contract.Agent, id: "harness-contract")
    assert {:ok, turn} = Jido.AgentServer.call(agent, signal)
    assert %Jido.AgentServer.TurnResult{status: :committed} = turn
    assert Application.get_application(Jido.Action) == :jido
    assert Application.get_application(Jido.Signal) == :jido
    assert Application.get_application(Jido.AI.Context) == :jido
  end
end
