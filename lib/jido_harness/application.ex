defmodule Jido.Harness.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Jido.Harness.ProcessRegistry},
      {Registry, keys: :unique, name: Jido.Harness.RunRegistry},
      {Registry, keys: :unique, name: Jido.Harness.SessionRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: Jido.Harness.ProcessSupervisor},
      {DynamicSupervisor, strategy: :one_for_one, name: Jido.Harness.RunSupervisor},
      {DynamicSupervisor, strategy: :one_for_one, name: Jido.Harness.SessionSupervisor},
      {DynamicSupervisor, strategy: :one_for_one, name: Jido.Harness.SessionTransportSupervisor},
      {Task.Supervisor, name: Jido.Harness.AdapterTaskSupervisor},
      {Task.Supervisor, name: Jido.Harness.SessionTaskSupervisor},
      Jido.Harness.Retention
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Jido.Harness.Supervisor)
  end
end
