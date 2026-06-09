defmodule HydraAgent.BrowserTest do
  use HydraAgent.DataCase, async: false

  alias HydraAgent.Browser

  test "sends configured bearer token to browser worker actions" do
    url =
      start_worker_fixture(
        200,
        ~s({"worker_session_id":"bw-test","url":"about:blank","title":""})
      )

    with_app_env(:browser_worker_url, url)
    with_app_env(:browser_worker, auth_required?: true, token_env: "HYDRA_BROWSER_WORKER_TOKEN")
    with_env("HYDRA_BROWSER_WORKER_TOKEN", "test-worker-token")

    assert {:ok, %{"backend" => "worker", "result" => %{"worker_session_id" => "bw-test"}}} =
             Browser.execute("extract", %{"selector" => "body"}, %{})

    assert_receive {:browser_worker_request, request}, 2_000
    assert String.contains?(String.downcase(request), "authorization: bearer test-worker-token")
    assert String.contains?(request, "POST /actions HTTP/1.1")
  end

  defp with_app_env(key, value) do
    previous = Application.get_env(:hydra_agent, key)
    Application.put_env(:hydra_agent, key, value)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:hydra_agent, key)
      else
        Application.put_env(:hydra_agent, key, previous)
      end
    end)
  end

  defp with_env(name, value) do
    previous = System.get_env(name)
    System.put_env(name, value)

    on_exit(fn ->
      if is_nil(previous), do: System.delete_env(name), else: System.put_env(name, previous)
    end)
  end

  defp start_worker_fixture(status, body) do
    parent = self()

    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(socket)

    start_supervised!(
      {Task,
       fn ->
         {:ok, client} = :gen_tcp.accept(socket)
         {:ok, request} = :gen_tcp.recv(client, 0, 2_000)
         send(parent, {:browser_worker_request, request})

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
