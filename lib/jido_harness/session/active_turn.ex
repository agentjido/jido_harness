defmodule Jido.Harness.Session.ActiveTurn do
  @moduledoc false

  alias Jido.Harness.TextTail

  @enforce_keys [:id, :request, :text_tail, :started_at]
  defstruct [:id, :request, :text_tail, :final_text_tail, :started_at, usage: %{}]

  @type t :: %__MODULE__{}

  @doc false
  @spec new(String.t(), Jido.Harness.TurnRequest.t(), pos_integer()) :: t()
  def new(id, request, max_bytes) do
    %__MODULE__{
      id: id,
      request: request,
      text_tail: TextTail.new(max_bytes),
      started_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end
end
