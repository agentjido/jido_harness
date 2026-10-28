defmodule Jido.Harness.Plugin.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link({init, connections}), do: Supervisor.start_link(__MODULE__, {init, connections})

  @impl true
  def init({init, connections}) do
    watcher_name = {:global, {Jido.Harness.Plugin.WatcherSupervisor, init.agent_server}}

    children = [
      Supervisor.child_spec({DynamicSupervisor, strategy: :one_for_one, name: watcher_name},
        id: Jido.Harness.Plugin.WatcherSupervisor
      ),
      Supervisor.child_spec({Jido.Harness.Plugin.Runtime, {init, connections}}, id: Jido.Harness.Plugin.Runtime)
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
