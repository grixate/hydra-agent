defmodule HydraAgent.RuntimeFixtures do
  @moduledoc """
  Helpers for DB-backed runtime tests.
  """

  alias HydraAgent.Runtime
  alias HydraAgent.Loops

  def workspace_fixture(attrs \\ %{}) do
    slug = Map.get(attrs, :slug) || Map.get(attrs, "slug") || unique_slug("workspace")

    attrs =
      %{
        name: "Test Workspace",
        slug: slug
      }
      |> Map.merge(attrs)

    {:ok, workspace} = Runtime.create_workspace(attrs)
    workspace
  end

  def agent_fixture(workspace, attrs \\ %{}) do
    role = Map.get(attrs, :role) || Map.get(attrs, "role") || "operator"
    slug = Map.get(attrs, :slug) || Map.get(attrs, "slug") || unique_slug(role)

    attrs =
      %{
        workspace_id: workspace.id,
        name: "Test #{String.capitalize(role)}",
        slug: slug,
        role: role
      }
      |> Map.merge(attrs)

    {:ok, agent} = Runtime.create_agent(attrs)
    agent
  end

  def tool_policy_fixture(workspace, attrs \\ %{}) do
    attrs =
      %{
        workspace_id: workspace.id,
        allowed_tools: ["noop", "knowledge_read"],
        side_effect_classes: ["read_only"],
        requires_approval: false
      }
      |> Map.merge(attrs)

    {:ok, policy} = Runtime.create_tool_policy(attrs)
    policy
  end

  def run_fixture(workspace, attrs \\ %{}) do
    attrs =
      %{
        workspace_id: workspace.id,
        title: "Test Run",
        goal: "Exercise the runtime"
      }
      |> Map.merge(attrs)

    {:ok, run} = Runtime.create_run(attrs)
    run
  end

  def loop_fixture(workspace, attrs \\ %{}) do
    agent = Map.get(attrs, :supervisor_agent) || agent_fixture(workspace, %{role: "supervisor"})

    attrs =
      %{
        workspace_id: workspace.id,
        supervisor_agent_id: agent.id,
        name: "Test Loop",
        slug: unique_slug("loop"),
        status: "active",
        purpose: "Exercise governed loop behavior",
        trigger: %{"type" => "manual"},
        guardrails: %{
          "max_iterations_per_tick" => 1,
          "max_child_runs_per_tick" => 3,
          "max_consecutive_no_progress" => 3,
          "max_runtime_seconds" => 300
        }
      }
      |> Map.merge(Map.drop(attrs, [:supervisor_agent]))

    {:ok, loop} = Loops.create_loop(attrs)
    loop
  end

  def run_step_fixture(run, attrs \\ %{}) do
    attrs =
      %{
        index: 0,
        title: "Test Step",
        tool_name: "noop",
        side_effect_class: "read_only",
        input: %{"ok" => true}
      }
      |> Map.merge(attrs)

    {:ok, step} = Runtime.create_run_step(run, attrs)
    step
  end

  def runtime_fixture(attrs \\ %{}) do
    workspace = workspace_fixture()
    agent = agent_fixture(workspace, Map.get(attrs, :agent, %{}))

    tool_policy_fixture(
      workspace,
      %{agent_id: agent.id}
      |> Map.merge(Map.get(attrs, :policy, %{}))
    )

    run =
      run_fixture(
        workspace,
        %{supervisor_agent_id: agent.id}
        |> Map.merge(Map.get(attrs, :run, %{}))
      )

    %{workspace: workspace, agent: agent, run: run}
  end

  defp unique_slug(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end
end
