if Code.ensure_loaded?(Jido.Agent.Extension) do
  defmodule Jido.Harness.Plugin.Dispatch do
    @moduledoc false
    use Jido.Agent.Directive

    alias Jido.Harness.Plugin.Command

    @enforce_keys [:signal]
    defstruct [:signal]

    @type t :: %__MODULE__{signal: Jido.Signal.t()}

    @impl true
    def validate(%__MODULE__{signal: signal} = directive) do
      with {:ok, _command} <- Command.parse(signal), do: {:ok, directive}
    end
  end

  defmodule Jido.Harness.Plugin.Execute do
    @moduledoc "Terminal Action that requests Harness I/O after the Agent turn commits."
    use Jido.Action, name: "harness_plugin_execute", schema: Jido.Joi.map()

    alias Jido.Harness.Plugin.Dispatch

    @impl true
    def run(_params, context) do
      {:ok, context.agent_state, [%Dispatch{signal: context.signal}]}
    end
  end
end
