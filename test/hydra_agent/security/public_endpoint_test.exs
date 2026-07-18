defmodule HydraAgent.Security.PublicEndpointTest do
  use ExUnit.Case, async: true

  alias HydraAgent.Security.PublicEndpoint

  test "accepts a public HTTPS hostname and pins the resolved address" do
    resolver = fn "example.org" -> {:ok, [{93, 184, 216, 34}]} end

    assert {:ok, target} =
             PublicEndpoint.validate("https://example.org/hooks/hydra?mode=test",
               resolver: resolver
             )

    assert target.original_url == "https://example.org/hooks/hydra?mode=test"
    assert target.pinned_url == "https://93.184.216.34/hooks/hydra?mode=test"
    assert target.host == "example.org"
    assert target.connect_options[:hostname] == "example.org"
  end

  test "rejects private, special-use, literal, credentialed, and non-HTTPS endpoints" do
    private_resolver = fn _host -> {:ok, [{10, 0, 0, 4}]} end
    mixed_resolver = fn _host -> {:ok, [{93, 184, 216, 34}, {127, 0, 0, 1}]} end

    assert {:error, :non_public_host} =
             PublicEndpoint.validate("https://internal.example/hook", resolver: private_resolver)

    assert {:error, :non_public_host} =
             PublicEndpoint.validate("https://mixed.example/hook", resolver: mixed_resolver)

    assert {:error, :ip_literal_not_allowed} =
             PublicEndpoint.validate("https://127.0.0.1/hook", resolver: private_resolver)

    assert {:error, :invalid_public_https_url} =
             PublicEndpoint.validate("https://user:secret@example.org/hook",
               resolver: private_resolver
             )

    assert {:error, :invalid_public_https_url} =
             PublicEndpoint.validate("http://example.org/hook", resolver: private_resolver)
  end
end
