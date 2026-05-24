defmodule HydraAgentWeb.MemoryController do
  use HydraAgentWeb, :controller

  alias HydraAgent.Memory

  def curate(conn, %{"workspace_id" => workspace_id} = params) do
    result =
      Memory.curate_workspace(workspace_id,
        dry_run?: params["dry_run"] != false,
        archive_below_confidence: parse_float(params["archive_below_confidence"], 0.2)
      )

    json(conn, %{data: result})
  end

  defp parse_float(nil, default), do: default
  defp parse_float(value, _default) when is_float(value), do: value
  defp parse_float(value, _default) when is_integer(value), do: value / 1

  defp parse_float(value, default) when is_binary(value) do
    case Float.parse(value) do
      {float, _rest} -> float
      :error -> default
    end
  end
end
