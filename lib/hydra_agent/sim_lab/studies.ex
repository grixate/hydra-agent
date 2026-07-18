defmodule HydraAgent.SimLab.Studies do
  @moduledoc """
  Durable study, source, evidence, and context-pack operations.

  This context is intentionally distinct from the neutral agent runtime. It
  becomes the boundary through which research data gains provenance and can be
  invalidated when a source is deleted.
  """

  import Ecto.Query

  alias HydraAgent.Repo
  alias HydraAgent.SimLab.{BehaviorCompiler, LocalContextBuilder}

  alias HydraAgent.SimLab.Schemas.{
    ActionPattern,
    ActionPatternPersona,
    ContextPack,
    EvidenceItem,
    Persona,
    Source,
    Study
  }

  def list_studies(workspace_id) do
    Study
    |> where([study], study.workspace_id == ^workspace_id)
    |> order_by([study], desc: study.updated_at)
    |> Repo.all()
  end

  def get_study!(workspace_id, id) do
    Study
    |> where([study], study.workspace_id == ^workspace_id and study.id == ^id)
    |> Repo.one!()
  end

  def create_study(attrs), do: %Study{} |> Study.changeset(attrs) |> Repo.insert()
  def update_study(%Study{} = study, attrs), do: study |> Study.changeset(attrs) |> Repo.update()

  def add_source(%Study{} = study, attrs) do
    attrs = Map.merge(attrs, %{study_id: study.id, workspace_id: study.workspace_id})
    %Source{} |> Source.changeset(attrs) |> Repo.insert()
  end

  def add_evidence(%Study{} = study, attrs) do
    attrs = Map.put(attrs, :study_id, study.id)
    %EvidenceItem{} |> EvidenceItem.changeset(attrs) |> Repo.insert()
  end

  def review_evidence(study, evidence_id, decision, reviewer_id \\ nil)

  def review_evidence(%Study{} = study, evidence_id, decision, reviewer_id)
      when decision in ["reviewed", "dismissed"] do
    case study_evidence(study, evidence_id) do
      %EvidenceItem{} = evidence ->
        metadata =
          (evidence.metadata || %{})
          |> Map.merge(%{
            "review_status" => decision,
            "reviewed_at" =>
              DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
          })
          |> maybe_put_reviewer(reviewer_id)

        evidence |> EvidenceItem.changeset(%{metadata: metadata}) |> Repo.update()

      nil ->
        {:error, :evidence_not_in_study}
    end
  end

  def review_evidence(%Study{}, _evidence_id, _decision, _reviewer_id),
    do: {:error, :invalid_review_decision}

  def create_context_pack(%Study{} = study, attrs) do
    attrs = Map.put_new(attrs, :study_id, study.id)
    %ContextPack{} |> ContextPack.changeset(attrs) |> Repo.insert()
  end

  def update_context_pack(%ContextPack{} = context_pack, attrs),
    do: context_pack |> ContextPack.changeset(attrs) |> Repo.update()

  @doc """
  Adds a local research note as explicitly labelled direct user data.

  Notes are stored locally, marked as potentially sensitive by default, and
  establish the first active context pack when a study has none. This gives a
  researcher a useful path before an external research provider is configured.
  """
  def add_manual_note(%Study{} = study, attrs) do
    note = (fetch_attr(attrs, :note) || "") |> to_string() |> String.trim()

    if note == "" do
      {:error, :blank_note}
    else
      Repo.transaction(fn ->
        source =
          add_source!(study, %{
            kind: "manual_note",
            title: fetch_attr(attrs, :title) || "Research note",
            content_hash: note_hash(note),
            parsed_text: note,
            metadata: %{"entry_type" => "local_note"},
            pii_status: "suspected",
            access_policy: %{"scope" => "workspace_only", "external_send" => false},
            status: "parsed"
          })

        evidence =
          add_evidence!(study, %{
            source_id: source.id,
            kind: "research_note",
            claim: note,
            normalized_claim: normalize_note(note),
            source_ref: %{"source_id" => to_string(source.id), "kind" => "manual_note"},
            grounding_level: "direct_user_data",
            reliability_score: 0.7,
            relevance_score: 0.7,
            freshness_score: 0.7,
            confidence_score: 0.55,
            simulation_impact: "Requires review before it changes a behavior rule.",
            tags: ["local_note", "review_required"],
            metadata: %{"review_status" => "unreviewed"}
          })

        context_pack =
          ensure_local_context!(study, source, note, "local_note")

        updated_study = update_study!(study, %{status: "context_ready"})
        %{study: updated_study, source: source, evidence: evidence, context_pack: context_pack}
      end)
    end
  end

  @doc """
  Adds a small extracted local document as direct user data. The caller is
  responsible for validating the upload type and size before passing text in.
  No upload path or external storage reference is persisted.
  """
  def add_uploaded_text(%Study{} = study, attrs) do
    text = (fetch_attr(attrs, :text) || "") |> to_string() |> String.trim()

    if text == "" do
      {:error, :blank_document}
    else
      title = fetch_attr(attrs, :title) || "Local document"
      filename = fetch_attr(attrs, :filename) || title
      extension = fetch_attr(attrs, :extension) || ""

      Repo.transaction(fn ->
        source =
          add_source!(study, %{
            kind: "upload",
            title: title,
            content_hash: note_hash(text),
            parsed_text: text,
            metadata: %{
              "entry_type" => "uploaded_text",
              "filename" => filename,
              "extension" => extension
            },
            pii_status: "suspected",
            access_policy: %{"scope" => "workspace_only", "external_send" => false},
            status: "parsed"
          })

        evidence =
          add_evidence!(study, %{
            source_id: source.id,
            kind: "uploaded_data",
            claim: document_claim(text),
            normalized_claim: normalize_note(text),
            source_ref: %{"source_id" => to_string(source.id), "kind" => "upload"},
            grounding_level: "direct_user_data",
            reliability_score: 0.65,
            relevance_score: 0.65,
            freshness_score: 0.65,
            confidence_score: 0.5,
            simulation_impact:
              "Review and link this local document before it changes a behavior rule.",
            tags: ["uploaded_text", "review_required"],
            metadata: %{"review_status" => "unreviewed"}
          })

        context_pack = ensure_local_context!(study, source, text, "local_document")
        updated_study = update_study!(study, %{status: "context_ready"})
        %{study: updated_study, source: source, evidence: evidence, context_pack: context_pack}
      end)
    end
  end

  @doc """
  Adds text fetched from an explicitly researcher-supplied public URL. The
  caller must fetch and validate the URL first; this context only persists the
  reviewed artifact and its external-research grounding.
  """
  def add_public_web_source(%Study{} = study, attrs) do
    uri = fetch_attr(attrs, :uri)
    title = fetch_attr(attrs, :title) || "Public web source"
    text = (fetch_attr(attrs, :text) || "") |> to_string() |> String.trim()

    if not is_binary(uri) or uri == "" or text == "" do
      {:error, :invalid_public_source}
    else
      Repo.transaction(fn ->
        source =
          add_source!(study, %{
            kind: "web",
            title: title,
            uri: uri,
            content_hash: note_hash(text),
            parsed_text: text,
            metadata: %{"entry_type" => "manual_public_url"},
            pii_status: "none",
            access_policy: %{"scope" => "workspace_only", "external_send" => false},
            status: "parsed"
          })

        evidence =
          add_evidence!(study, %{
            source_id: source.id,
            kind: "research_candidate",
            claim: document_claim(text),
            normalized_claim: normalize_note(text),
            source_ref: %{"source_id" => to_string(source.id), "uri" => uri, "kind" => "web"},
            grounding_level: "external_research",
            reliability_score: 0.5,
            relevance_score: 0.6,
            freshness_score: 0.5,
            confidence_score: 0.5,
            simulation_impact:
              "Review and link this public source before it changes a behavior rule.",
            tags: ["manual_public_url", "review_required"],
            metadata: %{"review_status" => "unreviewed"}
          })

        context_pack = ensure_public_context!(study, source, evidence)
        updated_study = update_study!(study, %{status: "context_ready"})
        %{study: updated_study, source: source, evidence: evidence, context_pack: context_pack}
      end)
    end
  end

  @doc """
  Removes a study source and every derived evidence item. The source
  record is retained only as a deleted audit marker; its parsed content is
  redacted and it is excluded from normal study queries.
  """
  def remove_local_source(%Study{} = study, source_id) do
    with %Source{} = source <- removable_source(study, source_id) do
      Repo.transaction(fn ->
        removed_evidence_ids =
          EvidenceItem
          |> where([item], item.source_id == ^source.id)
          |> select([item], item.id)
          |> Repo.all()

        invalidate_behavior_grounding!(study, removed_evidence_ids)

        EvidenceItem
        |> where([item], item.source_id == ^source.id)
        |> Repo.delete_all()

        removed_source =
          source
          |> Source.changeset(%{
            parsed_text: nil,
            raw_object_key: nil,
            metadata: Map.put(source.metadata || %{}, "removed_from_study", true),
            status: "deleted"
          })
          |> update_or_rollback!()

        context_pack = update_context_after_local_removal!(study, source.id)
        %{source: removed_source, context_pack: context_pack}
      end)
    else
      nil -> {:error, :source_not_in_study}
    end
  end

  @doc """
  Starts a study without local or external evidence while making the absence of
  evidence explicit in the durable context pack and its confidence.
  """
  def create_assumption_context(%Study{} = study) do
    if active_context_pack(study) do
      {:error, :context_already_exists}
    else
      Repo.transaction(fn ->
        context_pack =
          create_context_pack!(study, %{
            version: next_context_version(study),
            summary: %{"research_status" => "assumption_start", "local_entry_count" => 0},
            source_mix: %{"direct_user_data" => 0, "external_research" => 0, "assumptions" => 1},
            key_findings: [],
            assumptions: [
              %{
                "statement" =>
                  "No direct or external research evidence has been added; behavior is a starting hypothesis only."
              }
            ],
            open_questions: [
              %{"question" => "Which user evidence would most change this forecast?"}
            ],
            simulation_implications: [
              %{
                "note" =>
                  "Keep the simulation directional and validate the most influential assumptions before making a decision."
              }
            ],
            confidence: 0.25,
            generated_by_protocol_version: "sim-lab-assumption-start/v1",
            status: "active"
          })

        updated_study = update_study!(study, %{status: "context_ready"})
        %{study: updated_study, context_pack: context_pack}
      end)
    end
  end

  @doc """
  Produces a new active Context Pack from evidence already stored in the
  workspace. No provider is contacted and no local source text leaves Hydra.
  """
  def synthesize_workspace_context(%Study{} = study) do
    Repo.transaction(fn ->
      sources = list_sources(study)
      evidence = list_evidence(study)

      if sources == [] or evidence == [] do
        Repo.rollback(:no_workspace_evidence)
      end

      ContextPack
      |> where([pack], pack.study_id == ^study.id and pack.status == "active")
      |> Repo.update_all(set: [status: "superseded"])

      context_pack =
        study
        |> LocalContextBuilder.build(sources, evidence, next_context_version(study))
        |> then(&create_context_pack!(study, &1))

      updated_study = update_study!(study, %{status: "context_ready"})
      %{study: updated_study, context_pack: context_pack}
    end)
  end

  @doc """
  Adds an explicit behavioral segment while keeping its population distribution
  bounded to the study population.
  """
  def add_persona(%Study{} = study, attrs) do
    Repo.transaction(fn ->
      persona =
        attrs
        |> stringify_keys()
        |> Map.put("study_id", study.id)
        |> then(&add_persona!(&1))

      allocated_weight =
        Persona
        |> where([persona], persona.study_id == ^study.id and persona.status == "active")
        |> select([persona], sum(persona.distribution_weight))
        |> Repo.one()

      if allocated_weight > 1.0 + 1.0e-9 do
        Repo.rollback(:distribution_exceeds_population)
      end

      updated_study = update_study!(study, %{status: "personas_ready"})
      %{study: updated_study, persona: persona, allocated_weight: allocated_weight}
    end)
  end

  @doc """
  Revises a behavioral segment in place while retaining an inspectable version
  increment and the study-wide population allocation invariant.
  """
  def update_persona(%Study{} = study, persona_id, attrs) do
    with %Persona{} = persona <- study_persona(study, persona_id),
         {:ok, evidence, evidence_refs} <-
           evidence_for_refs(study, fetch_attr(attrs, :evidence_refs)) do
      Repo.transaction(fn ->
        updated_persona =
          persona
          |> Persona.changeset(
            attrs
            |> stringify_keys()
            |> Map.merge(%{
              "version" => persona.version + 1,
              "evidence_refs" => evidence_refs,
              "grounding_mix" => grounding_mix(evidence)
            })
          )
          |> update_or_rollback!()

        allocated_weight = allocated_persona_weight(study)

        if allocated_weight > 1.0 + 1.0e-9 do
          Repo.rollback(:distribution_exceeds_population)
        end

        updated_study = update_study!(study, %{status: "personas_ready"})
        %{study: updated_study, persona: updated_persona, allocated_weight: allocated_weight}
      end)
    else
      nil -> {:error, :persona_not_in_study}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Adds a low-cost executable action pattern for a persona in the same study.
  """
  def add_action_pattern(%Study{} = study, persona_id, attrs) do
    with %Persona{} = persona <- study_persona(study, persona_id) do
      attrs =
        attrs
        |> stringify_keys()
        |> Map.merge(%{
          "study_id" => study.id,
          "persona_ids" => [persona.id],
          "grounding_level" => "assumption",
          "status" => "active"
        })

      Repo.transaction(fn ->
        pattern =
          %ActionPattern{}
          |> ActionPattern.changeset(attrs)
          |> insert_or_rollback!()

        sync_pattern_personas!(pattern, [persona])

        updated_study = update_study!(study, %{status: "patterns_ready"})
        %{study: updated_study, pattern: pattern}
      end)
    else
      nil -> {:error, :persona_not_in_study}
    end
  end

  @doc """
  Revises an executable rule only when both the rule and its selected segment
  belong to the current study. Every saved revision increments its version.
  """
  def update_action_pattern(%Study{} = study, pattern_id, persona_id, attrs) do
    with %ActionPattern{} = pattern <- study_pattern(study, pattern_id),
         %Persona{} = persona <- study_persona(study, persona_id),
         {:ok, evidence, evidence_refs} <-
           evidence_for_refs(study, fetch_attr(attrs, :evidence_refs)) do
      Repo.transaction(fn ->
        updated_pattern =
          pattern
          |> ActionPattern.changeset(
            attrs
            |> stringify_keys()
            |> Map.merge(%{
              "persona_ids" => [persona.id],
              "version" => pattern.version + 1,
              "evidence_refs" => evidence_refs,
              "grounding_level" => dominant_grounding(evidence)
            })
          )
          |> update_or_rollback!()

        sync_pattern_personas!(updated_pattern, [persona])

        updated_study = update_study!(study, %{status: "patterns_ready"})
        %{study: updated_study, pattern: updated_pattern}
      end)
    else
      nil -> {:error, :record_not_in_study}
      {:error, _reason} = error -> error
    end
  end

  def generate_behavior_draft(%Study{} = study) do
    Repo.transaction(fn ->
      locked_study =
        Study
        |> where([candidate], candidate.id == ^study.id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      if list_personas(locked_study) != [] do
        Repo.rollback(:personas_already_exist)
      end

      compiled =
        BehaviorCompiler.compile(
          locked_study,
          active_context_pack(locked_study),
          list_evidence(locked_study)
        )

      generated =
        Enum.map(compiled.personas, fn draft ->
          persona =
            draft.persona
            |> Map.put(:study_id, locked_study.id)
            |> add_persona!()

          patterns =
            Enum.map(draft.patterns, fn pattern_attrs ->
              pattern =
                %ActionPattern{}
                |> ActionPattern.changeset(
                  pattern_attrs
                  |> Map.put(:study_id, locked_study.id)
                  |> Map.put(:persona_ids, [persona.id])
                )
                |> insert_or_rollback!()

              sync_pattern_personas!(pattern, [persona])
              pattern
            end)

          %{persona: persona, patterns: patterns}
        end)

      updated_study = update_study!(locked_study, %{status: "patterns_ready"})

      %{
        study: updated_study,
        generated: generated,
        persona_count: compiled.persona_count,
        pattern_count: compiled.pattern_count,
        protocol_version: compiled.protocol_version,
        context_fingerprint: compiled.context_fingerprint
      }
    end)
  end

  @doc """
  Persists a reviewable research output atomically and makes its context pack
  the active version for the study. The caller must have already obtained the
  study through its workspace-scoped lookup.
  """
  def persist_research_output(%Study{} = study, output) do
    Repo.transaction(fn ->
      sources =
        Enum.map(output.sources, fn attrs ->
          attrs
          |> Map.drop([:reference])
          |> then(&add_source!(study, &1))
        end)

      source_ids =
        output.sources
        |> Enum.zip(sources)
        |> Map.new(fn {%{reference: reference}, source} -> {reference, source.id} end)

      Enum.each(output.evidence, fn attrs ->
        attrs
        |> Map.drop([:source_reference])
        |> Map.put(:source_id, Map.fetch!(source_ids, attrs.source_reference))
        |> then(&add_evidence!(study, &1))
      end)

      version = next_context_version(study)

      ContextPack
      |> where([pack], pack.study_id == ^study.id and pack.status == "active")
      |> Repo.update_all(set: [status: "superseded"])

      context_pack =
        output.context_pack
        |> Map.put(:version, version)
        |> then(&create_context_pack!(study, &1))

      updated_study = update_study!(study, %{status: "context_ready"})
      %{study: updated_study, context_pack: context_pack, sources: sources}
    end)
  end

  def list_sources(%Study{id: study_id}), do: list_sources(study_id)

  def list_sources(study_id) do
    Source
    |> where([source], source.study_id == ^study_id and source.status != "deleted")
    |> order_by([source], desc: source.inserted_at)
    |> Repo.all()
  end

  def list_evidence(%Study{id: study_id}), do: list_evidence(study_id)

  def list_evidence(study_id) do
    EvidenceItem
    |> where([item], item.study_id == ^study_id)
    |> order_by([item], desc: item.confidence_score, desc: item.inserted_at)
    |> Repo.all()
  end

  def list_personas(%Study{id: study_id}), do: list_personas(study_id)

  def list_personas(study_id) do
    Persona
    |> where([persona], persona.study_id == ^study_id and persona.status == "active")
    |> order_by([persona], asc: persona.inserted_at, asc: persona.id)
    |> Repo.all()
  end

  def list_action_patterns(%Study{id: study_id}), do: list_action_patterns(study_id)

  def list_action_patterns(study_id) do
    ActionPattern
    |> where([pattern], pattern.study_id == ^study_id and pattern.status == "active")
    |> order_by([pattern], asc: pattern.inserted_at, asc: pattern.id)
    |> Repo.all()
  end

  def active_context_pack(%Study{id: study_id}) do
    ContextPack
    |> where([pack], pack.study_id == ^study_id and pack.status == "active")
    |> order_by([pack], desc: pack.version)
    |> Repo.one()
  end

  defp next_context_version(%Study{id: study_id}) do
    ContextPack
    |> where([pack], pack.study_id == ^study_id)
    |> select([pack], max(pack.version))
    |> Repo.one()
    |> then(&((&1 || 0) + 1))
  end

  defp sync_pattern_personas!(pattern, personas) do
    ActionPatternPersona
    |> where([link], link.action_pattern_id == ^pattern.id)
    |> Repo.delete_all()

    Enum.each(personas, fn persona ->
      %ActionPatternPersona{}
      |> ActionPatternPersona.changeset(%{
        action_pattern_id: pattern.id,
        persona_id: persona.id
      })
      |> insert_or_rollback!()
    end)
  end

  defp ensure_local_context!(study, source, text, entry_type) do
    case active_context_pack(study) do
      nil -> create_initial_local_context!(study, source, text, entry_type)
      pack -> update_local_context!(pack, source, text, entry_type)
    end
  end

  defp ensure_public_context!(study, source, evidence) do
    finding = %{
      "kind" => "manual_public_url",
      "statement" => String.slice(evidence.claim, 0, 280),
      "source_id" => source.id
    }

    case active_context_pack(study) do
      nil ->
        create_context_pack!(study, %{
          version: next_context_version(study),
          summary: %{"research_status" => "manual_public_url", "local_entry_count" => 0},
          source_mix: %{"direct_user_data" => 0, "external_research" => 1, "assumptions" => 0},
          key_findings: [finding],
          assumptions: [],
          open_questions: [
            %{"question" => "How representative is this public source for the study audience?"}
          ],
          simulation_implications: [
            %{"note" => "Review this public source before linking it to behavior rules."}
          ],
          confidence: 0.5,
          generated_by_protocol_version: "sim-lab-manual-public-source/v1",
          status: "active"
        })

      context_pack ->
        source_mix = Map.update(context_pack.source_mix || %{}, "external_research", 1, &(&1 + 1))

        case update_context_pack(context_pack, %{
               source_mix: source_mix,
               summary:
                 Map.put(context_pack.summary || %{}, "research_status", "manual_public_url"),
               key_findings: (context_pack.key_findings || []) ++ [finding],
               confidence: max(context_pack.confidence || 0.25, 0.5)
             }) do
          {:ok, updated} -> updated
          {:error, changeset} -> Repo.rollback(changeset)
        end
    end
  end

  defp create_initial_local_context!(study, source, text, entry_type) do
    create_context_pack!(study, %{
      version: next_context_version(study),
      summary: %{"research_status" => entry_type, "local_entry_count" => 1},
      source_mix: %{"direct_user_data" => 1, "external_research" => 0, "assumptions" => 0},
      key_findings: [
        %{
          "kind" => entry_type,
          "statement" => String.slice(text, 0, 280),
          "source_id" => source.id
        }
      ],
      assumptions: [],
      open_questions: [%{"question" => "What evidence would change this note?"}],
      simulation_implications: [
        %{"note" => "Review local evidence before creating executable patterns."}
      ],
      confidence: 0.55,
      generated_by_protocol_version: "sim-lab-local-notes/v1",
      status: "active"
    })
  end

  defp update_local_context!(context_pack, source, text, entry_type) do
    source_mix = Map.update(context_pack.source_mix || %{}, "direct_user_data", 1, &(&1 + 1))
    summary = Map.update(context_pack.summary || %{}, "local_entry_count", 1, &(&1 + 1))

    key_findings =
      (context_pack.key_findings || []) ++
        [
          %{
            "kind" => entry_type,
            "statement" => String.slice(text, 0, 280),
            "source_id" => source.id
          }
        ]

    case update_context_pack(context_pack, %{
           source_mix: source_mix,
           summary: summary,
           key_findings: key_findings,
           confidence: 0.55
         }) do
      {:ok, updated} -> updated
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp update_context_after_local_removal!(study, removed_source_id) do
    case active_context_pack(study) do
      nil ->
        nil

      context_pack ->
        remaining_sources = list_sources(study)
        remaining_evidence = list_evidence(study)
        direct_count = Enum.count(remaining_evidence, &(&1.grounding_level == "direct_user_data"))

        external_count =
          Enum.count(remaining_evidence, &(&1.grounding_level == "external_research"))

        source_mix =
          (context_pack.source_mix || %{})
          |> Map.put("direct_user_data", direct_count)
          |> Map.put("external_research", external_count)

        summary =
          (context_pack.summary || %{})
          |> Map.put(
            "local_entry_count",
            Enum.count(remaining_sources, &(&1.kind in ["manual_note", "upload"]))
          )

        context_attrs = purge_removed_source_context(context_pack, removed_source_id)

        {summary, source_mix, confidence, context_attrs} =
          if direct_count == 0 and external_count == 0 do
            {
              Map.put(summary, "research_status", "no_local_evidence"),
              Map.update(source_mix, "assumptions", 1, &max(&1, 1)),
              0.25,
              %{
                key_findings: [],
                market_context: [],
                behavioral_context: [],
                recent_context: [],
                regulatory_context: [],
                risks: [
                  %{
                    "kind" => "no_local_evidence",
                    "note" => "Removed local sources no longer ground this context pack."
                  }
                ],
                assumptions: [
                  %{
                    "statement" =>
                      "No retained evidence remains; this context is an assumption-only starting point."
                  }
                ],
                open_questions: [
                  %{"question" => "Which evidence should be added before creating a forecast?"}
                ],
                simulation_implications: [
                  %{
                    "note" =>
                      "Do not rely on deleted local evidence when interpreting future runs."
                  }
                ]
              }
            }
          else
            {summary, source_mix, context_pack.confidence, context_attrs}
          end

        attrs =
          %{source_mix: source_mix, summary: summary, confidence: confidence}
          |> Map.merge(context_attrs)

        case update_context_pack(context_pack, attrs) do
          {:ok, updated} -> updated
          {:error, changeset} -> Repo.rollback(changeset)
        end
    end
  end

  defp purge_removed_source_context(context_pack, removed_source_id) do
    %{
      key_findings: purge_context_entries(context_pack.key_findings, removed_source_id),
      market_context: purge_context_entries(context_pack.market_context, removed_source_id),
      behavioral_context:
        purge_context_entries(context_pack.behavioral_context, removed_source_id),
      recent_context: purge_context_entries(context_pack.recent_context, removed_source_id),
      regulatory_context:
        purge_context_entries(context_pack.regulatory_context, removed_source_id)
    }
  end

  defp purge_context_entries(entries, removed_source_id) do
    Enum.reject(entries || [], fn entry ->
      source_id = Map.get(entry, "source_id") || Map.get(entry, :source_id)
      to_string(source_id || "") == to_string(removed_source_id)
    end)
  end

  # Evidence references are part of executable behavior. When a researcher
  # removes a local source, linked personas and rules are revised into explicit
  # assumptions rather than quietly retaining deleted grounding.
  defp invalidate_behavior_grounding!(_study, []), do: :ok

  defp invalidate_behavior_grounding!(study, removed_evidence_ids) do
    removed_ids = MapSet.new(Enum.map(removed_evidence_ids, &to_string/1))

    remaining_evidence =
      EvidenceItem
      |> where([item], item.study_id == ^study.id and item.id not in ^removed_evidence_ids)
      |> Repo.all()

    Persona
    |> where([persona], persona.study_id == ^study.id and persona.status == "active")
    |> Repo.all()
    |> Enum.each(fn persona ->
      refs = Enum.reject(persona.evidence_refs || [], &(to_string(&1) in removed_ids))

      if refs != persona.evidence_refs do
        evidence = evidence_for_ids(remaining_evidence, refs)

        persona
        |> Persona.changeset(%{
          evidence_refs: refs,
          grounding_mix: grounding_mix(evidence),
          version: persona.version + 1
        })
        |> update_or_rollback!()
      end
    end)

    ActionPattern
    |> where([pattern], pattern.study_id == ^study.id and pattern.status == "active")
    |> Repo.all()
    |> Enum.each(fn pattern ->
      refs = Enum.reject(pattern.evidence_refs || [], &(to_string(&1) in removed_ids))

      if refs != pattern.evidence_refs do
        evidence = evidence_for_ids(remaining_evidence, refs)

        pattern
        |> ActionPattern.changeset(%{
          evidence_refs: refs,
          grounding_level: dominant_grounding(evidence),
          version: pattern.version + 1,
          executable_rule: Map.put(pattern.executable_rule || %{}, "grounding_invalidated", true)
        })
        |> update_or_rollback!()
      end
    end)

    :ok
  end

  defp evidence_for_ids(evidence, refs) do
    refs = MapSet.new(Enum.map(refs, &to_string/1))
    Enum.filter(evidence, &(to_string(&1.id) in refs))
  end

  defp fetch_attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, to_string(key))
  end

  defp stringify_keys(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

  defp note_hash(note), do: :crypto.hash(:sha256, note) |> Base.encode16(case: :lower)

  defp normalize_note(note) do
    note
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp document_claim(text) do
    text
    |> String.split(~r/[\r\n]+/u, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.find(&(&1 != ""))
    |> case do
      nil -> String.slice(text, 0, 600)
      claim -> String.slice(claim, 0, 600)
    end
  end

  defp add_source!(study, attrs) do
    case add_source(study, attrs) do
      {:ok, source} -> source
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp add_evidence!(study, attrs) do
    case add_evidence(study, attrs) do
      {:ok, evidence} -> evidence
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp create_context_pack!(study, attrs) do
    case create_context_pack(study, attrs) do
      {:ok, context_pack} -> context_pack
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp update_study!(study, attrs) do
    case update_study(study, attrs) do
      {:ok, updated_study} -> updated_study
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp add_persona!(attrs) do
    %Persona{} |> Persona.changeset(attrs) |> insert_or_rollback!()
  end

  defp study_persona(study, persona_id) do
    Persona
    |> where([persona], persona.study_id == ^study.id and persona.id == ^persona_id)
    |> Repo.one()
  end

  defp study_pattern(study, pattern_id) do
    ActionPattern
    |> where([pattern], pattern.study_id == ^study.id and pattern.id == ^pattern_id)
    |> Repo.one()
  end

  defp study_evidence(study, evidence_id) do
    EvidenceItem
    |> where([item], item.study_id == ^study.id and item.id == ^evidence_id)
    |> Repo.one()
  end

  defp maybe_put_reviewer(metadata, nil), do: metadata

  defp maybe_put_reviewer(metadata, reviewer_id),
    do: Map.put(metadata, "reviewer_user_id", reviewer_id)

  defp removable_source(study, source_id) do
    Source
    |> where(
      [source],
      source.study_id == ^study.id and source.id == ^source_id and source.status != "deleted"
    )
    |> Repo.one()
  end

  defp evidence_for_refs(study, refs) do
    evidence_refs =
      refs
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    evidence =
      study
      |> list_evidence()
      |> Enum.filter(&(to_string(&1.id) in evidence_refs))

    if length(evidence) == length(evidence_refs) do
      {:ok, evidence, evidence_refs}
    else
      {:error, :evidence_not_in_study}
    end
  end

  defp grounding_mix([]), do: %{"assumption" => 1.0}

  defp grounding_mix(evidence) do
    total = length(evidence)

    evidence
    |> Enum.frequencies_by(& &1.grounding_level)
    |> Map.new(fn {level, count} -> {level, Float.round(count / total, 2)} end)
  end

  defp dominant_grounding([]), do: "assumption"

  defp dominant_grounding(evidence) do
    evidence
    |> Enum.map(& &1.grounding_level)
    |> Enum.max_by(&grounding_priority/1)
  end

  defp grounding_priority("direct_user_data"), do: 5
  defp grounding_priority("external_research"), do: 4
  defp grounding_priority("analogue_evidence"), do: 3
  defp grounding_priority("domain_prior"), do: 2
  defp grounding_priority("assumption"), do: 1
  defp grounding_priority("contradicted"), do: 0
  defp grounding_priority(_level), do: 0

  defp allocated_persona_weight(study) do
    Persona
    |> where([persona], persona.study_id == ^study.id and persona.status == "active")
    |> select([persona], sum(persona.distribution_weight))
    |> Repo.one()
  end

  defp insert_or_rollback!(changeset) do
    case Repo.insert(changeset) do
      {:ok, record} -> record
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp update_or_rollback!(changeset) do
    case Repo.update(changeset) do
      {:ok, record} -> record
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end
end
