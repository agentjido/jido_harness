defmodule Jido.Harness.Signal.Command.Schemas do
  @moduledoc false

  def run_start do
    strict(%{
      "command_id" => id(),
      "connection" => id(),
      "workspace" => optional_id(),
      "path" => Zoi.string() |> Zoi.optional(),
      "prompt" => id(),
      "options" => options()
    })
  end

  def run_resource(resource) do
    strict(%{"command_id" => id(), "connection" => id(), resource => id()})
  end

  def session_start do
    strict(%{
      "command_id" => id(),
      "connection" => id(),
      "workspace" => optional_id(),
      "path" => Zoi.string() |> Zoi.optional(),
      "options" => options()
    })
  end

  def session_turn do
    strict(%{
      "command_id" => id(),
      "connection" => id(),
      "session_id" => id(),
      "prompt" => id(),
      "options" => options()
    })
  end

  def session_interrupt do
    strict(%{
      "command_id" => id(),
      "connection" => id(),
      "session_id" => id(),
      "turn_id" => optional_id()
    })
  end

  def session_approval do
    strict(%{
      "command_id" => id(),
      "connection" => id(),
      "session_id" => id(),
      "approval_request_id" => id(),
      "response" => Zoi.any()
    })
  end

  def session_configure do
    strict(%{
      "command_id" => id(),
      "connection" => id(),
      "session_id" => id(),
      "changes" => Zoi.map()
    })
  end

  def command_result do
    strict(%{
      "command_id" => id(),
      "connection" => id(),
      "operation" => id(),
      "resource_kind" => id() |> Zoi.optional(),
      "resource_id" => id() |> Zoi.optional(),
      "result" => Zoi.map() |> Zoi.default(%{})
    })
  end

  def command_failure do
    strict(%{
      "command_id" => id(),
      "connection" => id(),
      "operation" => id(),
      "code" => id(),
      "message" => Zoi.string()
    })
  end

  defp id, do: Zoi.string() |> Zoi.min(1)
  defp optional_id, do: id() |> Zoi.optional()
  defp options, do: Zoi.map() |> Zoi.default(%{})
  defp strict(fields), do: Zoi.map(fields, unrecognized_keys: :error)
end
