defmodule HydraAgentWeb.SimLabHTMLTest do
  use ExUnit.Case, async: true

  alias HydraAgentWeb.SimLabHTML

  test "evidence impact copy follows the review decision" do
    pending = %{
      metadata: %{"review_status" => "unreviewed"},
      simulation_impact: "Requires review before it changes generated behavior."
    }

    reviewed = put_in(pending, [:metadata, "review_status"], "reviewed")
    dismissed = put_in(pending, [:metadata, "review_status"], "dismissed")

    assert SimLabHTML.evidence_impact_text(pending) ==
             "Requires review before it changes generated behavior."

    assert SimLabHTML.evidence_impact_text(reviewed) ==
             "Reviewed for model provenance. Its influence remains directional."

    assert SimLabHTML.evidence_impact_text(dismissed) ==
             "Dismissed. It is excluded from generated behavior."
  end
end
