defmodule HydraAgent.Usage do
  @moduledoc """
  Provider/tool usage accounting.
  """

  import Ecto.Query

  alias HydraAgent.Repo
  alias HydraAgent.Usage.Record

  def record_provider_response(context, provider_response, category) do
    usage = provider_response["usage"] || %{}

    attrs =
      context
      |> stringify_keys()
      |> Map.merge(%{
        "provider" => provider_response["provider"],
        "model" => provider_response["model"],
        "category" => category,
        "status" => "ok",
        "input_tokens" => usage["input_tokens"] || 0,
        "output_tokens" => usage["output_tokens"] || 0,
        "total_tokens" =>
          usage["total_tokens"] || (usage["input_tokens"] || 0) + (usage["output_tokens"] || 0),
        "metadata" => %{"route" => provider_response["route"] || %{}}
      })

    create_record(attrs)
  end

  def record_error(context, error, category) do
    attrs =
      context
      |> stringify_keys()
      |> Map.merge(%{
        "category" => category,
        "status" => "error",
        "metadata" => %{"error" => error}
      })

    create_record(attrs)
  end

  def create_record(attrs) do
    %Record{} |> Record.changeset(attrs) |> Repo.insert()
  end

  def list_records(workspace_id, opts \\ []) do
    Record
    |> where([record], record.workspace_id == ^workspace_id)
    |> maybe_filter_category(opt(opts, :category))
    |> maybe_filter_agent(opt(opts, :agent_id))
    |> maybe_filter_inserted_after(opt(opts, :since))
    |> order_by([record], desc: record.inserted_at)
    |> limit(^Keyword.get(opts, :limit, 200))
    |> Repo.all()
  end

  def summarize(workspace_id, opts \\ []) do
    records = list_records(workspace_id, Keyword.merge([limit: 10_000], opts))

    %{
      "records" => length(records),
      "input_tokens" => Enum.sum(Enum.map(records, & &1.input_tokens)),
      "output_tokens" => Enum.sum(Enum.map(records, & &1.output_tokens)),
      "total_tokens" => Enum.sum(Enum.map(records, & &1.total_tokens)),
      "by_category" =>
        records
        |> Enum.group_by(& &1.category)
        |> Map.new(fn {category, category_records} -> {category, length(category_records)} end)
    }
  end

  defp maybe_filter_category(query, nil), do: query

  defp maybe_filter_category(query, category),
    do: where(query, [record], record.category == ^category)

  defp maybe_filter_agent(query, nil), do: query

  defp maybe_filter_agent(query, agent_id),
    do: where(query, [record], record.agent_id == ^agent_id)

  defp maybe_filter_inserted_after(query, nil), do: query

  defp maybe_filter_inserted_after(query, %DateTime{} = since),
    do: where(query, [record], record.inserted_at >= ^since)

  defp maybe_filter_inserted_after(query, _since), do: query

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp opt(opts, key) when is_map(opts), do: Map.get(opts, key) || Map.get(opts, to_string(key))
end
