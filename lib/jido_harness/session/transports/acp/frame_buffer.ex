defmodule Jido.Harness.SessionAdapters.ACP.FrameBuffer do
  @moduledoc false

  defstruct chunks: [], pending: [], pending_bytes: 0, bytes: 0
  @type t :: %__MODULE__{}

  @doc false
  @spec feed(t(), binary(), pos_integer()) :: {:ok, [binary()], t()} | {:error, :frame_too_large}
  def feed(state, data, limit), do: split(state, data, limit, [])

  defp split(state, data, limit, frames) do
    case :binary.match(data, "\n") do
      :nomatch ->
        if state.bytes + byte_size(data) > limit do
          {:error, :frame_too_large}
        else
          {:ok, Enum.reverse(frames), stash(state, data)}
        end

      {offset, 1} when state.bytes + offset > limit ->
        {:error, :frame_too_large}

      {offset, 1} ->
        <<part::binary-size(^offset), _newline, rest::binary>> = data
        pieces = Enum.reverse(state.chunks, Enum.reverse([part | state.pending]))
        frame = pieces |> IO.iodata_to_binary() |> String.trim()
        frames = if frame == "", do: frames, else: [frame | frames]
        split(%__MODULE__{}, rest, limit, frames)
    end
  end

  defp stash(state, ""), do: state

  defp stash(state, data) do
    pending = [detach(data) | state.pending]
    bytes = state.bytes + byte_size(data)
    pending_bytes = state.pending_bytes + byte_size(data)

    if pending_bytes >= 4_096 do
      block = pending |> Enum.reverse() |> IO.iodata_to_binary()
      %{state | chunks: [block | state.chunks], pending: [], pending_bytes: 0, bytes: bytes}
    else
      %{state | pending: pending, pending_bytes: pending_bytes, bytes: bytes}
    end
  end

  defp detach(data) do
    if :binary.referenced_byte_size(data) > max(4_096, 2 * byte_size(data)), do: :binary.copy(data), else: data
  end
end
