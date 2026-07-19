defmodule HydraAgent.PublicDisclosure do
  @moduledoc "Deployment-owned public privacy and support disclosure."

  @required_fields ~w(operator_name support_email security_email privacy_url retention_summary)a
  @fields @required_fields ++ [:retention_summary_ru]

  def snapshot do
    configured = Application.get_env(:hydra_agent, :public_disclosure, [])

    values =
      Map.new(@fields, fn field ->
        {field, configured |> Keyword.get(field) |> normalize()}
      end)

    Map.put(
      values,
      :complete?,
      Enum.all?(@required_fields, &(is_binary(values[&1]) and values[&1] != ""))
    )
  end

  defp normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> String.slice(normalized, 0, 1_000)
    end
  end

  defp normalize(_value), do: nil
end
