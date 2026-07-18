defmodule HydraAgentWeb.TelegramController do
  use HydraAgentWeb, :controller

  alias HydraAgent.Rooms

  plug HydraAgentWeb.Plugs.RateLimit,
       [scope: "telegram_webhook", limit: 120, window_seconds: 60, identity: :webhook]
       when action in [:webhook]

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
            conn |> put_status(error_status(error)) |> json(%{errors: error})
        end
    end
  end

  defp error_status(%{"reason" => reason})
       when reason in ["missing_telegram_secret", "invalid_telegram_secret"],
       do: :unauthorized

  defp error_status(%{"reason" => reason})
       when reason in ["missing_telegram_secret_env", "missing_secret_env"],
       do: :service_unavailable

  defp error_status(_error), do: :unprocessable_entity
end
