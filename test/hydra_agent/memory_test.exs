defmodule HydraAgent.MemoryTest do
  use HydraAgent.DataCase, async: true

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.Knowledge
  alias HydraAgent.Memory

  test "formats recalled context compactly" do
    context =
      Memory.format_context(%{
        "nodes" => [
          %{
            "id" => 1,
            "type_key" => "decision",
            "title" => "Use OTP",
            "body" => "Supervise workers."
          }
        ]
      })

    assert context == "- [decision:1] Use OTP: Supervise workers."
  end

  test "formats empty memory as blank context" do
    assert Memory.format_context(%{"nodes" => []}) == ""
  end

  test "proposes draft memory nodes with agent and run provenance" do
    %{agent: agent, run: run} =
      runtime_fixture(%{agent: %{knowledge_scopes: ["workspace"]}})

    assert {:ok, node} =
             Memory.propose_node(agent, %{
               title: "Prefer durable events",
               body: "Use persisted runtime events as the visible mission timeline.",
               run_id: run.id,
               reason: "Captured from planning",
               evidence: ["roadmap"]
             })

    assert node.type_key == "memory"
    assert node.status == "draft"
    assert node.created_by_agent_id == agent.id
    assert node.attributes["proposal_status"] == "pending"
    assert node.provenance["kind"] == "memory_proposal"
    assert node.provenance["agent_id"] == agent.id
    assert node.provenance["run_id"] == run.id
    assert node.provenance["evidence"] == ["roadmap"]
  end

  test "propose_from_run creates an idempotent memory proposal from run context" do
    workspace = workspace_fixture(%{slug: "memory-propose-from-run"})
    agent = agent_fixture(workspace, %{slug: "memory-proposal-agent"})

    run =
      run_fixture(workspace, %{
        supervisor_agent_id: agent.id,
        title: "Investigate Runtime",
        goal: "Capture durable runtime lessons."
      })

    _step =
      run_step_fixture(run, %{
        title: "Inspect event timeline",
        status: "completed",
        tool_name: "knowledge_read"
      })

    run = HydraAgent.Runtime.get_run_detail!(run.id)

    assert {:ok, proposal} = Memory.propose_from_run(run)
    assert proposal.type_key == "memory"
    assert proposal.status == "draft"
    assert proposal.created_by_agent_id == agent.id
    assert proposal.attributes["proposal_status"] == "pending"
    assert proposal.provenance["kind"] == "memory_proposal"
    assert proposal.provenance["source"] == "run_detail"
    assert proposal.provenance["run_id"] == run.id
    assert proposal.title == "Memory from Investigate Runtime"
    assert proposal.body =~ "Inspect event timeline: completed"

    assert {:ok, same_proposal} = Memory.propose_from_run(run)
    assert same_proposal.id == proposal.id
    assert [^proposal] = Memory.list_proposals(workspace.id)
  end

  test "recall excludes draft memory proposals until promoted" do
    workspace = workspace_fixture()
    agent = agent_fixture(workspace, %{knowledge_scopes: ["workspace"]})

    {:ok, _draft} =
      Memory.propose_node(agent, %{
        title: "Draft only",
        body: "This should not be recalled before review."
      })

    {:ok, _active} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "memory",
        title: "Active runtime memory",
        body: "This can be recalled.",
        status: "active"
      })

    recalled = Memory.recall(agent, "memory", limit: 10)

    assert recalled["count"] == 1
    assert [%{"title" => "Active runtime memory"}] = recalled["nodes"]
  end

  test "proposal lifecycle lists pending proposals and gates recall until promotion" do
    workspace = workspace_fixture()
    agent = agent_fixture(workspace, %{knowledge_scopes: ["workspace"]})

    {:ok, proposal} =
      Memory.propose_node(agent, %{
        title: "Mission timeline",
        body: "Use durable events for the mission detail page."
      })

    assert [^proposal] = Memory.list_proposals(workspace.id)
    assert Memory.recall(agent, "Mission timeline")["count"] == 0

    assert {:ok, promoted} =
             Memory.promote_proposal(proposal, %{actor: "tester", reason: "Verified"})

    assert promoted.status == "active"
    assert promoted.attributes["proposal_status"] == "promoted"
    assert promoted.attributes["review_actor"] == "tester"
    assert [%{"decision" => "promoted"}] = promoted.provenance["reviews"]
    assert Memory.list_proposals(workspace.id) == []
    assert Memory.recall(agent, "Mission timeline")["count"] == 1
  end

  test "pending proposals can be edited before review" do
    workspace = workspace_fixture()
    agent = agent_fixture(workspace, %{knowledge_scopes: ["workspace"]})

    {:ok, proposal} =
      Memory.propose_node(agent, %{
        title: "Rough memory",
        body: "Needs better wording.",
        confidence: 0.3,
        importance: 0.4
      })

    assert {:ok, updated} =
             Memory.update_proposal_draft(proposal, %{
               title: "Refined memory",
               body: "Use durable run events for timeline reconstruction.",
               confidence: "0.82",
               importance: "0.73",
               actor: "tester"
             })

    assert updated.title == "Refined memory"
    assert updated.body == "Use durable run events for timeline reconstruction."
    assert updated.confidence == 0.82
    assert updated.importance == 0.73
    assert updated.attributes["edited_actor"] == "tester"

    {:ok, promoted} = Memory.promote_proposal(updated)

    assert {:error, %{"reason" => "proposal_already_reviewed"}} =
             Memory.update_proposal_draft(promoted, %{title: "Too late"})
  end

  test "durable memory controls update reviewed nodes but not pending proposals" do
    workspace = workspace_fixture()
    agent = agent_fixture(workspace, %{knowledge_scopes: ["workspace"]})

    {:ok, memory} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "memory",
        title: "Tune recall controls",
        body: "Operators should adjust confidence without rewriting memory.",
        status: "active",
        confidence: 0.4,
        importance: 0.5,
        provenance: %{"kind" => "operator_review"}
      })

    assert {:ok, updated} =
             Memory.update_memory_node(memory, %{
               status: "verified",
               confidence: "0.91",
               importance: "0.66",
               actor: "tester"
             })

    assert updated.status == "verified"
    assert updated.confidence == 0.91
    assert updated.importance == 0.66
    assert updated.attributes["edited_actor"] == "tester"

    {:ok, proposal} =
      Memory.propose_node(agent, %{
        title: "Pending control proposal",
        body: "Review should happen before durable memory edits."
      })

    assert {:error, %{"reason" => "pending_proposal_requires_review"}} =
             Memory.update_memory_node(proposal, %{status: "verified"})
  end

  test "proposal rejection archives the draft" do
    workspace = workspace_fixture()
    agent = agent_fixture(workspace, %{knowledge_scopes: ["workspace"]})

    {:ok, proposal} =
      Memory.propose_node(agent, %{
        title: "Temporary note",
        body: "This should not survive review."
      })

    assert {:ok, rejected} = Memory.reject_proposal(proposal, %{reason: "Too vague"})

    assert rejected.status == "archived"
    assert rejected.attributes["proposal_status"] == "rejected"
    assert rejected.attributes["review_reason"] == "Too vague"
    assert Memory.recall(agent, "Temporary note")["count"] == 0
  end

  test "archives durable memory nodes but not pending proposals" do
    workspace = workspace_fixture()
    agent = agent_fixture(workspace, %{knowledge_scopes: ["workspace"]})

    {:ok, memory} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "memory",
        title: "Archive me",
        body: "Operator decided this is stale.",
        status: "active",
        provenance: %{"kind" => "operator_review"}
      })

    assert {:ok, archived} =
             Memory.archive_node(memory, %{"actor" => "operator", "reason" => "stale"})

    assert archived.status == "archived"
    assert archived.attributes["archived_actor"] == "operator"
    assert archived.attributes["archived_reason"] == "stale"

    {:ok, proposal} =
      Memory.propose_node(agent, %{
        title: "Pending proposal",
        body: "Needs review first."
      })

    assert {:error, %{"reason" => "pending_proposal_requires_review"}} =
             Memory.archive_node(proposal)
  end

  test "curates active low-confidence memories with archive provenance" do
    workspace = workspace_fixture(%{slug: "memory-curate-low-confidence"})

    {:ok, low_confidence} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "memory",
        title: "Low signal",
        body: "This memory is below the operator threshold.",
        status: "active",
        confidence: 0.1,
        importance: 0.2,
        attributes: %{"source" => "test"},
        provenance: %{"kind" => "manual"}
      })

    {:ok, high_confidence} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "memory",
        title: "Keep signal",
        body: "This memory should stay active.",
        status: "active",
        confidence: 0.8,
        importance: 0.7,
        provenance: %{"kind" => "manual"}
      })

    {:ok, draft_low_confidence} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "memory",
        title: "Draft signal",
        body: "Draft memories are not bulk archived.",
        status: "draft",
        confidence: 0.05,
        importance: 0.2,
        provenance: %{"kind" => "manual"}
      })

    dry_run = Memory.curate_workspace(workspace.id, archive_below_confidence: 0.2)

    assert [%{"id" => low_confidence_id}] = dry_run["low_confidence_candidates"]
    assert low_confidence_id == low_confidence.id
    assert dry_run["archived_node_ids"] == []

    result =
      Memory.curate_workspace(workspace.id,
        dry_run?: false,
        archive_below_confidence: 0.2,
        actor: "tester"
      )

    assert result["archived_node_ids"] == [low_confidence.id]

    archived = Knowledge.get_node!(low_confidence.id)
    assert archived.status == "archived"
    assert archived.attributes["source"] == "test"
    assert archived.attributes["archived_actor"] == "tester"
    assert archived.attributes["archived_reason"] == "low_confidence"
    assert archived.attributes["archive_below_confidence"] == 0.2
    assert archived.attributes["archived_at"]

    assert Knowledge.get_node!(high_confidence.id).status == "active"
    assert Knowledge.get_node!(draft_low_confidence.id).status == "draft"
  end

  test "curates duplicate memory titles while keeping strongest canonical node" do
    workspace = workspace_fixture(%{slug: "memory-curate-duplicates"})

    {:ok, canonical} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "memory",
        title: "Provider fallback",
        body: "Verified high-confidence duplicate should remain.",
        status: "verified",
        confidence: 0.9,
        importance: 0.8,
        provenance: %{"kind" => "operator_review"}
      })

    {:ok, duplicate} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "memory",
        title: " provider fallback ",
        body: "Lower-confidence active duplicate should archive.",
        status: "active",
        confidence: 0.4,
        importance: 0.5,
        provenance: %{"kind" => "manual"}
      })

    {:ok, claim} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "claim",
        title: "Provider fallback",
        body: "Non-memory duplicates are ignored by memory curation.",
        status: "active",
        confidence: 0.2,
        importance: 0.2,
        provenance: %{"kind" => "manual"}
      })

    dry_run = Memory.curate_workspace(workspace.id)

    assert [
             %{
               "title" => "provider fallback",
               "count" => 2,
               "canonical_node" => %{"id" => canonical_id},
               "duplicate_nodes" => [%{"id" => duplicate_id}]
             }
           ] = dry_run["duplicate_title_groups"]

    assert canonical_id == canonical.id
    assert duplicate_id == duplicate.id

    result =
      Memory.curate_workspace(workspace.id,
        dry_run?: false,
        archive_low_confidence?: false,
        resolve_duplicates?: true,
        actor: "tester"
      )

    assert result["archived_duplicate_node_ids"] == [duplicate.id]
    assert result["archived_node_ids"] == []

    assert Knowledge.get_node!(canonical.id).status == "verified"
    assert Knowledge.get_node!(claim.id).status == "active"

    archived = Knowledge.get_node!(duplicate.id)
    assert archived.status == "archived"
    assert archived.attributes["archived_actor"] == "tester"
    assert archived.attributes["archived_reason"] == "duplicate_title"
    assert archived.attributes["duplicate_canonical_node_id"] == canonical.id
    assert archived.attributes["archived_at"]
  end
end
