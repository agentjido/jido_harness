defmodule Jido.Harness.Actions.ProvisionWorkspace do
  @moduledoc "Provision a workspace/session for harness runtime execution."

  use Jido.Action,
    name: "harness_provision_workspace",
    description: "Provision harness workspace",
    schema: [
      workspace_id: [type: :string, required: true],
      environment: [type: :atom, required: false],
      opts: [type: :map, default: %{}]
    ]

  alias Jido.Harness.Actions.Helpers
  alias Jido.Harness.Exec.Error
  alias Jido.Harness.Exec.Workspace

  @impl true
  def run(params, _context) do
    with {:ok, opts} <- Helpers.to_keyword(params.opts || %{}) do
      opts = maybe_put_environment(opts, Map.get(params, :environment))
      Workspace.provision_workspace(params.workspace_id, opts)
    else
      {:error, {:invalid_option_key, key}} ->
        {:error, Error.invalid("Unsupported option key for provision workspace", %{field: :opts, key: key})}

      {:error, :invalid_options} ->
        {:error, Error.invalid("opts must be a map or keyword list", %{field: :opts})}
    end
  end

  defp maybe_put_environment(opts, nil), do: opts
  defp maybe_put_environment(opts, env) when is_atom(env), do: Keyword.put(opts, :environment, env)
end
