defmodule HydraAgent.ProductFeatures do
  @moduledoc """
  Runtime feature contract for the additive Blueprint Studio migration.

  These flags select product behavior only. They never migrate, delete, or
  reinterpret persisted records. Database compatibility remains the
  responsibility of additive migrations and explicit domain adapters.
  """

  @app :hydra_agent
  @key :product_features
  @surfaces [:legacy_simlab, :blueprint_studio]
  @boolean_features [:balanced_mode, :deep_mode, :blueprint_import, :legacy_simlab]
  @defaults %{
    surface: :legacy_simlab,
    balanced_mode: true,
    deep_mode: false,
    blueprint_import: true,
    legacy_simlab: true
  }

  def surface, do: config().surface

  def blueprint_studio?, do: surface() == :blueprint_studio

  def enabled?(feature) when feature in @boolean_features do
    Map.fetch!(config(), feature)
  end

  def snapshot, do: config()

  def validate!(value) do
    config = normalize(value)

    unless config.surface in @surfaces do
      raise ArgumentError,
            "product surface must be one of: #{Enum.map_join(@surfaces, ", ", &Atom.to_string/1)}"
    end

    Enum.each(@boolean_features, fn feature ->
      unless is_boolean(Map.fetch!(config, feature)) do
        raise ArgumentError, "product feature #{feature} must be a boolean"
      end
    end)

    if config.surface == :legacy_simlab and not config.legacy_simlab do
      raise ArgumentError, "legacy_simlab must remain enabled while it is the selected surface"
    end

    config
  end

  defp config do
    @app
    |> Application.get_env(@key, [])
    |> validate!()
  end

  defp normalize(value) do
    configured =
      cond do
        is_list(value) ->
          Map.new(value)

        is_map(value) ->
          value

        true ->
          raise ArgumentError, "product features must be configured as a keyword list or map"
      end

    Map.merge(@defaults, configured)
  end
end
