defmodule Jido.Harness.Actions.Helpers do
  @moduledoc false

  @spec to_keyword(map() | keyword() | nil) :: {:ok, keyword()} | {:error, term()}
  def to_keyword(nil), do: {:ok, []}
  def to_keyword(opts) when is_list(opts), do: {:ok, opts}

  def to_keyword(opts) when is_map(opts) do
    Enum.reduce_while(opts, {:ok, []}, fn
      {key, value}, {:ok, acc} when is_atom(key) ->
        {:cont, {:ok, [{key, value} | acc]}}

      {key, value}, {:ok, acc} when is_binary(key) ->
        case to_existing_atom(key) do
          {:ok, atom_key} ->
            {:cont, {:ok, [{atom_key, value} | acc]}}

          :error ->
            {:halt, {:error, {:invalid_option_key, key}}}
        end

      {key, _value}, _acc ->
        {:halt, {:error, {:invalid_option_key, key}}}
    end)
    |> case do
      {:ok, keyword} -> {:ok, Enum.reverse(keyword)}
      {:error, _} = error -> error
    end
  end

  def to_keyword(_opts), do: {:error, :invalid_options}

  defp to_existing_atom(value) when is_binary(value) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError -> :error
  end
end
