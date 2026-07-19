defmodule HydraAgent.Providers.Mock do
  @behaviour HydraAgent.Provider

  @impl true
  def chat(provider, request) do
    cond do
      simulation_request?(request) and provider.metadata["mock_simulation_response"] == "error" ->
        {:error, %{"reason" => "mock_provider_failure"}}

      report_request?(request) and provider.metadata["mock_report_response"] == "error" ->
        {:error, %{"reason" => "mock_report_failure"}}

      true ->
        {text, usage} = mock_content(provider, request)

        {:ok,
         %{
           "provider" => provider.name,
           "model" => provider.model,
           "message" => %{"role" => "assistant", "content" => text},
           "usage" => usage
         }}
    end
  end

  @impl true
  def stream_chat(provider, request, callback) do
    {:ok, response} = chat(provider, request)
    callback.(%{"type" => "message.delta", "content" => response["message"]["content"]})
    {:ok, response}
  end

  @impl true
  def embed(provider, request) do
    inputs = List.wrap(request["input"] || "")

    {:ok,
     %{
       "provider" => provider.name,
       "model" => provider.model,
       "embeddings" => Enum.map(inputs, fn _ -> List.duplicate(0.0, 8) end)
     }}
  end

  @impl true
  def models(provider), do: {:ok, [%{"id" => provider.model, "provider" => provider.name}]}

  @impl true
  def health(_provider), do: :ok

  defp mock_content(
         %{metadata: %{"mock_simulation_response" => "invalid"}},
         %{"metadata" => %{"hydra_simulation_decision" => true}}
       ),
       do: {"not-json", %{"input_tokens" => 4, "output_tokens" => 2}}

  defp mock_content(_provider, %{"metadata" => %{"hydra_simulation_decision" => true}} = request) do
    allowed = get_in(request, ["metadata", "allowed_actions"]) || ["observe"]
    decision_key = get_in(request, ["metadata", "decision_key"]) || ""
    index = if allowed == [], do: 0, else: :erlang.phash2(decision_key, length(allowed))
    action_id = Enum.at(allowed, index) || "observe"

    payload = %{
      "action_id" => action_id,
      "parameters" => %{},
      "reason_codes" => ["representative_policy"],
      "short_rationale" => "Selected from the allowed actions for this policy signature.",
      "memory_updates" => %{},
      "uncertainty" => 0.25
    }

    {Jason.encode!(payload), %{"input_tokens" => 24, "output_tokens" => 32}}
  end

  defp mock_content(
         %{metadata: %{"mock_report_response" => "invalid_json"}},
         %{"metadata" => %{"hydra_analysis_report" => true}}
       ),
       do: {"not-json", %{"input_tokens" => 320, "output_tokens" => 8}}

  defp mock_content(provider, %{"metadata" => %{"hydra_analysis_report" => true}} = request) do
    metadata = request["metadata"]
    locale = metadata["locale"] || "en"
    reference = metadata["primary_reference"] || "setup:run"
    mode = provider.metadata["mock_report_response"]

    payload = report_fixture(locale, reference)

    payload =
      case mode do
        "unsupported_reference" ->
          put_in(payload, ["sections", Access.at(0), "references"], ["metric:not-recorded"])

        "invalid_number" ->
          put_in(
            payload,
            ["sections", Access.at(0), "body"],
            "The simulated result changed by 999999 percent."
          )

        "invented_url" ->
          put_in(
            payload,
            ["sections", Access.at(0), "body"],
            "The source is available at https://invented.invalid."
          )

        _other ->
          payload
      end

    {Jason.encode!(payload), %{"input_tokens" => 320, "output_tokens" => 420}}
  end

  defp mock_content(_provider, request) do
    text =
      request
      |> Map.get("messages", [])
      |> List.last()
      |> case do
        %{"content" => content} -> content
        %{content: content} -> content
        _ -> "ok"
      end

    {"mock: #{text}", %{"input_tokens" => 0, "output_tokens" => 0}}
  end

  defp simulation_request?(request),
    do: get_in(request, ["metadata", "hydra_simulation_decision"]) == true

  defp report_request?(request),
    do: get_in(request, ["metadata", "hydra_analysis_report"]) == true

  defp report_fixture("ru", reference) do
    %{
      "title" => "Отчёт о симуляции",
      "summary" =>
        "Симуляция показывает направленный результат, который следует проверять на реальных данных.",
      "sections" =>
        report_sections(
          [
            {"Постановка и вопрос", "Зафиксированы вопрос, условия и границы симуляции."},
            {"Краткий результат",
             "Смоделированный результат указывает направление, но не доказывает причинность."},
            {"Изменение мира",
             "Состояние мира менялось согласно записанным правилам и событиям."},
            {"Различия групп",
             "Группы демонстрировали различающиеся смоделированные траектории."},
            {"Потоки ресурсов и влияния",
             "Потоки отражают операции внутри модели, а не наблюдаемые транзакции."},
            {"Ключевые факторы",
             "На результат влияли записанные переходы, действия и условия мира."},
            {"Неопределённость и допущения",
             "Выводы остаются направленными из-за синтетической популяции и допущений."},
            {"Проверка и следующая симуляция",
             "Следующий запуск должен проверить чувствительность и сопоставить направление с наблюдениями."},
            {"Стоимость и конфигурация",
             "Конфигурация и использование сохранены вместе с воспроизводимой записью запуска."}
          ],
          reference
        ),
      "limitations" => [
        "Синтетическая популяция не является наблюдаемой выборкой.",
        "Направленный результат требует проверки на реальных данных."
      ],
      "recommended_next_steps" => [
        "Запустить сопоставимый сценарий с другим seed.",
        "Сравнить направление результата с наблюдаемыми данными."
      ]
    }
  end

  defp report_fixture(_locale, reference) do
    %{
      "title" => "Simulation report",
      "summary" =>
        "The simulation indicates a directional result that should be tested against observed evidence.",
      "sections" =>
        report_sections(
          [
            {"Setup and question",
             "The question, conditions, and simulation boundary are recorded."},
            {"Concise result",
             "The modeled result suggests a direction without establishing causality."},
            {"World evolution", "World state evolved through the recorded rules and events."},
            {"Group differences",
             "Groups followed distinct modeled trajectories within the run."},
            {"Resource and influence flows",
             "Flows represent model operations rather than observed transactions."},
            {"Pivotal drivers",
             "Recorded transitions, actions, and world conditions shaped the outcome."},
            {"Uncertainty and assumptions",
             "The result remains directional because the population is synthetic and assumptions are explicit."},
            {"Validation and next simulation",
             "A comparable run should test sensitivity and compare direction with observations."},
            {"Cost and configuration",
             "Configuration and usage are preserved with the reproducible run record."}
          ],
          reference
        ),
      "limitations" => [
        "The synthetic population is not an observed sample.",
        "The directional result requires real-world validation."
      ],
      "recommended_next_steps" => [
        "Run a comparable scenario with another seed.",
        "Compare the result direction with observed evidence."
      ]
    }
  end

  defp report_sections(sections, reference) do
    Enum.map(sections, fn {heading, body} ->
      %{"heading" => heading, "body" => body, "references" => [reference]}
    end)
  end
end
