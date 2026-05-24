defmodule HydraAgent.Tools.FileToolsTest do
  use ExUnit.Case, async: true

  alias HydraAgent.Tools.{FileList, FileRead, FileWrite}

  setup do
    root =
      Path.join(System.tmp_dir!(), "hydra-agent-file-tools-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, root: root}
  end

  test "writes, reads, and lists workspace files", %{root: root} do
    context = %{"workspace_root" => root}

    assert {:ok, write} =
             FileWrite.execute(%{"path" => "notes/result.txt", "content" => "hydra"}, context)

    assert write["bytes_written"] == 5

    assert {:ok, read} = FileRead.execute(%{"path" => "notes/result.txt"}, context)
    assert read["content"] == "hydra"

    assert {:ok, listed} = FileList.execute(%{"path" => "notes"}, context)
    assert [%{"type" => "file"}] = listed["entries"]
  end

  test "rejects paths outside workspace root", %{root: root} do
    assert {:error, %{"reason" => "path_outside_workspace_root"}} =
             FileRead.execute(%{"path" => "../outside.txt"}, %{"workspace_root" => root})
  end
end
