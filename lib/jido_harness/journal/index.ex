defmodule Jido.Harness.Journal.Index do
  @moduledoc false

  @record_interval 64
  @byte_interval 65_536

  @doc false
  @spec new(String.t()) :: map()
  def new(path) do
    %{
      path: path,
      bytes: 0,
      count: 0,
      first: nil,
      last: 0,
      checkpoints: :gb_trees.empty(),
      checkpoint_offset: 0,
      checkpoint_records: 0
    }
  end

  @doc false
  @spec append(map(), pos_integer() | nil, non_neg_integer()) :: map()
  def append(segment, nil, bytes), do: %{segment | bytes: segment.bytes + bytes}

  def append(segment, sequence, bytes) do
    checkpoint? =
      is_nil(segment.first) or segment.checkpoint_records >= @record_interval or
        segment.bytes - segment.checkpoint_offset >= @byte_interval

    segment =
      if checkpoint? do
        %{
          segment
          | checkpoints: :gb_trees.enter(sequence, segment.bytes, segment.checkpoints),
            checkpoint_offset: segment.bytes,
            checkpoint_records: 0
        }
      else
        segment
      end

    %{
      segment
      | bytes: segment.bytes + bytes,
        count: segment.count + 1,
        first: segment.first || sequence,
        last: sequence,
        checkpoint_records: segment.checkpoint_records + 1
    }
  end

  @doc false
  @spec offset(map(), non_neg_integer()) :: non_neg_integer()
  def offset(segment, cursor) do
    case :gb_trees.next(:gb_trees.iterator_from(cursor + 1, segment.checkpoints, :reversed)) do
      {_sequence, offset, _iterator} -> offset
      :none -> 0
    end
  end
end
