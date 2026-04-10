defmodule Jido.Harness.Event.Usage do
  @moduledoc """
  Builder for canonical `:usage` events.

  All adapters declaring `usage?: true` in their capabilities should emit exactly
  **one** `:usage` event per session, placed immediately before
  `:session_completed` (or `:session_failed`).

  ## Canonical payload keys

  | Key                    | Type                | Required |
  |------------------------|---------------------|----------|
  | `"input_tokens"`       | `non_neg_integer()` | yes      |
  | `"output_tokens"`      | `non_neg_integer()` | yes      |
  | `"total_tokens"`       | `non_neg_integer()` | no (computed as input + output when absent) |
  | `"cached_input_tokens"`| `non_neg_integer()` | no (default 0) |
  | `"cost_usd"`           | `float() \\| nil`   | no       |
  | `"duration_ms"`        | `integer() \\| nil`  | no       |
  | `"model"`              | `String.t() \\| nil` | no       |

  ## Example

      Jido.Harness.Event.Usage.build(:claude, "session-42",
        input_tokens: 1250,
        output_tokens: 890,
        cost_usd: 0.00542,
        model: "claude-sonnet-4-20250514"
      )
  """

  alias Jido.Harness.Event

  @required_keys [:input_tokens, :output_tokens]

  @doc """
  Builds a canonical `:usage` event.

  `provider` and `session_id` are required.  `opts` must include at least
  `:input_tokens` and `:output_tokens`.

  Optional keys: `:total_tokens`, `:cached_input_tokens`, `:cost_usd`,
  `:duration_ms`, `:model`.

  An optional `:raw` key can carry the original SDK object for debugging.
  """
  @spec build(atom(), String.t(), keyword()) :: Event.t()
  def build(provider, session_id, opts) when is_atom(provider) and is_binary(session_id) do
    for key <- @required_keys do
      unless Keyword.has_key?(opts, key) do
        raise ArgumentError, "Usage event requires #{inspect(key)}"
      end
    end

    input = Keyword.fetch!(opts, :input_tokens)
    output = Keyword.fetch!(opts, :output_tokens)

    payload =
      %{
        "input_tokens" => input,
        "output_tokens" => output,
        "total_tokens" => Keyword.get(opts, :total_tokens, input + output),
        "cached_input_tokens" => Keyword.get(opts, :cached_input_tokens, 0)
      }
      |> put_if("cost_usd", Keyword.get(opts, :cost_usd))
      |> put_if("duration_ms", Keyword.get(opts, :duration_ms))
      |> put_if("model", Keyword.get(opts, :model))

    Event.new!(%{
      type: :usage,
      provider: provider,
      session_id: session_id,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      payload: payload,
      raw: Keyword.get(opts, :raw)
    })
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
