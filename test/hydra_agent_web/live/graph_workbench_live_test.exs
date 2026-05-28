defmodule HydraAgentWeb.GraphWorkbenchLiveTest do
  use HydraAgentWeb.ConnCase

  import HydraAgent.RuntimeFixtures
  import Phoenix.LiveViewTest

  alias HydraAgent.Knowledge

  test "renders empty graph workbench", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/control/graph")

    assert html =~ "Graph Workbench"
    assert html =~ "No workspaces yet."
  end

  test "falls back from malformed workspace params", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-graph-malformed-param"})

    {:ok, view, html} = live(conn, ~p"/control/graph?workspace_id=not-an-id")

    assert html =~ "Graph Workbench"
    assert render(view) =~ workspace.name
  end

  test "renders graph nodes and relationships with provenance labels", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-graph-workbench"})

    {:ok, decision} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "decision",
        title: "Use persisted timelines",
        body: "Run detail should render from stored events.",
        status: "active",
        provenance: %{"kind" => "operator_review"}
      })

    {:ok, claim} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "claim",
        title: "Timeline source",
        body: "Durable events rebuild the visible mission timeline.",
        status: "verified",
        provenance: %{"kind" => "memory_proposal"}
      })

    {:ok, relationship} =
      Knowledge.create_relationship(%{
        workspace_id: workspace.id,
        from_node_id: decision.id,
        to_node_id: claim.id,
        type_key: "supports",
        confidence: 0.9,
        provenance: %{"kind" => "operator_link", "run_id" => 42}
      })

    {:ok, view, _html} = live(conn, ~p"/control/graph?workspace_id=#{workspace.id}")

    assert has_element?(view, "#graph-workbench")
    assert has_element?(view, "#graph-node-#{decision.id}")
    assert has_element?(view, "#graph-node-#{claim.id}")
    assert has_element?(view, "#graph-relationship-#{relationship.id}")

    html = render(view)
    assert html =~ "Use persisted timelines"
    assert html =~ "Timeline source"
    assert html =~ "Use persisted timelines supports Timeline source"
    assert html =~ "supports Timeline source"
    assert html =~ "Use persisted timelines supports"
    assert html =~ ~s(&quot;run_id&quot;:42)
    assert html =~ "provenance operator_link"
    assert has_element?(view, ~s|a[href="/control/runs/42"]|, "Open source run")
  end

  test "filters graph by node type, status, relationship type, and provenance", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-graph-filter"})

    {:ok, decision} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "decision",
        title: "Keep graph evidence",
        body: "Operator-reviewed decision.",
        status: "active",
        provenance: %{"kind" => "loose_link"}
      })

    {:ok, memory} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "memory",
        title: "Evidence memory",
        body: "Promoted from a memory proposal.",
        status: "verified",
        provenance: %{"kind" => "operator_link"}
      })

    {:ok, claim} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "claim",
        title: "Evidence claim",
        body: "The memory supports this claim.",
        status: "active",
        provenance: %{"kind" => "operator_link"}
      })

    {:ok, supports} =
      Knowledge.create_relationship(%{
        workspace_id: workspace.id,
        from_node_id: memory.id,
        to_node_id: claim.id,
        type_key: "supports",
        confidence: 0.8,
        provenance: %{"kind" => "operator_link"}
      })

    {:ok, relates} =
      Knowledge.create_relationship(%{
        workspace_id: workspace.id,
        from_node_id: decision.id,
        to_node_id: memory.id,
        type_key: "relates_to",
        confidence: 0.4,
        provenance: %{"kind" => "loose_link"}
      })

    {:ok, view, _html} =
      live(
        conn,
        ~p"/control/graph?workspace_id=#{workspace.id}&node_type=memory&node_status=verified&relationship_type=supports&provenance=operator_link"
      )

    refute has_element?(view, "#graph-node-#{decision.id}")
    assert has_element?(view, "#graph-node-#{memory.id}")
    assert has_element?(view, "#graph-relationship-#{supports.id}")
    refute has_element?(view, "#graph-relationship-#{relates.id}")

    view
    |> form("#graph-filter-form", %{
      node_type: "decision",
      node_status: "active",
      relationship_type: "relates_to",
      provenance: "loose_link"
    })
    |> render_change()

    assert_patch(
      view,
      ~p"/control/graph?workspace_id=#{workspace.id}&node_type=decision&node_status=active&relationship_type=relates_to&provenance=loose_link"
    )

    assert has_element?(view, "#graph-node-#{decision.id}")
    refute has_element?(view, "#graph-node-#{memory.id}")
    refute has_element?(view, "#graph-relationship-#{supports.id}")
    assert has_element?(view, "#graph-relationship-#{relates.id}")
  end

  test "updates graph node and relationship controls", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-graph-edit-controls"})

    {:ok, memory} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "memory",
        title: "Tune graph memory",
        body: "Operators can adjust graph confidence.",
        status: "active",
        confidence: 0.4,
        importance: 0.5,
        provenance: %{"kind" => "operator_review"}
      })

    {:ok, claim} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "claim",
        title: "Graph confidence claim",
        body: "The edge confidence should be inspectable.",
        status: "active",
        provenance: %{"kind" => "operator_review"}
      })

    {:ok, relationship} =
      Knowledge.create_relationship(%{
        workspace_id: workspace.id,
        from_node_id: memory.id,
        to_node_id: claim.id,
        type_key: "supports",
        confidence: 0.45,
        provenance: %{"kind" => "operator_link"}
      })

    {:ok, view, _html} =
      live(conn, ~p"/control/graph?workspace_id=#{workspace.id}&node_status=all")

    view
    |> element("#graph-node-settings-form-#{memory.id}")
    |> render_submit(%{
      node_id: memory.id,
      status: "verified",
      confidence: "0.87",
      importance: "0.76"
    })

    updated_node = Knowledge.get_node!(memory.id)
    assert updated_node.status == "verified"
    assert updated_node.confidence == 0.87
    assert updated_node.importance == 0.76

    view
    |> element("#graph-relationship-settings-form-#{relationship.id}")
    |> render_submit(%{
      relationship_id: relationship.id,
      confidence: "0.93",
      provenance: ~s({"kind":"operator_link","run_id":123,"reviewed_by":"graph"})
    })

    updated_relationship = Knowledge.get_relationship!(relationship.id)
    assert updated_relationship.confidence == 0.93

    assert updated_relationship.provenance == %{
             "kind" => "operator_link",
             "run_id" => 123,
             "reviewed_by" => "graph"
           }

    view
    |> element("#graph-relationship-settings-form-#{relationship.id}")
    |> render_submit(%{
      relationship_id: relationship.id,
      confidence: "0.2",
      provenance: "[not a map]"
    })

    assert Knowledge.get_relationship!(relationship.id).confidence == 0.93

    html = render(view)
    assert html =~ "verified"
    assert html =~ "confidence 0.93"
    assert html =~ "provenance must be valid JSON"
    assert html =~ "reviewed_by"
    assert has_element?(view, "#graph-node-#{memory.id}")
    assert has_element?(view, "#graph-relationship-#{relationship.id}")
  end

  test "bulk verifies filtered draft and active graph nodes", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-graph-bulk-review"})

    {:ok, draft_claim} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "claim",
        title: "Draft claim",
        body: "This filtered claim should be verified.",
        status: "draft",
        confidence: 0.5,
        importance: 0.6,
        provenance: %{"kind" => "operator_review"}
      })

    {:ok, active_claim} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "claim",
        title: "Active claim",
        body: "This filtered claim should also be verified.",
        status: "active",
        confidence: 0.7,
        importance: 0.6,
        attributes: %{"source" => "existing"},
        provenance: %{"kind" => "operator_review"}
      })

    {:ok, archived_claim} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "claim",
        title: "Archived claim",
        body: "Archived nodes should not be bulk verified.",
        status: "archived",
        confidence: 0.2,
        importance: 0.4,
        provenance: %{"kind" => "operator_review"}
      })

    {:ok, active_memory} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "memory",
        title: "Active memory",
        body: "The node type filter should exclude this.",
        status: "active",
        confidence: 0.8,
        importance: 0.6,
        provenance: %{"kind" => "operator_review"}
      })

    {:ok, view, _html} =
      live(conn, ~p"/control/graph?workspace_id=#{workspace.id}&node_type=claim")

    assert has_element?(view, "#graph-node-#{draft_claim.id}")
    assert has_element?(view, "#graph-node-#{active_claim.id}")
    assert has_element?(view, "#graph-node-#{archived_claim.id}")
    refute has_element?(view, "#graph-node-#{active_memory.id}")

    html = render(view)
    assert html =~ "2 filtered draft/active nodes ready for bulk review"

    view
    |> element("#graph-bulk-node-review-form")
    |> render_submit(%{reason: "Reviewed source-backed claim batch"})

    reviewed_draft = Knowledge.get_node!(draft_claim.id)
    reviewed_active = Knowledge.get_node!(active_claim.id)

    assert reviewed_draft.status == "verified"
    assert reviewed_draft.attributes["reviewed_actor"] == "graph_workbench"
    assert reviewed_draft.attributes["reviewed_reason"] == "Reviewed source-backed claim batch"
    assert reviewed_draft.attributes["reviewed_source"] == "bulk_graph_review"
    assert reviewed_draft.attributes["reviewed_at"]

    assert reviewed_active.status == "verified"
    assert reviewed_active.attributes["source"] == "existing"
    assert reviewed_active.attributes["reviewed_actor"] == "graph_workbench"

    assert Knowledge.get_node!(archived_claim.id).status == "archived"
    assert Knowledge.get_node!(active_memory.id).status == "active"

    html = render(view)
    assert html =~ "Verified 2 filtered graph nodes"
    assert html =~ "0 filtered draft/active nodes ready for bulk review"
  end

  test "bulk reviews filtered graph relationships with provenance metadata", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-graph-bulk-relationship-review"})

    {:ok, memory} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "memory",
        title: "Runtime memory",
        body: "Memory supports the claim.",
        status: "active",
        provenance: %{"kind" => "operator_review"}
      })

    {:ok, claim} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "claim",
        title: "Runtime claim",
        body: "The runtime keeps graph evidence.",
        status: "active",
        provenance: %{"kind" => "operator_review"}
      })

    {:ok, decision} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "decision",
        title: "Runtime decision",
        body: "Use the graph workbench.",
        status: "active",
        provenance: %{"kind" => "operator_review"}
      })

    {:ok, supports} =
      Knowledge.create_relationship(%{
        workspace_id: workspace.id,
        from_node_id: memory.id,
        to_node_id: claim.id,
        type_key: "supports",
        confidence: 0.4,
        provenance: %{"kind" => "agent_link"}
      })

    {:ok, relates} =
      Knowledge.create_relationship(%{
        workspace_id: workspace.id,
        from_node_id: decision.id,
        to_node_id: memory.id,
        type_key: "relates_to",
        confidence: 0.3,
        provenance: %{"kind" => "agent_link"}
      })

    {:ok, view, _html} =
      live(conn, ~p"/control/graph?workspace_id=#{workspace.id}&relationship_type=supports")

    assert has_element?(view, "#graph-relationship-#{supports.id}")
    refute has_element?(view, "#graph-relationship-#{relates.id}")

    html = render(view)
    assert html =~ "1 filtered relationships ready for bulk review"

    view
    |> element("#graph-bulk-relationship-review-form")
    |> render_submit(%{reason: "Source-backed edge", confidence: "0.88"})

    reviewed = Knowledge.get_relationship!(supports.id)
    assert reviewed.confidence == 0.88
    assert reviewed.provenance["kind"] == "agent_link"
    assert reviewed.provenance["reviewed_actor"] == "graph_workbench"
    assert reviewed.provenance["reviewed_reason"] == "Source-backed edge"
    assert reviewed.provenance["reviewed_source"] == "bulk_relationship_review"
    assert reviewed.provenance["reviewed_at"]

    untouched = Knowledge.get_relationship!(relates.id)
    assert untouched.confidence == 0.3
    refute Map.has_key?(untouched.provenance, "reviewed_actor")

    html = render(view)
    assert html =~ "Reviewed 1 filtered graph relationships"
    assert html =~ "confidence 0.88"
  end
end
