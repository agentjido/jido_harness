defmodule Jido.Harness.Signal.RuntimeValidated do
  @moduledoc """
  Signal emitted when shared/provider runtime checks complete.
  """

  use Jido.Signal,
    type: "jido.harness.runtime.validated",
    default_source: "/jido/harness/runtime",
    schema: [
      run_id: [type: :string, required: false],
      request_id: [type: :string, required: false],
      session_id: [type: :string, required: false],
      provider: [type: :atom, required: false],
      checks: [type: :map, required: false]
    ]
end
