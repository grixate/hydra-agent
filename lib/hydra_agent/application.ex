defmodule HydraAgent.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      HydraAgentWeb.Telemetry,
      HydraAgent.Repo,
      {DNSCluster, query: Application.get_env(:hydra_agent, :dns_cluster_query) || :ignore},
      {Registry, keys: :unique, name: HydraAgent.ProcessRegistry},
      {Phoenix.PubSub, name: HydraAgent.PubSub},
      {Task.Supervisor, name: HydraAgent.TaskSupervisor},
      HydraAgent.Agent.Supervisor,
      HydraAgent.Simulation.Supervisor,
      {HydraAgent.Simulation.Reconciler,
       enabled: Application.get_env(:hydra_agent, :simulation_reconciler_enabled, true)},
      HydraAgent.MCP.SessionSupervisor,
      HydraAgent.Runtime.RecoveryWorker,
      HydraAgent.Automations.Worker,
      HydraAgent.Loops.Worker,
      HydraAgent.Skills.LearningWorker,
      # Start to serve requests, typically the last entry
      HydraAgentWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: HydraAgent.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    HydraAgentWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
