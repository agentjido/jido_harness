defmodule Jido.Harness.Actions.ValidateSharedRuntime do
  @moduledoc "Validate shared runtime prerequisites in an existing shell session."

  use Jido.Action,
    name: "harness_validate_shared_runtime",
    description: "Validate shared runtime requirements",
    schema: [
      session_id: [type: :string, required: true],
      opts: [type: :map, default: %{}]
    ]

  alias Jido.Harness.Actions.Helpers
  alias Jido.Harness.Exec.Error
  alias Jido.Harness.Exec.Preflight

  @impl true
  def run(params, _context) do
    with {:ok, opts} <- Helpers.to_keyword(params.opts || %{}) do
      Preflight.validate_shared_runtime(params.session_id, opts)
    else
      {:error, {:invalid_option_key, key}} ->
        {:error, Error.invalid("Unsupported option key for shared runtime validation", %{field: :opts, key: key})}

      {:error, :invalid_options} ->
        {:error, Error.invalid("opts must be a map or keyword list", %{field: :opts})}
    end
  end
end
