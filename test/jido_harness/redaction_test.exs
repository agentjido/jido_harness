defmodule Jido.Harness.RedactionTest do
  use ExUnit.Case, async: true

  alias Jido.Harness.Redaction

  test "redacts sensitive fields and embedded credential values without altering usage" do
    secret = "fixture-secret-value"

    value = %{
      "authorization" => "Bearer #{secret}",
      "nested" => %{
        "api-key" => secret,
        "message" => "value=#{secret}",
        "responseHeaders" => %{
          "set-cookie" => "session=opaque-cookie-value; HttpOnly",
          "content-type" => "application/json"
        }
      },
      "input_tokens" => 42,
      "header" => "Bearer another-secret"
    }

    assert %{
             "authorization" => "[REDACTED]",
             "nested" => %{
               "api-key" => "[REDACTED]",
               "message" => "value=[REDACTED]",
               "responseHeaders" => %{
                 "set-cookie" => "[REDACTED]",
                 "content-type" => "application/json"
               }
             },
             "input_tokens" => 42,
             "header" => "Bearer [REDACTED]"
           } = Redaction.redact(value, [secret])
  end

  test "a bearer token is redacted in any case" do
    for word <- ["Bearer", "bearer", "BEARER", "bEaReR"] do
      assert Redaction.redact("x: #{word} abc.def, next") == "x: Bearer [REDACTED], next"
    end

    assert Redaction.redact("forbearer abc") == "forbearer abc"
  end

  test "megabytes without a token take no noticeable time" do
    image = String.duplicate("iVBORw0K", 250_000)
    {microseconds, redacted} = :timer.tc(fn -> Redaction.redact(%{"data" => image}) end)

    assert redacted == %{"data" => image}
    assert microseconds < 1_000_000
  end
end
