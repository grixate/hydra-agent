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

# Filesystem-capable runtime features need a stable server-owned fallback when
# a workspace has not configured its own project_root. Keep this absolute so
# request handling never derives an authority boundary from the process cwd.
config :hydra_agent, :server_workspace_root, Path.expand("..", __DIR__)

config :hydra_agent, :api_auth,
  enabled?: false,
  token_env: "HYDRA_API_TOKEN"

config :hydra_agent, :browser_auth, enabled?: false

config :hydra_agent, :browser_worker_url, nil

config :hydra_agent, :public_disclosure,
  operator_name: nil,
  support_email: nil,
  security_email: nil,
  privacy_url: nil,
  retention_summary: nil

config :hydra_agent, :mcp_security,
  stdio_executable_allowlist: [],
  env_ref_allowlist: []

config :hydra_agent, :rate_limits,
  api_edge: {1_200, 60},
  api_read: {600, 60},
  api_write: {120, 60}

# SimLab is an optional product layer. Keeping the flag at the boundary lets
# the neutral Hydra Agent runtime remain usable without the research product.
config :hydra_agent, :sim_lab_enabled, true

# Blueprint Studio is introduced behind runtime flags so the current SimLab
# records and routes remain available throughout the additive migration. The
# legacy surface stays the safe default until the new vertical slice is ready.
config :hydra_agent, :product_features,
  surface: :legacy_simlab,
  balanced_mode: true,
  deep_mode: false,
  blueprint_import: true,
  legacy_simlab: true

# This local Codex bridge is a development aid, never a production provider.
# Operators must also opt in with HYDRA_SIM_CODEX_CLI_TESTING=1 at runtime.
config :hydra_agent, :environment, config_env()

config :hydra_agent, :sim_lab_codex_cli,
  enabled?: config_env() != :prod,
  executable: "codex",
  timeout_ms: 120_000

config :hydra_agent, :sim_lab_tavily,
  endpoint: "https://api.tavily.com/search",
  api_key_env: "TAVILY_API_KEY",
  timeout_ms: 30_000

config :hydra_agent, Oban,
  repo: HydraAgent.Repo,
  queues: [sim_lab: 5, research: 3, simulations: 3],
  plugins: [{Oban.Plugins.Pruner, max_age: 86_400}]

config :tailwind,
  version: "4.3.0",
  default: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/tailwind.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

config :esbuild,
  version: "0.25.0",
  default: [
    args: ~w(js/live.js --bundle --target=es2017 --outdir=../priv/static/assets),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

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
