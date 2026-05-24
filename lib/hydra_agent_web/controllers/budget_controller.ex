defmodule HydraAgentWeb.BudgetController do
  use HydraAgentWeb, :controller

  alias HydraAgent.Budgets

  def index(conn, %{"workspace_id" => workspace_id} = params) do
    budgets =
      Budgets.list_budgets(workspace_id, status: params["status"], agent_id: params["agent_id"])

    statuses = Map.new(Budgets.list_budget_statuses(workspace_id), &{&1["budget_id"], &1})

    json(conn, %{
      data:
        Enum.map(budgets, fn budget ->
          budget
          |> budget_json()
          |> Map.put(:usage_status, statuses[budget.id])
        end)
    })
  end

  def create(conn, params) do
    case Budgets.create_budget(params) do
      {:ok, budget} ->
        conn
        |> put_status(:created)
        |> json(%{data: budget_json(budget)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: errors_json(changeset)})
    end
  end

  def show(conn, %{"id" => id}) do
    budget = Budgets.get_budget!(id)

    json(conn, %{data: Map.put(budget_json(budget), :usage_status, Budgets.budget_status(budget))})
  end

  defp budget_json(budget) do
    %{
      id: budget.id,
      workspace_id: budget.workspace_id,
      agent_id: budget.agent_id,
      name: budget.name,
      status: budget.status,
      category: budget.category,
      period: budget.period,
      token_limit: budget.token_limit,
      cost_limit: decimal_to_string(budget.cost_limit),
      metadata: budget.metadata
    }
  end

  defp decimal_to_string(nil), do: nil
  defp decimal_to_string(decimal), do: Decimal.to_string(decimal)

  defp errors_json(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
