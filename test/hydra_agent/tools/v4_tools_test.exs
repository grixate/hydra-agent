defmodule HydraAgent.Tools.V4ToolsTest do
  use HydraAgent.DataCase

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.Runtime
  alias HydraAgent.Tools.Registry

  test "vision tool accepts image inputs and rejects non-images" do
    assert {:ok, %{"modality" => "image"}} =
             Registry.execute("vision_analyze", %{"path" => "artifact.png"}, %{})

    assert {:error, %{"reason" => "unsupported_vision_input"}} =
             Registry.execute("vision_analyze", %{"path" => "notes.txt"}, %{})
  end

  test "media-generation tools create artifact records" do
    workspace = workspace_fixture(%{slug: "v4-media-tools"})
    agent = agent_fixture(workspace, %{slug: "v4-media-agent"})

    context = %{"workspace_id" => workspace.id, "agent_id" => agent.id}

    assert {:ok, %{"node_id" => image_node_id}} =
             Registry.execute("image_generate", %{"prompt" => "diagram"}, context)

    assert is_integer(image_node_id)

    assert {:ok, %{"node_id" => audio_node_id}} =
             Registry.execute("text_to_speech", %{"text" => "hello"}, context)

    assert is_integer(audio_node_id)
  end

  test "code execution is bounded to supported runtimes" do
    assert {:ok, %{"exit_status" => 0, "output" => output}} =
             Registry.execute(
               "code_execute",
               %{"runtime" => "elixir", "code" => "IO.write(1 + 1)"},
               %{}
             )

    assert output == "2"

    assert {:error, %{"reason" => "unsupported_or_oversized_code_execution"}} =
             Registry.execute("code_execute", %{"runtime" => "python", "code" => "print(1)"}, %{})

    assert {:error, %{"reason" => "unsafe_code_execution", "pattern" => "Req."}} =
             Registry.execute(
               "code_execute",
               %{"runtime" => "elixir", "code" => ~s|Req.get!("https://example.com")|},
               %{}
             )

    assert {:error, %{"reason" => "unsafe_code_execution", "pattern" => "require("}} =
             Registry.execute(
               "code_execute",
               %{"runtime" => "node", "code" => ~s|require("fs").readFileSync("x")|},
               %{}
             )
  end

  test "browser tools record auditable sessions when no worker is configured" do
    workspace = workspace_fixture(%{slug: "v4-browser-tools"})
    agent = agent_fixture(workspace, %{slug: "v4-browser-agent"})

    assert {:ok, result} =
             Registry.execute(
               "browser_navigate",
               %{"url" => "https://example.com"},
               %{"workspace_id" => workspace.id, "agent_id" => agent.id}
             )

    assert result["status"] == "recorded"
    assert result["backend"] == "recorded"
    assert is_integer(result["browser_session_id"])
    assert is_integer(result["artifact_id"])

    assert {:error, %{"reason" => "browser_url_not_allowed"}} =
             Registry.execute(
               "browser_navigate",
               %{"url" => "https://blocked.example"},
               %{"browser_allowlist" => ["example.com"]}
             )
  end

  test "project skill runner executes project-local skill entrypoints" do
    root =
      Path.join(
        System.tmp_dir!(),
        "hydra-project-skill-run-#{System.unique_integer([:positive])}"
      )

    skill_dir = Path.join([root, ".hydra", "skills", "hello-skill", "scripts"])
    File.mkdir_p!(skill_dir)
    File.write!(Path.join(skill_dir, "run.sh"), "echo project-skill-ok\n")

    assert {:ok, %{"exit_status" => 0, "output" => "project-skill-ok\n"}} =
             Registry.execute(
               "project_skill_run",
               %{
                 "skill_slug" => "hello-skill",
                 "entrypoint" => "scripts/run.sh",
                 "runtime" => "shell"
               },
               %{"workspace_root" => root}
             )

    assert {:error, %{"reason" => "unsafe_project_skill_entrypoint"}} =
             Registry.execute(
               "project_skill_run",
               %{
                 "skill_slug" => "hello-skill",
                 "entrypoint" => "../outside.sh",
                 "runtime" => "shell"
               },
               %{"workspace_root" => root}
             )
  end

  test "multi-model consensus records partial provider results" do
    workspace = workspace_fixture(%{slug: "v4-consensus-tools"})

    {:ok, _provider} =
      Runtime.create_provider(%{
        workspace_id: workspace.id,
        name: "mock",
        kind: "mock",
        model: "mock-model"
      })

    assert {:ok, %{"ok_count" => 1, "responses" => responses, "synthesis" => synthesis}} =
             Registry.execute(
               "multi_model_consensus",
               %{"prompt" => "hello", "providers" => ["mock", "missing"]},
               %{"workspace_id" => workspace.id}
             )

    assert Enum.any?(responses, &(&1["status"] == "missing"))
    assert synthesis =~ "mock: hello"
  end
end
