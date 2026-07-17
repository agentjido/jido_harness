defmodule Jido.Harness.Adapters.Codex do
  @moduledoc "Codex CLI adapter using non-interactive exec JSONL."
  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{AdapterSpec, Adapters.CLIArgs, Adapters.CLIMapper, Adapters.CLIStream}
  alias Jido.Harness.{Adapters.Helpers, Capabilities, Error, RunRequest}

  @provider_options [
    :cli_path,
    :resume_last,
    :skip_git_repo_check,
    :web_search_enabled,
    :network_access_enabled,
    :model_reasoning_summary
  ]

  @impl true
  def spec do
    %AdapterSpec{
      provider: :codex,
      name: "Codex",
      executable: "codex",
      docs_url: "https://github.com/openai/codex",
      capabilities: %Capabilities{
        streaming?: true,
        tool_calls?: true,
        tool_results?: true,
        thinking?: true,
        resume?: true,
        usage?: true,
        file_changes?: true,
        native_cancel?: true
      },
      default_session_transport: :exec_jsonl_resume,
      session_transports: [Jido.Harness.SessionTransportSpec.managed(:exec_jsonl_resume, %{multimodal: :managed})],
      normalized_options: [
        :model,
        :provider_session_id,
        :system_prompt,
        :add_dirs,
        :approval_mode,
        :sandbox_mode,
        :attachments,
        :reasoning_effort
      ],
      provider_options: @provider_options,
      install: %{npm: "@openai/codex"}
    }
  end

  @impl true
  def run(%RunRequest{} = request, context) do
    options = Helpers.provider_options(request.provider_options, @provider_options)

    with :ok <- validate_options(request, options),
         {:ok, argv} <- build_argv(request, options) do
      request = %{request | env: Helpers.merge_env(request, context.config)}
      executable = options[:cli_path] || Helpers.cli_path(context.config, spec().executable)
      CLIStream.run(:codex, request, context, executable, argv, &CLIMapper.codex/1)
    end
  rescue
    exception ->
      {:error,
       Error.validation("invalid Codex options", provider: :codex, details: %{message: Exception.message(exception)})}
  end

  @impl true
  def status(config),
    do:
      Helpers.status(:codex, spec().executable, ["OPENAI_API_KEY", "CODEX_API_KEY"], config,
        cli_path_env: "CODEX_PATH",
        capabilities: spec().capabilities
      )

  @impl true
  def install(_config, options), do: Helpers.install_npm(:codex, "@openai/codex", options)

  @impl true
  def cancel(run_id, _context), do: Helpers.cancel_cli_run(run_id)

  @doc false
  def build_argv(request, options) do
    common =
      ["exec", "--json"] ++
        CLIArgs.pair("--model", request.model) ++
        sandbox_args(request.sandbox_mode) ++
        CLIArgs.repeat("--add-dir", request.add_dirs) ++
        CLIArgs.flag("--skip-git-repo-check", options[:skip_git_repo_check]) ++
        approval_args(request.approval_mode) ++
        CLIArgs.config("developer_instructions", request.system_prompt) ++
        CLIArgs.config("model_reasoning_effort", request.reasoning_effort) ++
        CLIArgs.config("model_reasoning_summary", options[:model_reasoning_summary]) ++
        CLIArgs.config("features.web_search_request", options[:web_search_enabled]) ++
        CLIArgs.config("sandbox_workspace_write.network_access", options[:network_access_enabled]) ++
        CLIArgs.repeat("--image", request.attachments)

    invocation =
      cond do
        request.provider_session_id -> ["resume", request.provider_session_id, request.prompt]
        options[:resume_last] -> ["resume", "--last", request.prompt]
        true -> [request.prompt]
      end

    {:ok, common ++ invocation}
  end

  defp validate_options(%{provider_session_id: session_id}, %{resume_last: true}) when is_binary(session_id),
    do: {:error, Error.validation("Codex provider_session_id and resume_last cannot be combined", provider: :codex)}

  defp validate_options(_request, options) do
    cond do
      not optional_string?(options[:cli_path]) -> invalid(:cli_path, "a string")
      not optional_string?(options[:model_reasoning_summary]) -> invalid(:model_reasoning_summary, "a string")
      not optional_boolean?(options[:resume_last]) -> invalid(:resume_last, "a boolean")
      not optional_boolean?(options[:skip_git_repo_check]) -> invalid(:skip_git_repo_check, "a boolean")
      not optional_boolean?(options[:web_search_enabled]) -> invalid(:web_search_enabled, "a boolean")
      not optional_boolean?(options[:network_access_enabled]) -> invalid(:network_access_enabled, "a boolean")
      true -> :ok
    end
  end

  defp approval_args(:default), do: []
  defp approval_args(:prompt), do: CLIArgs.config("approval_policy", "on-request")
  defp approval_args(:auto_edit), do: CLIArgs.config("approval_policy", "on-failure")
  defp approval_args(:auto_approve), do: CLIArgs.config("approval_policy", "never")
  defp sandbox_args(:default), do: []
  defp sandbox_args(:read_only), do: ["--sandbox", "read-only"]
  defp sandbox_args(:workspace_write), do: ["--sandbox", "workspace-write"]
  defp sandbox_args(:unrestricted), do: ["--sandbox", "danger-full-access"]
  defp optional_string?(value), do: is_nil(value) or is_binary(value)
  defp optional_boolean?(value), do: is_nil(value) or is_boolean(value)
  defp invalid(field, expected), do: {:error, Error.validation("Codex #{field} must be #{expected}", provider: :codex)}
end
