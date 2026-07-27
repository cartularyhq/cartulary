# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Memory.Query do
  @moduledoc """
  Temporary F7 retrieval transition helper.

  F1 confines the remaining static SQL to this custom query module. The
  replacement ticket is roadmap F7, where named retrieval strategies move to
  dedicated Ash-backed modules. No public write is implemented here.
  """

  alias Cartulary.Repo

  def message_account_key!(message_id) do
    """
    SELECT account.key
    FROM messages AS message
    JOIN accounts AS account ON account.id = message.account_id
    WHERE message.id = $1
    """
    |> one!([db_uuid!(message_id)])
    |> Map.fetch!("key")
  end

  def run_strategy(:lexical, account_id, scope_paths, peer_id, query, limit) do
    loose_query = lexical_tsquery(query)

    """
    SELECT k.id, k.statement, k.kind, k.confidence, k.sensitivity, k.state,
           k.source_message_ids, k.extracting_model, k.pipeline_version,
           s.path AS scope_path,
           (
             CASE WHEN $4 = '' THEN 0.0 ELSE ts_rank(k.search_vector, plainto_tsquery('english', $4)) END +
             CASE WHEN $5 = '' THEN 0.0 ELSE ts_rank(k.search_vector, to_tsquery('english', $5)) END
           ) AS score
    FROM knowledge_items k
    JOIN scopes s ON s.id = k.scope_id
    WHERE k.account_id = $1
      AND s.path = ANY($2)
      AND (
        k.state = 'active'
        OR (k.state = 'provisional' AND ($3::uuid IS NULL OR k.subject_peer_id = $3))
      )
      AND (
        $4 = ''
        OR k.search_vector @@ plainto_tsquery('english', $4)
        OR ($5 != '' AND k.search_vector @@ to_tsquery('english', $5))
      )
    ORDER BY score DESC, k.confidence DESC, k.inserted_at DESC
    LIMIT $6
    """
    |> all([db_uuid!(account_id), scope_paths, db_uuid(peer_id), query, loose_query, limit])
    |> ranked(:lexical)
  end

  def run_strategy(:temporal, account_id, scope_paths, peer_id, _query, limit) do
    """
    SELECT k.id, k.statement, k.kind, k.confidence, k.sensitivity, k.state,
           k.source_message_ids, k.extracting_model, k.pipeline_version,
           s.path AS scope_path,
           CASE WHEN k.relevant_from IS NULL AND k.relevant_until IS NULL THEN 0.5 ELSE 1.0 END AS score
    FROM knowledge_items k
    JOIN scopes s ON s.id = k.scope_id
    WHERE k.account_id = $1
      AND s.path = ANY($2)
      AND (
        k.state = 'active'
        OR (k.state = 'provisional' AND ($3::uuid IS NULL OR k.subject_peer_id = $3))
      )
      AND (k.expires_at IS NULL OR k.expires_at > NOW())
    ORDER BY score DESC, k.inserted_at DESC
    LIMIT $4
    """
    |> all([db_uuid!(account_id), scope_paths, db_uuid(peer_id), limit])
    |> ranked(:temporal)
  end

  def run_strategy(:salience_recency, account_id, scope_paths, peer_id, _query, limit) do
    """
    SELECT k.id, k.statement, k.kind, k.confidence, k.sensitivity, k.state,
           k.source_message_ids, k.extracting_model, k.pipeline_version,
           s.path AS scope_path,
           k.confidence AS score
    FROM knowledge_items k
    JOIN scopes s ON s.id = k.scope_id
    WHERE k.account_id = $1
      AND s.path = ANY($2)
      AND (
        k.state = 'active'
        OR (k.state = 'provisional' AND ($3::uuid IS NULL OR k.subject_peer_id = $3))
      )
    ORDER BY k.confidence DESC, k.inserted_at DESC
    LIMIT $4
    """
    |> all([db_uuid!(account_id), scope_paths, db_uuid(peer_id), limit])
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

  defp one!(sql, params) do
    case all(sql, params) do
      [row] -> row
      [] -> raise Ecto.NoResultsError, queryable: sql
      rows -> raise "expected one row, got #{length(rows)}"
    end
  end

  # All SQL strings in this F7 transition helper are static and parameterized.
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

  defp normalize_db_value(_column, value), do: value

  defp normalize_uuid(<<_::128>> = value) do
    case Ecto.UUID.load(value) do
      {:ok, uuid} -> uuid
      :error -> value
    end
  end

  defp normalize_uuid(value), do: value

  defp db_uuid!(<<_::128>> = value), do: value

  defp db_uuid!(value) when is_binary(value) do
    case Ecto.UUID.dump(value) do
      {:ok, dumped} -> dumped
      :error -> raise ArgumentError, "invalid uuid #{inspect(value)}"
    end
  end

  defp db_uuid(nil), do: nil
  defp db_uuid(value), do: db_uuid!(value)
end
