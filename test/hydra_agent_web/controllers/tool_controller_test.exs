defmodule HydraAgentWeb.ToolControllerTest do
  use HydraAgentWeb.ConnCase

  test "lists registered tool bundles", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/tools/bundles")

    assert %{"data" => bundles} = json_response(conn, 200)
    assert Enum.any?(bundles, &(&1["name"] == "knowledge_read"))
    assert Enum.any?(bundles, &(&1["name"] == "terminal" and &1["requires_approval"]))
  end
end
