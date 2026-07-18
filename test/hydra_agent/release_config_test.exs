defmodule HydraAgent.ReleaseConfigTest do
  use ExUnit.Case, async: false

  alias HydraAgent.ReleaseConfig

  setup do
    names = ~w(TEST_REQUIRED TEST_SECRET TEST_HOST TEST_INTEGER TEST_BOOLEAN TEST_ENUM)
    previous = Map.new(names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    Enum.each(names, &System.delete_env/1)
    :ok
  end

  test "required values reject missing and blank environment variables" do
    assert_raise RuntimeError, ~r/TEST_REQUIRED is required/, fn ->
      ReleaseConfig.required_env!("TEST_REQUIRED")
    end

    System.put_env("TEST_REQUIRED", "  ")

    assert_raise RuntimeError, ~r/must not be empty/, fn ->
      ReleaseConfig.required_env!("TEST_REQUIRED")
    end
  end

  test "secrets enforce a minimum byte length" do
    System.put_env("TEST_SECRET", "too-short")

    assert_raise RuntimeError, ~r/at least 32 bytes/, fn ->
      ReleaseConfig.secret_env!("TEST_SECRET", 32)
    end

    System.put_env("TEST_SECRET", String.duplicate("x", 32))
    assert String.length(ReleaseConfig.secret_env!("TEST_SECRET", 32)) == 32
  end

  test "public hosts reject placeholders, local names, schemes, and paths" do
    for host <- ["example.com", "localhost", "app.local", "https://hydra.test", "hydra.test/path"] do
      System.put_env("TEST_HOST", host)

      assert_raise RuntimeError, fn ->
        ReleaseConfig.public_host_env!("TEST_HOST")
      end
    end

    System.put_env("TEST_HOST", "Hydra.EXAMPLE.org.")
    assert ReleaseConfig.public_host_env!("TEST_HOST") == "hydra.example.org"
  end

  test "numeric and boolean values reject malformed input" do
    System.put_env("TEST_INTEGER", "0")
    assert_raise RuntimeError, fn -> ReleaseConfig.positive_integer_env!("TEST_INTEGER", 10) end

    System.put_env("TEST_BOOLEAN", "yes")
    assert_raise RuntimeError, fn -> ReleaseConfig.boolean_env!("TEST_BOOLEAN") end

    System.put_env("TEST_INTEGER", "12")
    System.put_env("TEST_BOOLEAN", "1")
    assert ReleaseConfig.positive_integer_env!("TEST_INTEGER", 10) == 12
    assert ReleaseConfig.boolean_env!("TEST_BOOLEAN")
  end

  test "enumerated values are bounded and use the declared default" do
    assert ReleaseConfig.enum_env!("TEST_ENUM", ~w(one two), "one") == "one"

    System.put_env("TEST_ENUM", "two")
    assert ReleaseConfig.enum_env!("TEST_ENUM", ~w(one two), "one") == "two"

    System.put_env("TEST_ENUM", "three")

    assert_raise RuntimeError, ~r/must be one of one, two/, fn ->
      ReleaseConfig.enum_env!("TEST_ENUM", ~w(one two), "one")
    end
  end
end
