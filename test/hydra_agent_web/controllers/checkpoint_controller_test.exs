defmodule HydraAgentWeb.CheckpointControllerTest do
  use HydraAgentWeb.ConnCase

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.Repo
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

  test "workspace-scoped diff and restore ignore a caller-supplied workspace root", %{
    conn: conn,
    root: root
  } do
    trusted_root = Path.join(root, "trusted")
    supplied_root = Path.join(root, "caller-supplied")
    File.mkdir_p!(trusted_root)
    File.mkdir_p!(supplied_root)

    workspace =
      workspace_fixture(%{
        name: "Trusted root",
        slug: "trusted-checkpoint-root",
        settings: %{"project_root" => trusted_root}
      })

    run = run_fixture(workspace)
    target = Path.join(trusted_root, "notes.txt")
    File.write!(target, "before")

    assert {:ok, write} =
             FileWrite.execute(
               %{"path" => "notes.txt", "content" => "after"},
               %{
                 "workspace_root" => trusted_root,
                 "workspace_id" => workspace.id,
                 "run_id" => run.id
               }
             )

    checkpoint_id = write["checkpoint"]["record_id"]

    diff_conn =
      get(
        conn,
        ~p"/api/v1/workspaces/#{workspace.id}/checkpoints/#{checkpoint_id}/diff?workspace_root=#{supplied_root}"
      )

    assert %{"data" => %{"changed" => true, "path" => ^target}} = json_response(diff_conn, 200)

    restore_conn =
      post(
        build_conn(),
        ~p"/api/v1/workspaces/#{workspace.id}/checkpoints/#{checkpoint_id}/restore",
        %{"workspace_root" => supplied_root}
      )

    assert %{"data" => %{"path" => ^target}} = json_response(restore_conn, 200)
    assert File.read!(target) == "before"
    refute File.exists?(Path.join(supplied_root, "notes.txt"))
  end

  test "workspace-scoped restore is fenced by the current trusted root after it changes", %{
    conn: conn,
    root: root
  } do
    original_root = Path.join(root, "original")
    current_root = Path.join(root, "current")
    File.mkdir_p!(original_root)
    File.mkdir_p!(current_root)

    workspace =
      workspace_fixture(%{
        name: "Rotated root",
        slug: "rotated-checkpoint-root",
        settings: %{"project_root" => original_root}
      })

    run = run_fixture(workspace)
    original_target = Path.join(original_root, "notes.txt")
    File.write!(original_target, "before")

    assert {:ok, write} =
             FileWrite.execute(
               %{"path" => "notes.txt", "content" => "after"},
               %{
                 "workspace_root" => original_root,
                 "workspace_id" => workspace.id,
                 "run_id" => run.id
               }
             )

    checkpoint_id = write["checkpoint"]["record_id"]

    workspace
    |> Ecto.Changeset.change(settings: %{"project_root" => current_root})
    |> Repo.update!()

    restore_conn =
      post(
        conn,
        ~p"/api/v1/workspaces/#{workspace.id}/checkpoints/#{checkpoint_id}/restore",
        %{"workspace_root" => original_root}
      )

    assert %{"errors" => %{"reason" => "restore_path_outside_workspace"}} =
             json_response(restore_conn, 422)

    assert File.read!(original_target) == "after"
    refute File.exists?(Path.join(current_root, "notes.txt"))
  end
end
