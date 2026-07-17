defmodule Jido.Harness.RedactionTest do
  use ExUnit.Case, async: true

  alias Jido.Harness.Redaction

  test "redacts sensitive fields and embedded credential values without altering usage" do
    secret = "fixture-secret-value"

    value = %{
      "authorization" => "Bearer #{secret}",
      "nested" => %{"api-key" => secret, "message" => "value=#{secret}"},
      "input_tokens" => 42,
      "header" => "Bearer another-secret"
    }

    assert %{
             "authorization" => "[REDACTED]",
             "nested" => %{"api-key" => "[REDACTED]", "message" => "value=[REDACTED]"},
             "input_tokens" => 42,
             "header" => "Bearer [REDACTED]"
           } = Redaction.redact(value, [secret])
  end
end
