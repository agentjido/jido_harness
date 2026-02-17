defmodule Jido.Harness.Capabilities do
  @moduledoc """
  Describes the capabilities supported by a CLI agent adapter.
  """

  defstruct streaming?: true,
            tool_calls?: false,
            tool_results?: false,
            thinking?: false,
            resume?: false,
            usage?: false,
            file_changes?: false,
            cancellation?: false

  @type t :: %__MODULE__{
          streaming?: boolean(),
          tool_calls?: boolean(),
          tool_results?: boolean(),
          thinking?: boolean(),
          resume?: boolean(),
          usage?: boolean(),
          file_changes?: boolean(),
          cancellation?: boolean()
        }
end
