defmodule HydraAgent.Budgets do
  @moduledoc """
  Workspace and agent budget visibility.
  """

  import Ecto.Query

  alias HydraAgent.Budgets.Budget
  alias HydraAgent.{Repo, Usage}

  def create_budget(attrs) do
    %Budget{} |> Budget.changeset(attrs) |> Repo.insert()
  end

  def list_budgets(workspace_id, opts \\ []) do
    Budget
    |> where([budget], budget.workspace_id == ^workspace_id)
    |> maybe_filter_agent(opt(opts, :agent_id))
    |> maybe_filter_status(opt(opts, :status))
    |> order_by([budget], asc: budget.name)
    |> Repo.all()
  end

  def get_budget!(id), do: Repo.get!(Budget, id)

  def budget_status(%Budget{} = budget) do
    usage_opts =
      []
      |> maybe_put(:agent_id, budget.agent_id)
      |> maybe_put(:category, budget.category)
      |> maybe_put(:since, period_start(budget.period))

    summary = Usage.summarize(budget.workspace_id, usage_opts)
    token_limit = budget.token_limit
    cost_limit = budget.cost_limit

    %{
      "budget_id" => budget.id,
      "status" => limit_status(summary, token_limit, cost_limit),
      "period" => budget.period,
      "category" => budget.category,
      "used_tokens" => summary["total_tokens"],
      "token_limit" => token_limit,
      "token_ratio" => ratio(summary["total_tokens"], token_limit),
      "used_cost" => nil,
      "cost_limit" => cost_limit,
      "cost_ratio" => nil,
      "usage" => summary
    }
  end

  def list_budget_statuses(workspace_id, opts \\ []) do
    workspace_id
    |> list_budgets(opts)
    |> Enum.map(&budget_status/1)
  end

  def check_available(workspace_id, opts \\ []) do
    applicable =
      workspace_id
      |> list_budgets(status: "active")
      |> Enum.filter(&applies_to?(&1, opts))
      |> Enum.map(&budget_status/1)

    case Enum.find(applicable, &(&1["status"] == "exceeded")) do
      nil ->
        :ok

      status ->
        {:error,
         %{
           "reason" => "budget_exceeded",
           "budget_id" => status["budget_id"],
           "category" => status["category"],
           "period" => status["period"],
           "used_tokens" => status["used_tokens"],
           "token_limit" => status["token_limit"]
         }}
    end
  end

  defp maybe_filter_agent(query, nil), do: query

  defp maybe_filter_agent(query, agent_id),
    do: where(query, [budget], budget.agent_id == ^agent_id)

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [budget], budget.status == ^status)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp applies_to?(budget, opts) do
    agent_id = opt(opts, :agent_id)
    category = opt(opts, :category)

    (is_nil(budget.agent_id) or is_nil(agent_id) or
       to_string(budget.agent_id) == to_string(agent_id)) and
      (is_nil(budget.category) or is_nil(category) or budget.category == category)
  end

  defp period_start("daily"), do: DateTime.utc_now() |> DateTime.add(-1, :day)
  defp period_start("weekly"), do: DateTime.utc_now() |> DateTime.add(-7, :day)
  defp period_start("monthly"), do: DateTime.utc_now() |> DateTime.add(-31, :day)
  defp period_start("total"), do: nil
  defp period_start(_period), do: nil

  defp limit_status(_summary, nil, nil), do: "unbounded"

  defp limit_status(summary, token_limit, _cost_limit) when is_integer(token_limit) do
    cond do
      summary["total_tokens"] >= token_limit -> "exceeded"
      ratio(summary["total_tokens"], token_limit) >= 0.8 -> "warning"
      true -> "ok"
    end
  end

  defp limit_status(_summary, _token_limit, _cost_limit), do: "ok"

  defp ratio(_used, nil), do: nil
  defp ratio(_used, 0), do: nil
  defp ratio(used, limit), do: used / limit

  defp opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp opt(opts, key) when is_map(opts), do: Map.get(opts, key) || Map.get(opts, to_string(key))
end
