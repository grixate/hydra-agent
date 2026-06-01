defmodule HydraAgentWeb.ToolPolicyControllerTest do
  use HydraAgentWeb.ConnCase

  import HydraAgent.RuntimeFixtures

  test "creates policies from tool bundles", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-tool-bundles-api"})

    conn =
      post(conn, ~p"/api/v1/workspaces/#{workspace.id}/tool_policies", %{
        tool_bundles: ["files_read"],
        requires_approval: false,
        shell_env_allowlist: ["HYDRA_TEST_FLAG"],
        filesystem_allowlist: ["lib"]
      })

    assert %{
             "data" => %{
               "allowed_tools" => allowed_tools,
               "side_effect_classes" => ["read_only"],
               "requires_approval" => false,
               "shell_env_allowlist" => ["HYDRA_TEST_FLAG"],
               "tool_bundles" => ["files_read"]
             }
           } = json_response(conn, 201)

    assert Enum.sort(allowed_tools) == ["file_list", "file_read"]
  end

  test "workspace-scoped policy show rejects foreign policy ids", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-tool-policy-scope"})
    other_workspace = workspace_fixture(%{name: "Other Ops", slug: "other-ops-tool-policy-scope"})
    policy = tool_policy_fixture(workspace)

    assert_error_sent 404, fn ->
      get(conn, ~p"/api/v1/workspaces/#{other_workspace.id}/tool_policies/#{policy.id}")
    end
  end

  test "flags risky but approvable policy posture warnings", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-tool-policy-warnings"})

    assert {:error, changeset} =
             HydraAgent.Runtime.create_tool_policy(%{
               workspace_id: workspace.id,
               allowed_tools: ["shell_command"],
               side_effect_classes: ["shell"],
               shell_allowlist: ["*"],
               requires_approval: false
             })

    assert {"must be true for dangerous side effects", _meta} =
             changeset.errors[:requires_approval]

    {:ok, policy} =
      HydraAgent.Runtime.create_tool_policy(%{
        workspace_id: workspace.id,
        allowed_tools: ["shell_command"],
        side_effect_classes: ["shell"],
        shell_allowlist: ["*"]
      })

    conn = get(conn, ~p"/api/v1/workspaces/#{workspace.id}/tool_policies/#{policy.id}")

    assert %{
             "data" => %{
               "warnings" => warnings
             }
           } = json_response(conn, 200)

    refute "dangerous side effects can run without approval" in warnings
    assert "shell allowlist permits every command" in warnings
  end

  test "rejects unknown policy bundles", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-tool-bundles-api-reject"})

    conn =
      post(conn, ~p"/api/v1/workspaces/#{workspace.id}/tool_policies", %{
        tool_bundles: ["missing_bundle"]
      })

    assert %{"errors" => %{"metadata" => ["contains unknown tool bundles: missing_bundle"]}} =
             json_response(conn, 422)
  end
end
