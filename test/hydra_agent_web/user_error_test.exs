defmodule HydraAgentWeb.UserErrorTest do
  use ExUnit.Case, async: true

  alias HydraAgentWeb.UserError

  test "internal failures become actionable copy without exposing details" do
    message =
      UserError.message(
        "start the worker",
        {:provider_failed, %{token: "secret-token", endpoint: "http://internal"}}
      )

    assert message ==
             "We couldn't start the worker. Review the saved configuration and try again."

    refute message =~ "secret-token"
    refute message =~ "internal"
    refute message =~ "provider_failed"
  end

  test "validation failures use entered-detail guidance" do
    changeset =
      {%{}, %{name: :string}}
      |> Ecto.Changeset.cast(%{name: ""}, [:name])
      |> Ecto.Changeset.validate_required([:name])

    assert UserError.message("save the item", changeset) ==
             "We couldn't save the item. Name can't be blank"
  end
end
