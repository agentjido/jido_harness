defmodule Jido.Harness.RunResult do
  @moduledoc "The terminal result of a harness run."

  alias Jido.Harness.{Error, Event}

  @enforce_keys [:run_id, :provider, :status]
  defstruct [:run_id, :provider, :session_id, :status, :text, :usage, :events, :metadata, :error]

  @type t :: %__MODULE__{
          run_id: String.t(),
          provider: atom(),
          session_id: String.t() | nil,
          status: :completed | :failed | :cancelled,
          text: String.t(),
          usage: map(),
          events: [Event.t()],
          metadata: map(),
          error: Error.t() | term() | nil
        }
end
