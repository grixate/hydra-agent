defmodule HydraAgent.SimLab.Research.StudyParser do
  @moduledoc """
  Deterministically extracts enough context to plan safe research before an LLM
  protocol is available. The output is inspectable and intentionally modest.
  """

  def parse(question, attrs \\ %{}) when is_binary(question) do
    attrs = Map.new(attrs)
    normalized = String.downcase(question)

    %{
      question: String.trim(question),
      domain: Map.get(attrs, :domain) || Map.get(attrs, "domain") || infer_domain(normalized),
      region: Map.get(attrs, :region) || Map.get(attrs, "region"),
      language: Map.get(attrs, :language) || Map.get(attrs, "language") || "en",
      target_audience:
        Map.get(attrs, :target_audience) || Map.get(attrs, "target_audience") ||
          infer_audience(normalized),
      behavior: infer_behavior(normalized),
      change: infer_change(normalized),
      research_depth:
        Map.get(attrs, :research_depth) || Map.get(attrs, "research_depth") || "standard"
    }
  end

  defp infer_domain(question) do
    cond do
      String.contains?(question, ["certificate", "learning", "employee", "hr"]) ->
        "corporate learning / HR platform"

      String.contains?(question, ["checkout", "retail", "shopper"]) ->
        "retail"

      true ->
        "product adoption"
    end
  end

  defp infer_audience(question) do
    cond do
      String.contains?(question, ["employee", "hr"]) -> "employees"
      String.contains?(question, ["shopper", "consumer"]) -> "consumers"
      true -> "target users"
    end
  end

  defp infer_behavior(question) do
    cond do
      String.contains?(question, "react") -> "reaction to product or policy change"
      String.contains?(question, "adopt") -> "adoption"
      true -> "decision behavior"
    end
  end

  defp infer_change(question) do
    cond do
      String.contains?(question, "visible") -> "visibility setting changes"
      String.contains?(question, "launch") -> "product launch"
      true -> "proposed product change"
    end
  end
end
