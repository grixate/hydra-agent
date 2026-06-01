defmodule HydraAgentWeb.MemoryControllerTest do
  use HydraAgentWeb.ConnCase

  import HydraAgent.RuntimeFixtures

  test "creates draft memory proposals for an agent", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-memory-api"})
    agent = agent_fixture(workspace, %{knowledge_scopes: ["workspace"]})
    run = run_fixture(workspace, %{supervisor_agent_id: agent.id})

    conn =
      post(conn, ~p"/api/v1/agents/#{agent.id}/memory/proposals", %{
        title: "Keep evidence visible",
        body: "Mission detail should show durable events.",
        run_id: run.id,
        evidence: ["run_events"]
      })

    assert %{
             "data" => %{
               "type_key" => "memory",
               "status" => "draft",
               "created_by_agent_id" => agent_id,
               "attributes" => %{"proposal_status" => "pending"},
               "provenance" => %{
                 "kind" => "memory_proposal",
                 "run_id" => run_id,
                 "evidence" => ["run_events"]
               }
             }
           } = json_response(conn, 201)

    assert agent_id == agent.id
    assert run_id == run.id
  end

  test "lists, promotes, and rejects memory proposals", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-memory-review-api"})
    agent = agent_fixture(workspace, %{knowledge_scopes: ["workspace"]})

    {:ok, promote_me} =
      HydraAgent.Memory.propose_node(agent, %{
        title: "Promote me",
        body: "This memory is useful."
      })

    {:ok, reject_me} =
      HydraAgent.Memory.propose_node(agent, %{
        title: "Reject me",
        body: "This memory is too vague."
      })

    conn = get(conn, ~p"/api/v1/workspaces/#{workspace.id}/memory/proposals")

    assert %{"data" => proposals} = json_response(conn, 200)
    assert Enum.map(proposals, & &1["id"]) |> Enum.sort() == [promote_me.id, reject_me.id]

    promote_conn =
      post(conn, ~p"/api/v1/memory/proposals/#{promote_me.id}/promote", %{
        reason: "Verified"
      })

    assert %{
             "data" => %{
               "id" => promoted_id,
               "status" => "active",
               "attributes" => %{"proposal_status" => "promoted"}
             }
           } = json_response(promote_conn, 200)

    reject_conn =
      post(conn, ~p"/api/v1/memory/proposals/#{reject_me.id}/reject", %{
        reason: "Too vague"
      })

    assert %{
             "data" => %{
               "id" => rejected_id,
               "status" => "archived",
               "attributes" => %{"proposal_status" => "rejected"}
             }
           } = json_response(reject_conn, 200)

    assert promoted_id == promote_me.id
    assert rejected_id == reject_me.id
  end
end
