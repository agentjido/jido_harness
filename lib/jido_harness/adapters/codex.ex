defmodule Jido.Harness.Adapters.Codex do
  @moduledoc "Codex CLI adapter using non-interactive exec JSONL."
  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{AdapterSpec, Adapters.CLIArgs, Adapters.CLIMapper, Adapters.CLIStream}
  alias Jido.Harness.{Adapters.CodexCompatibility, Adapters.CodexEnvironment, Adapters.Helpers}
  alias Jido.Harness.{Capabilities, Error, RunRequest}
  alias Jido.Harness.StructuredOutput.{SchemaWorkspace, Stream, WorkspaceGuard}

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
        native_cancel?: true,
        structured_output?: true
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
        :reasoning_effort,
        :structured_output
      ],
      normalized_values: %{reasoning_effort: [nil, :low, :medium, :high, :xhigh]},
      provider_options: @provider_options,
      install: %{npm: "@openai/codex"}
    }
  end

  @impl true
  def run(%RunRequest{} = request, context) do
    options = Helpers.provider_options(request.provider_options, @provider_options)

    with :ok <- validate_options(request, options),
         executable = options[:cli_path] || Helpers.cli_path(context.config, spec().executable) do
      if request.structured_output do
        run_structured(request, context, executable, options)
      else
        with {:ok, argv} <- build_argv(request, options) do
          request = %{request | env: Helpers.merge_env(request, context.config)}
          CLIStream.run(:codex, request, context, executable, argv, &CLIMapper.codex/1)
        end
      end
    end
  rescue
    exception ->
      if request.structured_output do
        structured_error(:structured_execution_setup_failed)
      else
        {:error,
         Error.validation("invalid Codex options", provider: :codex, details: %{message: Exception.message(exception)})}
      end
  end

  @impl true
  def status(config) do
    with {:ok, status} <-
           Helpers.status(:codex, spec().executable, [], config,
             cli_path_env: "CODEX_PATH",
             capabilities: spec().capabilities,
             probe_env: CodexEnvironment.cached_subscription(),
             probe_env_mode: :replace
           ) do
      status =
        if status.installed and status.compatible do
          with :ok <- CodexCompatibility.validate(status.executable, %{}),
               true <- CodexCompatibility.subscription_authenticated?(status.executable) do
            %{status | authenticated: true}
          else
            false -> %{status | authenticated: false, error: :cached_subscription_authentication_missing}
            {:error, error} -> %{status | compatible: false, authenticated: :unknown, error: error}
          end
        else
          status
        end

      {:ok, Jido.Harness.ProviderStatus.finalize(status)}
    end
  end

  @impl true
  def install(_config, options), do: Helpers.install_npm(:codex, "@openai/codex", options)

  @impl true
  def cancel(run_id, _context), do: Helpers.cancel_cli_run(run_id)

  @doc false
  def build_argv(request, options, schema_path \\ nil) do
    common =
      ["exec", "--json"] ++
        structured_args(request, schema_path) ++
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

  defp run_structured(request, context, executable, options) do
    with :ok <- validate_structured_options(request, options),
         :ok <- CodexCompatibility.validate(executable, context),
         {:ok, workspace} <- SchemaWorkspace.open(request.structured_output),
         {:ok, guard} <- start_guard(workspace) do
      prepared = isolate(request, workspace.working_directory)
      {:ok, argv} = build_argv(prepared, options, workspace.schema_path)

      case CLIStream.run(:codex, prepared, context, executable, argv, &CLIMapper.codex/1) do
        {:ok, stream} -> {:ok, Stream.wrap(stream, request.structured_output, guard)}
        _error -> close_guard(guard, :provider_start_failed)
      end
    end
  end

  defp start_guard(workspace) do
    case WorkspaceGuard.start(workspace, self()) do
      {:ok, guard} ->
        {:ok, guard}

      {:error, _reason} ->
        _ = SchemaWorkspace.close(workspace)
        structured_error(:schema_guard_failed)
    end
  end

  defp close_guard(guard, failure_kind) do
    :ok = WorkspaceGuard.close(guard)
    structured_error(failure_kind)
  end

  defp validate_structured_options(request, options) do
    cond do
      request.provider_session_id -> unsupported_structured(:provider_session_id)
      options[:resume_last] -> unsupported_structured(:resume_last)
      request.add_dirs not in [nil, []] -> unsupported_structured(:add_dirs)
      request.attachments != [] -> unsupported_structured(:attachments)
      request.env != %{} -> unsupported_structured(:env)
      request.sandbox_mode not in [:default, :read_only] -> unsupported_structured(:sandbox_mode)
      request.approval_mode not in [:default, :auto_approve] -> unsupported_structured(:approval_mode)
      Enum.any?(Map.keys(options), &(&1 != :cli_path)) -> unsupported_structured(:provider_options)
      true -> :ok
    end
  end

  defp isolate(request, working_directory) do
    %{
      request
      | cwd: working_directory,
        env: CodexEnvironment.cached_subscription(),
        env_mode: :replace,
        provider_session_id: nil,
        add_dirs: nil,
        attachments: [],
        approval_mode: :auto_approve,
        sandbox_mode: :read_only
    }
  end

  defp structured_args(%{structured_output: nil}, _schema_path), do: []

  defp structured_args(%{structured_output: %{}}, schema_path) when is_binary(schema_path) do
    [
      "--ephemeral",
      "--ignore-user-config",
      "--ignore-rules",
      "--output-schema",
      schema_path,
      "--skip-git-repo-check"
    ] ++
      CLIArgs.config("project_doc_max_bytes", 0) ++
      ["--config", "project_doc_fallback_filenames=[]"] ++
      CLIArgs.config("shell_environment_policy.inherit", "none") ++
      CLIArgs.config("features.web_search_request", false) ++
      CLIArgs.config("sandbox_workspace_write.network_access", false)
  end

  defp unsupported_structured(field),
    do:
      {:error,
       Error.validation("option is incompatible with isolated structured output",
         provider: :codex,
         details: %{field: field, failure_kind: :incompatible_option}
       )}

  defp structured_error(kind),
    do:
      {:error,
       Error.execution("structured-output execution could not start",
         provider: :codex,
         details: %{failure_kind: kind}
       )}

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
