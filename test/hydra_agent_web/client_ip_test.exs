defmodule HydraAgentWeb.ClientIpTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias HydraAgentWeb.ClientIp

  setup do
    previous = Application.get_env(:hydra_agent, :trusted_proxy_ips)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:hydra_agent, :trusted_proxy_ips, previous),
        else: Application.delete_env(:hydra_agent, :trusted_proxy_ips)
    end)

    :ok
  end

  test "ignores forwarded headers from untrusted peers" do
    conn =
      :get
      |> conn("/")
      |> Map.put(:remote_ip, {198, 51, 99, 8})
      |> put_req_header("x-forwarded-for", "203.0.113.9")

    assert ClientIp.address(conn) == "198.51.99.8"
  end

  test "uses the rightmost valid address from a trusted same-host proxy" do
    conn =
      :get
      |> conn("/")
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> put_req_header("x-forwarded-for", "spoofed, 203.0.113.12")

    assert ClientIp.address(conn) == "203.0.113.12"
  end

  test "supports explicitly trusted proxy addresses and fails closed on malformed headers" do
    Application.put_env(:hydra_agent, :trusted_proxy_ips, ["10.20.30.40"])

    trusted =
      :get
      |> conn("/")
      |> Map.put(:remote_ip, {10, 20, 30, 40})
      |> put_req_header("x-forwarded-for", "2001:db8::12")

    malformed =
      :get
      |> conn("/")
      |> Map.put(:remote_ip, {10, 20, 30, 40})
      |> put_req_header("x-forwarded-for", "not-an-address")

    assert ClientIp.address(trusted) == "2001:db8::12"
    assert ClientIp.address(malformed) == "10.20.30.40"
  end
end
