defmodule HydraAgent.KnowledgeTest do
  use ExUnit.Case, async: true

  alias HydraAgent.Knowledge

  test "neutral type definitions cover core runtime graph concepts" do
    keys = Enum.map(Knowledge.neutral_type_definitions(), & &1["type_key"])

    for key <-
          ~w(source artifact observation claim entity event decision task risk memory references supports contradicts derived_from produced_by depends_on relates_to resolves) do
      assert key in keys
    end
  end

  test "task seed is explicitly not durable execution state" do
    task =
      Enum.find(Knowledge.neutral_type_definitions(), &(&1["type_key"] == "task"))

    assert task["description"] =~ "RunStep"
  end

  test "neutral type definitions are valid type definition attrs" do
    for attrs <- Knowledge.neutral_type_definitions() do
      changeset =
        HydraAgent.Knowledge.TypeDefinition.changeset(
          %HydraAgent.Knowledge.TypeDefinition{},
          Map.put(attrs, "workspace_id", 1)
        )

      assert changeset.valid?
    end
  end

  test "source nodes require source provenance and url" do
    valid =
      Knowledge.change_node(%{
        workspace_id: 1,
        type_key: "source",
        title: "Source",
        provenance: %{"kind" => "source_ingest"},
        attributes: %{"url" => "https://example.com"}
      })

    invalid =
      Knowledge.change_node(%{
        workspace_id: 1,
        type_key: "source",
        title: "Source",
        provenance: %{"kind" => "source_ingest"},
        attributes: %{}
      })

    assert valid.valid?
    refute invalid.valid?

    assert {"source nodes require source_ingest provenance and a url", _meta} =
             invalid.errors[:provenance]
  end

  test "artifact nodes require artifact provenance and a path or uri" do
    valid =
      Knowledge.change_node(%{
        workspace_id: 1,
        type_key: "artifact",
        title: "Report",
        provenance: %{"kind" => "artifact_record"},
        attributes: %{"path" => "reports/run.md"}
      })

    invalid =
      Knowledge.change_node(%{
        workspace_id: 1,
        type_key: "artifact",
        title: "Report",
        provenance: %{"kind" => "artifact_record"},
        attributes: %{}
      })

    assert valid.valid?
    refute invalid.valid?
    assert {"artifact nodes require a path or uri", _meta} = invalid.errors[:provenance]
  end
end
