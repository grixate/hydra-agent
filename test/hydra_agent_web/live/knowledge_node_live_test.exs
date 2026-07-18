defmodule HydraAgentWeb.KnowledgeNodeLiveTest do
  use HydraAgentWeb.ConnCase

  import HydraAgent.RuntimeFixtures
  import Phoenix.LiveViewTest

  alias HydraAgent.Knowledge

  test "falls back from malformed workspace params on node detail", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-knowledge-malformed-param"})

    {:ok, memory} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "memory",
        title: "Stable Node Detail",
        body: "Malformed workspace params should not break detail views.",
        provenance: %{"kind" => "test"}
      })

    {:ok, view, html} = live(conn, ~p"/control/memory/#{memory.id}?workspace_id=not-an-id")

    assert html =~ "Stable Node Detail"
    assert render(view) =~ workspace.name
  end

  test "renders memory and graph node detail routes", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-knowledge-detail"})

    {:ok, memory} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "memory",
        title: "Remember Mission Lineage",
        body: "Retries and forks stay attached to their mission.",
        provenance: %{"kind" => "test"}
      })

    {:ok, artifact} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "observation",
        title: "Trace Export",
        body: "Run trace JSON",
        provenance: %{"kind" => "test"}
      })

    {:ok, _relationship} =
      Knowledge.create_relationship(%{
        workspace_id: workspace.id,
        from_node_id: artifact.id,
        to_node_id: memory.id,
        type_key: "relates_to"
      })

    {:ok, view, html} = live(conn, ~p"/control/memory/#{memory.id}?workspace_id=#{workspace.id}")

    assert html =~ "Remember Mission Lineage"
    assert has_element?(view, "#knowledge-node-#{memory.id}")
    assert render(view) =~ "Trace Export -&gt; relates_to"

    {:ok, view, _html} =
      live(conn, ~p"/control/graph/nodes/#{artifact.id}?workspace_id=#{workspace.id}")

    assert render(view) =~ "relates_to -&gt; Remember Mission Lineage"
  end

  test "node detail keeps its shell anchored to the node workspace", %{conn: conn} do
    first = workspace_fixture(%{name: "First", slug: "node-shell-first"})
    second = workspace_fixture(%{name: "Second", slug: "node-shell-second"})

    {:ok, memory} =
      Knowledge.create_node(%{
        workspace_id: first.id,
        type_key: "memory",
        title: "Workspace anchored memory",
        body: "The shell must not suggest this record belongs elsewhere.",
        provenance: %{"kind" => "test"}
      })

    {:ok, view, _html} =
      live(conn, ~p"/control/memory/#{memory.id}?workspace_id=#{second.id}")

    active_workspace = view |> element(".workspace-option.is-active") |> render()
    assert active_workspace =~ "workspace_id=#{first.id}"
    refute active_workspace =~ "workspace_id=#{second.id}"
  end
end
