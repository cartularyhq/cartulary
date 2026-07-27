# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Memory do
  @moduledoc """
  POC memory operations.

  This module is the single write path for raw observations and pipeline-created
  knowledge in the local proof of concept.

  This is a temporary compatibility facade whose `poc-0` behavior is frozen by
  the F0 contract tests. F1 and F2 replace its direct SQL with authoritative Ash
  actions and transactional AshOban workflows; public callers should not add
  new dependencies on this module or bypass it to write knowledge.
  """

  alias Cartulary.Clock
  alias Cartulary.Observability
  alias Cartulary.Pipeline.Extractor
  alias Cartulary.Pipeline.ExtractWorker
  alias Cartulary.Repo

  @default_limit 12

  def ingest_message(attrs) do
    Observability.with_span(:memory, "cartulary.memory.ingest_message", fn ->
      attrs = normalize_attrs(attrs)
      sync_extract? = Map.get(attrs, "sync_extract", true)
      enqueue_extract? = Map.get(attrs, "enqueue_extract", not sync_extract?)

      Observability.set_attributes(:memory, %{
        "cartulary.ingest.sync_extract" => sync_extract?,
        "cartulary.ingest.enqueue_extract" => enqueue_extract?,
        "cartulary.message.role" => Map.get(attrs, "role", "user"),
        "cartulary.message.content_length" =>
          String.length(to_string(Map.get(attrs, "content", "")))
      })

      {:ok, message} =
        Repo.transaction(fn ->
          account = ensure_account!(Map.fetch!(attrs, "account_key"))
          scope = ensure_scope!(account["id"], Map.fetch!(attrs, "scope_path"))

          peer =
            ensure_peer!(
              account["id"],
              Map.fetch!(attrs, "peer_key"),
              Map.get(attrs, "peer_name")
            )

          session =
            ensure_session!(
              account["id"],
              scope["id"],
              peer["id"],
              Map.fetch!(attrs, "session_id")
            )

          message = insert_message!(account["id"], scope["id"], peer["id"], session["id"], attrs)

          if enqueue_extract? do
            %{message_id: message["id"]}
            |> ExtractWorker.new(unique: [period: 86_400, keys: [:message_id]])
            |> OpentelemetryOban.insert!()
          end

          message
        end)

      Observability.set_attribute(:memory, "cartulary.message.id", message["id"])

      if sync_extract? do
        {:ok, knowledge} = extract_message(message["id"])

        Observability.set_attribute(
          :memory,
          "cartulary.knowledge.created_count",
          length(knowledge)
        )

        {:ok, Map.put(message, "knowledge", knowledge)}
      else
        {:ok, message}
      end
    end)
  end

  def extract_message(message_id) do
    Observability.with_span(:memory, "cartulary.memory.extract_message", fn ->
      Observability.set_attribute(:memory, "cartulary.message.id", message_id)

      message = fetch_message!(message_id)
      items = Extractor.extract(message)
      Observability.set_attribute(:memory, "cartulary.extract.item_count", length(items))

      {:ok, knowledge} =
        Repo.transaction(fn ->
          Enum.map(items, &insert_knowledge!(message, &1))
        end)

      Observability.set_attribute(:memory, "cartulary.knowledge.created_count", length(knowledge))
      {:ok, knowledge}
    end)
  end

  def query_knowledge(filters) do
    Observability.with_span(:memory, "cartulary.memory.query_knowledge", fn ->
      filters = normalize_attrs(filters)
      account = account_from_filters!(filters)
      scope_paths = visible_scope_paths(account["id"], Map.get(filters, "scope_path", "/poc"))
      state = Map.get(filters, "state", "active")
      limit = parse_int(Map.get(filters, "limit"), @default_limit)

      Observability.set_attributes(:memory, %{
        "cartulary.knowledge.state" => state,
        "cartulary.query.limit" => limit,
        "cartulary.query.scope_count" => length(scope_paths)
      })

      params = [db_uuid!(account["id"]), scope_paths, state, limit]

      rows =
        """
        SELECT k.id, k.statement, k.kind, k.confidence, k.sensitivity, k.state,
               k.source_message_ids, k.extracting_model, k.pipeline_version,
               s.path AS scope_path, k.inserted_at
        FROM knowledge_items k
        JOIN scopes s ON s.id = k.scope_id
        WHERE k.account_id = $1
          AND s.path = ANY($2)
          AND k.state = $3
        ORDER BY k.confidence DESC, k.inserted_at DESC
        LIMIT $4
        """
        |> all(params)

      Observability.set_attribute(:memory, "cartulary.query.result_count", length(rows))
      rows
    end)
  end

  def search(filters) do
    Observability.with_span(:memory, "cartulary.memory.search", fn ->
      filters = normalize_attrs(filters)
      account = account_from_filters!(filters)
      query = Map.get(filters, "query", "")
      scope_path = Map.get(filters, "scope_path", "/poc")
      profile = parse_profile(Map.get(filters, "profile", "balanced"))
      limit = parse_int(Map.get(filters, "limit"), @default_limit)
      deadline? = Map.get(filters, "deadline", "enabled")
      started_at = System.monotonic_time(:millisecond)

      profile_config = profile_config(profile)
      strategies = Map.fetch!(profile_config, :strategies)
      scope_paths = visible_scope_paths(account["id"], scope_path)

      Observability.set_attributes(:memory, %{
        "cartulary.retrieval.profile" => Atom.to_string(profile),
        "cartulary.retrieval.profile_version" => Map.fetch!(profile_config, :version),
        "cartulary.retrieval.strategy_count" => length(strategies),
        "cartulary.query.limit" => limit,
        "cartulary.query.text_length" => String.length(query),
        "cartulary.query.scope_count" => length(scope_paths)
      })

      strategy_results =
        strategies
        |> Enum.map(fn strategy ->
          {strategy, run_strategy(strategy, account["id"], scope_paths, query, limit)}
        end)

      fused = fuse(strategy_results, limit)
      latency_ms = System.monotonic_time(:millisecond) - started_at

      Observability.set_attributes(:memory, %{
        "cartulary.retrieval.candidate_count" => length(fused),
        "cartulary.retrieval.latency_ms" => latency_ms
      })

      %{
        "query" => query,
        "profile" => Atom.to_string(profile),
        "profile_version" => Map.fetch!(profile_config, :version),
        "deadline" => deadline?,
        "latency_ms" => latency_ms,
        "contributed_strategies" =>
          Enum.map(strategy_results, fn {strategy, rows} -> strategy_name(strategy, rows) end),
        "dropped_strategies" => [],
        "candidates" => fused
      }
    end)
  end

  def ask(attrs) do
    Observability.with_span(:memory, "cartulary.memory.ask", fn ->
      attrs = normalize_attrs(attrs)
      question = Map.fetch!(attrs, "question")
      profile = Map.get(attrs, "profile", "thorough")

      Observability.set_attributes(:memory, %{
        "cartulary.ask.question_length" => String.length(question),
        "cartulary.retrieval.profile" => profile
      })

      retrieval =
        attrs
        |> Map.put("query", question)
        |> Map.put("profile", profile)
        |> search()

      candidates = Map.fetch!(retrieval, "candidates")

      answer =
        if model_configured?() and candidates != [] do
          model_answer(question, candidates)
        else
          fallback_answer(question, candidates)
        end

      Observability.set_attributes(:memory, %{
        "cartulary.ask.candidate_count" => length(candidates),
        "cartulary.ask.used_model" => model_configured?() and candidates != [],
        "cartulary.ask.abstained" => Map.get(answer, "abstained", false)
      })

      Map.merge(retrieval, answer)
    end)
  end

  def get_context(attrs) do
    Observability.with_span(:memory, "cartulary.memory.get_context", fn ->
      attrs = normalize_attrs(attrs)
      knowledge = query_knowledge(Map.put(attrs, "limit", Map.get(attrs, "limit", 8)))

      Observability.set_attribute(:memory, "cartulary.context.knowledge_count", length(knowledge))

      %{
        "profile_version" => "poc-0",
        "session_summary" => nil,
        "scope_cards" => [],
        "peer_profile" => [],
        "knowledge" => knowledge
      }
    end)
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  end

  defp account_from_filters!(%{"account_key" => key}) when is_binary(key),
    do: ensure_account!(key)

  defp account_from_filters!(%{"account_id" => id}) when is_binary(id),
    do: one!("SELECT * FROM accounts WHERE id = $1", [db_uuid!(id)])

  defp account_from_filters!(_filters) do
    raise ArgumentError,
          "account_key is required; derive it from caller identity or x-cartulary-account-key"
  end

  defp ensure_account!(key) do
    name = String.replace(key, ~r/[-_]+/, " ")

    one!(
      """
      INSERT INTO accounts (key, name, inserted_at, updated_at)
      VALUES ($1, $2, NOW(), NOW())
      ON CONFLICT (key) DO UPDATE SET updated_at = NOW()
      RETURNING *
      """,
      [key, name]
    )
  end

  defp ensure_peer!(account_id, key, nil), do: ensure_peer!(account_id, key, key)

  defp ensure_peer!(account_id, key, name) do
    one!(
      """
      INSERT INTO peers (account_id, key, name, inserted_at, updated_at)
      VALUES ($1, $2, $3, NOW(), NOW())
      ON CONFLICT (account_id, key) DO UPDATE SET name = EXCLUDED.name, updated_at = NOW()
      RETURNING *
      """,
      [db_uuid!(account_id), key, name]
    )
  end

  defp ensure_scope!(account_id, path) do
    path
    |> normalize_path()
    |> scope_segments()
    |> Enum.reduce(nil, fn {key, scope_path}, parent ->
      one!(
        """
        INSERT INTO scopes (account_id, parent_id, key, name, path, inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, NOW(), NOW())
        ON CONFLICT (account_id, path) DO UPDATE SET updated_at = NOW()
        RETURNING *
        """,
        [db_uuid!(account_id), db_uuid(parent && parent["id"]), key, key, scope_path]
      )
    end)
  end

  defp ensure_session!(account_id, scope_id, peer_id, external_id) do
    one!(
      """
      INSERT INTO sessions (account_id, scope_id, peer_id, external_id, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, NOW(), NOW())
      ON CONFLICT (account_id, external_id) DO UPDATE SET updated_at = NOW()
      RETURNING *
      """,
      [db_uuid!(account_id), db_uuid!(scope_id), db_uuid!(peer_id), external_id]
    )
  end

  defp insert_message!(account_id, scope_id, peer_id, session_id, attrs) do
    occurred_at = Map.get(attrs, "occurred_at") || Clock.utc_now()

    one!(
      """
      INSERT INTO messages
        (account_id, session_id, scope_id, peer_id, role, content, occurred_at, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, NOW(), NOW())
      RETURNING *
      """,
      [
        db_uuid!(account_id),
        db_uuid!(session_id),
        db_uuid!(scope_id),
        db_uuid!(peer_id),
        Map.get(attrs, "role", "user"),
        Map.fetch!(attrs, "content"),
        coerce_datetime!(occurred_at)
      ]
    )
  end

  defp fetch_message!(message_id) do
    one!(
      """
      SELECT m.*, p.key AS peer_key, s.path AS scope_path, a.key AS account_key
      FROM messages m
      JOIN peers p ON p.id = m.peer_id
      JOIN scopes s ON s.id = m.scope_id
      JOIN accounts a ON a.id = m.account_id
      WHERE m.id = $1
      """,
      [db_uuid!(message_id)]
    )
  end

  defp insert_knowledge!(message, item) do
    state =
      if item.confidence >= 0.5 and item.sensitivity in ["public", "internal"],
        do: "active",
        else: "proposed"

    existing =
      maybe_one(
        """
        SELECT *
        FROM knowledge_items
        WHERE account_id = $1
          AND scope_id = $2
          AND lower(statement) = lower($3)
          AND state IN ('active', 'proposed')
        LIMIT 1
        """,
        [db_uuid!(message["account_id"]), db_uuid!(message["scope_id"]), item.statement]
      )

    knowledge =
      if existing do
        one!(
          """
          UPDATE knowledge_items
          SET source_message_ids = (SELECT array_agg(DISTINCT x) FROM unnest(source_message_ids || ARRAY[$2::uuid]) AS x),
              confidence = GREATEST(confidence, $3),
              updated_at = NOW()
          WHERE id = $1
          RETURNING *
          """,
          [db_uuid!(existing["id"]), db_uuid!(message["id"]), item.confidence]
        )
      else
        one!(
          """
          INSERT INTO knowledge_items
            (account_id, scope_id, subject_peer_id, subject_scope_id, statement, kind, confidence,
             sensitivity, state, source_message_ids, extracting_model, pipeline_version, inserted_at, updated_at)
          VALUES ($1, $2, $3, NULL, $4, $5, $6, $7, $8, ARRAY[$9::uuid], $10, $11, NOW(), NOW())
          RETURNING *
          """,
          [
            db_uuid!(message["account_id"]),
            db_uuid!(message["scope_id"]),
            db_uuid!(message["peer_id"]),
            item.statement,
            item.kind,
            item.confidence,
            item.sensitivity,
            state,
            db_uuid!(message["id"]),
            item.extracting_model,
            item.pipeline_version
          ]
        )
      end

    insert_lifecycle!(knowledge, nil, knowledge["state"], "poc_auto_gate")
    knowledge
  end

  defp insert_lifecycle!(knowledge, from_state, to_state, reason) do
    one!(
      """
      INSERT INTO knowledge_lifecycle_events
        (account_id, knowledge_item_id, from_state, to_state, reason, occurred_at, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, NOW(), NOW())
      RETURNING *
      """,
      [
        db_uuid!(knowledge["account_id"]),
        db_uuid!(knowledge["id"]),
        from_state,
        to_state,
        reason,
        Clock.utc_now()
      ]
    )
  end

  defp visible_scope_paths(account_id, path) do
    normalized = normalize_path(path)
    ancestor_paths = ancestor_paths(normalized)

    """
    SELECT path
    FROM scopes
    WHERE account_id = $1 AND path = ANY($2)
    ORDER BY length(path) DESC
    """
    |> all([db_uuid!(account_id), ancestor_paths])
    |> Enum.map(& &1["path"])
  end

  defp run_strategy(:lexical, account_id, scope_paths, query, limit) do
    loose_query = lexical_tsquery(query)

    """
    SELECT k.id, k.statement, k.kind, k.confidence, k.sensitivity, k.state,
           k.source_message_ids, k.extracting_model, k.pipeline_version,
           s.path AS scope_path,
           (
             CASE WHEN $3 = '' THEN 0.0 ELSE ts_rank(k.search_vector, plainto_tsquery('english', $3)) END +
             CASE WHEN $4 = '' THEN 0.0 ELSE ts_rank(k.search_vector, to_tsquery('english', $4)) END
           ) AS score
    FROM knowledge_items k
    JOIN scopes s ON s.id = k.scope_id
    WHERE k.account_id = $1
      AND s.path = ANY($2)
      AND k.state = 'active'
      AND (
        $3 = ''
        OR k.search_vector @@ plainto_tsquery('english', $3)
        OR ($4 != '' AND k.search_vector @@ to_tsquery('english', $4))
      )
    ORDER BY score DESC, k.confidence DESC, k.inserted_at DESC
    LIMIT $5
    """
    |> all([db_uuid!(account_id), scope_paths, query, loose_query, limit])
    |> ranked(:lexical)
  end

  defp run_strategy(:temporal, account_id, scope_paths, _query, limit) do
    """
    SELECT k.id, k.statement, k.kind, k.confidence, k.sensitivity, k.state,
           k.source_message_ids, k.extracting_model, k.pipeline_version,
           s.path AS scope_path,
           CASE WHEN k.relevant_from IS NULL AND k.relevant_until IS NULL THEN 0.5 ELSE 1.0 END AS score
    FROM knowledge_items k
    JOIN scopes s ON s.id = k.scope_id
    WHERE k.account_id = $1
      AND s.path = ANY($2)
      AND k.state = 'active'
      AND (k.expires_at IS NULL OR k.expires_at > NOW())
    ORDER BY score DESC, k.inserted_at DESC
    LIMIT $3
    """
    |> all([db_uuid!(account_id), scope_paths, limit])
    |> ranked(:temporal)
  end

  defp run_strategy(:salience_recency, account_id, scope_paths, _query, limit) do
    """
    SELECT k.id, k.statement, k.kind, k.confidence, k.sensitivity, k.state,
           k.source_message_ids, k.extracting_model, k.pipeline_version,
           s.path AS scope_path,
           k.confidence AS score
    FROM knowledge_items k
    JOIN scopes s ON s.id = k.scope_id
    WHERE k.account_id = $1
      AND s.path = ANY($2)
      AND k.state = 'active'
    ORDER BY k.confidence DESC, k.inserted_at DESC
    LIMIT $3
    """
    |> all([db_uuid!(account_id), scope_paths, limit])
    |> ranked(:salience_recency)
  end

  defp ranked(rows, strategy) do
    rows
    |> Enum.with_index(1)
    |> Enum.map(fn {row, rank} ->
      row
      |> Map.put("rank", rank)
      |> Map.put("strategy", Atom.to_string(strategy))
    end)
  end

  defp fuse(strategy_results, limit) do
    strategy_results
    |> Enum.flat_map(fn {_strategy, rows} -> rows end)
    |> Enum.group_by(& &1["id"])
    |> Enum.map(fn {_id, rows} ->
      rrf_score = Enum.reduce(rows, 0.0, fn row, acc -> acc + 1.0 / (60 + row["rank"]) end)

      rows
      |> List.first()
      |> Map.put("rrf_score", rrf_score)
      |> Map.put("strategies", Enum.map(rows, & &1["strategy"]) |> Enum.uniq())
    end)
    |> Enum.sort_by(& &1["rrf_score"], :desc)
    |> Enum.take(limit)
  end

  defp model_configured? do
    key =
      Keyword.get(Application.fetch_env!(:cartulary, :models), :api_key) ||
        System.get_env("OPENROUTER_API_KEY")

    is_binary(key) and key != ""
  end

  defp model_answer(question, candidates) do
    context =
      candidates
      |> Enum.map_join("\n", fn row -> "[#{row["id"]}] #{row["statement"]}" end)

    prompt = """
    Answer the question using only the cited Cartulary memory statements.
    Return JSON: {"answer":"...", "citations":["knowledge-id"], "abstained":false}.
    If the statements do not answer the question, return {"answer":"not known", "citations":[], "abstained":true}.

    Question: #{question}

    Memory:
    #{context}
    """

    decoded =
      Cartulary.Model.OpenRouter.chat_json!(:ask, [
        %{role: "system", content: "You are a grounded memory QA engine."},
        %{role: "user", content: prompt}
      ])

    cited_ids = candidates |> MapSet.new(& &1["id"])
    citations = decoded |> Map.get("citations", []) |> Enum.filter(&MapSet.member?(cited_ids, &1))

    %{
      "answer" => Map.get(decoded, "answer", fallback_answer(question, candidates)["answer"]),
      "citations" => citations,
      "abstained" => Map.get(decoded, "abstained", citations == [])
    }
  rescue
    _error -> fallback_answer(question, candidates)
  end

  defp fallback_answer(_question, []),
    do: %{"answer" => "not known", "citations" => [], "abstained" => true}

  defp fallback_answer(_question, candidates) do
    top = Enum.take(candidates, 4)

    %{
      "answer" => Enum.map_join(top, " ", & &1["statement"]),
      "citations" => Enum.map(top, & &1["id"]),
      "abstained" => false
    }
  end

  defp profile_config(profile) when profile in [:fast, :balanced, :thorough] do
    :cartulary
    |> Application.fetch_env!(:retrieval_profiles)
    |> Keyword.fetch!(profile)
  end

  defp profile_config(_profile), do: profile_config(:balanced)

  defp parse_profile("fast"), do: :fast
  defp parse_profile("balanced"), do: :balanced
  defp parse_profile("thorough"), do: :thorough
  defp parse_profile(:fast), do: :fast
  defp parse_profile(:balanced), do: :balanced
  defp parse_profile(:thorough), do: :thorough
  defp parse_profile(_profile), do: :balanced

  defp strategy_name(strategy, []), do: "#{strategy}:empty"
  defp strategy_name(strategy, _rows), do: Atom.to_string(strategy)

  defp lexical_tsquery(query) when is_binary(query) do
    query
    |> String.downcase()
    |> String.split(~r/[^[:alnum:]_]+/, trim: true)
    |> Enum.reject(&(&1 in ~w(the and for with what which does kind used should start scale)))
    |> Enum.filter(&(String.length(&1) >= 3))
    |> Enum.uniq()
    |> Enum.take(16)
    |> Enum.map_join(" | ", &"#{&1}:*")
  end

  defp normalize_path(path) when is_binary(path) do
    path
    |> String.trim()
    |> case do
      "" -> "/poc"
      "/" -> "/poc"
      "/" <> _ = path -> path
      path -> "/" <> path
    end
  end

  defp normalize_path(_path), do: "/poc"

  defp scope_segments(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.reduce({[], []}, fn segment, {parts, acc} ->
      parts = parts ++ [segment]
      {parts, acc ++ [{segment, "/" <> Enum.join(parts, "/")}]}
    end)
    |> elem(1)
  end

  defp ancestor_paths(path) do
    path
    |> scope_segments()
    |> Enum.map(fn {_segment, path} -> path end)
  end

  defp coerce_datetime!(%DateTime{} = datetime), do: datetime

  defp coerce_datetime!(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> Clock.utc_now()
    end
  end

  defp coerce_datetime!(_value), do: Clock.utc_now()

  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp parse_int(_value, default), do: default

  defp one!(sql, params) do
    case all(sql, params) do
      [row] -> row
      [] -> raise Ecto.NoResultsError, queryable: sql
      rows -> raise "expected one row, got #{length(rows)}"
    end
  end

  defp maybe_one(sql, params) do
    case all(sql, params) do
      [row] -> row
      [] -> nil
      rows -> raise "expected zero or one row, got #{length(rows)}"
    end
  end

  # POC callers pass static SQL strings and separate Postgrex parameters.
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
       when column == "id" or binary_part(column, byte_size(column) - 3, 3) == "_id" do
    normalize_uuid(value)
  end

  defp normalize_db_value("source_message_ids", values) when is_list(values) do
    Enum.map(values, &normalize_uuid/1)
  end

  defp normalize_db_value("search_vector", _value), do: nil

  defp normalize_db_value(_column, value), do: value

  defp normalize_uuid(<<_::128>> = value) do
    case Ecto.UUID.load(value) do
      {:ok, uuid} -> uuid
      :error -> value
    end
  end

  defp normalize_uuid(value), do: value

  defp db_uuid(nil), do: nil
  defp db_uuid(value), do: db_uuid!(value)

  defp db_uuid!(<<_::128>> = value), do: value

  defp db_uuid!(value) when is_binary(value) do
    case Ecto.UUID.dump(value) do
      {:ok, dumped} -> dumped
      :error -> raise ArgumentError, "invalid uuid #{inspect(value)}"
    end
  end
end
