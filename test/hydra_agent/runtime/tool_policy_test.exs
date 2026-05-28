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
        shell_env_allowlist: ["MIX_ENV", "HOME"],
        requires_approval: true
      })

    assert changeset.valid?
  end

  test "rejects invalid shell env allowlists" do
    changeset =
      ToolPolicy.changeset(%ToolPolicy{}, %{
        workspace_id: 1,
        allowed_tools: ["shell_command"],
        side_effect_classes: ["shell"],
        shell_env_allowlist: ["plain-secret"]
      })

    refute changeset.valid?

    assert {"contains invalid environment names: plain-secret", _meta} =
             changeset.errors[:shell_env_allowlist]
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

  test "rejects unknown registered tools" do
    changeset =
      ToolPolicy.changeset(%ToolPolicy{}, %{
        workspace_id: 1,
        allowed_tools: ["made_up_tool"]
      })

    refute changeset.valid?
    assert {"contains unknown values: made_up_tool", _meta} = changeset.errors[:allowed_tools]
  end

  test "rejects failed bundle expansion metadata" do
    changeset =
      ToolPolicy.changeset(%ToolPolicy{}, %{
        workspace_id: 1,
        metadata: %{"unknown_tool_bundles" => ["made_up_bundle"]}
      })

    refute changeset.valid?
    assert {"contains unknown tool bundles: made_up_bundle", _meta} = changeset.errors[:metadata]
  end

  test "dangerous side effects must require approval" do
    changeset =
      ToolPolicy.changeset(%ToolPolicy{}, %{
        workspace_id: 1,
        allowed_tools: ["mcp_call"],
        side_effect_classes: ["mcp"],
        requires_approval: false
      })

    refute changeset.valid?

    assert {"must be true for dangerous side effects", _meta} =
             changeset.errors[:requires_approval]
  end
end
