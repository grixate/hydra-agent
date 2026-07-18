defmodule HydraAgent.Tools.CheckpointsTest do
  use HydraAgent.DataCase

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.Tools.{Checkpoints, FileWrite, ShellCommand}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "hydra-agent-checkpoints-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, root: root}
  end

  test "records diffs and restores file checkpoints", %{root: root} do
    workspace = workspace_fixture()
    run = run_fixture(workspace)
    context = %{"workspace_root" => root, "workspace_id" => workspace.id, "run_id" => run.id}

    File.mkdir_p!(Path.join(root, "notes"))
    File.write!(Path.join(root, "notes/result.txt"), "before\n")

    assert {:ok, write} =
             FileWrite.execute(%{"path" => "notes/result.txt", "content" => "after\n"}, context)

    assert write["checkpoint"]["record_id"]
    [checkpoint] = Checkpoints.list_records(workspace.id, run_id: run.id)
    assert checkpoint.relative_path == "notes/result.txt"

    assert {:ok, %{"changed" => true, "diff" => diff}} =
             Checkpoints.diff_record(checkpoint.id, context)

    assert diff =~ "- before"
    assert diff =~ "+ after"

    assert {:ok, restored} = Checkpoints.restore_record(checkpoint.id, context)
    assert restored["restored_at"]
    assert File.read!(Path.join(root, "notes/result.txt")) == "before\n"
  end

  test "shell commands infer redirection checkpoint targets", %{root: root} do
    workspace = workspace_fixture()
    run = run_fixture(workspace)
    context = %{"workspace_root" => root, "workspace_id" => workspace.id, "run_id" => run.id}

    File.write!(Path.join(root, "notes.txt"), "old")

    assert {:ok, result} =
             ShellCommand.execute(
               %{"command" => ["sh", "-c", "printf new > notes.txt"], "cwd" => root},
               context
             )

    assert [%{"record_id" => record_id}] = result["checkpoints"]
    assert File.read!(Path.join(root, "notes.txt")) == "new"

    assert {:ok, _restored} = Checkpoints.restore_record(record_id, context)
    assert File.read!(Path.join(root, "notes.txt")) == "old"
  end

  test "restore refuses symlinked targets and checkpoint files", %{root: root} do
    workspace = workspace_fixture()
    run = run_fixture(workspace)
    context = %{"workspace_root" => root, "workspace_id" => workspace.id, "run_id" => run.id}
    target = Path.join(root, "notes.txt")
    outside = root <> "-outside.txt"
    File.write!(target, "before")
    File.write!(outside, "outside")

    assert {:ok, write} =
             FileWrite.execute(%{"path" => "notes.txt", "content" => "after"}, context)

    record_id = write["checkpoint"]["record_id"]
    checkpoint_path = write["checkpoint"]["checkpoint_path"]
    File.rm!(target)
    File.ln_s!(outside, target)

    assert {:error, %{"reason" => "workspace_path_symlink"}} =
             Checkpoints.restore_record(record_id, context)

    File.rm!(target)
    File.write!(target, "after")
    File.rm!(checkpoint_path)
    File.ln_s!(outside, checkpoint_path)

    assert {:error, %{"reason" => "workspace_path_symlink"}} =
             Checkpoints.restore_record(record_id, context)

    assert File.read!(outside) == "outside"
    File.rm!(outside)
  end
end
