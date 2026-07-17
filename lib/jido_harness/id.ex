defmodule Jido.Harness.ID do
  @moduledoc false

  @spec generate(String.t()) :: String.t()
  def generate(prefix) do
    suffix = :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
    prefix <> "_" <> suffix
  end
end
