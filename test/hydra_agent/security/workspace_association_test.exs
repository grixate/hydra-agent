defmodule HydraAgent.Security.WorkspaceAssociationTest do
  use HydraAgent.DataCase

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.{Budgets, Connectors, Evals, Knowledge, Repo, Runtime, Skills}
  alias HydraAgent.Evals.{Case, Result}

  setup do
    first_workspace = workspace_fixture(%{slug: "association-first"})
    second_workspace = workspace_fixture(%{slug: "association-second"})
    first_agent = agent_fixture(first_workspace, %{slug: "association-first-agent"})
    second_agent = agent_fixture(second_workspace, %{slug: "association-second-agent"})

    {:ok,
     first_workspace: first_workspace,
     second_workspace: second_workspace,
     first_agent: first_agent,
     second_agent: second_agent}
  end

  test "runtime records reject agents, missions, and parents from another workspace", context do
    foreign_mission = mission_fixture(context.second_workspace, context.second_agent)

    foreign_parent =
      run_fixture(context.second_workspace, %{supervisor_agent_id: context.second_agent.id})

    assert {:error, mission_changeset} =
             Runtime.create_mission(%{
               workspace_id: context.first_workspace.id,
               supervisor_agent_id: context.second_agent.id,
               title: "Cross-workspace mission",
               objective: "Must be rejected"
             })

    assert "must belong to the same workspace" in errors_on(mission_changeset).supervisor_agent_id

    assert {:error, run_changeset} =
             Runtime.create_run(%{
               workspace_id: context.first_workspace.id,
               mission_id: foreign_mission.id,
               supervisor_agent_id: context.second_agent.id,
               parent_run_id: foreign_parent.id,
               title: "Cross-workspace run",
               goal: "Must be rejected"
             })

    assert "must belong to the same workspace" in errors_on(run_changeset).mission_id
    assert "must belong to the same workspace" in errors_on(run_changeset).supervisor_agent_id
    assert "must belong to the same workspace" in errors_on(run_changeset).parent_run_id

    assert {:error, policy_changeset} =
             Runtime.create_tool_policy(%{
               workspace_id: context.first_workspace.id,
               agent_id: context.second_agent.id,
               allowed_tools: ["noop"],
               side_effect_classes: ["read_only"]
             })

    assert "must belong to the same workspace" in errors_on(policy_changeset).agent_id

    assert {:error, conversation_changeset} =
             Runtime.create_conversation(%{
               workspace_id: context.first_workspace.id,
               agent_id: context.second_agent.id
             })

    assert "must belong to the same workspace" in errors_on(conversation_changeset).agent_id

    first_run = run_fixture(context.first_workspace)

    assert {:error, step_changeset} =
             Runtime.create_run_step(first_run, %{
               index: 0,
               title: "Foreign assignee",
               assigned_agent_id: context.second_agent.id
             })

    assert "must belong to the same workspace" in errors_on(step_changeset).assigned_agent_id
  end

  test "budgets, knowledge, skills, connectors, and evals reject foreign associations", context do
    foreign_run =
      run_fixture(context.second_workspace, %{supervisor_agent_id: context.second_agent.id})

    assert {:error, budget_changeset} =
             Budgets.create_budget(%{
               workspace_id: context.first_workspace.id,
               agent_id: context.second_agent.id,
               name: "Foreign agent budget",
               period: "total",
               token_limit: 100
             })

    assert "must belong to the same workspace" in errors_on(budget_changeset).agent_id

    assert {:error, node_changeset} =
             Knowledge.create_node(%{
               workspace_id: context.first_workspace.id,
               created_by_agent_id: context.second_agent.id,
               type_key: "memory",
               title: "Foreign author"
             })

    assert "must belong to the same workspace" in errors_on(node_changeset).created_by_agent_id

    assert {:error, skill_changeset} =
             Skills.create_skill(%{
               workspace_id: context.first_workspace.id,
               owner_agent_id: context.second_agent.id,
               source_run_id: foreign_run.id,
               name: "Foreign source skill",
               slug: "foreign-source-skill",
               description: "Must be rejected",
               instructions: "Do not cross tenant boundaries."
             })

    assert "must belong to the same workspace" in errors_on(skill_changeset).owner_agent_id
    assert "must belong to the same workspace" in errors_on(skill_changeset).source_run_id

    {:ok, account} =
      Connectors.create_account(%{
        workspace_id: context.first_workspace.id,
        provider: "notes",
        slug: "association-notes",
        display_name: "Association notes"
      })

    assert {:error, connector_changeset} =
             Connectors.request_action(account, %{
               action: "read",
               agent_id: context.second_agent.id
             })

    assert "must belong to the same workspace" in errors_on(connector_changeset).agent_id

    {:ok, foreign_suite} =
      Evals.create_suite(%{
        workspace_id: context.second_workspace.id,
        name: "Foreign suite",
        slug: "foreign-suite"
      })

    assert {:error, eval_run_changeset} =
             Evals.create_run(%{
               workspace_id: context.first_workspace.id,
               suite_id: foreign_suite.id,
               agent_id: context.second_agent.id
             })

    assert "must belong to the same workspace" in errors_on(eval_run_changeset).suite_id
    assert "must belong to the same workspace" in errors_on(eval_run_changeset).agent_id

    case_changeset =
      Case.changeset(%Case{}, %{
        workspace_id: context.first_workspace.id,
        suite_id: foreign_suite.id,
        name: "Foreign case",
        slug: "foreign-case",
        prompt: "Must be rejected"
      })

    refute case_changeset.valid?
    assert "must belong to the same workspace" in errors_on(case_changeset).suite_id

    {:ok, foreign_eval_run} =
      Evals.create_run(%{
        workspace_id: context.second_workspace.id,
        suite_id: foreign_suite.id,
        agent_id: context.second_agent.id
      })

    foreign_case =
      %Case{}
      |> Case.changeset(%{
        workspace_id: context.second_workspace.id,
        suite_id: foreign_suite.id,
        name: "Foreign result case",
        slug: "foreign-result-case",
        prompt: "Must remain isolated"
      })
      |> Repo.insert!()

    result_changeset =
      Result.changeset(%Result{}, %{
        workspace_id: context.first_workspace.id,
        eval_run_id: foreign_eval_run.id,
        eval_case_id: foreign_case.id
      })

    refute result_changeset.valid?
    assert "must belong to the same workspace" in errors_on(result_changeset).eval_run_id
    assert "must belong to the same workspace" in errors_on(result_changeset).eval_case_id

    assert {:error, room_changeset} =
             HydraAgent.Rooms.create_room(%{
               workspace_id: context.first_workspace.id,
               coordinator_agent_id: context.second_agent.id,
               title: "Foreign coordinator room",
               slug: "foreign-coordinator-room"
             })

    assert "must belong to the same workspace" in errors_on(room_changeset).coordinator_agent_id
  end

  test "same-workspace and explicitly global credential pools remain valid", context do
    {:ok, mission} =
      Runtime.create_mission(%{
        workspace_id: context.first_workspace.id,
        supervisor_agent_id: context.first_agent.id,
        title: "Valid mission",
        objective: "Stay inside the workspace"
      })

    assert mission.supervisor_agent_id == context.first_agent.id

    {:ok, global_pool} =
      Runtime.create_credential_pool(%{
        name: "Global failover pool",
        slug: "global-failover-pool",
        env_vars: []
      })

    assert {:ok, provider} =
             Runtime.create_provider(%{
               workspace_id: context.first_workspace.id,
               credential_pool_id: global_pool.id,
               name: "workspace-provider",
               kind: "mock",
               model: "mock-1"
             })

    assert provider.credential_pool_id == global_pool.id
  end

  defp mission_fixture(workspace, agent) do
    {:ok, mission} =
      Runtime.create_mission(%{
        workspace_id: workspace.id,
        supervisor_agent_id: agent.id,
        title: "Foreign mission",
        objective: "Belongs elsewhere"
      })

    mission
  end
end
