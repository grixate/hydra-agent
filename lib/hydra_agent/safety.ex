defmodule HydraAgent.Safety do
  @moduledoc """
  Safety ledger for policy decisions, approvals, blocks, and runtime incidents.
  """

  import Ecto.Query

  alias HydraAgent.Repo
  alias HydraAgent.Safety.Event

  def record_event(attrs) do
    %Event{} |> Event.changeset(attrs) |> Repo.insert()
  end

  def list_events(workspace_id, opts \\ []) do
    Event
    |> where([event], event.workspace_id == ^workspace_id)
    |> maybe_filter_category(opt(opts, :category))
    |> maybe_filter_run(opt(opts, :run_id))
    |> order_by([event], desc: event.inserted_at)
    |> limit(^opt(opts, :limit, 100))
    |> Repo.all()
  end

  defp maybe_filter_category(query, nil), do: query

  defp maybe_filter_category(query, category),
    do: where(query, [event], event.category == ^category)

  defp maybe_filter_run(query, nil), do: query

  defp maybe_filter_run(query, run_id),
    do: where(query, [event], event.run_id == ^run_id)

  defp opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp opt(opts, key) when is_map(opts), do: Map.get(opts, key) || Map.get(opts, to_string(key))

  defp opt(opts, key, default) do
    opt(opts, key) || default
  end
end
