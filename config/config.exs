# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :hydra_agent,
  ecto_repos: [HydraAgent.Repo],
  generators: [timestamp_type: :utc_datetime_usec]

config :hydra_agent, :api_auth,
  enabled?: false,
  token_env: "HYDRA_API_TOKEN"

config :hydra_agent, :browser_worker_url, nil

# Configures the endpoint
config :hydra_agent, HydraAgentWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: HydraAgentWeb.ErrorHTML, json: HydraAgentWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: HydraAgent.PubSub,
  live_view: [signing_salt: "7rbF02Px"]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
