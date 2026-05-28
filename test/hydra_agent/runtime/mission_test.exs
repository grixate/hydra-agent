defmodule HydraAgent.Runtime.MissionTest do
  use HydraAgent.DataCase

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.Runtime

  test "create_run creates an implicit mission and records lineage payload" do
    workspace = workspace_fixture()

    {:ok, run} =
      Runtime.create_run(%{
        workspace_id: workspace.id,
        title: "Investigate flaky worker",
        goal: "Find the stale lease source"
      })

    assert run.mission_id
    assert run.lineage_type == "original"

    mission = Runtime.get_mission!(run.mission_id)
    assert mission.title == "Investigate flaky worker"
    assert mission.objective == "Find the stale lease source"
    assert mission.metadata["created_from"] == "implicit_run"

    [event] = Runtime.list_run_events(run.id)
    assert event.event_type == "run.created"
    assert event.payload["mission_id"] == run.mission_id
    assert event.payload["lineage_type"] == "original"
  end

  test "mission runs can be retried and forked with lineage" do
    workspace = workspace_fixture()

    {:ok, mission} =
      Runtime.create_mission(%{
        workspace_id: workspace.id,
        title: "Ship v2",
        objective: "Implement the remaining management surface"
      })

    {:ok, run} = Runtime.create_mission_run(mission, %{title: "Primary pass"})
    {:ok, retry} = Runtime.retry_run(run, %{"lineage_reason" => "provider timeout"})
    {:ok, fork} = Runtime.fork_run(run, %{"title" => "Alternative route"})

    assert retry.mission_id == mission.id
    assert retry.parent_run_id == run.id
    assert retry.lineage_type == "retry"
    assert retry.lineage_reason == "provider timeout"

    assert fork.mission_id == mission.id
    assert fork.parent_run_id == run.id
    assert fork.lineage_type == "fork"
    assert fork.title == "Alternative route"
  end

  test "mission start modes and rollups preserve mission context" do
    workspace = workspace_fixture()

    {:ok, mission} =
      Runtime.create_mission(%{
        workspace_id: workspace.id,
        title: "Plan release",
        objective: "Prepare final release",
        start_mode: "plan_only",
        success_criteria: %{"checks" => ["tests pass"]},
        context: %{"repo" => "hydra-agent"},
        team: %{"agents" => ["planner"]},
        permissions: %{"side_effect_classes" => ["read_only"]}
      })

    {:ok, %{mission: started_mission, run: run}} = Runtime.start_mission(mission)

    assert started_mission.status == "planned"
    assert run.status == "planned"
    assert run.plan["success_criteria"] == %{"checks" => ["tests pass"]}
    assert run.plan["mission_context"] == %{"repo" => "hydra-agent"}
    assert run.plan["team"] == %{"agents" => ["planner"]}
    assert run.plan["permissions"] == %{"side_effect_classes" => ["read_only"]}

    {:ok, completed} = Runtime.complete_run(run)
    assert completed.status == "completed"
    assert Runtime.get_mission!(mission.id).status == "completed"
  end

  test "trace_run returns a complete run bundle" do
    workspace = workspace_fixture()
    run = run_fixture(workspace)
    step = run_step_fixture(run, %{title: "Trace step"})

    {:ok, _usage} =
      HydraAgent.Usage.create_record(%{
        workspace_id: workspace.id,
        run_id: run.id,
        run_step_id: step.id,
        category: "tool",
        total_tokens: 3
      })

    {:ok, _safety} =
      HydraAgent.Safety.record_event(%{
        workspace_id: workspace.id,
        run_id: run.id,
        run_step_id: step.id,
        category: "runtime",
        severity: "info",
        action: "trace_check",
        summary: "Trace includes safety"
      })

    context = %{"workspace_id" => workspace.id, "run_id" => run.id, "run_step_id" => step.id}

    assert {:ok, %{"node_id" => memory_id}} =
             HydraAgent.Tools.KnowledgeWrite.execute(
               %{"type_key" => "memory", "title" => "Trace memory"},
               context
             )

    assert {:ok, %{"node_id" => artifact_id}} =
             HydraAgent.Tools.ArtifactRecord.execute(
               %{"title" => "Trace artifact", "path" => "reports/trace.json"},
               context
             )

    assert {:ok, %{"relationship_id" => relationship_id}} =
             HydraAgent.Tools.RelationshipCreate.execute(
               %{
                 "from_node_id" => artifact_id,
                 "to_node_id" => memory_id,
                 "type_key" => "relates_to"
               },
               context
             )

    trace = Runtime.trace_run(run.id)

    assert trace.run.id == run.id
    assert trace.mission.id == run.mission_id
    assert Enum.map(trace.steps, & &1.title) == ["Trace step"]
    assert Enum.any?(trace.events, &(&1.event_type == "run.created"))
    assert Enum.any?(trace.safety_events, &(&1.action == "trace_check"))
    assert Enum.any?(trace.knowledge_nodes, &(&1.id == memory_id))
    assert Enum.any?(trace.memory_nodes, &(&1.id == memory_id))
    assert Enum.any?(trace.artifact_nodes, &(&1.id == artifact_id))
    assert Enum.any?(trace.graph_relationships, &(&1.id == relationship_id))
    assert trace.usage_summary["total_tokens"] == 3
  end
end
