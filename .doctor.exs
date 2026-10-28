Mix.Task.run("compile")
Application.load(:jido_harness)
{:ok, package_modules} = :application.get_key(:jido_harness, :modules)

hidden_modules =
  Enum.filter(package_modules, fn module ->
    case Code.fetch_docs(module) do
      {:docs_v1, _, _, _, :hidden, _, _} -> true
      _other -> false
    end
  end)

%Doctor.Config{
  ignore_modules: hidden_modules,
  ignore_paths: [],
  min_module_doc_coverage: 50,
  min_module_spec_coverage: 0,
  min_overall_doc_coverage: 95,
  min_overall_moduledoc_coverage: 100,
  min_overall_spec_coverage: 75,
  exception_moduledoc_required: true,
  raise: true,
  reporter: Doctor.Reporters.Full,
  struct_type_spec_required: true,
  umbrella: false
}
