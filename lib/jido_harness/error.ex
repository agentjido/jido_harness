defmodule Jido.Harness.Error do
  @moduledoc "A provider-neutral harness error."

  @type category :: :validation | :configuration | :provider | :process | :execution | :timeout | :cancelled | :internal
  @type t :: %__MODULE__{
          category: category(),
          provider: atom() | nil,
          run_id: String.t() | nil,
          message: String.t(),
          details: map(),
          cause: term()
        }

  defexception category: :internal,
               provider: nil,
               run_id: nil,
               message: "harness error",
               details: %{},
               cause: nil

  @spec new(category(), String.t(), keyword() | map()) :: t()
  @doc "Builds a normalized harness error."
  def new(category, message, attrs \\ %{}) when is_atom(category) and is_binary(message) do
    attrs = Map.new(attrs)
    struct!(__MODULE__, Map.merge(attrs, %{category: category, message: message}))
  end

  @spec validation(String.t(), keyword() | map()) :: t()
  @doc "Builds a validation-category error."
  def validation(message, attrs \\ %{}), do: new(:validation, message, attrs)

  @spec execution(String.t(), keyword() | map()) :: t()
  @doc "Builds an execution-category error."
  def execution(message, attrs \\ %{}), do: new(:execution, message, attrs)

  @impl true
  @doc false
  def message(%__MODULE__{} = error) do
    prefix = if error.provider, do: "#{error.provider}: ", else: ""
    prefix <> error.message
  end
end
