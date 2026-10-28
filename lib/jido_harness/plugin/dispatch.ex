defmodule Jido.Harness.Plugin.Dispatch do
  @moduledoc false

  alias Jido.Harness.Plugin.Runtime
  alias Jido.Harness.Signal.Command.{Accepted, Failed}

  def run(runtime, %Jido.Signal{} = signal) do
    with {:ok, connection} <- Runtime.connection(runtime, signal.data["connection"]),
         :ok <- allowed_command(connection, signal.type) do
      case Runtime.begin_command(runtime, signal) do
        :ok -> execute(runtime, connection, signal)
        {:duplicate, entry} -> repeat_outcome(runtime, signal, entry)
        {:error, reason} -> fail(runtime, signal, reason)
      end
    else
      {:error, reason} -> fail(runtime, signal, reason)
    end
  end

  defp execute(runtime, connection, signal) do
    case operation(runtime, connection, signal) do
      {:ok, result} -> accept(runtime, signal, result)
      {:error, reason} -> fail(runtime, signal, reason)
    end
  end

  defp operation(runtime, connection, %{type: "jido.harness.command.run.start"} = signal) do
    with {:ok, request, workspace} <- request(connection, signal.data, :run),
         {:ok, run_id} <- Jido.Harness.Run.start(connection.provider, request),
         :ok <- claim_and_watch(runtime, connection, workspace, signal, :run, run_id) do
      {:ok, resource_result(:run, run_id, workspace)}
    end
  end

  defp operation(runtime, connection, %{type: "jido.harness.command.session.start"} = signal) do
    with {:ok, request, workspace} <- request(connection, signal.data, :session),
         {:ok, session_id} <- Jido.Harness.Session.start(connection.provider, request),
         :ok <- claim_and_watch(runtime, connection, workspace, signal, :session, session_id) do
      {:ok, resource_result(:session, session_id, workspace)}
    end
  end

  defp operation(runtime, connection, %{type: "jido.harness.command.run.cancel"} = signal) do
    with :ok <- owned(runtime, connection, :run, signal.data["run_id"]),
         :ok <- Jido.Harness.Run.cancel(signal.data["run_id"]) do
      {:ok, resource_result(:run, signal.data["run_id"], nil)}
    end
  end

  defp operation(runtime, connection, %{type: "jido.harness.command.run.prune"} = signal) do
    id = signal.data["run_id"]

    with :ok <- owned(runtime, connection, :run, id),
         :ok <- Jido.Harness.Run.prune(id),
         :ok <- Runtime.release(runtime, :run, id) do
      {:ok, resource_result(:run, id, nil)}
    end
  end

  defp operation(runtime, connection, %{type: type} = signal)
       when type in [
              "jido.harness.command.session.send_message",
              "jido.harness.command.session.follow_up",
              "jido.harness.command.session.steer"
            ] do
    id = signal.data["session_id"]

    with :ok <- owned(runtime, connection, :session, id),
         {:ok, options} <- allowed_options(connection, signal.data["options"] || %{}),
         {:ok, turn_id} <- session_turn(type, id, signal.data["prompt"], options) do
      {:ok, Map.put(resource_result(:session, id, nil), "turn_id", turn_id)}
    end
  end

  defp operation(runtime, connection, %{type: "jido.harness.command.session.interrupt"} = signal) do
    id = signal.data["session_id"]

    with :ok <- owned(runtime, connection, :session, id),
         :ok <- Jido.Harness.Session.interrupt(id, signal.data["turn_id"] || :active) do
      {:ok, resource_result(:session, id, nil)}
    end
  end

  defp operation(runtime, connection, %{type: "jido.harness.command.session.respond_approval"} = signal) do
    id = signal.data["session_id"]

    with :ok <- owned(runtime, connection, :session, id),
         :ok <-
           Jido.Harness.Session.respond_approval(
             id,
             signal.data["approval_request_id"],
             signal.data["response"]
           ) do
      {:ok, resource_result(:session, id, nil)}
    end
  end

  defp operation(runtime, connection, %{type: "jido.harness.command.session.configure"} = signal) do
    id = signal.data["session_id"]

    with :ok <- owned(runtime, connection, :session, id),
         :ok <- Jido.Harness.Session.configure(id, signal.data["changes"]) do
      {:ok, resource_result(:session, id, nil)}
    end
  end

  defp operation(runtime, connection, %{type: type} = signal)
       when type in [
              "jido.harness.command.session.close",
              "jido.harness.command.session.kill",
              "jido.harness.command.session.prune"
            ] do
    id = signal.data["session_id"]

    with :ok <- owned(runtime, connection, :session, id),
         :ok <- session_resource_operation(type, id),
         :ok <- maybe_release(runtime, type, :session, id) do
      {:ok, resource_result(:session, id, nil)}
    end
  end

  defp operation(_runtime, _connection, signal), do: {:error, {:unknown_harness_command, signal.type}}

  defp claim_and_watch(runtime, connection, workspace, signal, kind, id) do
    metadata = %{
      connection: Atom.to_string(connection.name),
      workspace: workspace,
      command_id: signal.data["command_id"],
      signals: connection.signals
    }

    result =
      with :ok <- Runtime.claim(runtime, kind, id, metadata),
           :ok <- Runtime.register_watcher(runtime, kind, id, %{}) do
        :ok
      end

    if result != :ok do
      Runtime.release(runtime, kind, id)
      cancel_started(kind, id)
    end

    result
  end

  defp cancel_started(:run, id), do: Jido.Harness.Run.cancel(id)
  defp cancel_started(:session, id), do: Jido.Harness.Session.kill(id)

  defp request(connection, data, kind) do
    with {:ok, workspace, root} <- workspace(connection, data["workspace"]),
         {:ok, cwd} <- workspace_path(root, data["path"]),
         {:ok, options} <- allowed_options(connection, data["options"] || %{}) do
      request = connection.defaults |> Map.merge(options) |> Map.put(:cwd, cwd)
      request = if kind == :run, do: Map.put(request, :prompt, data["prompt"]), else: request
      {:ok, request, workspace}
    end
  end

  defp workspace(connection, requested) do
    name = requested || Atom.to_string(connection.default_workspace)

    case Map.fetch(connection.workspaces, name) do
      {:ok, root} -> {:ok, name, root}
      :error -> {:error, :unknown_harness_workspace}
    end
  end

  defp workspace_path(root, nil), do: {:ok, root}

  defp workspace_path(root, path) do
    cwd = if Path.type(path) == :absolute, do: Path.expand(path), else: Path.expand(path, root)

    if cwd == root or String.starts_with?(cwd, root <> "/"),
      do: {:ok, cwd},
      else: {:error, :harness_workspace_denied}
  end

  defp allowed_options(connection, options) when is_map(options) do
    allowed = Map.new(connection.allowed_options, &{Atom.to_string(&1), &1})

    Enum.reduce_while(options, {:ok, %{}}, fn {key, value}, {:ok, result} ->
      case Map.fetch(allowed, to_string(key)) do
        {:ok, atom} -> {:cont, {:ok, Map.put(result, atom, value)}}
        :error -> {:halt, {:error, {:harness_option_denied, key}}}
      end
    end)
  end

  defp allowed_options(_connection, _options), do: {:error, :invalid_harness_options}

  defp allowed_command(connection, type) do
    if Enum.any?(connection.commands, &(&1.signal_definition().type() == type)),
      do: :ok,
      else: {:error, :harness_command_denied}
  end

  defp owned(runtime, connection, kind, id) do
    connection_name = Atom.to_string(connection.name)

    case Runtime.owner(runtime, kind, id) do
      {:ok, %{connection: ^connection_name}} -> :ok
      {:ok, _resource} -> {:error, :harness_resource_scope_denied}
      {:error, _reason} = error -> error
    end
  end

  defp session_turn("jido.harness.command.session.send_message", id, prompt, options),
    do: Jido.Harness.Session.send_message(id, prompt, Map.to_list(options))

  defp session_turn("jido.harness.command.session.follow_up", id, prompt, options),
    do: Jido.Harness.Session.follow_up(id, prompt, Map.to_list(options))

  defp session_turn("jido.harness.command.session.steer", id, prompt, options),
    do: Jido.Harness.Session.steer(id, prompt, Map.to_list(options))

  defp session_resource_operation("jido.harness.command.session.close", id),
    do: Jido.Harness.Session.close(id)

  defp session_resource_operation("jido.harness.command.session.kill", id),
    do: Jido.Harness.Session.kill(id)

  defp session_resource_operation("jido.harness.command.session.prune", id),
    do: Jido.Harness.Session.prune(id)

  defp maybe_release(runtime, "jido.harness.command.session.prune", kind, id),
    do: Runtime.release(runtime, kind, id)

  defp maybe_release(_runtime, _type, _kind, _id), do: :ok

  defp resource_result(kind, id, workspace) do
    %{
      "resource_kind" => Atom.to_string(kind),
      "resource_id" => id,
      "workspace" => workspace
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp accept(runtime, signal, result) do
    data = %{
      "command_id" => signal.data["command_id"],
      "connection" => signal.data["connection"],
      "operation" => signal.type,
      "resource_kind" => result["resource_kind"],
      "resource_id" => result["resource_id"],
      "result" => result
    }

    accepted = Accepted.new!(data)
    :ok = Runtime.complete_command(runtime, signal.data["command_id"], %{"status" => "accepted", "outcome" => data})
    deliver(runtime, signal.data["connection"], accepted)
  end

  defp fail(runtime, signal, reason) do
    data = %{
      "command_id" => signal.data["command_id"],
      "connection" => signal.data["connection"],
      "operation" => signal.type,
      "code" => error_code(reason),
      "message" => error_message(reason)
    }

    failed = Failed.new!(data)
    :ok = Runtime.complete_command(runtime, signal.data["command_id"], %{"status" => "failed", "outcome" => data})
    deliver(runtime, signal.data["connection"], failed)
  end

  defp repeat_outcome(runtime, signal, %{"status" => "accepted", "outcome" => data}),
    do: deliver(runtime, signal.data["connection"], Accepted.new!(data))

  defp repeat_outcome(runtime, signal, %{"status" => "failed", "outcome" => data}),
    do: deliver(runtime, signal.data["connection"], Failed.new!(data))

  defp repeat_outcome(runtime, signal, _entry), do: fail(runtime, signal, :duplicate_harness_command)

  defp deliver(runtime, connection_name, signal) do
    with {:ok, connection} <- Runtime.connection(runtime, connection_name),
         true <- Enum.any?(connection.signals, &Jido.Agent.Data.matches?(signal.type, &1)) do
      Jido.AgentServer.cast(Runtime.agent_server(runtime), signal)
    else
      false -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp error_code(%{kind: kind}) when is_atom(kind), do: Atom.to_string(kind)
  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "harness_error"

  defp error_message(error) when is_exception(error), do: Exception.message(error)
  defp error_message(reason), do: inspect(reason)
end
