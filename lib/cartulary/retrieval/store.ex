# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Retrieval.Store do
  @moduledoc """
  PostgreSQL-native retrieval data layer.

  This is the reviewed F7 custom-query boundary for PG-FTS, pgvector ANN, and
  hop-one expansion. Every statement applies Account, authorized scope, and
  lifecycle filters before content leaves PostgreSQL. It performs no writes.
  """

  alias Cartulary.Repo

  @knowledge_columns """
  k.id, k.scope_id, s.path AS scope_path, k.statement, k.kind, k.confidence,
  k.sensitivity, k.state, k.source_message_ids, k.extracting_model,
  k.extracting_provider, k.pipeline_version, k.corroboration_count
  """

  def lexical(query, limit) do
    knowledge =
      if query.target in [:knowledge, :all] do
        sql = """
        SELECT #{@knowledge_columns},
               ts_rank_cd(k.search_vector, websearch_to_tsquery('english', $4)) AS score,
               'knowledge' AS candidate_type
        FROM knowledge_items AS k
        JOIN scopes AS s ON s.id = k.scope_id AND s.account_id = k.account_id
        WHERE k.account_id = $1
          AND k.scope_id = ANY($2)
          AND (
            k.state = 'active'
            OR (k.state = 'provisional' AND ($3::uuid IS NULL OR k.subject_peer_id = $3))
          )
          AND k.deleted_at IS NULL
          AND k.search_vector @@ websearch_to_tsquery('english', $4)
        ORDER BY score DESC, k.confidence DESC, k.inserted_at DESC
        LIMIT $5
        """

        all(sql, [
          db_uuid!(query.account_id),
          db_uuids!(query.scope_ids),
          db_uuid(query.actor.peer_id),
          query.text,
          limit
        ])
      else
        []
      end

    documents =
      if query.target in [:documents, :all] do
        sql = """
        SELECT c.id, c.scope_id, s.path AS scope_path, c.text AS statement,
               'document_chunk' AS kind, 1.0::float8 AS confidence,
               'internal' AS sensitivity, c.status AS state,
               ARRAY[]::uuid[] AS source_message_ids,
               NULL::text AS extracting_model, 'f7-1' AS pipeline_version,
               ts_rank_cd(c.search_vector, websearch_to_tsquery('english', $3)) AS score,
               'document_chunk' AS candidate_type,
               c.document_id, c.document_version_id, c.position
        FROM document_chunks AS c
        JOIN scopes AS s ON s.id = c.scope_id AND s.account_id = c.account_id
        WHERE c.account_id = $1
          AND c.scope_id = ANY($2)
          AND c.status = 'active'
          AND c.search_vector @@ websearch_to_tsquery('english', $3)
        ORDER BY score DESC, c.position ASC
        LIMIT $4
        """

        all(sql, [
          db_uuid!(query.account_id),
          db_uuids!(query.scope_ids),
          query.text,
          limit
        ])
      else
        []
      end

    top(knowledge ++ documents, limit)
  end

  def semantic(query, embedding, identity, limit) do
    vector = vector_literal(embedding)

    knowledge =
      if query.target in [:knowledge, :all] do
        sql =
          if identity.dimensions == 384 do
            """
            SELECT #{@knowledge_columns},
                   1.0 - (k.embedding::vector(384) <=> $4::text::vector(384)) AS score,
                   'knowledge' AS candidate_type
            FROM knowledge_items AS k
            JOIN scopes AS s ON s.id = k.scope_id AND s.account_id = k.account_id
            WHERE k.account_id = $1
              AND k.scope_id = ANY($2)
              AND (
                k.state = 'active'
                OR (k.state = 'provisional' AND ($3::uuid IS NULL OR k.subject_peer_id = $3))
              )
              AND k.deleted_at IS NULL
              AND k.embedding IS NOT NULL
              AND k.embedding_provider = $5
              AND k.embedding_model = $6
              AND k.embedding_version = $7
              AND k.embedding_dimensions = $8
            ORDER BY k.embedding::vector(384) <=> $4::text::vector(384)
            LIMIT $9
            """
          else
            """
            SELECT #{@knowledge_columns},
                   1.0 - (k.embedding <=> $4::text::vector) AS score,
                   'knowledge' AS candidate_type
            FROM knowledge_items AS k
            JOIN scopes AS s ON s.id = k.scope_id AND s.account_id = k.account_id
            WHERE k.account_id = $1
              AND k.scope_id = ANY($2)
              AND (
                k.state = 'active'
                OR (k.state = 'provisional' AND ($3::uuid IS NULL OR k.subject_peer_id = $3))
              )
              AND k.deleted_at IS NULL
              AND k.embedding IS NOT NULL
              AND k.embedding_provider = $5
              AND k.embedding_model = $6
              AND k.embedding_version = $7
              AND k.embedding_dimensions = $8
            ORDER BY k.embedding <=> $4::text::vector
            LIMIT $9
            """
          end

        all(sql, [
          db_uuid!(query.account_id),
          db_uuids!(query.scope_ids),
          db_uuid(query.actor.peer_id),
          vector,
          identity.provider,
          identity.model,
          identity.version,
          identity.dimensions,
          limit
        ])
      else
        []
      end

    documents =
      if query.target in [:documents, :all] do
        sql =
          if identity.dimensions == 384 do
            """
            SELECT c.id, c.scope_id, s.path AS scope_path, c.text AS statement,
                   'document_chunk' AS kind, 1.0::float8 AS confidence,
                   'internal' AS sensitivity, c.status AS state,
                   ARRAY[]::uuid[] AS source_message_ids,
                   NULL::text AS extracting_model, 'f7-1' AS pipeline_version,
                   1.0 - (c.embedding::vector(384) <=> $3::text::vector(384)) AS score,
                   'document_chunk' AS candidate_type,
                   c.document_id, c.document_version_id, c.position
            FROM document_chunks AS c
            JOIN scopes AS s ON s.id = c.scope_id AND s.account_id = c.account_id
            WHERE c.account_id = $1
              AND c.scope_id = ANY($2)
              AND c.status = 'active'
              AND c.embedding_provider = $4
              AND c.embedding_model = $5
              AND c.embedding_version = $6
              AND c.embedding_dimensions = $7
            ORDER BY c.embedding::vector(384) <=> $3::text::vector(384)
            LIMIT $8
            """
          else
            """
            SELECT c.id, c.scope_id, s.path AS scope_path, c.text AS statement,
                   'document_chunk' AS kind, 1.0::float8 AS confidence,
                   'internal' AS sensitivity, c.status AS state,
                   ARRAY[]::uuid[] AS source_message_ids,
                   NULL::text AS extracting_model, 'f7-1' AS pipeline_version,
                   1.0 - (c.embedding <=> $3::text::vector) AS score,
                   'document_chunk' AS candidate_type,
                   c.document_id, c.document_version_id, c.position
            FROM document_chunks AS c
            JOIN scopes AS s ON s.id = c.scope_id AND s.account_id = c.account_id
            WHERE c.account_id = $1
              AND c.scope_id = ANY($2)
              AND c.status = 'active'
              AND c.embedding_provider = $4
              AND c.embedding_model = $5
              AND c.embedding_version = $6
              AND c.embedding_dimensions = $7
            ORDER BY c.embedding <=> $3::text::vector
            LIMIT $8
            """
          end

        all(sql, [
          db_uuid!(query.account_id),
          db_uuids!(query.scope_ids),
          vector,
          identity.provider,
          identity.model,
          identity.version,
          identity.dimensions,
          limit
        ])
      else
        []
      end

    top(knowledge ++ documents, limit)
  end

  def temporal(query, limit) do
    as_of = query.as_of || Cartulary.Clock.utc_now()

    sql = """
    SELECT #{@knowledge_columns},
           (
             CASE
               WHEN k.relevant_from IS NULL AND k.relevant_until IS NULL THEN 0.5
               WHEN (k.relevant_from IS NULL OR k.relevant_from <= $4)
                AND (k.relevant_until IS NULL OR k.relevant_until >= $4) THEN 1.0
               ELSE 0.1
             END
           )::float8 AS score,
           'knowledge' AS candidate_type
    FROM knowledge_items AS k
    JOIN scopes AS s ON s.id = k.scope_id AND s.account_id = k.account_id
    WHERE k.account_id = $1
      AND k.scope_id = ANY($2)
      AND (
        k.state = 'active'
        OR (k.state = 'provisional' AND ($3::uuid IS NULL OR k.subject_peer_id = $3))
      )
      AND k.deleted_at IS NULL
      AND k.inserted_at <= $4
      AND (k.expires_at IS NULL OR k.expires_at > $4)
    ORDER BY score DESC, k.inserted_at DESC
    LIMIT $5
    """

    if query.target in [:knowledge, :all] do
      all(sql, [
        db_uuid!(query.account_id),
        db_uuids!(query.scope_ids),
        db_uuid(query.actor.peer_id),
        as_of,
        limit
      ])
    else
      []
    end
  end

  def salience_recency(query, limit) do
    sql = """
    SELECT #{@knowledge_columns},
           (
             k.confidence
             * (1.0 + ln(1 + k.corroboration_count))
             * exp(-extract(epoch FROM (now() - k.updated_at)) / 2592000.0)
           )::float8 AS score,
           'knowledge' AS candidate_type
    FROM knowledge_items AS k
    JOIN scopes AS s ON s.id = k.scope_id AND s.account_id = k.account_id
    WHERE k.account_id = $1
      AND k.scope_id = ANY($2)
      AND (
        k.state = 'active'
        OR (k.state = 'provisional' AND ($3::uuid IS NULL OR k.subject_peer_id = $3))
      )
      AND k.deleted_at IS NULL
      AND (k.expires_at IS NULL OR k.expires_at > now())
    ORDER BY score DESC, k.updated_at DESC
    LIMIT $4
    """

    if query.target in [:knowledge, :all] do
      all(sql, [
        db_uuid!(query.account_id),
        db_uuids!(query.scope_ids),
        db_uuid(query.actor.peer_id),
        limit
      ])
    else
      []
    end
  end

  def entity_match(query, limit) do
    terms =
      query.text
      |> String.downcase()
      |> String.split(~r/[^[:alnum:]@._-]+/u, trim: true)
      |> Enum.uniq()

    sql = """
    SELECT #{@knowledge_columns},
           max(m.confidence * k.confidence)::float8 AS score,
           'knowledge' AS candidate_type
    FROM entities AS e
    JOIN entity_mentions AS m
      ON m.entity_id = e.id AND m.account_id = e.account_id
    JOIN knowledge_items AS k
      ON k.id = m.knowledge_item_id AND k.account_id = m.account_id
    JOIN scopes AS s ON s.id = k.scope_id AND s.account_id = k.account_id
    WHERE e.account_id = $1
      AND k.scope_id = ANY($2)
      AND (
        k.state = 'active'
        OR (k.state = 'provisional' AND ($3::uuid IS NULL OR k.subject_peer_id = $3))
      )
      AND k.deleted_at IS NULL
      AND EXISTS (
        SELECT 1
        FROM unnest(e.aliases || ARRAY[e.canonical_name]) AS alias
        WHERE lower(alias) = ANY($4)
      )
    GROUP BY k.id, s.path
    ORDER BY score DESC, k.updated_at DESC
    LIMIT $5
    """

    if query.target in [:knowledge, :all] and terms != [] do
      all(sql, [
        db_uuid!(query.account_id),
        db_uuids!(query.scope_ids),
        db_uuid(query.actor.peer_id),
        terms,
        limit
      ])
    else
      []
    end
  end

  def relation_expand(query, limit) do
    sql = """
    WITH structural AS (
      SELECT
        CASE
          WHEN r.source_knowledge_id = ANY($4) THEN r.target_knowledge_id
          ELSE r.source_knowledge_id
        END AS knowledge_id,
        r.confidence AS edge_score
      FROM knowledge_relations AS r
      WHERE r.account_id = $1
        AND (r.source_knowledge_id = ANY($4) OR r.target_knowledge_id = ANY($4))
    ),
    shared_entity AS (
      SELECT DISTINCT other.knowledge_item_id AS knowledge_id,
             least(seed.confidence, other.confidence) AS edge_score
      FROM entity_mentions AS seed
      JOIN entity_mentions AS other
        ON other.account_id = seed.account_id
       AND other.entity_id = seed.entity_id
       AND other.knowledge_item_id <> seed.knowledge_item_id
      WHERE seed.account_id = $1
        AND seed.knowledge_item_id = ANY($4)
    ),
    scope_expanded AS (
      SELECT related.id AS knowledge_id, 1.0::float8 AS edge_score
      FROM knowledge_items AS seed
      JOIN scope_relations AS relation
        ON relation.account_id = seed.account_id
       AND (
         relation.source_scope_id = seed.scope_id
         OR relation.target_scope_id = seed.scope_id
       )
      JOIN knowledge_items AS related
        ON related.account_id = seed.account_id
       AND related.scope_id = CASE
         WHEN relation.source_scope_id = seed.scope_id THEN relation.target_scope_id
         ELSE relation.source_scope_id
       END
      WHERE seed.account_id = $1
        AND seed.id = ANY($4)
        AND relation.source_scope_id = ANY($2)
        AND relation.target_scope_id = ANY($2)
    ),
    expanded AS (
      SELECT * FROM structural
      UNION ALL
      SELECT * FROM shared_entity
      UNION ALL
      SELECT * FROM scope_expanded
    )
    SELECT #{@knowledge_columns},
           max(expanded.edge_score * k.confidence)::float8 AS score,
           'knowledge' AS candidate_type
    FROM expanded
    JOIN knowledge_items AS k ON k.id = expanded.knowledge_id AND k.account_id = $1
    JOIN scopes AS s ON s.id = k.scope_id AND s.account_id = k.account_id
    WHERE k.scope_id = ANY($2)
      AND (
        k.state = 'active'
        OR (k.state = 'provisional' AND ($3::uuid IS NULL OR k.subject_peer_id = $3))
      )
      AND k.deleted_at IS NULL
    GROUP BY k.id, s.path
    ORDER BY score DESC, k.updated_at DESC
    LIMIT $5
    """

    if query.target in [:knowledge, :all] and query.seed_ids != [] do
      all(sql, [
        db_uuid!(query.account_id),
        db_uuids!(query.scope_ids),
        db_uuid(query.actor.peer_id),
        db_uuids!(query.seed_ids),
        limit
      ])
    else
      []
    end
  end

  defp top(rows, limit),
    do: rows |> Enum.sort_by(&(&1["score"] || 0.0), :desc) |> Enum.take(limit)

  defp vector_literal(values) do
    "[" <> Enum.map_join(values, ",", &Float.to_string(&1 * 1.0)) <> "]"
  end

  # SQL is static and parameterized; only the two database-native retrieval
  # operators and hop-one expansion live in this data-layer boundary.
  # sobelow_skip ["SQL.Query"]
  defp all(sql, params) do
    %{columns: columns, rows: rows} = Ecto.Adapters.SQL.query!(Repo, sql, params)

    Enum.map(rows, fn row ->
      columns
      |> Enum.zip(row)
      |> Map.new(fn {column, value} -> {column, normalize_db_value(column, value)} end)
    end)
  end

  defp normalize_db_value(column, value)
       when column == "id" or
              (byte_size(column) >= 3 and
                 binary_part(column, byte_size(column) - 3, 3) == "_id") do
    normalize_uuid(value)
  end

  defp normalize_db_value("source_message_ids", values) when is_list(values),
    do: Enum.map(values, &normalize_uuid/1)

  defp normalize_db_value(_column, value), do: value

  defp normalize_uuid(<<_::128>> = value), do: Ecto.UUID.load!(value)
  defp normalize_uuid(value), do: value

  defp db_uuids!(values), do: Enum.map(values, &db_uuid!/1)
  defp db_uuid(nil), do: nil
  defp db_uuid(value), do: db_uuid!(value)
  defp db_uuid!(<<_::128>> = value), do: value
  defp db_uuid!(value), do: Ecto.UUID.dump!(value)
end
