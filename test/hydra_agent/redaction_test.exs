defmodule HydraAgent.RedactionTest do
  use ExUnit.Case, async: true

  alias HydraAgent.Redaction

  test "recursively redacts sensitive keys and truncates long strings" do
    redacted =
      Redaction.redact(%{
        "api_key" => "secret",
        "nested" => [%{"token" => "secret", "safe" => String.duplicate("x", 600)}]
      })

    assert redacted["api_key"] == "[REDACTED]"
    assert [%{"token" => "[REDACTED]", "safe" => safe}] = redacted["nested"]
    assert byte_size(safe) < 530
    assert String.ends_with?(safe, "...[TRUNCATED]")
  end
end
