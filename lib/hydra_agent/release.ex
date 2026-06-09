defmodule HydraAgent.Release do
  @moduledoc false

  @app :hydra_agent

  alias HydraAgent.Doctor

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _started, _stopped} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()

    {:ok, _started, _stopped} =
      Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  def smoke(opts \\ []) do
    if Keyword.get(opts, :start_app?, true) do
      {:ok, _started} = Application.ensure_all_started(@app)
    else
      load_app()
    end

    doctor = Keyword.get(opts, :doctor, &Doctor.run/1)
    report = doctor.(doctor_opts(opts))

    IO.puts(Jason.encode!(%{"data" => report}, pretty: true))
    assert_smoke_status!(report, Keyword.get(opts, :fail_on_warning?, fail_on_warning?()))
  end

  defp assert_smoke_status!(%{"status" => "error"}, _fail_on_warning?) do
    raise "Hydra production smoke failed: doctor reported errors"
  end

  defp assert_smoke_status!(%{"status" => "warning"}, true) do
    raise "Hydra production smoke failed: doctor reported warnings"
  end

  defp assert_smoke_status!(_report, _fail_on_warning?), do: :ok

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    Application.load(@app)
  end

  defp doctor_opts(opts) do
    case Keyword.get(opts, :workspace_id, System.get_env("HYDRA_SMOKE_WORKSPACE_ID")) do
      nil -> []
      "" -> []
      workspace_id -> [workspace_id: workspace_id]
    end
  end

  defp fail_on_warning? do
    System.get_env("HYDRA_SMOKE_FAIL_ON_WARNING") in ~w(true 1)
  end
end
