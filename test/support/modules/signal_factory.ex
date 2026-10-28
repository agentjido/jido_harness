defmodule Jido.Harness.SignalFactory do
  @moduledoc false

  alias Jido.Harness.Process.DriverMessage
  alias Jido.Harness.Signal

  def process(type, data, options \\ []) do
    process_id = Keyword.get(options, :process_id, "fixture")
    sequence = Keyword.get(options, :sequence, 1)

    if type == :replay_gap do
      {:ok, signal} =
        Signal.build(
          :replay_gap,
          %{
            "process_id" => process_id,
            "sequence" => sequence,
            "payload" => data,
            "metadata" => %{}
          },
          "urn:jido:harness:process:fixture",
          "2026-09-04T00:00:00Z",
          nil
        )

      signal
    else
      message = %DriverMessage{
        type: type,
        timestamp: "2026-09-04T00:00:00Z",
        stream: if(type in [:stdout, :stderr], do: type),
        data: data,
        metadata: %{}
      }

      {:ok, signal} = Signal.from_process(message, process_id, sequence)
      signal
    end
  end

  def fact(kind, attributes \\ %{}) do
    sequence = Map.get(attributes, :sequence, 1)
    payload = Map.get(attributes, :payload, %{})
    resource = Map.get(attributes, :resource, :run)
    id = Map.get(attributes, :id, "fixture")
    provider = Map.get(attributes, :provider, "test")

    data = %{
      "sequence" => sequence,
      "payload" => payload,
      "metadata" => Map.get(attributes, :metadata, %{}),
      "provider" => provider,
      (Atom.to_string(resource) <> "_id") => id
    }

    data =
      Enum.reduce([:turn_id, :request_id, :provider_session_id], data, fn key, result ->
        case Map.fetch(attributes, key) do
          {:ok, value} -> Map.put(result, Atom.to_string(key), value)
          :error -> result
        end
      end)

    {:ok, signal} =
      Signal.build(
        kind,
        data,
        "urn:jido:harness:#{resource}:fixture",
        "2026-09-04T00:00:00Z",
        nil
      )

    signal
  end

  def payload(%Jido.Signal{data: data}), do: data["payload"] || %{}
  def process_data(signal), do: payload(signal)["data"]
end
