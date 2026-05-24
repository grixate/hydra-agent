defmodule HydraAgent.Runtime.ToolPolicyTest do
  use ExUnit.Case, async: true

  alias HydraAgent.Runtime.ToolPolicy

  test "accepts explicit network allowlists" do
    changeset =
      ToolPolicy.changeset(%ToolPolicy{}, %{
        workspace_id: 1,
        allowed_tools: ["http_fetch"],
        side_effect_classes: ["read_only", "network"],
        network_allowlist: ["example.com", "*.hex.pm"],
        requires_approval: true
      })

    assert changeset.valid?
  end

  test "accepts explicit shell allowlists" do
    changeset =
      ToolPolicy.changeset(%ToolPolicy{}, %{
        workspace_id: 1,
        allowed_tools: ["shell_command"],
        side_effect_classes: ["read_only", "shell"],
        shell_allowlist: ["git status", "mix test"],
        requires_approval: true
      })

    assert changeset.valid?
  end

  test "accepts explicit filesystem allowlists and denylists" do
    changeset =
      ToolPolicy.changeset(%ToolPolicy{}, %{
        workspace_id: 1,
        allowed_tools: ["file_read", "file_write"],
        side_effect_classes: ["read_only", "workspace_write"],
        filesystem_allowlist: ["lib", "test"],
        filesystem_denylist: ["config/prod.exs"],
        requires_approval: true
      })

    assert changeset.valid?
  end

  test "rejects unknown side effect classes" do
    changeset =
      ToolPolicy.changeset(%ToolPolicy{}, %{
        workspace_id: 1,
        side_effect_classes: ["telepathy"]
      })

    refute changeset.valid?
    assert {"contains unknown values: telepathy", _meta} = changeset.errors[:side_effect_classes]
  end
end
