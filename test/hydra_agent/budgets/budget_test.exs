defmodule HydraAgent.Budgets.BudgetTest do
  use ExUnit.Case, async: true

  alias HydraAgent.Budgets.Budget

  test "validates active token budgets" do
    changeset =
      Budget.changeset(%Budget{}, %{
        workspace_id: 1,
        name: "Monthly chat budget",
        status: "active",
        category: "chat",
        period: "monthly",
        token_limit: 100_000
      })

    assert changeset.valid?
  end

  test "rejects unknown periods and non-positive token limits" do
    changeset =
      Budget.changeset(%Budget{}, %{
        workspace_id: 1,
        name: "Bad budget",
        status: "active",
        period: "whenever",
        token_limit: 0
      })

    refute changeset.valid?
    assert {"is invalid", _meta} = changeset.errors[:period]
    assert {"must be greater than %{number}", _meta} = changeset.errors[:token_limit]
  end
end
