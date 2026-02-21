defmodule Jido.Harness.Actions.TeardownWorkspace do
  @moduledoc "Tear down a workspace/session for harness runtime execution."

  use Jido.Action,
    name: "harness_teardown_workspace",
    description: "Teardown harness workspace",
    schema: [
      session_id: [type: :string, required: true],
      opts: [type: :map, default: %{}]
    ]

  alias Jido.Harness.Actions.Helpers
  alias Jido.Harness.Exec.Error
  alias Jido.Harness.Exec.Workspace

  @impl true
  def run(params, _context) do
    with {:ok, opts} <- Helpers.to_keyword(params.opts || %{}) do
      {:ok, Workspace.teardown_workspace(params.session_id, opts)}
    else
      {:error, {:invalid_option_key, key}} ->
        {:error, Error.invalid("Unsupported option key for workspace teardown", %{field: :opts, key: key})}

      {:error, :invalid_options} ->
        {:error, Error.invalid("opts must be a map or keyword list", %{field: :opts})}
    end
  end
end
