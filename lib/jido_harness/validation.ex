defmodule Jido.Harness.Validation do
  @moduledoc false

  alias Jido.Harness.Error

  @spec await_timeout(term()) :: :ok | {:error, Error.t()}
  def await_timeout(:infinity), do: :ok
  def await_timeout(timeout) when is_integer(timeout) and timeout >= 0, do: :ok

  def await_timeout(timeout) do
    {:error,
     Error.validation("await timeout must be :infinity or a non-negative integer", details: %{timeout: timeout})}
  end

  @spec keyword_options(term()) :: {:ok, keyword()} | {:error, Error.t()}
  def keyword_options(options) when is_list(options) do
    if Keyword.keyword?(options),
      do: {:ok, options},
      else: {:error, Error.validation("options must be a keyword list")}
  end

  def keyword_options(_options), do: {:error, Error.validation("options must be a keyword list")}

  @spec options_map(term()) :: {:ok, map()} | {:error, Error.t()}
  def options_map(options) do
    with {:ok, options} <- keyword_options(options), do: {:ok, Map.new(options)}
  end

  @spec attributes_map(term(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def attributes_map(attributes, _name) when is_map(attributes), do: {:ok, attributes}

  def attributes_map(attributes, name) when is_list(attributes) do
    if Enum.all?(attributes, &match?({_, _}, &1)),
      do: {:ok, Map.new(attributes)},
      else: {:error, Error.validation("#{name} must be a map or key-value list")}
  end

  def attributes_map(_attributes, name), do: {:error, Error.validation("#{name} must be a map or key-value list")}
end
