defmodule Jido.Harness.Protocol.JSONL do
  @moduledoc false

  def push(buffer, chunk) when is_binary(buffer) and is_binary(chunk) do
    parts = String.split(buffer <> chunk, "\n")
    {lines, rest} = {Enum.drop(parts, -1), List.last(parts) || ""}
    {Enum.flat_map(lines, &decode_line/1), rest}
  end

  def flush(""), do: []
  def flush(buffer), do: decode_line(buffer)

  def encode(value), do: Jason.encode_to_iodata!(value) |> IO.iodata_to_binary() |> Kernel.<>("\n")

  defp decode_line(line) do
    line = String.trim(line)

    if line == "" do
      []
    else
      case Jason.decode(line) do
        {:ok, value} -> [{:ok, value}]
        {:error, reason} -> [{:error, line, reason}]
      end
    end
  end
end
