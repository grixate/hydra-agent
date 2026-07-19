defmodule HydraAgentWeb.PrivacyCopy do
  @moduledoc false

  @copy %{
    "en" => %{
      page_title: "Privacy & data flow",
      eyebrow: "Settings · Privacy",
      title: "Know what stays here—and what may leave.",
      lede:
        "Hydra keeps simulation actions inside the modeled world. External data flow is limited to the provider route selected for a specific stage.",
      workspace: "Workspace",
      account_security: "Account security",
      operations: "Operator settings",
      incomplete_title: "Operator notice is incomplete",
      incomplete_lede:
        "Before a controlled pilot, publish the operator, support, security, privacy, and retention details below.",
      operator_title: "Who operates this deployment",
      operator: "Operator",
      support: "Support",
      security: "Security reports",
      privacy_notice: "Privacy notice",
      retention: "Retention",
      not_published: "Not published by this deployment",
      flow_title: "What each stage can send",
      flow_lede: "The current V1 boundary is intentionally narrow and inspectable.",
      research_title: "Context research",
      research_body:
        "A search provider receives bounded search queries. User-supplied public URLs are fetched by Hydra. Uploaded files and private notes are not sent to search providers.",
      balanced_title: "Balanced simulation",
      balanced_body:
        "The selected model receives bounded representative state and allowed actions. It does not receive full source files. Quick simulations make no model calls.",
      report_title: "Report generation",
      report_body:
        "The selected report model receives the validated Analysis Pack and permitted context references. The completed Run stays valid if report generation fails.",
      routes_title: "Available model routes",
      routes_lede:
        "Provider and model names are visible; credentials are never shown or stored in a Simulation Pack.",
      no_routes: "No enabled model routes are configured for this workspace.",
      local: "Local to this deployment",
      external: "External provider",
      test_only: "Test-only route",
      route_model: "Model",
      safeguards_title: "Product safeguards",
      safeguards: [
        "Simulation actions cannot email, message, change files, call arbitrary URLs, or modify external systems.",
        "Raw sources are excluded from portable exports by default; identity redaction always excludes them.",
        "Provider, usage, fallback, budget, and immutable Run lineage are recorded for audit.",
        "Hydra is for aggregate simulation—not consequential decisions about named individuals or covert profiling."
      ],
      storage_title: "Storage and deletion",
      storage_body:
        "Questions, uploaded evidence, immutable build artifacts, Runs, and audit records remain in the workspace database until the deployment operator applies its published retention or deletion process.",
      codex_title: "Local Codex CLI",
      codex_body:
        "The bundled Codex CLI bridge is a development-only hypothesis route. A production automation route must use explicit non-interactive authentication and pass the same timeout, isolation, usage, and failure tests as every other provider."
    },
    "ru" => %{
      page_title: "Конфиденциальность и потоки данных",
      eyebrow: "Настройки · Конфиденциальность",
      title: "Что остаётся здесь — и что может покинуть систему.",
      lede:
        "Hydra выполняет действия только внутри моделируемого мира. Внешняя передача данных ограничена маршрутом провайдера для конкретного этапа.",
      workspace: "Рабочее пространство",
      account_security: "Безопасность аккаунта",
      operations: "Настройки оператора",
      incomplete_title: "Уведомление оператора не заполнено",
      incomplete_lede:
        "До контролируемого пилота опубликуйте сведения об операторе, поддержке, безопасности, конфиденциальности и сроках хранения.",
      operator_title: "Кто управляет этим развёртыванием",
      operator: "Оператор",
      support: "Поддержка",
      security: "Сообщить об уязвимости",
      privacy_notice: "Уведомление о конфиденциальности",
      retention: "Хранение",
      not_published: "Не опубликовано оператором",
      flow_title: "Что может передавать каждый этап",
      flow_lede: "Граница V1 намеренно узкая и проверяемая.",
      research_title: "Исследование контекста",
      research_body:
        "Поисковый провайдер получает ограниченные поисковые запросы. Публичные URL загружает Hydra. Файлы и частные заметки не передаются поисковым провайдерам.",
      balanced_title: "Сбалансированная симуляция",
      balanced_body:
        "Выбранная модель получает ограниченное состояние представителя и допустимые действия, но не исходные файлы. Быстрая симуляция не обращается к моделям.",
      report_title: "Создание отчёта",
      report_body:
        "Модель отчёта получает проверенный пакет анализа и разрешённые ссылки на контекст. Ошибка отчёта не отменяет завершённый запуск.",
      routes_title: "Доступные маршруты моделей",
      routes_lede:
        "Названия провайдера и модели видимы; учётные данные не показываются и не попадают в пакет симуляции.",
      no_routes: "В этом рабочем пространстве нет активных маршрутов моделей.",
      local: "Локально в этом развёртывании",
      external: "Внешний провайдер",
      test_only: "Только для тестов",
      route_model: "Модель",
      safeguards_title: "Защитные ограничения",
      safeguards: [
        "Действия симуляции не отправляют письма и сообщения, не меняют файлы и внешние системы и не вызывают произвольные URL.",
        "Исходные материалы по умолчанию исключены из переносимых файлов; скрытие личностей всегда исключает их.",
        "Провайдер, использование, резервные правила, бюджет и неизменяемая история запуска записываются для аудита.",
        "Hydra предназначена для агрегированной симуляции, а не решений о конкретных людях или скрытого профилирования."
      ],
      storage_title: "Хранение и удаление",
      storage_body:
        "Вопросы, загруженные материалы, неизменяемые артефакты сборки, запуски и аудит остаются в базе рабочего пространства до применения опубликованной оператором политики хранения или удаления.",
      codex_title: "Локальный Codex CLI",
      codex_body:
        "Встроенный мост Codex CLI предназначен только для тестовых гипотез. Производственный маршрут должен использовать явную неинтерактивную авторизацию и пройти те же проверки тайм-аутов, изоляции, использования и сбоев, что и другие провайдеры."
    }
  }

  def locale("ru"), do: "ru"
  def locale(_locale), do: "en"

  def t(locale, key) do
    @copy
    |> Map.fetch!(locale(locale))
    |> Map.fetch!(key)
  end
end
