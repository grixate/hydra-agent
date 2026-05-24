defmodule HydraAgent.Tools.RegistryTest do
  use ExUnit.Case, async: true

  alias HydraAgent.Tools.Registry

  test "built-in tools expose authorization metadata" do
    specs = Registry.all()

    assert Enum.any?(specs, &(&1.name == "knowledge_search"))

    assert Enum.any?(
             specs,
             &(&1.name == "source_ingest" and &1.side_effect_class == "workspace_write")
           )

    assert Enum.any?(
             specs,
             &(&1.name == "artifact_record" and &1.side_effect_class == "workspace_write")
           )

    assert Enum.any?(specs, &(&1.name == "http_fetch" and &1.side_effect_class == "network"))
    assert Enum.any?(specs, &(&1.name == "shell_command" and &1.side_effect_class == "shell"))
    assert Enum.any?(specs, &(&1.name == "file_read" and &1.side_effect_class == "read_only"))

    assert Enum.any?(
             specs,
             &(&1.name == "file_write" and &1.side_effect_class == "workspace_write")
           )

    for spec <- specs do
      assert is_binary(spec.name)
      assert is_binary(spec.side_effect_class)
      assert is_integer(spec.timeout_ms)
      assert is_boolean(spec.approval_sensitive)
      assert is_boolean(spec.parallel_safe)
      assert is_map(spec.input_schema)
      assert is_map(spec.output_schema)
    end
  end

  test "unknown tool execution fails closed" do
    assert {:error, %{"reason" => "unknown_tool", "tool_name" => "missing"}} =
             Registry.execute("missing", %{}, %{})
  end

  test "parallel-safe names only include explicitly safe tools" do
    names = Registry.parallel_safe_names()

    assert "knowledge_search" in names
    assert "noop" in names
    refute "file_write" in names
    refute "http_fetch" in names
    refute "shell_command" in names
  end

  test "noop is bounded and side-effect free" do
    assert {:ok, %{"input" => %{"x" => 1}}} = Registry.execute("noop", %{"x" => 1}, %{})
  end
end
