defmodule HydraAgent.Tools.Registry do
  @moduledoc """
  Registry of built-in tool modules.

  Agent packs and runtime policies reference tools by these stable names.
  """

  @tools [
    HydraAgent.Tools.KnowledgeSearch,
    HydraAgent.Tools.KnowledgeRead,
    HydraAgent.Tools.KnowledgeWrite,
    HydraAgent.Tools.RelationshipCreate,
    HydraAgent.Tools.SourceIngest,
    HydraAgent.Tools.ArtifactRecord,
    HydraAgent.Tools.FileList,
    HydraAgent.Tools.FileRead,
    HydraAgent.Tools.FileWrite,
    HydraAgent.Tools.HttpFetch,
    HydraAgent.Tools.BrowserNavigate,
    HydraAgent.Tools.BrowserClick,
    HydraAgent.Tools.BrowserType,
    HydraAgent.Tools.BrowserScreenshot,
    HydraAgent.Tools.BrowserExtract,
    HydraAgent.Tools.VisionAnalyze,
    HydraAgent.Tools.ImageGenerate,
    HydraAgent.Tools.TextToSpeech,
    HydraAgent.Tools.CodeExecute,
    HydraAgent.Tools.ProjectSkillRun,
    HydraAgent.Tools.MultiModelConsensus,
    HydraAgent.Tools.ShellCommand,
    HydraAgent.Tools.McpCall,
    HydraAgent.Tools.Noop
  ]

  def all do
    Enum.map(@tools, &normalize_spec(&1.spec()))
  end

  def names do
    Enum.map(all(), & &1.name)
  end

  def parallel_safe_names do
    all()
    |> Enum.filter(& &1.parallel_safe)
    |> Enum.map(& &1.name)
  end

  def get(name) when is_binary(name) do
    Enum.find_value(@tools, fn module ->
      spec = normalize_spec(module.spec())
      if spec.name == name, do: {module, spec}
    end)
  end

  def get(_name), do: nil

  def execute(name, input, context) when is_binary(name) do
    case get(name) do
      {module, spec} -> execute_with_timeout(module, spec, input || %{}, context || %{})
      nil -> {:error, %{"reason" => "unknown_tool", "tool_name" => name}}
    end
  end

  defp execute_with_timeout(module, spec, input, context) do
    timeout_ms = spec[:timeout_ms] || spec["timeout_ms"] || 30_000
    task = Task.async(fn -> module.execute(input, context) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        {:error,
         %{"reason" => "tool_timeout", "timeout_ms" => timeout_ms, "tool_name" => spec.name}}
    end
  end

  defp normalize_spec(spec) do
    spec
    |> Map.put_new(:parallel_safe, parallel_safe_by_default?(spec))
  end

  defp parallel_safe_by_default?(%{side_effect_class: "read_only"}), do: true
  defp parallel_safe_by_default?(_spec), do: false
end
