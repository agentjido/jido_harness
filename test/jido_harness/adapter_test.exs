defmodule Jido.Harness.AdapterTest do
  use ExUnit.Case, async: true

  alias Jido.Harness.{ACPAgentSpec, Error, Registry, RequestResolver}

  @profiles %{
    amp: {"amp-acp", :adapter, "amp-acp@0.9.0", []},
    claude: {"claude-agent-acp", :adapter, "@agentclientprotocol/claude-agent-acp@0.70.0", []},
    codex: {"codex-acp", :adapter, "@agentclientprotocol/codex-acp@1.6.2", []},
    gemini: {"gemini", :native, nil, ["--acp"]},
    grok: {"grok", :native, nil, ["agent", "stdio"]},
    kimi: {"kimi", :native, nil, ["acp"]},
    opencode: {"opencode", :native, nil, ["acp"]},
    pi: {"pi-acp", :adapter, "pi-acp@0.0.33", []},
    zai: {"claude-agent-acp", :adapter, "@agentclientprotocol/claude-agent-acp@0.70.0", []}
  }

  test "every built-in declares one validated ACP entry point" do
    Enum.each(@profiles, fn {provider, {executable, source, package, argv}} ->
      assert {:ok, spec} = Registry.spec(provider)

      assert %ACPAgentSpec{
               executable: ^executable,
               source: ^source,
               package: ^package,
               argv: ^argv
             } = spec.acp_agent
    end)
  end

  test "ACP profiles expose only options that their ACP entry point supports" do
    assert {:ok, request} =
             RequestResolver.resolve(:codex, %{
               prompt: "review",
               model: "gpt-5",
               approval_mode: :auto_approve,
               sandbox_mode: :read_only,
               attachments: []
             })

    assert request.model == "gpt-5"

    assert {:error, %Error{provider: :codex, details: %{field: :system_prompt}}} =
             RequestResolver.resolve(:codex, %{prompt: "review", system_prompt: "legacy direct flag"})

    assert {:error, %Error{provider: :grok, details: %{field: :model}}} =
             RequestResolver.resolve(:grok, %{prompt: "review", model: "legacy direct flag"})

    assert {:error, %Error{provider: :pi, details: %{field: :attachments}}} =
             RequestResolver.resolve(:pi, %{prompt: "review", attachments: ["image.png"]})
  end

  test "only ACP-specific Z.AI provider options remain" do
    assert {:ok, request} =
             RequestResolver.resolve(:zai, %{
               prompt: "review",
               provider_options: %{base_url: "https://api.z.ai/api/anthropic"}
             })

    assert request.provider_options.base_url == "https://api.z.ai/api/anthropic"

    assert {:error, %Error{details: %{key: :fallback_model}}} =
             RequestResolver.resolve(:zai, %{prompt: "review", provider_options: %{fallback_model: "legacy"}})
  end
end
