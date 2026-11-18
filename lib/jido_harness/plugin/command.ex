if Code.ensure_loaded?(Jido.Agent.Extension) do
  defmodule Jido.Harness.Plugin.Command do
    @moduledoc "Constructs prompt, interrupt, and permission response Signals for a Harness Agent."

    alias Jido.Signal

    @prefix "jido.harness.command."

    @doc "Builds a prompt Signal with an application request ID."
    @spec prompt(String.t(), String.t()) :: Signal.t()
    def prompt(request_id, text), do: new("prompt", request_id, %{"text" => text})

    @doc "Builds a Signal to interrupt the identified active turn."
    @spec interrupt(String.t(), String.t()) :: Signal.t()
    def interrupt(request_id, turn_id), do: new("interrupt", request_id, %{"turn_id" => turn_id})

    @doc "Builds a Signal to answer a permission request once."
    @spec respond_approval(String.t(), String.t(), :approve | :deny) :: Signal.t()
    def respond_approval(request_id, approval_id, decision) when decision in [:approve, :deny] do
      new("respond_approval", request_id, %{"approval_id" => approval_id, "decision" => Atom.to_string(decision)})
    end

    @doc false
    @spec parse(Signal.t()) :: {:ok, tuple()} | {:error, :invalid_harness_command}
    def parse(%Signal{type: @prefix <> operation, data: %{"request_id" => id} = data}) when is_binary(id) do
      case {operation, Map.delete(data, "request_id")} do
        {"prompt", %{"text" => text} = payload}
        when map_size(payload) == 1 and is_binary(text) and byte_size(text) > 0 ->
          command(id, {:prompt, id, text})

        {"interrupt", %{"turn_id" => turn_id} = payload}
        when map_size(payload) == 1 and is_binary(turn_id) and byte_size(turn_id) in 1..256 ->
          command(id, {:interrupt, id, turn_id})

        {"respond_approval", %{"approval_id" => approval_id, "decision" => decision} = payload}
        when map_size(payload) == 2 and is_binary(approval_id) and byte_size(approval_id) in 1..256 and
               decision in ["approve", "deny"] ->
          command(id, {:respond_approval, id, approval_id, if(decision == "approve", do: :approve, else: :deny)})

        _ ->
          {:error, :invalid_harness_command}
      end
    end

    def parse(_signal), do: {:error, :invalid_harness_command}

    defp command(id, command) when byte_size(id) in 1..256, do: {:ok, command}
    defp command(_id, _command), do: {:error, :invalid_harness_command}

    defp new(operation, request_id, payload) do
      signal = Signal.new!(@prefix <> operation, Map.put(payload, "request_id", request_id), source: "/harness/host")

      case parse(signal) do
        {:ok, _command} -> signal
        {:error, reason} -> raise ArgumentError, Atom.to_string(reason)
      end
    end
  end
end
