defmodule Jido.Harness.Plugin do
  @moduledoc """
  Adds supervised Harness runs and sessions to a Jido Agent.

  A connection fixes one provider, a set of named workspace roots, an option
  allowlist, allowed command Actions, and delivered Signal patterns. Actions
  create plugin-owned Directives. The Plugin starts CLI work only after the
  Agent turn commits.
  """

  alias Jido.Harness.Plugin.{Connection, Runtime, State, Workspace}
  alias Spark.Dsl.Extension, as: Dsl

  @default_commands Jido.Harness.Action.modules()

  @workspace %Spark.Dsl.Entity{
    name: :workspace,
    target: Workspace,
    args: [:name],
    schema: [
      name: [type: :atom, required: true],
      root: [type: :any, required: true]
    ]
  }

  @connection %Spark.Dsl.Entity{
    name: :connection,
    target: Connection,
    args: [:name],
    schema: [
      name: [type: :atom, required: true],
      provider: [type: :atom, required: true],
      default_workspace: [type: :atom, required: true],
      defaults: [type: :map, default: %{}],
      allowed_options: [type: {:list, :atom}, default: []],
      commands: [type: {:list, :atom}, default: @default_commands],
      signals: [type: {:list, :string}, default: ["jido.harness.**"]]
    ],
    entities: [workspaces: [@workspace]]
  }

  @section %Spark.Dsl.Section{name: :harness, entities: [@connection]}

  use Jido.Plugin,
    id: "jido.harness",
    sections: [@section],
    option_keys: [agent: [:connections, :command_history_limit], agent_server: [:connections]]

  @impl Jido.Plugin
  def state_spec(_opts), do: {:harness, State.schema()}

  @impl Jido.Plugin
  def directives(_opts), do: Jido.Harness.Action.directive_modules()

  @impl Jido.Plugin
  def reduce(reduction, opts), do: State.reduce(reduction, opts)

  @impl Jido.Agent.Extension
  def lower(dsl, config) do
    connections = Dsl.get_entities(dsl, [:harness])

    cond do
      connections != [] and config != %{} -> {:error, :use_harness_block_or_config}
      config != %{} -> {:ok, config}
      true -> {:ok, %{connections: Enum.map(connections, &connection_map/1)}}
    end
  end

  @impl Jido.Agent.Extension
  def normalize(%{connections: connections} = data) when is_list(connections) do
    with :ok <- Jido.Agent.Data.plain_map(data),
         :ok <- Jido.Agent.Data.static(data),
         :ok <- require_config(connections != [], :connections_required),
         :ok <- validate_connections(connections),
         :ok <- require_config(unique?(connections, & &1.name), :duplicate_connection) do
      {:ok, data}
    else
      {:error, _reason} = error -> error
    end
  end

  def normalize(_data), do: {:error, :invalid_harness_config}

  @impl Jido.Agent.Extension
  def verify(data, definition) do
    command_types =
      data.connections
      |> Enum.flat_map(&Enum.map(&1.commands, fn action -> action.signal_definition().type() end))

    input_types = MapSet.new(Enum.map(Jido.Harness.Action.modules(), & &1.signal_definition().type()))

    output_types =
      for module <- Jido.Harness.Signal.definitions(),
          type = module.type(),
          not MapSet.member?(input_types, type),
          Enum.any?(data.connections, fn connection -> selected?(connection.signals, type) end),
          do: type

    case Enum.find(Enum.uniq(command_types ++ output_types), fn type ->
           not Enum.any?(definition.routes, &Jido.Agent.Data.matches?(type, &1.path))
         end) do
      nil -> :ok
      type -> {:error, {:unhandled_harness_signal, type}}
    end
  end

  @impl Jido.Plugin
  def child_spec(init) do
    connections = Enum.map(init.options[:connections], &resolve_connection!/1)
    Supervisor.child_spec({Jido.Harness.Plugin.Supervisor, {init, connections}}, id: __MODULE__)
  end

  @impl Jido.Plugin
  def await_ready(_root, _opts), do: :ok

  @impl Jido.Plugin
  def dispatch(root, directive, _context, _opts) do
    Jido.Harness.Plugin.Dispatch.run(runtime(root), directive.signal)
  end

  @impl Jido.Plugin
  def quiesce(root, _opts), do: Runtime.quiesce(runtime(root))

  @impl Jido.Plugin
  def resume(root, _opts), do: Runtime.resume(runtime(root))

  @doc "Returns the resolved Harness connections for one active Agent Plugin root."
  def connections(root) do
    root
    |> runtime()
    |> :sys.get_state()
    |> Map.fetch!(:connections)
    |> Map.values()
  end

  defp runtime(root) do
    {Jido.Harness.Plugin.Runtime, pid, _type, _modules} =
      Enum.find(Supervisor.which_children(root), &(elem(&1, 0) == Jido.Harness.Plugin.Runtime))

    pid
  end

  defp resolve_connection!(connection) do
    {:ok, defaults} = Jido.Config.resolve(connection.defaults)

    workspaces =
      Map.new(connection.workspaces, fn workspace ->
        {:ok, root} = Jido.Config.resolve(workspace.root)
        {Atom.to_string(workspace.name), Path.expand(root)}
      end)

    default = Atom.to_string(connection.default_workspace)

    if not Map.has_key?(workspaces, default) do
      raise ArgumentError,
            "Harness connection #{connection.name}: default_workspace is not declared"
    end

    case Jido.Harness.Registry.lookup(connection.provider) do
      {:ok, _adapter} -> :ok
      {:error, reason} -> raise ArgumentError, "Harness connection #{connection.name}: #{inspect(reason)}"
    end

    %{connection | defaults: defaults, workspaces: workspaces}
  end

  defp connection_map(connection) do
    %{
      name: connection.name,
      provider: connection.provider,
      default_workspace: connection.default_workspace,
      defaults: connection.defaults,
      allowed_options: connection.allowed_options,
      commands: connection.commands,
      signals: connection.signals,
      workspaces: Enum.map(connection.workspaces, &Map.take(&1, [:name, :root]))
    }
  end

  defp valid_connection?(connection) do
    exact_keys =
      Map.keys(connection) --
        [
          :name,
          :provider,
          :default_workspace,
          :defaults,
          :allowed_options,
          :commands,
          :signals,
          :workspaces
        ]

    exact_keys == [] and is_atom(connection.name) and is_atom(connection.provider) and
      is_atom(connection.default_workspace) and is_map(connection.defaults) and
      valid_options?(connection.allowed_options) and valid_commands?(connection.commands) and
      valid_signals?(connection.signals) and valid_workspaces?(connection.workspaces) and
      Enum.any?(connection.workspaces, &(&1.name == connection.default_workspace))
  end

  defp valid_options?(options),
    do: is_list(options) and Enum.all?(options, &is_atom/1) and length(Enum.uniq(options)) == length(options)

  defp valid_commands?(commands) do
    is_list(commands) and commands != [] and
      Enum.all?(commands, &(&1 in @default_commands))
  end

  defp valid_signals?(signals),
    do: is_list(signals) and signals != [] and Enum.all?(signals, &(is_binary(&1) and &1 != ""))

  defp valid_workspaces?(workspaces) do
    is_list(workspaces) and workspaces != [] and unique?(workspaces, & &1.name) and
      Enum.all?(workspaces, fn workspace ->
        is_atom(workspace.name) and valid_reference?(workspace.root)
      end)
  end

  defp valid_reference?({:env, name}), do: is_binary(name) and name != ""
  defp valid_reference?(value), do: is_binary(value) and value != ""

  defp validate_connections(connections) do
    case Enum.find(connections, &(not valid_connection?(&1))) do
      nil -> :ok
      connection -> {:error, {:invalid_harness_connection, connection}}
    end
  end

  defp unique?(values, fun), do: length(Enum.uniq_by(values, fun)) == length(values)
  defp selected?(patterns, type), do: Enum.any?(patterns, &Jido.Agent.Data.matches?(type, &1))
  defp require_config(true, _reason), do: :ok
  defp require_config(false, reason), do: {:error, {:invalid_harness_config, reason}}
end
