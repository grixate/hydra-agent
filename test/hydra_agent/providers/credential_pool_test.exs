defmodule HydraAgent.Providers.CredentialPoolTest do
  use HydraAgent.DataCase

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.{Providers, Runtime}

  test "provider calls select and account for credential pool items" do
    workspace = workspace_fixture()

    {:ok, pool} =
      Runtime.create_credential_pool(%{
        workspace_id: workspace.id,
        name: "Mock Pool",
        env_vars: ["MOCK_PRIMARY_KEY", "MOCK_SECONDARY_KEY"]
      })

    {:ok, provider} =
      Runtime.create_provider(%{
        workspace_id: workspace.id,
        credential_pool_id: pool.id,
        name: "mock",
        kind: "mock",
        model: "mock-model"
      })

    assert {:ok, response} =
             Providers.chat(provider, %{"messages" => [%{"role" => "user", "content" => "hello"}]})

    assert response["route"]["credential_pool_id"] == pool.id
    assert response["route"]["api_key_env"] in ["MOCK_PRIMARY_KEY", "MOCK_SECONDARY_KEY"]

    items = Runtime.list_credential_pool_items(pool.id)
    assert Enum.sum(Enum.map(items, & &1.request_count)) == 1
  end

  test "failed credential items are cooled down and the next item is selected" do
    workspace = workspace_fixture()

    {:ok, pool} =
      Runtime.create_credential_pool(%{
        workspace_id: workspace.id,
        name: "Fallback Pool",
        env_vars: ["MOCK_FIRST_KEY", "MOCK_SECOND_KEY"]
      })

    [first | _rest] = Runtime.list_credential_pool_items(pool.id)
    {:ok, _failed} = Runtime.mark_credential_pool_item_failed(first, %{"status" => 429})

    selected = Runtime.next_credential_pool_item(pool)
    assert selected.env_var != first.env_var
  end
end
