defmodule HydraAgentWeb.PageController do
  use HydraAgentWeb, :controller

  alias HydraAgentWeb.UserAuth

  def home(conn, _params) do
    case conn.assigns[:current_user] do
      nil -> render(conn, :home, layout: false, page_title: "Agent runtime")
      user -> redirect(conn, to: UserAuth.default_path(user))
    end
  end
end
