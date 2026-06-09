defmodule HydraAgent.CLITest do
  use ExUnit.Case, async: true

  alias HydraAgent.CLI

  test "prints help without calling the API" do
    assert {:ok, usage} = CLI.run(["help"])
    assert usage =~ "hydra plugins install"
  end

  test "requires workspace for plugin list commands" do
    assert {:error, %{"reason" => "missing_required_option", "option" => "--workspace"}} =
             CLI.run(["plugins", "list"])
  end

  test "requires object JSON for plugin configure" do
    assert {:error, %{"reason" => "invalid_json"}} =
             CLI.run([
               "plugins",
               "configure",
               "--workspace",
               "1",
               "--id",
               "2",
               "--config-json",
               "[]"
             ])
  end
end
