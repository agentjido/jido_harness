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
  alias Jido.Harness.Exec.Preflight

  @impl true
  def run(params, _context) do
    Helpers.with_keyword_opts(params.opts, "Unsupported option key for shared runtime validation", fn opts ->
      Preflight.validate_shared_runtime(params.session_id, opts)
    end)
  end
end
