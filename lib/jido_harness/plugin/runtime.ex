defmodule Jido.Harness.Plugin.Runtime do
  @moduledoc false
  use GenServer

  def start_link({init, connections}), do: GenServer.start_link(__MODULE__, {init, connections})

  def connection(runtime, name), do: GenServer.call(runtime, {:connection, name})
  def begin_command(runtime, signal), do: GenServer.call(runtime, {:begin_command, signal})

  def complete_command(runtime, command_id, result),
    do: GenServer.call(runtime, {:complete_command, command_id, result})

  def claim(runtime, kind, id, metadata), do: GenServer.call(runtime, {:claim, kind, id, metadata})
  def release(runtime, kind, id), do: GenServer.call(runtime, {:release, kind, id})
  def owner(runtime, kind, id), do: GenServer.call(runtime, {:owner, kind, id})
  def register_watcher(runtime, kind, id, options), do: GenServer.call(runtime, {:register_watcher, kind, id, options})
  def cursor(runtime, kind, id, cursor), do: GenServer.cast(runtime, {:cursor, kind, id, cursor})
  def terminal(runtime, kind, id), do: GenServer.cast(runtime, {:terminal, kind, id})
  def agent_server(runtime), do: GenServer.call(runtime, :agent_server)
  def quiesce(runtime), do: GenServer.call(runtime, :quiesce, :infinity)
  def resume(runtime), do: GenServer.call(runtime, :resume, :infinity)

  @impl true
  def init({init, connections}) do
    resources = restore_resources(init.plugin_state || %{})

    {:ok,
     %{
       agent_server: init.agent_server,
       connections: Map.new(connections, &{Atom.to_string(&1.name), &1}),
       commands: Map.get(init.plugin_state || %{}, :commands, %{}),
       resources: resources,
       quiesced?: false,
       watcher_supervisor: {:global, {Jido.Harness.Plugin.WatcherSupervisor, init.agent_server}}
     }, {:continue, :restore_watchers}}
  end

  @impl true
  def handle_continue(:restore_watchers, state), do: {:noreply, restart_watchers(state)}

  @impl true
  def handle_call({:connection, name}, _from, state) do
    case Map.fetch(state.connections, to_string(name)) do
      {:ok, connection} -> {:reply, {:ok, connection}, state}
      :error -> {:reply, {:error, :unknown_harness_connection}, state}
    end
  end

  def handle_call({:begin_command, _signal}, _from, %{quiesced?: true} = state),
    do: {:reply, {:error, :harness_plugin_quiesced}, state}

  def handle_call({:begin_command, signal}, _from, state) do
    command_id = signal.data["command_id"]

    case Map.fetch(state.commands, command_id) do
      {:ok, entry} ->
        {:reply, {:duplicate, entry}, state}

      :error ->
        entry = %{
          "operation" => signal.type,
          "connection" => signal.data["connection"],
          "status" => "executing"
        }

        {:reply, :ok, %{state | commands: Map.put(state.commands, command_id, entry)}}
    end
  end

  def handle_call({:complete_command, command_id, result}, _from, state) do
    entry = state.commands |> Map.get(command_id, %{}) |> Map.merge(result)
    {:reply, :ok, %{state | commands: Map.put(state.commands, command_id, entry)}}
  end

  def handle_call({:claim, kind, id, metadata}, _from, state) do
    key = {kind, id}

    if Map.has_key?(state.resources, key) do
      {:reply, {:error, :harness_resource_already_owned}, state}
    else
      resource = Map.merge(metadata, %{kind: kind, id: id, cursor: 0, terminal?: false, watcher: nil})
      {:reply, :ok, %{state | resources: Map.put(state.resources, key, resource)}}
    end
  end

  def handle_call({:release, kind, id}, _from, state) do
    {:reply, :ok, %{state | resources: Map.delete(state.resources, {kind, id})}}
  end

  def handle_call({:owner, kind, id}, _from, state) do
    case Map.fetch(state.resources, {kind, id}) do
      {:ok, resource} -> {:reply, {:ok, resource}, state}
      :error -> {:reply, {:error, :unknown_harness_resource}, state}
    end
  end

  def handle_call({:register_watcher, kind, id, options}, _from, state) do
    key = {kind, id}

    with {:ok, resource} <- Map.fetch(state.resources, key),
         {:ok, pid} <- start_watcher(state, Map.merge(resource, options)) do
      resource = %{resource | watcher: pid}
      {:reply, :ok, %{state | resources: Map.put(state.resources, key, resource)}}
    else
      :error -> {:reply, {:error, :unknown_harness_resource}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:agent_server, _from, state), do: {:reply, state.agent_server, state}

  def handle_call(:quiesce, _from, state) do
    Enum.each(DynamicSupervisor.which_children(state.watcher_supervisor), fn {_, pid, _, _} ->
      DynamicSupervisor.terminate_child(state.watcher_supervisor, pid)
    end)

    resources = Map.new(state.resources, fn {key, resource} -> {key, %{resource | watcher: nil}} end)
    {:reply, :ok, %{state | quiesced?: true, resources: resources}}
  end

  def handle_call(:resume, _from, %{quiesced?: false} = state), do: {:reply, :ok, state}

  def handle_call(:resume, _from, state) do
    state = restart_watchers(%{state | quiesced?: false})
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:cursor, kind, id, cursor}, state) do
    key = {kind, id}

    resources =
      Map.update(state.resources, key, nil, &%{&1 | cursor: cursor}) |> Map.reject(fn {_k, v} -> is_nil(v) end)

    {:noreply, %{state | resources: resources}}
  end

  def handle_cast({:terminal, kind, id}, state) do
    key = {kind, id}

    resources =
      Map.update(state.resources, key, nil, &%{&1 | terminal?: true, watcher: nil})
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    {:noreply, %{state | resources: resources}}
  end

  defp restart_watchers(%{quiesced?: true} = state), do: state

  defp restart_watchers(state) do
    resources =
      Map.new(state.resources, fn {key, resource} ->
        if resource.terminal? do
          {key, resource}
        else
          case start_watcher(state, resource) do
            {:ok, pid} -> {key, %{resource | watcher: pid}}
            {:error, _reason} -> {key, %{resource | watcher: nil}}
          end
        end
      end)

    %{state | resources: resources}
  end

  defp start_watcher(state, resource) do
    options =
      resource
      |> Map.put(:agent_server, state.agent_server)
      |> Map.put(:runtime, self())

    DynamicSupervisor.start_child(state.watcher_supervisor, {Jido.Harness.Plugin.Watcher, options})
  catch
    :exit, reason -> {:error, {:watcher_supervisor_unavailable, reason}}
  end

  defp restore_resources(plugin_state) do
    runs = restore_kind(Map.get(plugin_state, :runs, %{}), :run)
    sessions = restore_kind(Map.get(plugin_state, :sessions, %{}), :session)
    Map.merge(runs, sessions)
  end

  defp restore_kind(resources, kind) do
    Map.new(resources, fn {id, value} ->
      {{kind, id},
       %{
         kind: kind,
         id: id,
         connection: value["connection"],
         workspace: value["workspace"],
         command_id: value["command_id"],
         signals: value["signals"] || ["jido.harness.**"],
         cursor: value["cursor"] || 0,
         terminal?: value["terminal"] || false,
         watcher: nil
       }}
    end)
  end
end
