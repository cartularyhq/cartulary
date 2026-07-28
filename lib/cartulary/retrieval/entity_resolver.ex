# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Retrieval.EntityResolver do
  @moduledoc """
  Dream-time exact-alias, embedding, and reasoner-adjudicated entity resolution.

  Only governed statements are inputs. Entity and mention records remain
  pipeline-internal derived caches and are never returned by retrieval.
  """

  alias Cartulary.DataLayer
  alias Cartulary.Knowledge.{Entity, EntityMention, KnowledgeItem}
  alias Cartulary.Model.{Embedding, Gateway}
  alias Cartulary.Retrieval.Vector

  require Ash.Query

  @match_threshold 0.86
  @reject_threshold 0.72
  @mention_regex ~r/\b(?:[A-Z][[:alnum:]@._-]*)(?:\s+[A-Z][[:alnum:]@._-]*){0,3}\b/u
  @email_regex ~r/\b[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}\b/u

  def rebuild_scope(account_id, scope_id) do
    DataLayer.with_account_id(
      account_id,
      [role: :system, pipeline?: true],
      fn _account, actor ->
        clear_mentions!(account_id, scope_id, actor)

        statements =
          KnowledgeItem
          |> Ash.Query.filter(scope_id == ^scope_id and state == "active" and is_nil(deleted_at))
          |> Ash.Query.set_tenant(account_id)
          |> Ash.read!(actor: actor)

        resolved =
          Enum.reduce(statements, 0, fn knowledge, count ->
            count + resolve_statement!(knowledge, actor)
          end)

        prune_entities!(account_id, actor)
        {:ok, %{statements: length(statements), mentions: resolved}}
      end
    )
  end

  defp resolve_statement!(knowledge, actor) do
    surfaces =
      (Regex.scan(@mention_regex, knowledge.statement) ++
         Regex.scan(@email_regex, knowledge.statement))
      |> Enum.map(&hd/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(String.length(&1) < 2))
      |> Enum.uniq_by(&String.downcase/1)

    Enum.reduce(surfaces, 0, fn surface, count ->
      case resolve_entity!(knowledge, surface, actor) do
        nil ->
          count

        entity ->
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

  defp resolve_by_embedding!(entities, knowledge, surface, actor) do
    context = %{
      account_id: knowledge.account_id,
      scope_id: knowledge.scope_id,
      actor: actor
    }

    case Embedding.embed([surface], context) do
      {:ok, result} ->
        [surface_embedding] = result.vectors

        {candidate, score} =
          entities
          |> Enum.map(&{&1, Vector.cosine(surface_embedding, &1.alias_embedding)})
          |> Enum.max_by(&elem(&1, 1), fn -> {nil, 0.0} end)

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

      {:error, _error} ->
        nil
    end
  end

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

  defp update_entity!(entity, knowledge_id, surface, actor) do
    aliases = Enum.uniq(entity.aliases ++ [surface])
    derived_from = Enum.uniq(entity.derived_from ++ [knowledge_id])
    context = %{account_id: entity.account_id, actor: actor}

    attrs = %{aliases: aliases, derived_from: derived_from}

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

    entity
    |> Ash.Changeset.for_update(:recompute_from_pipeline, attrs)
    |> Ash.Changeset.set_tenant(entity.account_id)
    |> Ash.update!(actor: actor, authorize?: false)
  end

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

  defp infer_kind(surface) do
    cond do
      String.contains?(surface, "@") -> "person"
      String.match?(surface, ~r/\b(?:Inc|LLC|Ltd|Corp|Org)\b/) -> "org"
      String.match?(surface, ~r/\b(?:API|DB|OS|Server|System)\b/) -> "system"
      true -> "concept"
    end
  end

  defp create!(resource, action, attrs, account_id, actor) do
    resource
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.Changeset.for_create(action, attrs)
    |> Ash.create!(actor: actor, authorize?: false)
  end
end
