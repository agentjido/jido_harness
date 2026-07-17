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
end
