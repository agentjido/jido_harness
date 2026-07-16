for provider <- [:amp, :claude, :codex, :gemini, :opencode, :grok, :zai] do
  defmodule Module.concat([Jido.Harness.Integration, Macro.camelize(Atom.to_string(provider)), ContractTest]) do
    use Jido.Harness.IntegrationCase, provider: provider
    harness_contract_tests()
  end
end
