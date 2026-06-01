defmodule HydraAgentWeb.CheckpointControllerTest do
  use HydraAgentWeb.ConnCase

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.Tools.FileWrite

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "hydra-agent-checkpoint-controller-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, root: root}
  end

  test "workspace-scoped checkpoint diff and restore reject foreign checkpoint ids", %{
    conn: conn,
    root: root
  } do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-checkpoint-scope"})
    other_workspace = workspace_fixture(%{name: "Other Ops", slug: "other-ops-checkpoint-scope"})
    run = run_fixture(workspace)

    File.write!(Path.join(root, "notes.txt"), "before")

    assert {:ok, write} =
             FileWrite.execute(
               %{"path" => "notes.txt", "content" => "after"},
               %{"workspace_root" => root, "workspace_id" => workspace.id, "run_id" => run.id}
             )

    checkpoint_id = write["checkpoint"]["record_id"]

    assert_error_sent 404, fn ->
      get(conn, ~p"/api/v1/workspaces/#{other_workspace.id}/checkpoints/#{checkpoint_id}/diff")
    end

    assert_error_sent 404, fn ->
      post(
        build_conn(),
        ~p"/api/v1/workspaces/#{other_workspace.id}/checkpoints/#{checkpoint_id}/restore"
      )
    end
  end
end
