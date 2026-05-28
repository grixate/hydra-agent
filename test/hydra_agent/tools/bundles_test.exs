defmodule HydraAgent.Tools.BundlesTest do
  use ExUnit.Case, async: true

  alias HydraAgent.Tools.Bundles

  test "all bundles expand to registered tools and side-effect classes" do
    bundles = Bundles.all()

    assert Enum.any?(bundles, &(&1.name == "knowledge_read"))
    assert Enum.any?(bundles, &(&1.name == "terminal" and &1.requires_approval))
    assert Enum.any?(bundles, &(&1.name == "mcp" and &1.requires_approval))
    assert Enum.any?(bundles, &(&1.name == "browser" and &1.requires_approval))
    assert Enum.any?(bundles, &(&1.name == "vision" and not &1.requires_approval))
    assert Enum.any?(bundles, &(&1.name == "multi_model" and &1.requires_approval))

    for bundle <- bundles do
      assert is_binary(bundle.name)
      assert bundle.tools != []
      assert bundle.side_effect_classes != []
      assert is_boolean(bundle.requires_approval)
      assert is_boolean(bundle.approval_sensitive)
    end
  end

  test "expands multiple bundles into explicit policy grants" do
    assert {:ok, expanded} = Bundles.expand(["knowledge_read", "files_write"])

    assert expanded["tool_bundles"] == ["knowledge_read", "files_write"]
    assert "knowledge_search" in expanded["allowed_tools"]
    assert "file_write" in expanded["allowed_tools"]
    assert "read_only" in expanded["side_effect_classes"]
    assert "workspace_write" in expanded["side_effect_classes"]
    assert expanded["requires_approval"]
  end

  test "unknown bundles fail closed" do
    assert {:error, ["dream_tools"]} = Bundles.expand(["knowledge_read", "dream_tools"])
  end
end
