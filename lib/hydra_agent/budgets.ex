defmodule HydraAgent.Budgets do
  @moduledoc """
  Workspace and agent budget visibility.
  """

  import Ecto.Query

  alias HydraAgent.Budgets.Budget
  alias HydraAgent.Simulation.BudgetReservation
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
    reserved = reservation_summary(budget.workspace_id, usage_opts)
    token_limit = budget.token_limit
    cost_limit = budget.cost_limit

    %{
      "budget_id" => budget.id,
      "status" => limit_status(summary, reserved, token_limit, cost_limit),
      "period" => budget.period,
      "category" => budget.category,
      "used_tokens" => summary["total_tokens"],
      "reserved_tokens" => reserved["estimated_tokens"],
      "token_limit" => token_limit,
      "token_ratio" => ratio(summary["total_tokens"] + reserved["estimated_tokens"], token_limit),
      "used_cost" => summary["estimated_cost"],
      "reserved_cost" => cents_to_decimal(reserved["remaining_cost_cents"]),
      "cost_limit" => cost_limit,
      "cost_ratio" =>
        ratio_decimal(
          Decimal.add(
            summary["estimated_cost"] || Decimal.new(0),
            cents_to_decimal(reserved["remaining_cost_cents"])
          ),
          cost_limit
        ),
      "usage" => summary,
      "reservations" => reserved
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

    case Enum.find(applicable, &budget_unavailable?(&1, opts)) do
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
           "cost_limit" => status["cost_limit"]
         }}
    end
  end

  def reserve_simulation_budget(repo, simulation, estimate) do
    lock_budget_scope(repo, simulation.workspace_id)
    reserved_cost_cents = reserved_simulation_cost_cents(simulation, estimate)

    opts = [
      agent_id: simulation.supervisor_agent_id,
      category: "simulation",
      estimated_tokens: estimate["estimated_tokens"],
      estimated_cost_cents: reserved_cost_cents
    ]

    with :ok <- check_available(simulation.workspace_id, opts) do
      %BudgetReservation{}
      |> BudgetReservation.changeset(%{
        "workspace_id" => simulation.workspace_id,
        "simulation_id" => simulation.id,
        "agent_id" => simulation.supervisor_agent_id,
        "category" => "simulation",
        "estimated_tokens" => estimate["estimated_tokens"] || 0,
        "estimated_cost_cents" => estimate["estimated_cost_cents"] || 0,
        "reserved_cost_cents" => reserved_cost_cents,
        "spent_cost_cents" => 0,
        "status" => "active",
        "metadata" => %{"source" => "simulation_create"}
      })
      |> repo.insert()
    end
  end

  defp reserved_simulation_cost_cents(simulation, estimate) do
    max(
      estimate["estimated_cost_cents"] || 0,
      get_in(simulation.config || %{}, ["max_budget_cents"]) || 0
    )
  end

  def spend_simulation_reservation(simulation_id, cost_cents, repo \\ Repo) do
    reservation =
      BudgetReservation
      |> where([reservation], reservation.simulation_id == ^simulation_id)
      |> repo.one()

    case reservation do
      nil ->
        {:ok, nil}

      %BudgetReservation{} = reservation ->
        spent = reservation.spent_cost_cents + max(cost_cents || 0, 0)

        status =
          if spent >= reservation.reserved_cost_cents, do: "exhausted", else: reservation.status

        reservation
        |> BudgetReservation.changeset(%{
          "spent_cost_cents" => spent,
          "status" => status,
          "metadata" =>
            Map.merge(reservation.metadata || %{}, %{
              "remaining_cost_cents" => max(reservation.reserved_cost_cents - spent, 0)
            })
        })
        |> repo.update()
    end
  end

  def release_simulation_reservation(simulation_id, status, repo \\ Repo) do
    reservation =
      BudgetReservation
      |> where([reservation], reservation.simulation_id == ^simulation_id)
      |> repo.one()

    case reservation do
      nil ->
        {:ok, nil}

      %BudgetReservation{} = reservation ->
        reservation
        |> BudgetReservation.changeset(%{
          "status" => reservation_status(status),
          "metadata" =>
            Map.merge(reservation.metadata || %{}, %{
              "released_for_status" => status,
              "released_at" => DateTime.utc_now() |> DateTime.to_iso8601()
            })
        })
        |> repo.update()
    end
  end

  def reservation_summary(workspace_id, opts \\ []) do
    reservations =
      BudgetReservation
      |> where([reservation], reservation.workspace_id == ^workspace_id)
      |> where([reservation], reservation.status == "active")
      |> maybe_filter_reservation_agent(opt(opts, :agent_id))
      |> maybe_filter_reservation_category(opt(opts, :category))
      |> Repo.all()

    %{
      "count" => length(reservations),
      "estimated_tokens" => Enum.sum(Enum.map(reservations, & &1.estimated_tokens)),
      "reserved_cost_cents" => Enum.sum(Enum.map(reservations, & &1.reserved_cost_cents)),
      "spent_cost_cents" => Enum.sum(Enum.map(reservations, & &1.spent_cost_cents)),
      "remaining_cost_cents" =>
        Enum.sum(Enum.map(reservations, &max(&1.reserved_cost_cents - &1.spent_cost_cents, 0)))
    }
  end

  defp lock_budget_scope(repo, workspace_id) do
    key = :erlang.phash2({"simulation_budget", workspace_id}, 2_147_483_647)
    repo.query!("SELECT pg_advisory_xact_lock($1)", [key])
    :ok
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

  defp budget_unavailable?(status, opts) do
    status["status"] == "exceeded" or projected_exceeded?(status, opts)
  end

  defp projected_exceeded?(status, opts) do
    projected_tokens = opt(opts, :estimated_tokens) || 0
    projected_cost_cents = opt(opts, :estimated_cost_cents) || 0

    token_would_exceed? =
      is_integer(status["token_limit"]) and
        status["used_tokens"] + status["reserved_tokens"] + projected_tokens >
          status["token_limit"]

    cost_would_exceed? =
      match?(%Decimal{}, status["cost_limit"]) and
        Decimal.compare(
          Decimal.add(
            Decimal.add(status["used_cost"] || Decimal.new(0), status["reserved_cost"]),
            cents_to_decimal(projected_cost_cents)
          ),
          status["cost_limit"]
        ) == :gt

    token_would_exceed? or cost_would_exceed?
  end

  defp cents_to_decimal(cents) when is_integer(cents),
    do: Decimal.div(Decimal.new(cents), Decimal.new(100))

  defp cents_to_decimal(cents) when is_float(cents),
    do: Decimal.div(Decimal.from_float(cents), Decimal.new(100))

  defp cents_to_decimal(_cents), do: Decimal.new(0)

  defp period_start("daily"), do: DateTime.utc_now() |> DateTime.add(-1, :day)
  defp period_start("weekly"), do: DateTime.utc_now() |> DateTime.add(-7, :day)
  defp period_start("monthly"), do: DateTime.utc_now() |> DateTime.add(-31, :day)
  defp period_start("total"), do: nil
  defp period_start(_period), do: nil

  defp maybe_filter_reservation_agent(query, nil), do: query

  defp maybe_filter_reservation_agent(query, agent_id),
    do:
      where(
        query,
        [reservation],
        is_nil(reservation.agent_id) or reservation.agent_id == ^agent_id
      )

  defp maybe_filter_reservation_category(query, nil), do: query

  defp maybe_filter_reservation_category(query, category),
    do: where(query, [reservation], reservation.category == ^category)

  defp reservation_status("budget_blocked"), do: "exhausted"
  defp reservation_status("canceled"), do: "canceled"
  defp reservation_status(_status), do: "released"

  defp limit_status(_summary, _reserved, nil, nil), do: "unbounded"

  defp limit_status(summary, reserved, token_limit, cost_limit) do
    token_status = token_limit_status(summary, reserved, token_limit)
    cost_status = cost_limit_status(summary, reserved, cost_limit)

    cond do
      "exceeded" in [token_status, cost_status] -> "exceeded"
      "warning" in [token_status, cost_status] -> "warning"
      token_status == "unbounded" and cost_status == "unbounded" -> "unbounded"
      true -> "ok"
    end
  end

  defp token_limit_status(_summary, _reserved, nil), do: "unbounded"

  defp token_limit_status(summary, reserved, token_limit) when is_integer(token_limit) do
    total = summary["total_tokens"] + reserved["estimated_tokens"]

    cond do
      total >= token_limit -> "exceeded"
      ratio(total, token_limit) >= 0.8 -> "warning"
      true -> "ok"
    end
  end

  defp token_limit_status(_summary, _reserved, _token_limit), do: "ok"

  defp cost_limit_status(_summary, _reserved, nil), do: "unbounded"

  defp cost_limit_status(summary, reserved, %Decimal{} = cost_limit) do
    total =
      Decimal.add(
        summary["estimated_cost"] || Decimal.new(0),
        cents_to_decimal(reserved["remaining_cost_cents"])
      )

    cond do
      Decimal.compare(total, cost_limit) != :lt ->
        "exceeded"

      ratio_decimal(total, cost_limit) >= 0.8 ->
        "warning"

      true ->
        "ok"
    end
  end

  defp cost_limit_status(_summary, _reserved, _cost_limit), do: "ok"

  defp ratio(_used, nil), do: nil
  defp ratio(_used, 0), do: nil
  defp ratio(used, limit), do: used / limit

  defp ratio_decimal(_used, nil), do: nil
  defp ratio_decimal(nil, _limit), do: nil

  defp ratio_decimal(%Decimal{} = used, %Decimal{} = limit) do
    if Decimal.compare(limit, Decimal.new(0)) == :eq do
      nil
    else
      used |> Decimal.div(limit) |> Decimal.to_float()
    end
  end

  defp opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp opt(opts, key) when is_map(opts), do: Map.get(opts, key) || Map.get(opts, to_string(key))
end
