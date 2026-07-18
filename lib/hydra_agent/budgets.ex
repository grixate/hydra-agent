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
    used_cost = summary["estimated_cost"] || Decimal.new(0)

    %{
      "budget_id" => budget.id,
      "status" => limit_status(summary, token_limit, cost_limit),
      "period" => budget.period,
      "category" => budget.category,
      "used_tokens" => summary["total_tokens"],
      "token_limit" => token_limit,
      "token_ratio" => ratio(summary["total_tokens"], token_limit),
      "used_cost" => used_cost,
      "cost_limit" => cost_limit,
      "cost_ratio" => ratio(used_cost, cost_limit),
      "unpriced_records" => summary["unpriced_records"],
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
           "token_limit" => status["token_limit"],
           "used_cost" => status["used_cost"],
           "cost_limit" => status["cost_limit"],
           "unpriced_records" => status["unpriced_records"]
         }}
    end
  end

  @doc """
  Atomically checks active budgets and records the provider capacity reserved
  by a pending call. Concurrent callers serialize on the applicable budget
  rows, so both cannot spend the same remaining allowance.
  """
  def reserve_provider_call(workspace_id, opts) do
    requested_tokens = max(opt(opts, :requested_tokens) || 0, 0)
    estimated_cost = decimal_or_nil(opt(opts, :estimated_cost))
    category = opt(opts, :category) || "chat"

    Repo.transaction(fn ->
      budgets =
        Budget
        |> where([budget], budget.workspace_id == ^workspace_id and budget.status == "active")
        |> order_by([budget], asc: budget.id)
        |> lock("FOR UPDATE")
        |> Repo.all()
        |> Enum.filter(&applies_to?(&1, opts))

      Enum.each(budgets, fn budget ->
        case projected_budget_error(budget, requested_tokens, estimated_cost) do
          nil -> :ok
          error -> Repo.rollback(error)
        end
      end)

      context =
        opts
        |> Map.new()
        |> Map.take([:agent_id, :run_id, :run_step_id, :conversation_id, :turn_id])
        |> Map.put(:workspace_id, workspace_id)

      case Usage.reserve_provider_call(context, category, requested_tokens, estimated_cost) do
        {:ok, reservation} -> reservation
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
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

  defp limit_status(summary, token_limit, cost_limit) do
    token_ratio = ratio(summary["total_tokens"], token_limit)
    cost_ratio = ratio(summary["estimated_cost"] || Decimal.new(0), cost_limit)

    cond do
      is_nil(token_limit) and is_nil(cost_limit) -> "unbounded"
      not is_nil(cost_limit) and summary["unpriced_records"] > 0 -> "exceeded"
      threshold_reached?(token_ratio, 1.0) or threshold_reached?(cost_ratio, 1.0) -> "exceeded"
      threshold_reached?(token_ratio, 0.8) or threshold_reached?(cost_ratio, 0.8) -> "warning"
      true -> "ok"
    end
  end

  defp ratio(_used, nil), do: nil
  defp ratio(_used, 0), do: nil

  defp ratio(%Decimal{} = used, %Decimal{} = limit),
    do: used |> Decimal.div(limit) |> Decimal.to_float()

  defp ratio(used, limit), do: used / limit

  defp threshold_reached?(nil, _threshold), do: false
  defp threshold_reached?(ratio, threshold), do: ratio >= threshold

  defp projected_budget_error(budget, requested_tokens, estimated_cost) do
    status = budget_status(budget)
    projected_tokens = status["used_tokens"] + requested_tokens

    cond do
      status["status"] == "exceeded" ->
        budget_error(budget, status, "budget_exceeded")

      not is_nil(budget.cost_limit) and is_nil(estimated_cost) ->
        budget_error(budget, status, "cost_estimate_required")

      not is_nil(budget.token_limit) and projected_tokens > budget.token_limit ->
        budget_error(budget, status, "budget_reservation_exceeds_limit")

      not is_nil(budget.cost_limit) and
          Decimal.compare(Decimal.add(status["used_cost"], estimated_cost), budget.cost_limit) ==
            :gt ->
        budget_error(budget, status, "budget_reservation_exceeds_limit")

      true ->
        nil
    end
  end

  defp budget_error(budget, status, reason) do
    %{
      "reason" => reason,
      "budget_id" => budget.id,
      "category" => budget.category,
      "period" => budget.period,
      "used_tokens" => status["used_tokens"],
      "token_limit" => budget.token_limit,
      "used_cost" => status["used_cost"],
      "cost_limit" => budget.cost_limit
    }
  end

  defp decimal_or_nil(nil), do: nil
  defp decimal_or_nil(%Decimal{} = value), do: value
  defp decimal_or_nil(value) when is_integer(value), do: Decimal.new(value)
  defp decimal_or_nil(value) when is_float(value), do: Decimal.from_float(value)
  defp decimal_or_nil(value) when is_binary(value), do: Decimal.new(value)

  defp opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp opt(opts, key) when is_map(opts), do: Map.get(opts, key) || Map.get(opts, to_string(key))
end
