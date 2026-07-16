defmodule Jido.Harness.RunInfo do
  @moduledoc "A snapshot of a supervised harness run."

  @enforce_keys [:run_id, :provider, :state, :started_at]
  defstruct [
    :run_id,
    :provider,
    :state,
    :started_at,
    :finished_at,
    :session_id,
    :error,
    :journal_dir,
    output_cursor: 0,
    metadata: %{}
  ]

  @type state :: :starting | :running | :completed | :failed | :cancelled
  @type t :: %__MODULE__{
          run_id: String.t(),
          provider: atom(),
          state: state(),
          started_at: String.t(),
          finished_at: String.t() | nil,
          session_id: String.t() | nil,
          error: term(),
          journal_dir: String.t() | nil,
          output_cursor: non_neg_integer(),
          metadata: map()
        }

  @spec terminal?(t()) :: boolean()
  @doc "Returns whether the run reached a terminal state."
  def terminal?(%__MODULE__{state: state}), do: state in [:completed, :failed, :cancelled]
end
