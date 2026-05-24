defmodule HydraAgent.SecretsTest do
  use ExUnit.Case, async: true

  alias HydraAgent.Secrets

  test "fetch_env returns structured missing-secret errors" do
    assert {:error, %{"reason" => "missing_secret_env", "env" => "HYDRA_MISSING_TEST_SECRET"}} =
             Secrets.fetch_env("HYDRA_MISSING_TEST_SECRET")
  end

  test "safe_ref never exposes values" do
    assert Secrets.safe_ref("HYDRA_TOKEN") == "env:HYDRA_TOKEN"
  end
end
