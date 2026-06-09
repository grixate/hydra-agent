defmodule HydraAgent.Tools.Registry do
  @moduledoc """
  Registry of built-in tool modules.

  Agent packs and runtime policies reference tools by these stable names.
  """

  alias HydraAgent.Plugins
  alias HydraAgent.Tools.PluginProxy

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
    HydraAgent.Tools.SimulationEstimate,
    HydraAgent.Tools.SimulationCreate,
    HydraAgent.Tools.SimulationStart,
    HydraAgent.Tools.SimulationCancel,
    HydraAgent.Tools.SimulationReplay,
    HydraAgent.Tools.SimulationExport,
    HydraAgent.Tools.SimulationDuplicate,
    HydraAgent.Tools.SimulationReport,
    HydraAgent.Tools.MultiModelConsensus,
    HydraAgent.Tools.ShellCommand,
    HydraAgent.Tools.McpCall,
    HydraAgent.Tools.Noop
  ]

  def all do
    Enum.map(@tools, &normalize_spec(&1.spec()))
  end

  def all(nil), do: all()

  def all(workspace_id) do
    all() ++ Plugins.enabled_tool_specs(workspace_id)
  end

  def names do
    Enum.map(all(), & &1.name)
  end

  def names(workspace_id) do
    Enum.map(all(workspace_id), & &1.name)
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

  def get(name, nil), do: get(name)

  def get(name, workspace_id) when is_binary(name) do
    get(name) ||
      workspace_id
      |> Plugins.enabled_tool_specs()
      |> Enum.find_value(fn spec ->
        if spec.name == name, do: {PluginProxy, normalize_spec(spec)}
      end)
  end

  def get(name, _workspace_id), do: get(name)

  def execute(name, input, context) when is_binary(name) do
    workspace_id = (context || %{})["workspace_id"] || (context || %{})[:workspace_id]

    case get(name, workspace_id) do
      {module, spec} -> execute_with_timeout(module, spec, input || %{}, context || %{})
      nil -> {:error, %{"reason" => "unknown_tool", "tool_name" => name}}
    end
  end

  defp execute_with_timeout(module, spec, input, context) do
    timeout_ms = timeout_ms(spec, input)
    task = Task.async(fn -> execute_module(module, spec, input, context) end)

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

  defp execute_module(PluginProxy, spec, input, context),
    do: PluginProxy.execute(input, context, spec)

  defp execute_module(module, _spec, input, context), do: module.execute(input, context)

  defp timeout_ms(spec, input) do
    spec_timeout = spec[:timeout_ms] || spec["timeout_ms"] || 30_000

    case input do
      %{"timeout_ms" => timeout} when is_integer(timeout) -> min(max(timeout, 1), spec_timeout)
      %{timeout_ms: timeout} when is_integer(timeout) -> min(max(timeout, 1), spec_timeout)
      _input -> spec_timeout
    end
  end

  defp parallel_safe_by_default?(%{side_effect_class: "read_only"}), do: true
  defp parallel_safe_by_default?(_spec), do: false
end
