defmodule HydraAgent.ProductFeaturesTest do
  use ExUnit.Case, async: false

  alias HydraAgent.ProductFeatures

  setup do
    previous = Application.get_env(:hydra_agent, :product_features)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:hydra_agent, :product_features)
      else
        Application.put_env(:hydra_agent, :product_features, previous)
      end
    end)

    :ok
  end

  test "reports a normalized snapshot for the migration flags" do
    Application.put_env(:hydra_agent, :product_features,
      surface: :blueprint_studio,
      balanced_mode: false,
      deep_mode: true,
      blueprint_import: false,
      legacy_simlab: true
    )

    assert ProductFeatures.blueprint_studio?()
    refute ProductFeatures.enabled?(:balanced_mode)
    assert ProductFeatures.enabled?(:deep_mode)
    refute ProductFeatures.enabled?(:blueprint_import)
    assert ProductFeatures.enabled?(:legacy_simlab)
  end

  test "fills omitted values from safe defaults" do
    Application.put_env(:hydra_agent, :product_features, surface: :blueprint_studio)

    assert ProductFeatures.snapshot() == %{
             surface: :blueprint_studio,
             balanced_mode: true,
             deep_mode: false,
             blueprint_import: true,
             legacy_simlab: true
           }
  end

  test "rejects invalid product surfaces and non-boolean flags" do
    assert_raise ArgumentError, ~r/product surface/, fn ->
      ProductFeatures.validate!(surface: :unknown)
    end

    assert_raise ArgumentError, ~r/deep_mode must be a boolean/, fn ->
      ProductFeatures.validate!(deep_mode: "true")
    end
  end

  test "cannot disable the selected legacy surface" do
    assert_raise ArgumentError, ~r/legacy_simlab must remain enabled/, fn ->
      ProductFeatures.validate!(surface: :legacy_simlab, legacy_simlab: false)
    end
  end
end
