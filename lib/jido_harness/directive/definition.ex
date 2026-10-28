defmodule Jido.Harness.Directive.Definition do
  @moduledoc false

  defmacro define(module, signal_module) do
    module = Macro.expand(module, __CALLER__)
    signal_module = Macro.expand(signal_module, __CALLER__)

    schema =
      Zoi.struct(
        module,
        %{signal: Zoi.struct(Jido.Signal, nil, description: "Validated Harness command Signal")},
        coerce: true,
        unrecognized_keys: :error
      )

    quote do
      defmodule unquote(module) do
        @moduledoc false
        use Jido.Agent.Directive

        @signal_module unquote(signal_module)
        @schema unquote(Macro.escape(schema))
        @type t :: unquote(Zoi.type_spec(schema))
        @enforce_keys Zoi.Struct.enforce_keys(@schema)
        defstruct Zoi.Struct.struct_fields(@schema)

        @doc false
        def schema, do: @schema

        @doc false
        def signal_definition, do: @signal_module

        @impl Jido.Agent.Directive
        def validate(%__MODULE__{signal: %Jido.Signal{type: type} = signal} = directive) do
          with true <- type == @signal_module.type(),
               {:ok, data} <- @signal_module.validate_data(signal.data),
               {:ok, directive} <- Zoi.parse(@schema, %{directive | signal: %{signal | data: data}}) do
            {:ok, directive}
          else
            false -> {:error, {:invalid_harness_command_type, type}}
            {:error, _reason} = error -> error
          end
        end

        def validate(value), do: {:error, {:invalid_harness_directive, value}}
      end
    end
  end
end
