defmodule HydraAgent.PublicDisclosure do
  @moduledoc "Deployment-owned public privacy and support disclosure."

  @fields ~w(operator_name support_email security_email privacy_url retention_summary)a

  def snapshot do
    configured = Application.get_env(:hydra_agent, :public_disclosure, [])

    values =
      Map.new(@fields, fn field ->
        {field, configured |> Keyword.get(field) |> normalize()}
      end)

    Map.put(values, :complete?, Enum.all?(@fields, &(is_binary(values[&1]) and values[&1] != "")))
  end

  defp normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> String.slice(normalized, 0, 1_000)
    end
  end

  defp normalize(_value), do: nil
end
