defmodule HydraAgent.Repo do
  use Ecto.Repo,
    otp_app: :hydra_agent,
    adapter: Ecto.Adapters.Postgres
end
