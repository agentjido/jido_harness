if Code.ensure_loaded?(Jido.Agent.Extension) do
  defmodule Jido.Harness.Plugin do
    @moduledoc """
    Connects one Jido V3 Agent activation to one coding-agent conversation.

    Declare the provider and working directory in a `harness` block. Route
    command Signals to `Jido.Harness.Plugin.Execute`. Harness starts the
    provider after the first prompt commits and closes it when the plugin
    runtime exits.
    """

    alias Jido.Harness.{Registry, SessionManager, SessionRequest}
    alias Jido.Harness.Plugin.{Command, Dispatch, Runtime}
    alias Spark.Dsl.Extension

    @options [
      provider: [type: :atom],
      cwd: [type: :any],
      sandbox_mode: [type: {:one_of, [:default, :read_only, :workspace_write, :unrestricted]}],
      model: [type: :any],
      turn_runtime_timeout_ms: [type: :pos_integer],
      turn_idle_timeout_ms: [type: :pos_integer],
      session_idle_timeout_ms: [type: :pos_integer],
      approval_timeout_ms: [type: :pos_integer],
      max_queued_turns: [type: :pos_integer],
      max_queued_bytes: [type: :pos_integer]
    ]

    @section %Spark.Dsl.Section{name: :harness, schema: @options}
    @defaults %{
      turn_runtime_timeout_ms: 600_000,
      session_idle_timeout_ms: 1_800_000,
      approval_timeout_ms: 30_000
    }

    use Jido.Plugin, id: "jido.harness", sections: [@section]

    @impl Jido.Agent.Extension
    def lower(dsl, config) do
      options =
        for {key, _schema} <- @options,
            value = Extension.get_opt(dsl, [:harness], key),
            not is_nil(value),
            into: %{},
            do: {key, value}

      case {map_size(options), map_size(config)} do
        {0, _} -> {:ok, config}
        {_, 0} -> {:ok, options}
        _ -> {:error, :use_harness_block_or_config}
      end
    end

    @impl Jido.Agent.Extension
    def normalize(data) do
      with {:ok, data} <- Jido.Joi.parse(config_schema(), data),
           true <- valid_config_value?(data.cwd),
           true <- is_nil(data[:model]) or valid_config_value?(data.model) do
        {:ok, Map.merge(@defaults, data)}
      else
        _ -> {:error, :invalid_harness_config}
      end
    end

    @impl Jido.Plugin
    def directives(_opts), do: [Dispatch]

    @impl Jido.Plugin
    def child_spec(init) do
      with {:ok, config} <- Jido.Plugin.Config.resolve(Map.new(init.options)),
           {:ok, request} <- SessionRequest.new(config),
           {:ok, adapter} <- Registry.lookup(request.provider),
           {:ok, %{acp_agent: %Jido.Harness.ACPAgentSpec{} = acp} = spec} <- Registry.spec(request.provider),
           :ok <- SessionManager.validate_request(request, spec, acp),
           :ok <- SessionManager.validate_adapter_request(adapter, request) do
        {Runtime, {GenServer.whereis(init.agent_server), request}}
        |> Supervisor.child_spec(id: __MODULE__)
      else
        _ -> raise ArgumentError, "invalid Harness plugin directory, provider, or session options"
      end
    end

    @impl Jido.Plugin
    def dispatch(runtime, %Dispatch{signal: signal}, _context, _opts) do
      with {:ok, command} <- Command.parse(signal), do: Runtime.enqueue(runtime, command)
    end

    defp valid_config_value?({:env, name}), do: is_binary(name) and name != ""
    defp valid_config_value?(value), do: is_binary(value) and value != ""

    defp config_schema do
      options =
        Map.new(@options, fn {key, schema} ->
          value =
            case schema[:type] do
              :atom -> Jido.Joi.atom()
              :any -> Jido.Joi.any()
              :pos_integer -> Jido.Joi.integer() |> Jido.Joi.min(1)
              {:one_of, values} -> Jido.Joi.enum(values)
            end

          {key, if(key in [:provider, :cwd], do: value, else: Jido.Joi.optional(value))}
        end)

      Jido.Joi.object(options, unrecognized_keys: :error)
    end
  end
end
