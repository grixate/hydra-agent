defmodule HydraAgent.KnowledgeRelationshipTest do
  use HydraAgent.DataCase, async: true

  alias HydraAgent.Knowledge
  alias HydraAgent.Runtime

  setup do
    {:ok, workspace} = Runtime.create_workspace(%{name: "Graph", slug: "graph"})
    %{workspace: workspace}
  end

  test "supports relationships must point to claims", %{workspace: workspace} do
    {:ok, source} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "source",
        title: "Source",
        provenance: %{"kind" => "source_ingest"},
        attributes: %{"url" => "https://example.com"}
      })

    {:ok, artifact} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "artifact",
        title: "Artifact",
        provenance: %{"kind" => "artifact_record"},
        attributes: %{"path" => "artifact.md"}
      })

    assert {:error, changeset} =
             Knowledge.create_relationship(%{
               workspace_id: workspace.id,
               from_node_id: source.id,
               to_node_id: artifact.id,
               type_key: "supports"
             })

    assert "supports relationships must point to a claim" in errors_on(changeset).to_node_id
  end

  test "references relationships point to sources or artifacts", %{workspace: workspace} do
    {:ok, claim} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "claim",
        title: "Claim"
      })

    {:ok, source} =
      Knowledge.create_node(%{
        workspace_id: workspace.id,
        type_key: "source",
        title: "Source",
        provenance: %{"kind" => "source_ingest"},
        attributes: %{"url" => "https://example.com"}
      })

    assert {:ok, relationship} =
             Knowledge.create_relationship(%{
               workspace_id: workspace.id,
               from_node_id: claim.id,
               to_node_id: source.id,
               type_key: "references"
             })

    assert relationship.type_key == "references"
  end
end
