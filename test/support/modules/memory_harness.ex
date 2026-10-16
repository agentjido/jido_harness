defmodule Jido.Harness.MemoryHarness do
  @moduledoc false

  alias Jido.Harness.{Buffer, SessionRequest, TurnRequest}
  alias Jido.Harness.Session.{ActiveTurn, Lifecycle, State}

  def state(options \\ %{}) do
    %State{
      id: "memory-session",
      provider: :test,
      request: SessionRequest.new!(options),
      adapter: Jido.Harness.Adapters.Claude,
      acp_agent: %{
        capabilities: Jido.Harness.SessionCapabilities.new!(%{}),
        turn_options: [],
        turn_provider_options: []
      },
      context: %{},
      started_at: "2026-10-16T00:00:00Z",
      status: :idle,
      buffer: Buffer.new(65_536),
      journal: nil
    }
  end

  def finish_turn(state, id) do
    active = ActiveTurn.new(id, TurnRequest.new!("fixture"), 4_096)
    state = %{state | active: active, known_turns: MapSet.put(state.known_turns, id), status: :running}
    Lifecycle.finish_turn(state, :turn_completed, %{}, nil, nil, false)
  end

  def await(fun, attempts \\ 500)
  def await(_fun, 0), do: raise("memory fixture did not reach the expected state")

  def await(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(2)
          await(fun, attempts - 1)
        )
  end
end

defmodule Jido.Harness.MemoryHarness.ProcessManager do
  @moduledoc false

  def start_owned_process(_spec, owner), do: {:ok, owner}
  def cancel_process(_owner), do: :ok
  def await_process(_owner, _timeout), do: {:ok, %{state: :cancelled}}
  def send_input(_owner, _data), do: :ok

  def live_stream_process(owner) do
    {:ok,
     Stream.resource(
       fn ->
         send(owner, {:memory_reader, self()})
         :open
       end,
       fn state ->
         receive do
           {:events, events} -> {events, state}
         end
       end,
       fn _ -> :ok end
     )}
  end
end

defmodule Jido.Harness.MemoryHarness.Driver do
  @moduledoc false
  @behaviour Jido.Harness.ProcessDriver

  @impl true
  def start(spec, owner) do
    exec =
      spawn(fn ->
        monitor = Process.monitor(owner)

        receive do
          {:DOWN, ^monitor, :process, ^owner, _reason} -> :ok
          :finish -> send(owner, {:DOWN, make_ref(), :process, self(), :normal})
        end
      end)

    os_pid = System.unique_integer([:positive])
    send(spec.metadata.test_pid, {:memory_driver, owner, exec, os_pid})
    {:ok, exec, os_pid}
  end

  @impl true
  def send_input(_process, _data), do: :ok

  @impl true
  def signal(_process, _signal), do: :ok
end
