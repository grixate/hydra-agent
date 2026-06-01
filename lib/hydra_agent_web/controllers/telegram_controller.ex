defmodule HydraAgentWeb.TelegramController do
  use HydraAgentWeb, :controller

  alias HydraAgent.Rooms

  def webhook(conn, %{"binding_slug" => slug} = params) do
    case Rooms.get_active_binding_by_slug("telegram", slug) do
      nil ->
        conn |> put_status(:not_found) |> json(%{errors: %{detail: "Telegram binding not found"}})

      binding ->
        update = Map.drop(params, ["binding_slug"])

        case Rooms.receive_telegram_update(binding, update, conn.req_headers) do
          {:ok, result} ->
            json(conn, %{
              data: %{
                user_message_id: result.user_message.id,
                agent_message_ids: Enum.map(result.agent_messages, & &1.id),
                pending_proposal_id: result.pending_proposal && result.pending_proposal.id
              }
            })

          {:error, error} ->
            conn |> put_status(:unprocessable_entity) |> json(%{errors: error})
        end
    end
  end
end
