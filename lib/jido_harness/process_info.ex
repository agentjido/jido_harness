defmodule Jido.Harness.ProcessInfo do
  @moduledoc "A redacted snapshot of a managed OS process."

  @enforce_keys [:process_id, :state, :started_at]
  defstruct [
    :process_id,
    :state,
    :started_at,
    :finished_at,
    :os_pid,
    :exit_status,
    :error,
    :journal_dir,
    output_cursor: 0,
    metadata: %{}
  ]

  @type state :: :starting | :running | :stopping | :exited | :failed | :cancelled | :timed_out
  @type t :: %__MODULE__{
          process_id: String.t(),
          state: state(),
          started_at: String.t(),
          finished_at: String.t() | nil,
          os_pid: integer() | nil,
          exit_status: integer() | nil,
          error: term(),
          journal_dir: String.t() | nil,
          output_cursor: non_neg_integer(),
          metadata: map()
        }

  @spec terminal?(t()) :: boolean()
  @doc "Returns whether the process reached a terminal state."
  def terminal?(%__MODULE__{state: state}), do: state in [:exited, :failed, :cancelled, :timed_out]
end
