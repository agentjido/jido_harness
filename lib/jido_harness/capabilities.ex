defmodule Jido.Harness.Capabilities do
  @moduledoc "Normalized provider capabilities."

  defstruct streaming?: true,
            tool_calls?: false,
            tool_results?: false,
            thinking?: false,
            resume?: false,
            usage?: false,
            file_changes?: false,
            native_cancel?: false

  @type t :: %__MODULE__{
          streaming?: boolean(),
          tool_calls?: boolean(),
          tool_results?: boolean(),
          thinking?: boolean(),
          resume?: boolean(),
          usage?: boolean(),
          file_changes?: boolean(),
          native_cancel?: boolean()
        }
end
