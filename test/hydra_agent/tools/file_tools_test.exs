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
    assert read["bytes_read"] == 5
    assert read["truncated"] == false

    assert {:ok, listed} = FileList.execute(%{"path" => "notes"}, context)
    assert [%{"type" => "file"}] = listed["entries"]
  end

  test "refuses binary reads unless explicitly allowed", %{root: root} do
    File.write!(Path.join(root, "bin.dat"), <<0, 1, 2, 3>>)

    assert {:error, %{"reason" => "binary_file_not_read", "bytes" => 4}} =
             FileRead.execute(%{"path" => "bin.dat"}, %{"workspace_root" => root})

    assert {:ok, read} =
             FileRead.execute(%{"path" => "bin.dat", "allow_binary" => true}, %{
               "workspace_root" => root
             })

    assert read["bytes_read"] == 4
  end

  test "supports bounded reads and validates max bytes", %{root: root} do
    File.write!(Path.join(root, "long.txt"), "abcdef")

    assert {:ok, read} =
             FileRead.execute(%{"path" => "long.txt", "max_bytes" => 3}, %{
               "workspace_root" => root
             })

    assert read["content"] == "abc"
    assert read["truncated"] == true

    assert {:error, %{"reason" => "invalid_max_bytes"}} =
             FileRead.execute(%{"path" => "long.txt", "max_bytes" => 0}, %{
               "workspace_root" => root
             })
  end

  test "create_new and expected sha protect file writes", %{root: root} do
    context = %{"workspace_root" => root}

    assert {:ok, created} =
             FileWrite.execute(
               %{"path" => "notes/conflict.txt", "content" => "one", "mode" => "create_new"},
               context
             )

    assert created["existed"] == false
    assert is_binary(created["sha256"])

    assert {:error, %{"reason" => "file_write_failed"}} =
             FileWrite.execute(
               %{"path" => "notes/conflict.txt", "content" => "two", "mode" => "create_new"},
               context
             )

    assert {:error, %{"reason" => "expected_sha256_mismatch"}} =
             FileWrite.execute(
               %{
                 "path" => "notes/conflict.txt",
                 "content" => "two",
                 "expected_sha256" => String.duplicate("0", 64)
               },
               context
             )

    assert {:ok, overwritten} =
             FileWrite.execute(
               %{
                 "path" => "notes/conflict.txt",
                 "content" => "two",
                 "expected_sha256" => created["sha256"]
               },
               context
             )

    assert overwritten["existed"] == true
    assert overwritten["checkpoint"]["existed"] == true
    assert File.read!(overwritten["checkpoint"]["checkpoint_path"]) == "one"
  end

  test "rejects paths outside workspace root", %{root: root} do
    assert {:error, %{"reason" => "path_outside_workspace_root"}} =
             FileRead.execute(%{"path" => "../outside.txt"}, %{"workspace_root" => root})
  end
end
