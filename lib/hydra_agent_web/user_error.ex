defmodule HydraAgentWeb.UserError do
  @moduledoc """
  Turns internal failures into calm, actionable UI copy without exposing
  implementation details, request data, or provider responses.
  """

  require Logger

  def message(action, %Ecto.Changeset{} = changeset) when is_binary(action) do
    log_failure(action, changeset)

    details =
      changeset.errors
      |> Enum.take(2)
      |> Enum.map_join(" ", &format_validation_error/1)

    if details == "",
      do: "We couldn't #{action}. Review the entered details and try again.",
      else: "We couldn't #{action}. #{details}"
  end

  def message(action, error) when is_binary(action) do
    log_failure(action, error)
    "We couldn't #{action}. Review the saved configuration and try again."
  end

  defp log_failure(action, error) do
    Logger.warning("UI action failed", action: action, reason: reason_class(error))
  end

  defp format_validation_error({field, {message, options}}) do
    message =
      Enum.reduce(options, message, fn {key, value}, rendered ->
        String.replace(rendered, "%{#{key}}", safe_option(value))
      end)

    field = field |> to_string() |> String.replace("_", " ") |> String.capitalize()
    "#{field} #{message}" |> String.replace(~r/\s+/, " ") |> String.slice(0, 240)
  end

  defp safe_option(value) when is_binary(value), do: String.slice(value, 0, 80)
  defp safe_option(value) when is_number(value) or is_atom(value), do: to_string(value)
  defp safe_option(_value), do: "the required value"

  defp reason_class(%Ecto.Changeset{} = changeset) do
    changeset.errors
    |> Keyword.keys()
    |> Enum.uniq()
    |> Enum.map_join(",", &to_string/1)
    |> then(&"validation:#{&1}")
  end

  defp reason_class(error) when is_atom(error), do: Atom.to_string(error)
  defp reason_class({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_class(%{__struct__: module}), do: inspect(module)
  defp reason_class(_error), do: "unclassified"
end
