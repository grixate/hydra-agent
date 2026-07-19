defmodule HydraAgent.Simulations.ReportExporter do
  @moduledoc "Deterministic, side-effect-free exports for Analysis Packs and validated Reports."

  import Ecto.Query

  alias HydraAgent.Repo
  alias HydraAgent.Runtime.RunEvent

  alias HydraAgent.Simulations.{
    AnalysisPack,
    ResourceTransaction,
    SimulationReport,
    SimulationRunRecord
  }

  def analysis_json(%AnalysisPack{} = pack),
    do: Jason.encode!(AnalysisPack.payload(pack), pretty: true) <> "\n"

  def metrics_csv(%AnalysisPack{} = pack) do
    rows =
      Enum.map(pack.metrics, fn metric ->
        [
          metric["ref"],
          metric["id"],
          metric["kind"],
          metric["unit"],
          metric["first"],
          metric["final"],
          metric["change"],
          metric["minimum"],
          metric["maximum"],
          metric["mean"],
          metric["direction"],
          metric["round_count"]
        ]
      end)

    csv(
      ~w(reference id kind unit first final change minimum maximum mean direction round_count),
      rows
    )
  end

  def events_csv(%SimulationRunRecord{} = record) do
    rows =
      RunEvent
      |> where([event], event.run_id == ^record.run_id)
      |> where([event], like(event.event_type, "simulation.%"))
      |> order_by([event], asc: event.sequence)
      |> Repo.all()
      |> Enum.map(fn event ->
        [
          event.sequence,
          event.round,
          event.phase,
          event.event_type,
          event.summary,
          event.actor_key,
          Enum.join(event.targets || [], "|"),
          event.source_ref,
          Jason.encode!(event.payload || %{}),
          Jason.encode!(event.provenance || %{}),
          iso8601(event.inserted_at)
        ]
      end)

    csv(
      ~w(sequence round phase event_type summary actor_key targets source_ref payload provenance recorded_at),
      rows
    )
  end

  def transactions_csv(%SimulationRunRecord{} = record) do
    rows =
      ResourceTransaction
      |> where([transaction], transaction.simulation_run_record_id == ^record.id)
      |> order_by([transaction], asc: transaction.sequence)
      |> Repo.all()
      |> Enum.map(fn transaction ->
        [
          transaction.sequence,
          transaction.round,
          transaction.phase,
          transaction.resource_id,
          transaction.operation,
          transaction.source_account,
          transaction.destination_account,
          Decimal.to_string(transaction.amount, :normal),
          transaction.source_ref,
          Enum.join(transaction.tags || [], "|"),
          Jason.encode!(transaction.resulting_balances || %{}),
          iso8601(transaction.inserted_at)
        ]
      end)

    csv(
      ~w(sequence round phase resource operation source_account destination_account amount source_ref tags resulting_balances recorded_at),
      rows
    )
  end

  def report_markdown(%SimulationReport{status: "ready"} = report) do
    labels = labels(report.locale)

    sections =
      Enum.map_join(report.sections, "\n\n", fn section ->
        references =
          section["references"]
          |> Enum.map_join(", ", &"`#{markdown_code(&1)}`")

        """
        ## #{markdown_text(section["heading"])}

        #{markdown_text(section["body"])}

        References: #{references}
        """
        |> String.trim()
      end)

    limitations = bullets(report.limitations, labels.none)
    next_steps = bullets(report.recommended_next_steps, labels.none)

    """
    # #{markdown_text(report.title)}

    #{markdown_text(report.summary)}

    #{sections}

    ## #{labels.limitations}

    #{limitations}

    ## #{labels.next_steps}

    #{next_steps}

    ---

    - Analysis: `#{markdown_code(report.analysis_hash)}`
    - Report: `#{markdown_code(report.content_hash)}`
    - Route: `#{markdown_code(report.provider)}/#{markdown_code(report.model)}`
    - Language: `#{markdown_code(report.locale)}` · Audience: `#{markdown_code(report.audience)}` · Length: `#{markdown_code(report.length)}`
    """
    |> String.trim()
    |> Kernel.<>("\n")
  end

  def report_markdown(%SimulationReport{}), do: raise(ArgumentError, "report is not ready")

  def report_html(%SimulationReport{status: "ready"} = report) do
    labels = labels(report.locale)

    sections =
      Enum.map_join(report.sections, "\n", fn section ->
        references =
          section["references"]
          |> Enum.map_join("", &"<li><code>#{html(&1)}</code></li>")

        """
        <section>
          <h2>#{html(section["heading"])}</h2>
          <p>#{html(section["body"])}</p>
          <details><summary>#{labels.references}</summary><ul>#{references}</ul></details>
        </section>
        """
      end)

    """
    <!doctype html>
    <html lang="#{html(report.locale)}">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>#{html(report.title)}</title>
      <style>
        :root { color-scheme: light; font-family: Inter, ui-sans-serif, system-ui, sans-serif; color: #191919; background: #fff; }
        body { margin: 0 auto; max-width: 760px; padding: 56px 28px 80px; line-height: 1.62; }
        h1 { font-size: 2.15rem; letter-spacing: -.035em; line-height: 1.08; margin: 0 0 18px; }
        h2 { font-size: 1.15rem; letter-spacing: -.015em; margin: 0 0 10px; }
        header { border-bottom: 1px solid #dedede; padding-bottom: 30px; margin-bottom: 34px; }
        section { break-inside: avoid; margin: 0 0 32px; }
        p { margin: 0; white-space: pre-line; }
        .summary { color: #4c4c4c; font-size: 1.08rem; }
        details { color: #666; font-size: .82rem; margin-top: 10px; }
        code { font-size: .78rem; overflow-wrap: anywhere; }
        .meta { color: #6b6b6b; font-size: .78rem; margin-top: 44px; border-top: 1px solid #dedede; padding-top: 18px; }
        @media print { body { max-width: none; padding: 0; } details { display: block; } }
      </style>
    </head>
    <body>
      <header><h1>#{html(report.title)}</h1><p class="summary">#{html(report.summary)}</p></header>
      <main>#{sections}</main>
      <section><h2>#{labels.limitations}</h2>#{html_list(report.limitations, labels.none)}</section>
      <section><h2>#{labels.next_steps}</h2>#{html_list(report.recommended_next_steps, labels.none)}</section>
      <footer class="meta">Analysis #{html(report.analysis_hash)} · Report #{html(report.content_hash)} · #{html(report.provider)}/#{html(report.model)}</footer>
    </body>
    </html>
    """
  end

  def report_html(%SimulationReport{}), do: raise(ArgumentError, "report is not ready")

  defp csv(headers, rows) do
    ([headers] ++ rows)
    |> Enum.map_join("\r\n", fn row -> Enum.map_join(row, ",", &csv_cell/1) end)
    |> Kernel.<>("\r\n")
  end

  defp csv_cell(nil), do: ""

  defp csv_cell(value) do
    value = value |> to_string() |> neutralize_spreadsheet_formula()

    if String.contains?(value, [",", "\"", "\r", "\n"]),
      do: "\"#{String.replace(value, "\"", "\"\"")}\"",
      else: value
  end

  defp bullets([], none), do: none
  defp bullets(items, _none), do: Enum.map_join(items, "\n", &"- #{markdown_text(&1)}")

  defp html_list([], none), do: "<p>#{html(none)}</p>"

  defp html_list(items, _none),
    do: "<ul>#{Enum.map_join(items, "", &"<li>#{html(&1)}</li>")}</ul>"

  defp labels("ru") do
    %{
      limitations: "Ограничения",
      next_steps: "Рекомендуемые следующие шаги",
      references: "Ссылки на данные",
      none: "Не указано."
    }
  end

  defp labels(_locale) do
    %{
      limitations: "Limitations",
      next_steps: "Recommended next steps",
      references: "Evidence references",
      none: "None recorded."
    }
  end

  defp html(value) do
    value
    |> to_string()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  defp markdown_text(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> html()
    |> String.replace(~r/([`*_{}\[\]()#+\-.!|>~=])/u, "\\\\\\1")
  end

  defp markdown_code(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("`", "&#96;")
  end

  defp neutralize_spreadsheet_formula(value) do
    if String.starts_with?(value, ["=", "+", "-", "@", "\t", "\r"]),
      do: "'" <> value,
      else: value
  end

  defp iso8601(nil), do: nil
  defp iso8601(value), do: DateTime.to_iso8601(value)
end
