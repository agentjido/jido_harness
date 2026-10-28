defmodule Jido.Harness.Action.Definition do
  @moduledoc false

  defmacro define(module, action_name, signal_module, directive_module) do
    module = Macro.expand(module, __CALLER__)
    signal_module = Macro.expand(signal_module, __CALLER__)
    directive_module = Macro.expand(directive_module, __CALLER__)
    signal_type = signal_module.type()

    quote do
      defmodule unquote(module) do
        @moduledoc false
        use Jido.Action, name: unquote(action_name), schema: Zoi.map()

        @signal_module unquote(signal_module)
        @signal_type unquote(signal_type)
        @directive_module unquote(directive_module)

        @doc "Returns the command Signal handled by this Action."
        def signal_definition, do: @signal_module

        @doc "Returns the post-commit Directive created by this Action."
        def directive_module, do: @directive_module

        @impl Jido.Action
        def run(_params, %{agent_state: state, signal: %Jido.Signal{type: type} = signal})
            when type == @signal_type do
          {:ok, state, [struct!(@directive_module, signal: signal)]}
        end

        def run(_params, _context), do: {:error, {:invalid_harness_action_context, __MODULE__}}
      end
    end
  end
end
