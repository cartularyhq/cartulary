# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Retrieval.StrategySupport do
  @moduledoc """
  The shared last step of every retrieval strategy: turn database rows into
  ranked candidates, applying the provenance filters and the score floor.

  This runs *before* fusion, and that ordering is the point. A statement the
  caller excluded by provenance must not be able to influence ranking, so it is
  removed while the list is still strategy-local rather than being stripped out
  of the merged result. Filtering after fusion would let excluded rows push
  wanted rows down or off the end.

  Ranks are assigned here, densely and from 1, over the surviving rows. The raw
  database score is moved into the candidate's evidence and dropped from the
  record that reaches callers, because that number is meaningful only relative
  to other hits from the same strategy.

  Every strategy in this file funnels through here. A new strategy that builds
  its own candidates would silently ignore both the provenance filters and the
  score floor.
  """

  alias Cartulary.Retrieval.Candidate

  @doc """
  Converts raw result rows into `Candidate` structs for one strategy.

  `rows` are column-keyed maps as returned by the retrieval store. `strategy`
  is the owning strategy's name atom. `min_score` drops rows scoring below it
  on that strategy's own scale — the same number means something different to
  each strategy, so it is a coarse noise cut, not a relevance threshold.
  `source_filters` restricts candidates by provenance; keys may be atoms or
  strings, and a nil value for any key means "do not filter on this".

  Supported provenance keys: `provider` and `model` (the extractor that
  produced the statement), `pipeline_version`, `minimum_corroboration` (an
  inclusive lower bound), `source_message_id` (the statement must derive from
  that message), and `source_document_id`.

  Returns candidates ranked from 1 in the order the rows arrived, so the
  caller's `ORDER BY` decides the ranking.
  """
  def candidates(rows, strategy, min_score \\ 0.0, source_filters \\ %{}) do
    rows
    |> Enum.filter(
      &(source_allowed?(&1, source_filters || %{}) and
          (&1["score"] || 0.0) >= min_score)
    )
    |> Enum.with_index(1)
    |> Enum.map(fn {row, rank} ->
      %Candidate{
        id: row["id"],
        score: (row["score"] || 0.0) * 1.0,
        rank: rank,
        strategy: strategy,
        record: Map.drop(row, ["score"]),
        evidence: %{"raw_score" => row["score"] || 0.0}
      }
    end)
  end

  # All filters must pass. Keys are normalised to strings because they arrive
  # both from decoded request payloads and from internal callers using atoms.
  defp source_allowed?(row, filters) do
    filters = Map.new(filters, fn {key, value} -> {to_string(key), value} end)

    matches?(row["extracting_provider"], filters["provider"]) and
      matches?(row["extracting_model"], filters["model"]) and
      matches?(row["pipeline_version"], filters["pipeline_version"]) and
      minimum?(row["corroboration_count"], filters["minimum_corroboration"]) and
      contains?(row["source_message_ids"], filters["source_message_id"]) and
      matches?(row["document_id"], filters["source_document_id"])
  end

  # A nil expectation means the caller did not ask for this filter, so it
  # passes. Absent row values are treated as the empty case rather than as a
  # match: a statement with no corroboration count counts as zero, and one with
  # no source message list contains nothing.
  defp matches?(_actual, nil), do: true
  defp matches?(actual, expected), do: actual == expected
  defp minimum?(_actual, nil), do: true
  defp minimum?(actual, expected), do: (actual || 0) >= expected
  defp contains?(_actual, nil), do: true
  defp contains?(actual, expected), do: expected in (actual || [])
end

defmodule Cartulary.Retrieval.Strategies.Semantic do
  @moduledoc """
  Meaning-based retrieval: embeds the query text and finds the nearest stored
  vectors.

  This is the strategy that finds a statement phrased entirely differently from
  the question, which is exactly what keyword search cannot do — and it is also
  the one that confidently returns something vaguely on-topic when nothing
  relevant exists. That is why it is fused with others rather than trusted
  alone.

  It runs in the seed stage and is classed `:moderate` because, unlike the
  other seed strategies, it needs an embedding call before it can touch the
  database.

  Search is confined to vectors produced by the Account's currently configured
  embedder: same provider, model, version, and dimension count. Rows embedded
  under an older identity are not candidates and are not silently reused, since
  distances across two embedding spaces are meaningless. Bringing them back
  means re-embedding them, not relaxing the filter.
  """
  @behaviour Cartulary.Retrieval.Strategy

  alias Cartulary.Model.{Config, Embedding}
  alias Cartulary.Retrieval.{Store, StrategySupport}

  @impl true
  def name, do: :semantic
  @impl true
  def cost_class, do: :moderate
  @impl true
  def stage, do: :seed

  @doc """
  True only for a non-blank query string.

  Embedding whitespace would cost a provider call and return an arbitrary
  neighbourhood of the corpus, so an empty query skips this strategy entirely.
  """
  @impl true
  def applicable?(query), do: is_binary(query.text) and String.trim(query.text) != ""

  @doc """
  Embeds the query and returns the nearest authorized records.

  An embedding failure returns an empty list rather than raising: the request
  continues on the remaining strategies, degraded but answered. The identity
  used to filter stored vectors is re-resolved from the Account's embedder
  configuration, so it always describes the same embedder that just produced
  the query vector.
  """
  @impl true
  def candidates(query, budget) do
    context = %{account_id: query.account_id, actor: query.actor}

    case Embedding.embed([query.text], context) do
      {:ok, %{vectors: [embedding]}} ->
        identity = :embedder |> Config.resolve(context) |> Config.embedding_identity()

        query
        |> Store.semantic(embedding, identity, budget.max_candidates)
        |> StrategySupport.candidates(
          name(),
          query.min_score || 0.0,
          query.source_filters
        )

      {:error, _error} ->
        []
    end
  end
end

defmodule Cartulary.Retrieval.Strategies.Lexical do
  @moduledoc """
  Word-based retrieval through PostgreSQL full-text search.

  This is the counterweight to semantic search. Exact tokens — an error code, a
  product name, a person's surname, an identifier — are what embeddings blur
  away, and a query that quotes one usually means it literally. Seed stage, and
  `:cheap` because it is an indexed database query with no model call.

  Because it needs terms to match, it contributes nothing to a paraphrased
  question, which is precisely when the semantic strategy carries the request.
  Neither is trusted alone; fusion is what makes the pair useful.
  """
  @behaviour Cartulary.Retrieval.Strategy

  alias Cartulary.Retrieval.{Store, StrategySupport}

  @impl true
  def name, do: :lexical
  @impl true
  def cost_class, do: :cheap
  @impl true
  def stage, do: :seed

  @doc "True only for a non-blank query string; there are no terms to match otherwise."
  @impl true
  def applicable?(query), do: is_binary(query.text) and String.trim(query.text) != ""

  @doc """
  Returns authorized statements and document chunks whose text matches the
  query terms, ranked by full-text relevance.

  Like the semantic strategy, and unlike the remaining ones, it can return
  document chunks as well as governed statements; the query's target decides.
  """
  @impl true
  def candidates(query, budget) do
    query
    |> Store.lexical(budget.max_candidates)
    |> StrategySupport.candidates(name(), query.min_score || 0.0, query.source_filters)
  end
end

defmodule Cartulary.Retrieval.Strategies.Temporal do
  @moduledoc """
  Time-aware candidate generation: prefers statements that were actually in
  force at the moment the caller asked about.

  Three timelines are kept apart deliberately. *When something was recorded* is
  not *when it was true*, and neither is *how important it is now*. This
  strategy reads the second one — the validity window — and asks whether the
  statement applied at the query's reference time, defaulting to now.

  So a superseded fact does not vanish from the record; it simply stops being
  in force, scores low here, and a query dated back into its window still finds
  it. Seed stage, `:cheap`, no model call and no query text needed.
  """
  @behaviour Cartulary.Retrieval.Strategy

  alias Cartulary.Retrieval.{Store, StrategySupport}

  @impl true
  def name, do: :temporal
  @impl true
  def cost_class, do: :cheap
  @impl true
  def stage, do: :seed

  @doc """
  True whenever the query wants governed statements.

  Document chunks have no validity period, so a documents-only query skips this
  strategy. It needs no query text: time is the whole criterion.
  """
  @impl true
  def applicable?(query), do: query.target in [:knowledge, :all]

  @doc """
  Returns authorized statements scored by whether they were in force at the
  query's reference time, excluding those not yet recorded or already expired
  at that instant.
  """
  @impl true
  def candidates(query, budget) do
    query
    |> Store.temporal(budget.max_candidates)
    |> StrategySupport.candidates(name(), query.min_score || 0.0, query.source_filters)
  end
end

defmodule Cartulary.Retrieval.Strategies.SalienceRecency do
  @moduledoc """
  Query-independent ranking by how important and how fresh a statement is.

  It answers "what matters here right now?" rather than "what matches this
  text?", combining confidence, corroboration, and recency. That makes it the
  backbone of context assembly, where there is often no real question to match
  against, and the safety net elsewhere: it needs no query text, no embedding,
  and no provider, so it still returns something useful when the embedder is
  down or the corpus is too small for meaningful similarity.

  Its blind spot is the mirror image: it will happily return the most important
  statements in the scope even when none of them relate to the question. Fusion
  with a text-driven strategy is what keeps that in check.

  Seed stage, `:cheap` — one indexed database query.
  """
  @behaviour Cartulary.Retrieval.Strategy

  alias Cartulary.Retrieval.{Store, StrategySupport}

  @impl true
  def name, do: :salience_recency
  @impl true
  def cost_class, do: :cheap
  @impl true
  def stage, do: :seed

  @doc """
  True whenever the query wants governed statements; document chunks carry no
  confidence or corroboration to rank by.
  """
  @impl true
  def applicable?(query), do: query.target in [:knowledge, :all]

  @doc """
  Returns authorized, unexpired statements ranked by confidence, corroboration,
  and recency of last update. The query text is not read at all.
  """
  @impl true
  def candidates(query, budget) do
    query
    |> Store.salience_recency(budget.max_candidates)
    |> StrategySupport.candidates(name(), query.min_score || 0.0, query.source_filters)
  end
end

defmodule Cartulary.Retrieval.Strategies.EntityMatch do
  @moduledoc """
  Finds statements about the people, organisations, systems, and concepts named
  in the query, using the internal alias index.

  Query terms are matched whole against an entity's canonical name and aliases,
  so once the resolver has folded "Ada" and "ada@example.com" onto one entity, a
  query naming either spelling reaches statements written with the other —
  which neither word matching nor embedding reliably does.

  The alias index it consults is a private, rebuildable cache. Its rows are a
  name graph nobody was granted access to, so this strategy uses them purely to
  locate statements and returns ordinary statement records: no entity id,
  canonical name, alias, or surface form is ever projected outward. The usual
  Account, scope, lifecycle, and provisional-subject filters still decide what
  is readable, so matching an entity can never widen a caller's visibility.

  Seed stage, `:cheap` — one database query, no model call. Because the cache
  is derived, it may lag behind fresh statements; that costs recall and never
  correctness.
  """
  @behaviour Cartulary.Retrieval.Strategy

  alias Cartulary.Retrieval.{Store, StrategySupport}

  @impl true
  def name, do: :entity_match
  @impl true
  def cost_class, do: :cheap
  @impl true
  def stage, do: :seed

  @doc """
  True when the query wants governed statements and its text is not the empty
  string. That is not a blank check: whitespace-only text is tokenised to
  nothing and simply yields no candidates.
  """
  @impl true
  def applicable?(query), do: query.target in [:knowledge, :all] and query.text != ""

  @doc """
  Returns authorized statements that mention an entity whose canonical name or
  alias appears in the query text, scored by mention and statement confidence.
  """
  @impl true
  def candidates(query, budget) do
    query
    |> Store.entity_match(budget.max_candidates)
    |> StrategySupport.candidates(name(), query.min_score || 0.0, query.source_filters)
  end
end

defmodule Cartulary.Retrieval.Strategies.RelationExpand do
  @moduledoc """
  The only expansion-stage strategy: it takes one step outwards from what the
  seed strategies already found.

  Some answers are not in any statement that resembles the question — they are
  one link away, in a statement that explains, contradicts, or shares a subject
  with a good hit. This strategy follows recorded relations between statements,
  shared entity mentions, and explicit relations between scopes.

  Exactly one hop. There is no recursion and no configurable depth, because the
  cost of a graph walk must stay bounded inside the request deadline, and
  because relevance decays fast: two hops out is mostly noise.

  A scope relation only expands when the caller can already read both endpoint
  scopes. A link is not a grant, and following one must never surface a
  statement from a scope the caller was not authorized for.

  Expand stage, `:moderate`. Of the shipped profiles only the thorough posture
  enables it.
  """
  @behaviour Cartulary.Retrieval.Strategy

  alias Cartulary.Retrieval.{Store, StrategySupport}

  @impl true
  def name, do: :relation_expand
  @impl true
  def cost_class, do: :moderate
  @impl true
  def stage, do: :expand

  @doc """
  True only when the query wants governed statements and the seed phase
  actually produced ids to expand from.

  The engine fills those ids in between phases, so this is false during the
  seed stage and stays false when the seed strategies found nothing — there is
  nothing to walk outwards from.
  """
  @impl true
  def applicable?(query), do: query.target in [:knowledge, :all] and query.seed_ids != []

  @doc """
  Returns authorized statements one hop from the seed set, scored by edge
  strength times the statement's own confidence.
  """
  @impl true
  def candidates(query, budget) do
    query
    |> Store.relation_expand(budget.max_candidates)
    |> StrategySupport.candidates(name(), query.min_score || 0.0, query.source_filters)
  end
end
