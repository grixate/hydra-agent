defmodule HydraAgent.Usage.RecordTest do
  use ExUnit.Case, async: true

  alias HydraAgent.Usage.Record

  test "validates provider usage records" do
    changeset =
      Record.changeset(%Record{}, %{
        workspace_id: 1,
        agent_id: 2,
        category: "chat",
        status: "ok",
        provider: "mock",
        model: "mock-default",
        input_tokens: 10,
        output_tokens: 5,
        total_tokens: 15,
        metadata: %{"route" => %{"provider" => "mock"}}
      })

    assert changeset.valid?
  end

  test "rejects unknown categories and negative token counts" do
    changeset =
      Record.changeset(%Record{}, %{
        workspace_id: 1,
        category: "alchemy",
        status: "ok",
        input_tokens: -1
      })

    refute changeset.valid?
    assert {"is invalid", _meta} = changeset.errors[:category]
    assert {"must be greater than or equal to %{number}", _meta} = changeset.errors[:input_tokens]
  end

  test "rejects unknown statuses" do
    changeset =
      Record.changeset(%Record{}, %{
        workspace_id: 1,
        category: "planning",
        status: "maybe"
      })

    refute changeset.valid?
    assert {"is invalid", _meta} = changeset.errors[:status]
  end
end
