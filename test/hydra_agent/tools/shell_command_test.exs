defmodule HydraAgent.Tools.ShellCommandTest do
  use ExUnit.Case, async: true

  alias HydraAgent.Tools.ShellCommand

  test "runs non-interactive argv commands" do
    assert {:ok, result} =
             ShellCommand.execute(%{"command" => ["echo", "hydra"]}, %{
               "workspace_root" => File.cwd!()
             })

    assert result["command"] == ["echo", "hydra"]
    assert result["exit_status"] == 0
    assert result["output"] =~ "hydra"
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
