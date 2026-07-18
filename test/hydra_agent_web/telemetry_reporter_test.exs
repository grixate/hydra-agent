defmodule HydraAgentWeb.TelemetryReporterTest do
  use ExUnit.Case, async: false

  alias HydraAgentWeb.TelemetryReporter

  test "exports bounded HTTP and job labels as OpenMetrics" do
    duration = System.convert_time_unit(25, :millisecond, :native)
    conn = %Plug.Conn{status: 503}

    assert :ok =
             TelemetryReporter.handle_event(
               [:phoenix, :endpoint, :stop],
               %{duration: duration},
               %{conn: conn},
               nil
             )

    assert :ok =
             TelemetryReporter.handle_event(
               [:oban, :job, :exception],
               %{duration: duration},
               %{job: %{queue: "research/unsafe label"}},
               nil
             )

    metrics = TelemetryReporter.openmetrics()
    assert metrics =~ ~s(hydra_http_requests_total{status_class="5xx")
    assert metrics =~ ~s(outcome="exception")
    assert metrics =~ ~s(queue="research_unsafe_label")
    assert metrics =~ "hydra_beam_process_count"
    assert String.ends_with?(metrics, "# EOF\n")
  end
end
