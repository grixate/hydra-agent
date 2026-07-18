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
        "estimated_cost" => provider_response["estimated_cost"] || usage["estimated_cost"],
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

  def reserve_provider_call(context, category, requested_tokens, estimated_cost \\ nil)
      when is_integer(requested_tokens) and requested_tokens >= 0 do
    context
    |> stringify_keys()
    |> Map.merge(%{
      "category" => category,
      "status" => "reserved",
      "total_tokens" => requested_tokens,
      "estimated_cost" => estimated_cost,
      "metadata" => %{"kind" => "provider_budget_reservation"}
    })
    |> create_record()
  end

  def complete_provider_reservation(%Record{} = reservation, provider_response) do
    usage = provider_response["usage"] || %{}

    reservation
    |> Record.changeset(%{
      "provider" => provider_response["provider"],
      "model" => provider_response["model"],
      "status" => "ok",
      "input_tokens" => usage["input_tokens"] || 0,
      "output_tokens" => usage["output_tokens"] || 0,
      "total_tokens" =>
        usage["total_tokens"] || (usage["input_tokens"] || 0) + (usage["output_tokens"] || 0),
      "estimated_cost" =>
        provider_response["estimated_cost"] || usage["estimated_cost"] ||
          reservation.estimated_cost,
      "metadata" =>
        Map.merge(reservation.metadata || %{}, %{"route" => provider_response["route"] || %{}})
    })
    |> Repo.update()
  end

  def fail_provider_reservation(%Record{} = reservation, error) do
    reservation
    |> Record.changeset(%{
      "status" => "error",
      "input_tokens" => 0,
      "output_tokens" => 0,
      "total_tokens" => 0,
      "estimated_cost" => nil,
      "metadata" => Map.merge(reservation.metadata || %{}, %{"error" => error})
    })
    |> Repo.update()
  end

  def attach_provider_context(%Record{} = reservation, attrs) do
    reservation
    |> Record.changeset(attrs)
    |> Repo.update()
  end

  def list_records(workspace_id, opts \\ []) do
    Record
    |> where([record], record.workspace_id == ^workspace_id)
    |> maybe_filter_category(opt(opts, :category))
    |> maybe_filter_agent(opt(opts, :agent_id))
    |> maybe_filter_run(opt(opts, :run_id))
    |> maybe_filter_inserted_after(opt(opts, :since))
    |> order_by([record], desc: record.inserted_at)
    |> limit(^Keyword.get(opts, :limit, 200))
    |> Repo.all()
  end

  def summarize(workspace_id, opts \\ []) do
    query =
      Record
      |> where([record], record.workspace_id == ^workspace_id)
      |> maybe_filter_category(opt(opts, :category))
      |> maybe_filter_agent(opt(opts, :agent_id))
      |> maybe_filter_run(opt(opts, :run_id))
      |> maybe_filter_inserted_after(opt(opts, :since))

    totals =
      query
      |> select([record], %{
        records: count(record.id),
        input_tokens: coalesce(sum(record.input_tokens), 0),
        output_tokens: coalesce(sum(record.output_tokens), 0),
        total_tokens: coalesce(sum(record.total_tokens), 0),
        estimated_cost: coalesce(sum(record.estimated_cost), 0),
        unpriced_records:
          fragment(
            "count(*) FILTER (WHERE ? IS NULL AND ? IN ('ok', 'reserved'))",
            record.estimated_cost,
            record.status
          )
      })
      |> Repo.one!()

    by_category =
      query
      |> group_by([record], record.category)
      |> select([record], {record.category, count(record.id)})
      |> Repo.all()
      |> Map.new()

    %{
      "records" => totals.records,
      "input_tokens" => totals.input_tokens,
      "output_tokens" => totals.output_tokens,
      "total_tokens" => totals.total_tokens,
      "estimated_cost" => totals.estimated_cost,
      "unpriced_records" => totals.unpriced_records,
      "by_category" => by_category
    }
  end

  defp maybe_filter_category(query, nil), do: query

  defp maybe_filter_category(query, category),
    do: where(query, [record], record.category == ^category)

  defp maybe_filter_agent(query, nil), do: query

  defp maybe_filter_agent(query, agent_id),
    do: where(query, [record], record.agent_id == ^agent_id)

  defp maybe_filter_run(query, nil), do: query

  defp maybe_filter_run(query, run_id),
    do: where(query, [record], record.run_id == ^run_id)

  defp maybe_filter_inserted_after(query, nil), do: query

  defp maybe_filter_inserted_after(query, %DateTime{} = since),
    do: where(query, [record], record.inserted_at >= ^since)

  defp maybe_filter_inserted_after(query, _since), do: query

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp opt(opts, key) when is_map(opts), do: Map.get(opts, key) || Map.get(opts, to_string(key))
end
