defmodule HydraAgent.Tools.ShellCommandTest do
  use ExUnit.Case, async: true

  alias HydraAgent.Tools.ShellCommand

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "hydra-agent-shell-tools-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, root: root}
  end

  test "runs non-interactive argv commands" do
    assert {:ok, result} =
             ShellCommand.execute(%{"command" => ["echo", "hydra"]}, %{
               "workspace_root" => File.cwd!()
             })

    assert result["command"] == ["echo", "hydra"]
    assert result["exit_status"] == 0
    assert result["output"] =~ "hydra"
    assert result["truncated"] == false
    assert result["output_bytes"] == byte_size(result["output"])
  end

  test "truncates oversized command output" do
    assert {:ok, result} =
             ShellCommand.execute(
               %{"command" => ["printf", "abcdef"], "max_output_bytes" => 3},
               %{"workspace_root" => File.cwd!()}
             )

    assert result["output"] == "abc"
    assert result["truncated"] == true
    assert result["output_bytes"] == 3
  end

  test "rejects command environment variables without an explicit allowlist" do
    assert {:error, %{"reason" => "shell_env_not_allowed", "env" => ["HYDRA_TEST_FLAG"]}} =
             ShellCommand.execute(
               %{"command" => ["echo", "hydra"], "env" => %{"HYDRA_TEST_FLAG" => "1"}},
               %{"workspace_root" => File.cwd!()}
             )
  end

  test "runs with allowlisted command environment variables" do
    assert {:ok, result} =
             ShellCommand.execute(
               %{
                 "command" => ["sh", "-c", "printf %s \"$HYDRA_TEST_FLAG\""],
                 "env" => %{"HYDRA_TEST_FLAG" => "enabled"}
               },
               %{
                 "workspace_root" => File.cwd!(),
                 "shell_env_allowlist" => ["HYDRA_TEST_FLAG"]
               }
             )

    assert result["output"] == "enabled"
  end

  test "creates checkpoints for declared shell mutation targets", %{root: root} do
    target = Path.join(root, "notes.txt")
    File.write!(target, "before")

    assert {:ok, result} =
             ShellCommand.execute(
               %{
                 "command" => ["sh", "-c", "printf after > notes.txt"],
                 "cwd" => root,
                 "checkpoint_paths" => ["notes.txt"]
               },
               %{"workspace_root" => root}
             )

    assert result["exit_status"] == 0
    assert [%{"existed" => true, "checkpoint_path" => checkpoint_path}] = result["checkpoints"]
    assert File.read!(checkpoint_path) == "before"
    assert File.read!(target) == "after"
  end

  test "rejects invalid command environment variable names" do
    assert {:error, %{"reason" => "invalid_env_names", "env" => ["plain-secret"]}} =
             ShellCommand.execute(
               %{"command" => ["echo", "hydra"], "env" => %{"plain-secret" => "1"}},
               %{
                 "workspace_root" => File.cwd!(),
                 "shell_env_allowlist" => ["*"]
               }
             )
  end

  test "validates max output bytes" do
    assert {:error, %{"reason" => "invalid_max_output_bytes"}} =
             ShellCommand.execute(
               %{"command" => ["echo", "hydra"], "max_output_bytes" => 0},
               %{"workspace_root" => File.cwd!()}
             )
  end

  test "rejects string shell commands" do
    assert {:error, %{"reason" => "command_must_be_non_empty_list"}} =
             ShellCommand.execute(%{"command" => "echo hydra"}, %{})
  end

  test "rejects cwd outside workspace root" do
    assert {:error, %{"reason" => "cwd_outside_workspace_root"}} =
             ShellCommand.execute(
               %{"command" => ["echo", "hydra"], "cwd" => "/"},
               %{"workspace_root" => File.cwd!()}
             )
  end
end
