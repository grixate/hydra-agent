defmodule HydraAgent.MemoryTest do
  use ExUnit.Case, async: true

  alias HydraAgent.Memory

  test "formats recalled context compactly" do
    context =
      Memory.format_context(%{
        "nodes" => [
          %{
            "id" => 1,
            "type_key" => "decision",
            "title" => "Use OTP",
            "body" => "Supervise workers."
          }
        ]
      })

    assert context == "- [decision:1] Use OTP: Supervise workers."
  end

  test "formats empty memory as blank context" do
    assert Memory.format_context(%{"nodes" => []}) == ""
  end
end
