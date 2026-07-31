# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Retrieval.Store do
  @moduledoc """
  Implements read-only retrieval SQL that cannot be expressed through Ash.

  Every query must filter Account, authorized scopes, active lifecycle, soft deletion, and the
  provisional subject before candidates leave this boundary. Peer-facing callers must supply a
  peer id. Scope joins also match Account.

  Knowledge queries share one result shape; chunk queries synthesize compatible fields. Scores
  are strategy-local. SQL is static and all caller values are bound parameters. Durable writes
  remain resource-action-only.
  """

  alias Cartulary.Repo

  # Shared caller-facing knowledge shape; only scope path comes from the joined scope.
  @knowledge_columns """
  k.id, k.scope_id, s.path AS scope_path, k.statement, k.kind, k.confidence,
  k.sensitivity, k.state, k.source_message_ids, k.extracting_model,
  k.extracting_provider, k.pipeline_version, k.corroboration_count
  """

  # The websearch operators a caller can spell: a quoted phrase, a term-leading `-` for NOT, and
  # a standalone `or`. Spelling one means the caller asked for that exact parse, so the query
  # keeps `websearch_to_tsquery` rather than being widened to a disjunction.
  @websearch_operators ~r/"|(?:^|\s)-\S|(?:^|\s)or(?:\s|$)/i

  @doc """
  Full-text search over governed statements and document chunks.

  Searches requested targets and ranks with `ts_rank_cd`, then merges and truncates to `limit`.

  A query spelling a websearch operator keeps the documented `websearch` parse. Any other query
  matches the disjunction of its own terms, because `websearch_to_tsquery` joins bare terms with
  `AND` and a one-sentence statement rarely carries every content word of a question. `ts_rank_cd`
  still orders by how many query terms a row covers and how densely.

  Returns a list of column-keyed maps with a `score` and a `candidate_type`.
  Raises `Postgrex.Error` if the statement fails.
  """
  def lexical(query, limit) do
    knowledge =
      if query.target in [:knowledge, :all] do
        tsquery = tsquery(query.text, "$4")

        sql = """
        SELECT #{@knowledge_columns},
               ts_rank_cd(k.search_vector, #{tsquery}) AS score,
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
          AND k.search_vector @@ #{tsquery}
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

    # Chunks synthesize knowledge fields. `f7-1` is the caller-visible retrieval/context contract;
    # changing it requires a documented contract transition.
    documents =
      if query.target in [:documents, :all] do
        tsquery = tsquery(query.text, "$3")

        sql = """
        SELECT c.id, c.scope_id, s.path AS scope_path, c.text AS statement,
               'document_chunk' AS kind, 1.0::float8 AS confidence,
               'internal' AS sensitivity, c.status AS state,
               ARRAY[]::uuid[] AS source_message_ids,
               NULL::text AS extracting_model, 'f7-1' AS pipeline_version,
               ts_rank_cd(c.search_vector, #{tsquery}) AS score,
               'document_chunk' AS candidate_type,
               c.document_id, c.document_version_id, c.position
        FROM document_chunks AS c
        JOIN scopes AS s ON s.id = c.scope_id AND s.account_id = c.account_id
        WHERE c.account_id = $1
          AND c.scope_id = ANY($2)
          AND c.status = 'active'
          AND c.search_vector @@ #{tsquery}
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

  @doc """
  Approximate nearest-neighbour search over stored embeddings.

  Filters by provider, model, version, and dimensions; incompatible rows require re-embedding.

  The 384-dimensional variant matches its indexed cast; other dimensions scan correctly. Scores
  are `1 - cosine distance`.

  Returns column-keyed maps with `score` and `candidate_type`, merged across
  knowledge and document chunks and truncated to `limit`. Raises
  `Postgrex.Error` if the statement fails.
  """
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

  @doc """
  Ranks statements by whether they were true at a point in time.

  Uses `as_of` or now, excluding not-yet-recorded and expired rows. Scores are coarse: in-force,
  undated, or out-of-force.

  Knowledge only — document chunks carry no validity period. Returns
  column-keyed maps, or an empty list when the query targets documents. Raises
  `Postgrex.Error` if the statement fails.
  """
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

  @doc """
  Ranks statements by durable importance rather than by resemblance to the
  query text.

  Multiplies confidence, logarithmically dampened corroboration, and exponential recency. The
  decay divisor is 2,592,000 seconds (30 days), leaving about 37% after one month.

  It needs no query text and no model, which makes it the fallback that keeps a
  cheap request useful when embedding is unavailable. Expired statements are
  excluded.

  Knowledge only. Returns column-keyed maps, or an empty list when the query
  targets documents. Raises `Postgrex.Error` if the statement fails.
  """
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

  @doc """
  Finds statements that mention an entity named in the query text.

  The query is split into lowercase terms and matched case-insensitively
  against each entity's canonical name and aliases. Letters and digits plus
  `@`, `.`, `_`, and `-` are kept together so email addresses, hostnames, and
  hyphenated names survive as single terms.

  Entity rows locate statements but never appear in results. Account, scope, lifecycle, and
  provisional filters still apply before candidates leave the query.

  Scores are the strongest mention-confidence times statement-confidence
  product per statement, grouped so one statement appears once however many of
  its mentions matched.

  Knowledge only. Returns an empty list when the query targets documents or
  yields no usable terms. Raises `Postgrex.Error` if the statement fails.
  """
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

  @doc """
  Widens a result set by one hop from the seed statements the first retrieval
  phase found.

  Three kinds of edge are followed and unioned:

  * **structural** — explicit recorded relations between two statements, in
    either direction, scored by the edge's own confidence;
  * **shared entity** — two statements that mention the same entity, scored by
    the weaker of the two mention confidences;
  * **scope relation** — statements in a scope explicitly related to a seed's
    scope, scored 1.0.

  Expansion is exactly one hop. Scope links require both endpoints authorized. The outer query
  applies scope, lifecycle, soft-delete, and provisional-subject filters to every expanded id.

  Knowledge only. Returns an empty list when the query targets documents or has
  no seed ids. Raises `Postgrex.Error` if the statement fails.
  """
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

  # Builds the `tsquery` SQL for one bound parameter, given the caller's raw query text.
  #
  # Only the disjunctive branch reaches for the lexemes directly: `to_tsvector` normalizes them
  # the same way the stored `search_vector` was normalized, `tsquery` input is taken verbatim
  # rather than stemmed a second time, and `quote_literal` stops a lexeme holding `&`, `|`, or a
  # quote from being read as an operator. Text with no lexemes aggregates to NULL, which matches
  # nothing — the same outcome `websearch_to_tsquery` gives for stopwords alone.
  defp tsquery(text, parameter) do
    if Regex.match?(@websearch_operators, text) do
      "websearch_to_tsquery('english', #{parameter})"
    else
      "(SELECT string_agg(quote_literal(lexeme), ' | ') " <>
        "FROM unnest(to_tsvector('english', #{parameter})))::tsquery"
    end
  end

  # Merge only halves scored by the same function, then restore the shared cap.
  defp top(rows, limit),
    do: rows |> Enum.sort_by(&(&1["score"] || 0.0), :desc) |> Enum.take(limit)

  # Build pgvector text as a bound parameter; coerce integers before `Float.to_string/1`.
  defp vector_literal(values) do
    "[" <> Enum.map_join(values, ",", &Float.to_string(&1 * 1.0)) <> "]"
  end

  # SQL is static and parameterized inside this reviewed data-layer boundary.
  # sobelow_skip ["SQL.Query"]
  defp all(sql, params) do
    %{columns: columns, rows: rows} = Ecto.Adapters.SQL.query!(Repo, sql, params)

    Enum.map(rows, fn row ->
      columns
      |> Enum.zip(row)
      |> Map.new(fn {column, value} -> {column, normalize_db_value(column, value)} end)
    end)
  end

  # Restore raw 16-byte UUID columns to caller-facing strings.
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

  # Accept string or dumped UUIDs; nil is only for optional peer id, and malformed ids raise.
  defp db_uuids!(values), do: Enum.map(values, &db_uuid!/1)
  defp db_uuid(nil), do: nil
  defp db_uuid(value), do: db_uuid!(value)
  defp db_uuid!(<<_::128>> = value), do: value
  defp db_uuid!(value), do: Ecto.UUID.dump!(value)
end
