defmodule Jido.Harness.Signal.Definition do
  @moduledoc false

  defmacro define(module, type) do
    schema =
      Zoi.map(
        %{
          "run_id" => optional_id(),
          "session_id" => optional_id(),
          "process_id" => optional_id(),
          "provider" => Zoi.string() |> Zoi.min(1) |> Zoi.optional(),
          "provider_session_id" => optional_id(),
          "turn_id" => optional_id(),
          "request_id" => optional_id(),
          "sequence" => Zoi.integer() |> Zoi.min(1),
          "payload" => Zoi.map(Zoi.string(), Zoi.any(), []) |> Zoi.default(%{}),
          "metadata" => Zoi.map(Zoi.string(), Zoi.any(), []) |> Zoi.default(%{})
        },
        unrecognized_keys: :error
      )

    schema_name = type |> String.replace_prefix("jido.harness.", "") |> String.replace(".", "_")
    dataschema = "urn:jido:harness:schema:#{schema_name}:1"

    quote do
      defmodule unquote(module) do
        @moduledoc false

        use Jido.Signal,
          type: unquote(type),
          dataschema: unquote(dataschema),
          default_source: "urn:jido:harness:local",
          schema: unquote(Macro.escape(schema))
      end
    end
  end

  defp optional_id, do: Zoi.string() |> Zoi.min(1) |> Zoi.optional()
end
