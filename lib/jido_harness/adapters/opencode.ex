defmodule Jido.Harness.Adapters.OpenCode do
  @moduledoc "OpenCode CLI adapter."
  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{
    AdapterSpec,
    Adapters.CLIStream,
    Adapters.Helpers,
    Adapters.JSONMapper,
    Capabilities,
    Error,
    RunRequest
  }

  @provider_options [:cli_path, :agent, :title, :attach, :fork, :continue, :thinking, :extra_args]
  @reserved_args [
    "--model",
    "--session",
    "--variant",
    "--file",
    "--agent",
    "--title",
    "--attach",
    "--fork",
    "--continue",
    "--thinking",
    "--auto",
    "--format"
  ]

  @impl true
  def spec do
    %AdapterSpec{
      provider: :opencode,
      name: "OpenCode",
      executable: "opencode",
      docs_url: "https://opencode.ai/docs",
      capabilities: %Capabilities{streaming?: true, native_cancel?: true},
      normalized_options: [:model, :session_id, :approval_mode, :attachments, :reasoning_effort],
      normalized_values: %{approval_mode: [:default, :prompt, :auto_approve]},
      provider_options: @provider_options,
      install: %{npm: "opencode-ai"}
    }
  end

  @impl true
  def run(%RunRequest{} = request, context) do
    options = Helpers.provider_options(request.provider_options, @provider_options)

    with :ok <- validate_options(request, options),
         {:ok, argv} <- build_argv(request, options) do
      executable = options[:cli_path] || Helpers.cli_path(context.config, spec().executable)
      CLIStream.run(:opencode, request, context, executable, argv, &JSONMapper.map(:opencode, &1))
    end
  end

  @impl true
  def status(config),
    do:
      Helpers.status(:opencode, spec().executable, ["OPENCODE_API_KEY", "ZAI_API_KEY"], config,
        capabilities: spec().capabilities
      )

  @impl true
  def install(_config, options), do: Helpers.install_npm(:opencode, "opencode-ai", options)

  @impl true
  def cancel(run_id, _context), do: Helpers.cancel_cli_run(run_id)

  @doc false
  def build_argv(request, options) do
    with {:ok, extra_args} <- extra_args(options[:extra_args]) do
      argv =
        ["run"] ++
          pair("--model", request.model) ++
          pair("--session", request.session_id) ++
          pair("--variant", request.reasoning_effort) ++
          repeat("--file", request.attachments) ++
          pair("--agent", options[:agent]) ++
          pair("--title", options[:title]) ++
          pair("--attach", options[:attach]) ++
          flag("--fork", options[:fork]) ++
          flag("--continue", options[:continue]) ++
          flag("--thinking", options[:thinking]) ++
          approval(request.approval_mode) ++
          ["--format", "json"] ++ extra_args ++ [request.prompt]

      {:ok, argv}
    end
  end

  defp validate_options(%{approval_mode: :auto_edit}, _options),
    do:
      {:error,
       Error.validation("OpenCode cannot represent :auto_edit approval mode",
         provider: :opencode,
         details: %{field: :approval_mode}
       )}

  defp validate_options(%{session_id: session_id}, %{continue: true}) when is_binary(session_id),
    do: {:error, Error.validation("OpenCode session_id and provider continue cannot be combined", provider: :opencode)}

  defp validate_options(_request, _options), do: :ok

  defp approval(:auto_approve), do: ["--auto"]
  defp approval(_mode), do: []
  defp flag(flag, true), do: [flag]
  defp flag(_flag, _value), do: []
  defp repeat(_flag, nil), do: []
  defp repeat(flag, values), do: Enum.flat_map(values, &pair(flag, &1))
  defp extra_args(nil), do: {:ok, []}

  defp extra_args(args) when is_list(args) do
    cond do
      not Enum.all?(args, &is_binary/1) ->
        extra_args(:invalid)

      shadow = Enum.find(args, &reserved_arg?(&1, @reserved_args)) ->
        {:error,
         Error.validation("OpenCode extra_args cannot shadow managed options",
           provider: :opencode,
           details: %{argument: shadow}
         )}

      true ->
        {:ok, args}
    end
  end

  defp extra_args(_args),
    do: {:error, Error.validation("OpenCode extra_args must be a list of strings", provider: :opencode)}

  defp pair(_flag, nil), do: []
  defp pair(flag, value), do: [flag, to_string(value)]

  defp reserved_arg?(argument, reserved) do
    argument in reserved or Enum.any?(reserved, &String.starts_with?(argument, &1 <> "="))
  end
end
