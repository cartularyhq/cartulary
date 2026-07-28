# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Retrieval.EntityResolver do
  @moduledoc """
  Builds the internal name index: which real-world things are mentioned in
  which approved statements, and which surface forms refer to the same thing.

  It exists so that once "Ada" and "ada@example.com" have been folded onto one
  entity, a question naming either spelling can reach statements written with
  the other.

  ## These rows are a cache, not a record

  Every entity and mention it writes is reconstructible from the approved
  statements alone, and the rebuild below throws them away and recreates them.
  Two consequences follow, and both are load-bearing:

  * **Nothing may be exposed.** No entity id, canonical name, alias, or surface
    form may reach a caller through any surface. The index is a graph of who
    and what appears where, assembled across scopes; publishing it would leak
    relationships nobody was granted. Retrieval uses it only to find statements
    and returns ordinary statement records.
  * **Nothing may depend on it.** A missing or stale entity costs recall and
    never correctness. Resolution never blocks a statement from being stored,
    approved, or retrieved.

  Only approved statements are read, so a proposal awaiting review contributes
  no mentions. When a statement is erased, rebuilding this index is what makes
  the erased names disappear from it.

  ## How a surface form is resolved

  Three tiers, cheapest first, and the expensive one runs only in the narrow
  band where the cheap ones are genuinely unsure:

  1. Case-insensitive match against an existing canonical name or alias.
  2. Cosine similarity between the surface form's embedding and the entity's
     alias embedding.
  3. For a middling similarity only, one structured yes/no question to the
     reasoning model.

  A surface form that resembles nothing becomes a new entity. One that
  resembles an existing entity but is judged not to be it records no mention at
  all, rather than inventing a near-duplicate. An embedding failure likewise
  skips the surface form; neither case interrupts the run.

  ## Cost

  It embeds each unmatched surface form and re-embeds an entity's whole alias
  set every time a surface form is folded into it, so cost scales with
  statements times distinct names. Nothing on the retrieval path calls it: it
  runs from the entity-resolution and projection-refresh jobs, and
  synchronously inside an erasure, which rebuilds the scopes it stripped.
  """

  alias Cartulary.DataLayer
  alias Cartulary.Knowledge.{Entity, EntityMention, KnowledgeItem}
  alias Cartulary.Model.{Embedding, Gateway}
  alias Cartulary.Retrieval.Vector

  require Ash.Query

  # Cosine similarity bands between a surface form and an entity's alias
  # embedding. At or above the match threshold the two are taken to be the same
  # entity outright. Between the two thresholds the evidence is genuinely
  # ambiguous and a model is asked to decide. Below the reject threshold no
  # model is consulted at all and a new entity is created, because a wrong
  # merge is far more damaging than a duplicate: merging two people's
  # statements crosses a boundary, whereas a duplicate entity only costs
  # recall and is repaired by the next rebuild.
  @match_threshold 0.86
  @reject_threshold 0.72

  # Candidate name spotting, deliberately crude. The first pattern takes runs
  # of one to four capitalised words, which catches most personal, company, and
  # product names in English prose; the second takes email addresses, which are
  # the strongest identity signal available and would otherwise be split apart.
  # False positives are acceptable here — a spurious entity costs a little
  # storage and no correctness — so this is not worth replacing with a model.
  @mention_regex ~r/\b(?:[A-Z][[:alnum:]@._-]*)(?:\s+[A-Z][[:alnum:]@._-]*){0,3}\b/u
  @email_regex ~r/\b[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}\b/u

  @doc """
  Rebuilds the entity index for one scope from scratch.

  Deletes every existing mention in the scope, re-derives mentions from the
  scope's approved statements, and then removes any entity in the Account left
  with no mentions at all. Rebuilding rather than patching is what makes it
  replay-safe: running it twice gives the same result, and it is the correct
  response to an erasure, an import, or a suspected stale index.

  The whole rebuild runs in one Account-scoped transaction as a system actor,
  so a failure leaves the previous index in place rather than a half-cleared
  one.

  Note the asymmetry: mentions are cleared per scope, but orphan entities are
  pruned Account-wide, because an entity is shared across scopes and only the
  full mention set can show it has become unreferenced.

  Returns `{:ok, %{statements: n, mentions: n}}`. Raises if a read or write
  fails; individual embedding or model failures do not raise, they just leave
  that surface form unresolved.
  """
  def rebuild_scope(account_id, scope_id) do
    DataLayer.with_account_id(
      account_id,
      [role: :system, pipeline?: true],
      fn _account, actor ->
        # Clear first, then re-derive. Any other order would leave duplicate
        # mentions for statements that are resolved again.
        clear_mentions!(account_id, scope_id, actor)

        # Only approved, undeleted statements feed the index. Proposals under
        # review and erased statements must leave no trace of their names here.
        statements =
          KnowledgeItem
          |> Ash.Query.filter(scope_id == ^scope_id and state == "active" and is_nil(deleted_at))
          |> Ash.Query.set_tenant(account_id)
          |> Ash.read!(actor: actor)

        resolved =
          Enum.reduce(statements, 0, fn knowledge, count ->
            count + resolve_statement!(knowledge, actor)
          end)

        # Runs last, once the scope's mentions have been rewritten, so an
        # entity that only this scope referenced is now visibly unreferenced.
        prune_entities!(account_id, actor)
        {:ok, %{statements: length(statements), mentions: resolved}}
      end
    )
  end

  # Extracts candidate names from one statement and records a mention for each
  # that resolves. Returns how many mentions were written.
  defp resolve_statement!(knowledge, actor) do
    # Single characters are rejected as noise (initials, stray capitals), and
    # case-insensitive de-duplication stops "Ada" and "ADA" in one sentence
    # from producing two mentions of the same entity.
    surfaces =
      (Regex.scan(@mention_regex, knowledge.statement) ++
         Regex.scan(@email_regex, knowledge.statement))
      |> Enum.map(&hd/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(String.length(&1) < 2))
      |> Enum.uniq_by(&String.downcase/1)

    Enum.reduce(surfaces, 0, fn surface, count ->
      case resolve_entity!(knowledge, surface, actor) do
        # Unresolved on purpose: the similarity was ambiguous and the model
        # said no, or embedding failed. Recording no mention is the safe
        # outcome — it costs recall, where a wrong mention would cross names.
        nil ->
          count

        entity ->
          # The mention carries the statement's own scope, which is how a
          # mention inherits visibility: retrieval filters mentions through the
          # statement they belong to, never through the shared entity. The
          # confidence is 1.0 because the uncertainty lives in the entity
          # resolution above, which either committed to a match or returned
          # nothing; the mention itself is not in doubt once it is written.
          create!(
            EntityMention,
            :create_from_pipeline,
            %{
              knowledge_item_id: knowledge.id,
              scope_id: knowledge.scope_id,
              entity_id: entity.id,
              surface_form: surface,
              confidence: 1.0
            },
            knowledge.account_id,
            actor
          )

          count + 1
      end
    end)
  end

  # Tier one: an exact, case-folded hit on a canonical name or alias. Reloading
  # the Account's entities for every surface form is deliberate — an entity
  # created moments ago by this same run must be visible to the next surface
  # form, or one rebuild would keep re-deciding the same name from scratch.
  defp resolve_entity!(knowledge, surface, actor) do
    entities = entities!(knowledge.account_id, actor)
    folded = String.downcase(surface)

    exact =
      Enum.find(entities, fn entity ->
        Enum.any?([entity.canonical_name | entity.aliases], &(String.downcase(&1) == folded))
      end)

    if exact,
      do: update_entity!(exact, knowledge.id, surface, actor),
      else: resolve_by_embedding!(entities, knowledge, surface, actor)
  end

  # Tiers two and three, reached only when no alias matched exactly. Compares
  # the surface form's embedding against every entity's alias embedding and
  # keeps the single best candidate. The cosine helper returns 0.0 for a
  # missing or differently sized vector, so an entity with no usable embedding
  # simply loses rather than crashing the comparison.
  defp resolve_by_embedding!(entities, knowledge, surface, actor) do
    context = %{
      account_id: knowledge.account_id,
      scope_id: knowledge.scope_id,
      actor: actor
    }

    case Embedding.embed([surface], context) do
      {:ok, result} ->
        [surface_embedding] = result.vectors

        # The empty-list fallback keeps the very first surface form of an
        # Account working, when there is nothing to compare against yet.
        {candidate, score} =
          entities
          |> Enum.map(&{&1, Vector.cosine(surface_embedding, &1.alias_embedding)})
          |> Enum.max_by(&elem(&1, 1), fn -> {nil, 0.0} end)

        # Clause order encodes the three similarity bands. Note the third
        # clause: a middling score whose adjudication said "not the same" ends
        # the attempt with no mention, rather than falling through to create a
        # new entity. That is deliberate — the model just said the surface form
        # resembles an existing entity without being it, which is exactly the
        # situation where inventing a near-duplicate entity would be wrong.
        cond do
          candidate && score >= @match_threshold ->
            update_entity!(candidate, knowledge.id, surface, actor)

          candidate && score >= @reject_threshold &&
              adjudicate?(surface, candidate.canonical_name, context) ->
            update_entity!(candidate, knowledge.id, surface, actor)

          candidate && score >= @reject_threshold ->
            nil

          true ->
            create_entity!(knowledge, surface, surface_embedding, result, actor)
        end

      # No embedder, no resolution. The statement is still stored, approved,
      # and retrievable by every other strategy; only this recall aid is lost.
      {:error, _error} ->
        nil
    end
  end

  # Tier three: one bounded structured question to the reasoning model, used
  # only inside the ambiguous similarity band. The schema asks for a single
  # boolean and forbids extra properties. Only an explicit `true` is read as a
  # match; a failure, a malformed answer, or `false` all mean "not the same",
  # so the model can confirm a merge but never provoke one by breaking.
  defp adjudicate?(surface, canonical_name, context) do
    schema = %{
      "type" => "object",
      "required" => ["same_entity"],
      "properties" => %{"same_entity" => %{"type" => "boolean"}},
      "additionalProperties" => false
    }

    messages = [
      %{
        role: "user",
        content:
          "Do these two surface forms identify the same real-world entity? " <>
            "Return only the structured decision. left=#{surface}; right=#{canonical_name}"
      }
    ]

    case Gateway.structured_once(:dream_reasoner, messages, schema, context,
           task: :entity_resolution
         ) do
      {:ok, %{"same_entity" => true}, _config} -> true
      _other -> false
    end
  end

  # Creates a new entity from an unmatched surface form. The first spelling
  # seen becomes the canonical name, which is arbitrary but harmless: the name
  # is never shown to anyone, and later spellings accumulate as aliases. The
  # create action upserts on canonical name and kind, so two passes racing on
  # the same new name converge on one row instead of near-duplicates. The
  # embedding identity is stored alongside the vector so a later comparison can
  # tell whether two vectors came from the same embedder. `derived_from` records
  # which statements produced this entity, which is what lets the prune step
  # and erasure reason about it without re-scanning text.
  defp create_entity!(knowledge, surface, embedding, result, actor) do
    create!(
      Entity,
      :create_from_pipeline,
      %{
        canonical_name: surface,
        kind: infer_kind(surface),
        aliases: [surface],
        alias_embedding: embedding,
        embedding_provider: result.provider,
        embedding_model: result.model,
        embedding_version: result.version,
        embedding_dimensions: result.dimensions,
        derived_from: [knowledge.id]
      },
      knowledge.account_id,
      actor
    )
  end

  # Folds a newly matched surface form into an existing entity: appends the
  # alias, records the statement it came from, and re-embeds. Both lists are
  # append-and-deduplicate, never replace, so repeated rebuilds converge
  # instead of oscillating.
  defp update_entity!(entity, knowledge_id, surface, actor) do
    aliases = Enum.uniq(entity.aliases ++ [surface])
    derived_from = Enum.uniq(entity.derived_from ++ [knowledge_id])
    context = %{account_id: entity.account_id, actor: actor}

    attrs = %{aliases: aliases, derived_from: derived_from}

    # The alias embedding covers the canonical name and every alias joined
    # together, so an entity known by several names sits between them in vector
    # space and each of those names matches it. It is recomputed on every fold,
    # including one that adds no new alias.
    #
    # A failed embedding leaves the previous vector in place: the alias list
    # still grew, so exact matching improves and only the fuzzy tier lags until
    # the next rebuild.
    attrs =
      case Embedding.embed([Enum.join([entity.canonical_name | aliases], " ")], context) do
        {:ok, result} ->
          Map.merge(attrs, %{
            alias_embedding: hd(result.vectors),
            embedding_provider: result.provider,
            embedding_model: result.model,
            embedding_version: result.version,
            embedding_dimensions: result.dimensions
          })

        {:error, _error} ->
          attrs
      end

    # Authorization is skipped because this runs as the system pipeline actor
    # inside an already Account-scoped transaction. The tenant is still set
    # explicitly, so the write cannot escape the Account.
    entity
    |> Ash.Changeset.for_update(:recompute_from_pipeline, attrs)
    |> Ash.Changeset.set_tenant(entity.account_id)
    |> Ash.update!(actor: actor, authorize?: false)
  end

  # Loads every entity in the Account, not just the current scope's: an entity
  # is Account-wide by design, so the same person mentioned in two scopes
  # resolves to one entity. `alias_embedding` has to be named explicitly here
  # because it is excluded from default selects for its size, and the fuzzy
  # tier cannot compare without it.
  defp entities!(account_id, actor) do
    Entity
    |> Ash.Query.select([
      :id,
      :account_id,
      :canonical_name,
      :kind,
      :aliases,
      :alias_embedding,
      :derived_from
    ])
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
  end

  # Deletes this scope's mentions so the rebuild starts from nothing. Hard
  # deletes are correct here: mentions are a cache, they carry no history worth
  # keeping, and a soft-deleted mention would keep an erased name in the index.
  defp clear_mentions!(account_id, scope_id, actor) do
    EntityMention
    |> Ash.Query.filter(scope_id == ^scope_id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.each(fn mention ->
      mention
      |> Ash.Changeset.for_destroy(:erase)
      |> Ash.Changeset.set_tenant(account_id)
      |> Ash.destroy!(actor: actor, authorize?: false)
    end)
  end

  # Removes entities no mention points at any more. This is how a name
  # disappears after the statements that introduced it are erased: the mentions
  # go with the statements, and the now-unreferenced entity goes here. The
  # mention set must be read Account-wide, because an entity referenced from
  # another scope is still in use.
  defp prune_entities!(account_id, actor) do
    mention_entity_ids =
      EntityMention
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read!(actor: actor)
      |> MapSet.new(& &1.entity_id)

    Entity
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.reject(&MapSet.member?(mention_entity_ids, &1.id))
    |> Enum.each(fn entity ->
      entity
      |> Ash.Changeset.for_destroy(:erase)
      |> Ash.Changeset.set_tenant(account_id)
      |> Ash.destroy!(actor: actor, authorize?: false)
    end)
  end

  # A cheap English-centric guess at what kind of thing a name refers to,
  # kept as metadata only. Nothing in retrieval branches on the answer, so a
  # wrong guess is harmless and it is not worth a model call. `concept` is the
  # catch-all, and the ordering matters: an address containing a company suffix
  # is still classed by its `@` as a person.
  defp infer_kind(surface) do
    cond do
      String.contains?(surface, "@") -> "person"
      String.match?(surface, ~r/\b(?:Inc|LLC|Ltd|Corp|Org)\b/) -> "org"
      String.match?(surface, ~r/\b(?:API|DB|OS|Server|System)\b/) -> "system"
      true -> "concept"
    end
  end

  # Shared create helper. The tenant is set before the changeset is built for
  # the action, so tenant-aware validations see it. Authorization is skipped
  # for the same reason as the updates above: a system pipeline actor inside an
  # Account-scoped transaction.
  defp create!(resource, action, attrs, account_id, actor) do
    resource
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.Changeset.for_create(action, attrs)
    |> Ash.create!(actor: actor, authorize?: false)
  end
end
