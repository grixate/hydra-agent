defmodule HydraAgent.ApiCredentialsTest do
  use HydraAgent.DataCase, async: true

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.ApiCredentials

  test "tokens are returned once, scoped, permissioned, expiring, and revocable" do
    workspace = workspace_fixture(%{slug: "credential-workspace"})

    assert {:ok, %{token: raw, record: record}} =
             ApiCredentials.issue_token(%{
               name: "Read reports",
               workspace_id: workspace.id,
               permissions: ["read"],
               expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
             })

    assert String.starts_with?(raw, "hydra_")
    refute inspect(record) =~ raw

    assert {:ok, principal} = ApiCredentials.authenticate(raw, "GET", workspace.id)
    assert principal.workspace_id == workspace.id

    assert {:error, :workspace_scope_mismatch} =
             ApiCredentials.authenticate(raw, "GET", workspace.id + 1)

    assert {:error, :workspace_scope_required} = ApiCredentials.authenticate(raw, "GET", nil)

    assert {:error, :insufficient_permission} =
             ApiCredentials.authenticate(raw, "POST", workspace.id)

    assert :ok = ApiCredentials.revoke_by_prefix(record.token_prefix)
    assert {:error, :invalid_token} = ApiCredentials.authenticate(raw, "GET", workspace.id)
  end

  test "expired tokens cannot authenticate" do
    assert {:ok, %{token: raw}} =
             ApiCredentials.issue_token(%{
               name: "Expired token",
               permissions: ["read", "write"],
               expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
             })

    assert {:error, :invalid_token} = ApiCredentials.authenticate(raw, "GET", nil)
  end
end
