defmodule HydraAgentWeb.MemoryStudioLiveTest do
  use HydraAgentWeb.ConnCase

  import HydraAgent.RuntimeFixtures
  import Phoenix.LiveViewTest

  alias HydraAgent.Knowledge
  alias HydraAgent.Memory

  test "renders empty memory studio", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/control/memory")

    assert html =~ "Memory Studio"
    assert html =~ "No workspaces yet."
  end

  test "falls back from malformed workspace params", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-memory-malformed-param"})

    {:ok, view, html} = live(conn, ~p"/control/memory?workspace_id=not-an-id")

    assert html =~ "Memory Studio"
    assert render(view) =~ workspace.name
  end

  test "renders memory proposals, durable memory, and curation signals", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-memory-studio"})
    agent = agent_fixture(workspace, %{knowledge_scopes: ["workspace"]})

    {:ok, proposal} =
      Memory.propose_node(agent, %{
        title: "Persist run timelines",
        body: "Use durable run events as the timeline source.",
        confidence: 0.7,
        importance: 0.8
      })

    {:ok, memory} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "memory",
        title: "Review provenance first",
        body: "Memory should retain source run provenance before recall.",
        status: "active",
        confidence: 0.9,
        importance: 0.7,
        attributes: %{
          "edited_at" => "2026-05-24T10:00:00Z",
          "edited_actor" => "memory_studio"
        },
        provenance: %{
          "kind" => "operator_review",
          "reviews" => [
            %{
              "decision" => "promoted",
              "review_actor" => "operator",
              "review_reason" => "source-backed",
              "reviewed_at" => "2026-05-24T09:00:00Z"
            }
          ]
        }
      })

    {:ok, low_confidence} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "memory",
        title: "Weak signal",
        body: "Maybe useful later.",
        status: "active",
        confidence: 0.1,
        importance: 0.2,
        provenance: %{"kind" => "manual"}
      })

    {:ok, view, _html} = live(conn, ~p"/control/memory?workspace_id=#{workspace.id}")

    assert has_element?(view, "#memory-studio")
    assert has_element?(view, "#memory-proposal-#{proposal.id}")
    assert has_element?(view, "#memory-result-#{memory.id}")
    assert has_element?(view, "#memory-result-#{low_confidence.id}")
    assert has_element?(view, "#memory-curation")

    html = render(view)
    assert html =~ "Persist run timelines"
    assert html =~ "Review provenance first"
    assert html =~ "History"
    assert html =~ "review promoted / operator / 2026-05-24T09:00:00Z"
    assert html =~ "edited / memory_studio / 2026-05-24T10:00:00Z"
    assert html =~ "source-backed"
    assert html =~ "1 candidates below current threshold"
  end

  test "filters durable memory by query and status", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-memory-filter"})

    {:ok, matching} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "memory",
        title: "Provider fallback",
        body: "Fallback routes should preserve usage accounting.",
        status: "active",
        provenance: %{"kind" => "manual"}
      })

    {:ok, archived} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "memory",
        title: "Provider fallback old",
        body: "Old fallback guidance.",
        status: "archived",
        provenance: %{"kind" => "manual"}
      })

    {:ok, view, _html} =
      live(conn, ~p"/control/memory?workspace_id=#{workspace.id}&q=provider&status=active")

    assert has_element?(view, "#memory-result-#{matching.id}")
    refute has_element?(view, "#memory-result-#{archived.id}")

    view
    |> form("#memory-filter-form", %{q: "provider", status: "archived"})
    |> render_change()

    assert_patch(
      view,
      ~p"/control/memory?workspace_id=#{workspace.id}&q=provider&status=archived&archive_below_confidence=#{0.2}"
    )

    refute has_element?(view, "#memory-result-#{matching.id}")
    assert has_element?(view, "#memory-result-#{archived.id}")
  end

  test "renders memory conflict signals", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-memory-conflicts"})

    {:ok, memory} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "memory",
        title: "Prefer provider fallback",
        body: "Always retry on fallback before reporting failure.",
        status: "conflicted",
        confidence: 0.6,
        importance: 0.8,
        provenance: %{"kind" => "operator_review"}
      })

    {:ok, claim} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "claim",
        title: "Fallback can duplicate side effects",
        body: "Retrying after a side-effecting call needs explicit idempotency evidence.",
        status: "verified",
        confidence: 0.9,
        importance: 0.7,
        provenance: %{"kind" => "incident_review"}
      })

    {:ok, relationship} =
      Knowledge.create_relationship(%{
        workspace_id: workspace.id,
        from_node_id: memory.id,
        to_node_id: claim.id,
        type_key: "contradicts",
        confidence: 0.88,
        provenance: %{"kind" => "operator_conflict"}
      })

    {:ok, view, _html} =
      live(conn, ~p"/control/memory?workspace_id=#{workspace.id}&status=conflicted")

    assert has_element?(view, "#memory-result-#{memory.id}")
    assert has_element?(view, "#memory-conflicts-#{memory.id}")
    assert has_element?(view, "#memory-conflict-#{memory.id}-#{relationship.id}")

    html = render(view)
    assert html =~ "Conflict Signals"
    assert html =~ "Prefer provider fallback contradicts Fallback can duplicate side effects"
    assert html =~ "operator_conflict"
    assert html =~ "88.0%"
  end

  test "reviews proposals and archives durable memory", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-memory-actions"})
    agent = agent_fixture(workspace, %{knowledge_scopes: ["workspace"]})

    {:ok, promote_me} =
      Memory.propose_node(agent, %{
        title: "Keep trace contract",
        body: "Timeline events are the source of truth."
      })

    {:ok, archive_me} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "memory",
        title: "Temporary memory",
        body: "Archive this from the studio.",
        status: "active",
        provenance: %{"kind" => "operator_review"}
      })

    {:ok, view, _html} = live(conn, ~p"/control/memory?workspace_id=#{workspace.id}")

    view
    |> element("#memory-review-form-#{promote_me.id}")
    |> render_submit(%{
      proposal_id: promote_me.id,
      decision: "promote",
      reason: "Matches run timeline contract"
    })

    promoted = Knowledge.get_node!(promote_me.id)
    assert promoted.status == "active"
    assert promoted.attributes["proposal_status"] == "promoted"
    assert promoted.attributes["review_reason"] == "Matches run timeline contract"
    refute has_element?(view, "#memory-proposal-#{promote_me.id}")

    view |> element("#memory-archive-#{archive_me.id}") |> render_click()

    archived = Knowledge.get_node!(archive_me.id)
    assert archived.status == "archived"
    assert archived.attributes["archived_actor"] == "memory_studio"
    refute has_element?(view, "#memory-result-#{archive_me.id}")
  end

  test "edits pending memory proposals before review", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-memory-edit-proposal"})
    agent = agent_fixture(workspace, %{knowledge_scopes: ["workspace"]})

    {:ok, proposal} =
      Memory.propose_node(agent, %{
        title: "Rough proposal",
        body: "Needs refining.",
        confidence: 0.2,
        importance: 0.3
      })

    {:ok, view, _html} = live(conn, ~p"/control/memory?workspace_id=#{workspace.id}")

    view
    |> element("#memory-proposal-edit-form-#{proposal.id}")
    |> render_submit(%{
      proposal_id: proposal.id,
      title: "Refined proposal",
      body: "Use persisted runtime events to reconstruct timelines.",
      confidence: "0.86",
      importance: "0.74"
    })

    updated = Knowledge.get_node!(proposal.id)
    assert updated.title == "Refined proposal"
    assert updated.body == "Use persisted runtime events to reconstruct timelines."
    assert updated.confidence == 0.86
    assert updated.importance == 0.74
    assert updated.attributes["edited_actor"] == "memory_studio"

    html = render(view)
    assert html =~ "Refined proposal"
    assert html =~ "86.0%"
    assert has_element?(view, "#memory-proposal-#{proposal.id}")
  end

  test "edits durable memory status and scores", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-memory-edit-durable"})

    {:ok, memory} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "memory",
        title: "Reviewed memory",
        body: "Operators can tune durable recall settings.",
        status: "active",
        confidence: 0.4,
        importance: 0.5,
        provenance: %{"kind" => "operator_review"}
      })

    {:ok, view, _html} =
      live(conn, ~p"/control/memory?workspace_id=#{workspace.id}&status=all")

    view
    |> element("#memory-settings-form-#{memory.id}")
    |> render_submit(%{
      memory_id: memory.id,
      status: "verified",
      confidence: "0.92",
      importance: "0.81"
    })

    updated = Knowledge.get_node!(memory.id)
    assert updated.status == "verified"
    assert updated.confidence == 0.92
    assert updated.importance == 0.81
    assert updated.attributes["edited_actor"] == "memory_studio"

    html = render(view)
    assert html =~ "verified"
    assert html =~ "92.0%"
    assert has_element?(view, "#memory-result-#{memory.id}")
  end

  test "bulk archives low-confidence memories from curation signals", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-memory-bulk-curation"})

    {:ok, low_confidence} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "memory",
        title: "Unreliable hint",
        body: "This should be removed from active recall.",
        status: "active",
        confidence: 0.1,
        importance: 0.2,
        provenance: %{"kind" => "manual"}
      })

    {:ok, high_confidence} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "memory",
        title: "Reliable lesson",
        body: "This should stay in active recall.",
        status: "active",
        confidence: 0.8,
        importance: 0.7,
        provenance: %{"kind" => "manual"}
      })

    {:ok, view, _html} = live(conn, ~p"/control/memory?workspace_id=#{workspace.id}")

    assert has_element?(view, "#memory-result-#{low_confidence.id}")
    assert has_element?(view, "#memory-result-#{high_confidence.id}")
    assert has_element?(view, "#memory-low-confidence-candidate-#{low_confidence.id}")

    html = render(view)
    assert html =~ "1 candidates below current threshold"
    assert html =~ "Unreliable hint"

    view |> element("#memory-archive-low-confidence") |> render_click()

    archived = Knowledge.get_node!(low_confidence.id)
    assert archived.status == "archived"
    assert archived.attributes["archived_actor"] == "memory_studio"
    assert archived.attributes["archived_reason"] == "low_confidence"
    assert archived.attributes["archive_below_confidence"] == 0.2
    assert archived.attributes["archived_at"]

    assert Knowledge.get_node!(high_confidence.id).status == "active"

    refute has_element?(view, "#memory-result-#{low_confidence.id}")
    assert has_element?(view, "#memory-result-#{high_confidence.id}")

    html = render(view)
    assert html =~ "Archived 1 low-confidence memories"
    assert html =~ "0 candidates below current threshold"
  end

  test "uses operator curation threshold for low-confidence bulk archive", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-memory-curation-threshold"})

    {:ok, borderline} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "memory",
        title: "Borderline signal",
        body: "This should only archive at a higher operator threshold.",
        status: "active",
        confidence: 0.25,
        importance: 0.5,
        provenance: %{"kind" => "manual"}
      })

    {:ok, view, _html} = live(conn, ~p"/control/memory?workspace_id=#{workspace.id}")

    refute has_element?(view, "#memory-low-confidence-candidate-#{borderline.id}")

    view
    |> form("#memory-curation-threshold-form", %{archive_below_confidence: "0.30"})
    |> render_change()

    assert_patch(
      view,
      ~p"/control/memory?workspace_id=#{workspace.id}&q=&status=active&archive_below_confidence=#{0.3}"
    )

    assert has_element?(view, "#memory-low-confidence-candidate-#{borderline.id}")

    view |> element("#memory-archive-low-confidence") |> render_click()

    archived = Knowledge.get_node!(borderline.id)
    assert archived.status == "archived"
    assert archived.attributes["archive_below_confidence"] == 0.3
  end

  test "bulk archives duplicate memories while keeping canonical memory", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-memory-duplicate-curation"})

    {:ok, canonical} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "memory",
        title: "Provider fallback",
        body: "Keep the verified memory.",
        status: "verified",
        confidence: 0.9,
        importance: 0.8,
        provenance: %{"kind" => "operator_review"}
      })

    {:ok, duplicate} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "memory",
        title: "provider fallback",
        body: "Archive the lower signal duplicate.",
        status: "active",
        confidence: 0.45,
        importance: 0.4,
        provenance: %{"kind" => "manual"}
      })

    {:ok, low_confidence} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "memory",
        title: "Weak but unique",
        body: "This should not be archived by duplicate resolution.",
        status: "active",
        confidence: 0.1,
        importance: 0.2,
        provenance: %{"kind" => "manual"}
      })

    {:ok, view, _html} =
      live(conn, ~p"/control/memory?workspace_id=#{workspace.id}&status=all")

    assert has_element?(view, "#memory-duplicate-title-group-#{canonical.id}")

    html = render(view)
    assert html =~ "1 duplicate groups"
    assert html =~ "keep Provider fallback / archive 1 duplicates"

    view |> element("#memory-archive-duplicate-memories") |> render_click()

    assert Knowledge.get_node!(canonical.id).status == "verified"
    assert Knowledge.get_node!(low_confidence.id).status == "active"

    archived = Knowledge.get_node!(duplicate.id)
    assert archived.status == "archived"
    assert archived.attributes["archived_actor"] == "memory_studio"
    assert archived.attributes["archived_reason"] == "duplicate_title"
    assert archived.attributes["duplicate_canonical_node_id"] == canonical.id

    html = render(view)
    assert html =~ "Archived 1 duplicate memories"
    assert html =~ "0 duplicate groups"
  end
end
