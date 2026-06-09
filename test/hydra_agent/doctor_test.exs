defmodule HydraAgent.DoctorTest do
  use HydraAgent.DataCase

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.Doctor

  test "status is error when any check errors" do
    assert Doctor.status([%{"status" => "ok"}, %{"status" => "error"}]) == "error"
  end

  test "status is warning when checks warn but do not error" do
    assert Doctor.status([%{"status" => "ok"}, %{"status" => "warning"}]) == "warning"
  end

  test "status is ok when all checks pass" do
    assert Doctor.status([%{"status" => "ok"}]) == "ok"
  end

  test "summarize counts checks by status" do
    assert Doctor.summarize([
             %{"status" => "ok"},
             %{"status" => "ok"},
             %{"status" => "warning"}
           ]) == %{"ok" => 2, "warning" => 1, "total" => 3}
  end

  test "run checks configured browser worker health endpoint" do
    url = start_browser_worker_fixture(200, ~s({"status":"ok","sessions":0}))
    with_browser_worker_url(url)

    report = Doctor.run()
    check = find_check(report, "browser_worker")

    assert check["status"] == "ok"
    assert check["metadata"]["url"] == url
    assert check["metadata"]["health_url"] =~ "/health"
    assert check["metadata"]["worker_status"] == "ok"
  end

  test "run reports configured browser worker health failures as errors" do
    url = start_browser_worker_fixture(503, ~s({"status":"error"}))
    with_browser_worker_url(url)

    report = Doctor.run()
    check = find_check(report, "browser_worker")

    assert report["status"] == "error"
    assert check["status"] == "error"
    assert check["metadata"]["status"] == 503
  end

  test "run fails closed when browser worker auth is required without a token" do
    with_browser_worker_url("http://127.0.0.1:4100/actions")

    with_browser_worker_config(
      auth_required?: true,
      token_env: "HYDRA_MISSING_BROWSER_WORKER_TOKEN"
    )

    report = Doctor.run()
    check = find_check(report, "browser_worker")

    assert report["status"] == "error"
    assert check["status"] == "error"
    assert check["summary"] == "Browser worker action auth is missing env value"
    assert check["metadata"]["token_env"] == "HYDRA_MISSING_BROWSER_WORKER_TOKEN"
  end

  test "run reports stale runtime pressure as a warning" do
    workspace = workspace_fixture()
    run = run_fixture(workspace, %{status: "running"})

    run_step_fixture(run, %{
      status: "running",
      lease_owner: "doctor-test",
      lease_expires_at: DateTime.utc_now() |> DateTime.add(-60, :second)
    })

    report = Doctor.run()
    check = find_check(report, "runtime_pressure")

    assert check["status"] == "warning"
    assert check["metadata"]["stale_running_steps"] == 1
  end

  defp find_check(report, name) do
    Enum.find(report["checks"], &(&1["name"] == name))
  end

  defp with_browser_worker_url(url) do
    previous = Application.get_env(:hydra_agent, :browser_worker_url)
    Application.put_env(:hydra_agent, :browser_worker_url, url)

    on_exit(fn ->
      Application.put_env(:hydra_agent, :browser_worker_url, previous)
    end)
  end

  defp with_browser_worker_config(config) do
    previous = Application.get_env(:hydra_agent, :browser_worker)
    Application.put_env(:hydra_agent, :browser_worker, config)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:hydra_agent, :browser_worker)
      else
        Application.put_env(:hydra_agent, :browser_worker, previous)
      end
    end)
  end

  defp start_browser_worker_fixture(status, body) do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(socket)

    start_supervised!(
      {Task,
       fn ->
         {:ok, client} = :gen_tcp.accept(socket)
         {:ok, _request} = :gen_tcp.recv(client, 0, 2_000)

         response = [
           "HTTP/1.1 #{status} OK\r\n",
           "content-type: application/json\r\n",
           "content-length: #{byte_size(body)}\r\n",
           "connection: close\r\n",
           "\r\n",
           body
         ]

         :ok = :gen_tcp.send(client, response)
         :ok = :gen_tcp.close(client)
         :ok = :gen_tcp.close(socket)
       end}
    )

    "http://127.0.0.1:#{port}/actions"
  end
end
