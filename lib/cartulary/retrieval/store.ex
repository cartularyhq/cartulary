# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Retrieval.Store do
  @moduledoc """
  The only place in the system that reaches past the resource layer to write
  retrieval SQL by hand, and it is read-only.

  Durable writes must go through resource actions, without exception. This
  module exists for the reads that cannot be expressed as ordinary resource
  reads: PostgreSQL full-text ranking, pgvector nearest-neighbour ordering,
  time and salience scoring in SQL, the alias-index join, and one-hop graph
  expansion. Nothing here inserts, updates, or deletes, and nothing here may
  start doing so.

  ## The filter contract

  Every statement in this file carries these predicates, and a new query that
  omits one is a data leak, not a bug to fix later:

  1. `account_id = $1` — tenant isolation. The Account is derived from the
     caller's identity upstream and passed in; it is never a request parameter.
  2. `scope_id = ANY($2)` — only the scopes this caller may read. The caller
     resolved that list; this module does not widen it.
  3. Lifecycle — `active` rows only for knowledge, `active` chunks only for
     documents. Every other state is invisible to retrieval.
  4. The provisional exception — a `provisional` statement is visible only when
     its subject is the calling peer. When no peer is known (`$3` is null) that
     branch admits every provisional row in the authorized scopes, so callers
     must pass a peer id for any peer-facing request.

  Knowledge queries also require `deleted_at IS NULL`; erasure soft-deletes and
  the index must not resurrect the row.

  ## Shape contract

  Every knowledge query returns the same column set, listed once below, so one
  candidate-building path can handle all of them. Document-chunk queries return
  a near-identical set: the knowledge-only columns are synthesised (confidence
  1.0, sensitivity `internal`, empty source message list), the chunk's own
  document id, version id, and position are added, and `extracting_provider`
  and `corroboration_count` are simply absent — the provenance filters read a
  missing key as the empty case. Each row carries a `candidate_type` of
  `knowledge` or `document_chunk`.

  Scores are strategy-local and mutually incomparable — a full-text rank, a
  cosine similarity, a time-relevance step, a salience product, a mention
  confidence. Only their ordering within one result list is meaningful.

  ## Safety

  Every statement is assembled only from literals and the shared column list
  below; no caller value is ever interpolated into SQL. Query text, ids, and
  vectors all reach PostgreSQL as bound parameters, including the text handed
  to the full-text parser. Keep it that way — an interpolated value here would
  be an injection point in hand-written SQL that no resource action guards.

  The scope join additionally requires the scope to belong to the same Account
  as the row, so a mis-set scope id cannot pull a scope path across tenants.
  """

  alias Cartulary.Repo

  # Shared projection so every knowledge query returns identical columns; the
  # candidate builder and the caller-facing record shape depend on that.
  # `scope_path` comes from the joined scope row and is the only column here
  # that is not on the knowledge table itself.
  @knowledge_columns """
  k.id, k.scope_id, s.path AS scope_path, k.statement, k.kind, k.confidence,
  k.sensitivity, k.state, k.source_message_ids, k.extracting_model,
  k.extracting_provider, k.pipeline_version, k.corroboration_count
  """

  @doc """
  Full-text search over governed statements and document chunks.

  Runs each side only when the query's `target` asks for it, then merges and
  truncates to `limit` by score. Both sides use PostgreSQL's `websearch`
  parser, so quoted phrases and `or`/`-` behave as a user expects, and rank
  with `ts_rank_cd`, which rewards term proximity.

  Returns a list of column-keyed maps with a `score` and a `candidate_type`.
  Raises `Postgrex.Error` if the statement fails.
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

    # A chunk has no extraction provenance of its own, so the knowledge-only
    # columns are synthesised to keep the two result shapes close. The literal
    # `f7-1` in `pipeline_version` is the retrieval and context contract
    # identity, standing in for the extraction pipeline version a chunk never
    # had. It reaches callers in the response, so changing it is a contract
    # change with a changelog entry, not incidental cleanup.
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

  @doc """
  Approximate nearest-neighbour search over stored embeddings.

  `embedding` is the query vector and `identity` describes the embedder that
  produced it: provider, model, version, and dimension count. Every statement
  filters stored rows on all four, so a vector produced by one embedder is
  never compared against a vector produced by another. Silently mixing
  embedding spaces would return plausible-looking nonsense; a row whose
  embedding identity does not match is simply not a candidate, and bringing it
  back requires re-embedding it under the current identity.

  Two SQL variants exist for one reason: 384-dimensional vectors have a
  dedicated cosine index, and the query must cast to `vector(384)` in exactly
  the same way the index expression does or PostgreSQL will not use it. Any
  other dimension count uses the unindexed form, which is correct but scans.
  Both order by cosine distance and report `1 - distance` as the score, so
  higher is more similar.

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

  The point is the query's `as_of`, defaulting to now. Statements are excluded
  outright if they had not yet been recorded at that instant or had already
  expired by it; the surviving rows get a coarse three-level score: in force at
  that time, undated (and so possibly relevant), or dated but out of force.

  The three levels are intentionally flat rather than a smooth decay, because
  this strategy's job is to supply time-appropriate candidates for fusion to
  weigh, not to express a fine-grained relevance opinion of its own.

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

  The score multiplies three factors: how confident the statement is, how often
  it has been independently corroborated (dampened logarithmically so the
  twentieth confirmation counts far less than the second), and an exponential
  decay on how long ago it was last touched. The decay divisor is 2 592 000
  seconds — thirty days — so a statement untouched for a month is worth about
  37% of a fresh one, and one untouched for a year is negligible.

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

  The entity table is joined only to *reach* statements. The result set is
  ordinary statement columns: no entity id, canonical name, alias, or surface
  form is projected. Those rows are an internal recall aid, and exposing them
  would publish a name graph the caller was never granted. The statement-level
  Account, scope, lifecycle, and provisional filters still apply, so matching
  an entity never widens what a caller may read.

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

  Exactly one hop, never a recursive walk: expansion is a recall aid whose cost
  must stay bounded and predictable inside the request deadline.

  Two authorization details matter. A scope relation only expands when *both*
  of its endpoint scopes are in the caller's authorized list — a link between a
  readable scope and an unreadable one grants nothing. And the structural and
  shared-entity branches deliberately do their own Account check but no scope
  or lifecycle check; the outer query applies scope, lifecycle, soft-delete,
  and the provisional-subject rule to every expanded id, so a relation pointing
  at an unreadable statement yields no row.

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

  # Merges the knowledge and document-chunk halves of one strategy. Both halves
  # already ran with the same `limit`, so the merged list can hold twice that;
  # re-sorting and truncating restores the cap. Comparing the two halves by
  # score is only defensible because both come from the same scoring function.
  defp top(rows, limit),
    do: rows |> Enum.sort_by(&(&1["score"] || 0.0), :desc) |> Enum.take(limit)

  # pgvector's text input format. Sent as a bound string parameter and cast in
  # SQL, so the numbers never become part of the statement text. The `* 1.0`
  # is there because `Float.to_string/1` rejects an integer.
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

  # Raw SQL bypasses the resource layer's type casting, so UUIDs arrive as
  # 16-byte binaries. Columns named `id` or ending in `_id` are converted back
  # to the hyphenated string form callers and comparisons expect; leaving them
  # as binaries produces ids that fail to match anything and are unprintable.
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

  # The inbound direction: parameters must be 16-byte binaries. Both forms are
  # accepted because callers mix already-dumped ids with string ids, and an
  # already-binary value must pass through untouched rather than be re-dumped.
  # `db_uuid/1` tolerates nil for the optional calling-peer parameter; the
  # bang forms raise on anything that is not a valid UUID, which is correct —
  # a malformed id must fail loudly, not quietly match no rows.
  defp db_uuids!(values), do: Enum.map(values, &db_uuid!/1)
  defp db_uuid(nil), do: nil
  defp db_uuid(value), do: db_uuid!(value)
  defp db_uuid!(<<_::128>> = value), do: value
  defp db_uuid!(value), do: Ecto.UUID.dump!(value)
end
