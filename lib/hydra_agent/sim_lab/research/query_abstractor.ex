defmodule HydraAgent.SimLab.Research.QueryAbstractor do
  @moduledoc """
  Detects and removes common private identifiers before a query leaves Hydra.

  This is a fail-closed query boundary, not a claim that arbitrary prose can be
  perfectly de-identified. Callers should pass known private entities as well;
  the returned audit makes every applied abstraction inspectable.
  """

  @patterns [
    {:email, ~r/\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/iu, "email address"},
    {:phone, ~r/(?<!\w)(?:\+?\d[\d\s().-]{7,}\d)(?!\w)/u, "phone number"},
    {:uuid, ~r/\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b/iu,
     "internal identifier"},
    {:internal_id,
     ~r/\b(?:employee|customer|account|user|ticket)[ _-]?(?:id|no|number)?\s*[:#-]?\s*[A-Z0-9][A-Z0-9-]{3,}\b/iu,
     "internal identifier"},
    {:ip_address, ~r/\b(?:\d{1,3}\.){3}\d{1,3}\b/u, "network address"},
    {:url, ~r/https?:\/\/[^\s]+/iu, "internal link"},
    {:company,
     ~r/\b(?:Sber|Acme|Hydra|[\p{Lu}][\p{L}\p{N}&'.-]+(?:\s+[\p{Lu}][\p{L}\p{N}&'.-]+){0,3}\s+(?:Inc|Ltd|LLC|PLC|GmbH|Oy|SA|AG))\b/u,
     "organisation"},
    {:metric, ~r/\b\d{2,}(?:\.\d+)?%/u, "market metric"}
  ]

  def abstract(query), do: abstract(query, [])

  def abstract(query, opts) when is_binary(query), do: analyze(query, opts).abstracted
  def abstract(_, _), do: ""

  def analyze(query, opts \\ [])

  def analyze(query, opts) when is_binary(query) do
    private_entities =
      opts
      |> Map.new()
      |> Map.get(:private_entities, [])
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    {query, findings} = replace_private_entities(query, private_entities)

    {abstracted, findings} =
      Enum.reduce(@patterns, {query, findings}, fn {kind, pattern, replacement}, acc ->
        replace(acc, kind, pattern, replacement)
      end)

    %{
      abstracted: abstracted |> String.replace(~r/\s+/, " ") |> String.trim(),
      findings: findings |> Enum.reverse() |> Enum.uniq(),
      changed?: findings != []
    }
  end

  def analyze(_, _), do: %{abstracted: "", findings: [], changed?: false}

  def private?(query) when is_binary(query), do: analyze(query).changed?
  def private?(_), do: false

  defp replace_private_entities(query, []), do: {query, []}

  defp replace_private_entities(query, entities) do
    pattern = ~r/#{Enum.map_join(entities, "|", &Regex.escape/1)}/iu
    replace({query, []}, :known_private_entity, pattern, "private study detail")
  end

  defp replace({query, findings}, kind, pattern, replacement) do
    count = length(Regex.scan(pattern, query))

    if count == 0 do
      {query, findings}
    else
      {Regex.replace(pattern, query, replacement), [%{kind: kind, count: count} | findings]}
    end
  end
end
