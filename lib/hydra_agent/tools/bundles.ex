defmodule HydraAgent.Tools.Bundles do
  @moduledoc """
  Named tool bundles used as policy templates.

  Bundles only expand into explicit tool names and side-effect classes. Runtime
  authorization still checks agent capabilities, tool policies, and input
  allowlists for every individual tool call.
  """

  alias HydraAgent.Tools.Registry

  @bundles [
    %{
      name: "knowledge_read",
      description: "Read-only workspace knowledge search and lookup.",
      tools: ["knowledge_search", "knowledge_read", "noop"],
      requires_approval: false
    },
    %{
      name: "knowledge_write",
      description: "Create knowledge nodes, relationships, sources, and artifacts.",
      tools: [
        "knowledge_search",
        "knowledge_read",
        "knowledge_write",
        "relationship_create",
        "source_ingest",
        "artifact_record"
      ],
      requires_approval: true
    },
    %{
      name: "files_read",
      description: "List and read files inside explicit filesystem allowlists.",
      tools: ["file_list", "file_read"],
      requires_approval: false
    },
    %{
      name: "files_write",
      description: "List, read, and write files inside explicit filesystem allowlists.",
      tools: ["file_list", "file_read", "file_write"],
      requires_approval: true
    },
    %{
      name: "web_research",
      description: "Fetch allowlisted web pages and record sources/artifacts.",
      tools: ["http_fetch", "source_ingest", "artifact_record"],
      requires_approval: true
    },
    %{
      name: "browser",
      description: "Drive browser-capable workers through policy-gated browser intents.",
      tools: [
        "browser_navigate",
        "browser_click",
        "browser_type",
        "browser_screenshot",
        "browser_extract"
      ],
      requires_approval: true
    },
    %{
      name: "vision",
      description: "Analyze image artifacts, files, or URLs through vision-capable workflows.",
      tools: ["vision_analyze"],
      requires_approval: false
    },
    %{
      name: "image_gen",
      description: "Create artifact-backed image generation requests.",
      tools: ["image_generate"],
      requires_approval: true
    },
    %{
      name: "tts",
      description: "Create artifact-backed text-to-speech requests.",
      tools: ["text_to_speech"],
      requires_approval: true
    },
    %{
      name: "code_execution",
      description: "Execute small local code snippets or project-local code skill entrypoints.",
      tools: ["code_execute", "project_skill_run"],
      requires_approval: true
    },
    %{
      name: "multi_model",
      description: "Ask multiple configured providers and return a consensus record.",
      tools: ["multi_model_consensus"],
      requires_approval: true
    },
    %{
      name: "terminal",
      description: "Run explicitly allowlisted non-interactive shell commands.",
      tools: ["shell_command"],
      requires_approval: true
    },
    %{
      name: "mcp",
      description: "Call explicitly included tools on active configured MCP servers.",
      tools: ["mcp_call"],
      requires_approval: true
    }
  ]

  def all do
    Enum.map(@bundles, &normalize_bundle/1)
  end

  def names, do: Enum.map(all(), & &1.name)

  def get(name) when is_binary(name) do
    Enum.find(all(), &(&1.name == name))
  end

  def get(_name), do: nil

  def expand(names) when is_list(names) do
    names = Enum.map(names, &to_string/1)
    unknown = names -- names()

    if unknown == [] do
      selected = Enum.map(names, &get/1)

      {:ok,
       %{
         "tool_bundles" => names,
         "allowed_tools" => selected |> Enum.flat_map(& &1.tools) |> Enum.uniq(),
         "side_effect_classes" =>
           selected |> Enum.flat_map(& &1.side_effect_classes) |> Enum.uniq(),
         "requires_approval" => Enum.any?(selected, & &1.requires_approval)
       }}
    else
      {:error, unknown}
    end
  end

  def expand(_names), do: {:error, ["tool_bundles_must_be_a_list"]}

  defp normalize_bundle(bundle) do
    specs =
      bundle.tools
      |> Enum.map(&Registry.get/1)
      |> Enum.map(fn {_module, spec} -> spec end)

    bundle
    |> Map.put(:side_effect_classes, specs |> Enum.map(& &1.side_effect_class) |> Enum.uniq())
    |> Map.put(:approval_sensitive, Enum.any?(specs, & &1.approval_sensitive))
  end
end
