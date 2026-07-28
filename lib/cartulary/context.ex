# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Context do
  @moduledoc "Reasoning-free projection and salience assembly for `get_context`."

  alias Cartulary.Context.Cache
  alias Cartulary.Knowledge.Projection
  alias Cartulary.Observations.Session
  alias Cartulary.Retrieval.Query

  require Ash.Query

  def get(account, actor, scopes, attrs) do
    scope_ids = Enum.map(scopes, & &1.id)
    session_id = resolve_session_id(account.id, actor, scope_ids, attrs["session_id"])
    {scope_cards, scope_hits} = scope_cards(account.id, actor, scopes)
    {peer_profiles, peer_hits} = peer_profiles(account.id, actor, scopes)
    {session_summary, session_hit} = session_summary(account.id, actor, scopes, session_id)

    projection_knowledge =
      projection_knowledge(scope_cards, peer_profiles)

    {knowledge, fallback?} =
      knowledge(account.id, actor, scope_ids, attrs, projection_knowledge)

    budget = parse_int(Map.get(attrs, "budget_chars"), retrieval_config(:context_budget_chars))

    {summary, profiles, cards, knowledge} =
      fit_budget(
        session_summary,
        List.flatten(peer_profiles),
        Enum.reject(scope_cards, &is_nil/1),
        knowledge,
        budget
      )

    %{
      "profile_version" => "f7-1",
      "session_summary" => summary,
      "scope_cards" => cards,
      "peer_profile" => profiles,
      "knowledge" => knowledge,
      "projection_cache_hit" => scope_hits + peer_hits + if(session_hit, do: 1, else: 0) > 0,
      "fast_fallback" => fallback?
    }
  end

  defp scope_cards(account_id, actor, scopes) do
    Enum.map_reduce(scopes, 0, fn scope, hits ->
      {projection, hit?} = projection(account_id, actor, scope.id, "scope:#{scope.id}")
      content = projection && projection.content
      {content, hits + if(hit?, do: 1, else: 0)}
    end)
  end

  defp peer_profiles(_account_id, %{peer_id: peer_id}, _scopes)
       when not is_binary(peer_id),
       do: {[], 0}

  defp peer_profiles(account_id, actor, scopes) do
    Enum.map_reduce(scopes, 0, fn scope, hits ->
      {projection, hit?} =
        projection(account_id, actor, scope.id, "peer:#{scope.id}:#{actor.peer_id}")

      knowledge = projection && Map.get(projection.content, "knowledge", [])
      {knowledge || [], hits + if(hit?, do: 1, else: 0)}
    end)
  end

  defp session_summary(_account_id, _actor, _scopes, nil), do: {nil, false}

  defp session_summary(account_id, actor, scopes, session_id) do
    Enum.find_value(scopes, {nil, false}, fn scope ->
      case projection(account_id, actor, scope.id, "session:#{scope.id}:#{session_id}") do
        {nil, false} -> nil
        {projection, hit?} -> {projection.content, hit?}
      end
    end)
  end

  defp projection_knowledge(scope_cards, peer_profiles) do
    (Enum.flat_map(scope_cards, &Map.get(&1 || %{}, "knowledge", [])) ++
       List.flatten(peer_profiles))
    |> Enum.uniq_by(& &1["id"])
  end

  defp knowledge(_account_id, _actor, _scope_ids, _attrs, [_ | _] = projection_knowledge),
    do: {projection_knowledge, false}

  defp knowledge(account_id, actor, scope_ids, attrs, []) do
    query = %Query{
      account_id: account_id,
      actor: actor,
      scope_ids: scope_ids,
      text: Map.get(attrs, "query", ""),
      target: :knowledge,
      max_candidates: parse_int(Map.get(attrs, "limit"), 8)
    }

    result = Cartulary.Retrieval.retrieve(query, :fast)
    {result.candidates, true}
  end

  defp projection(account_id, actor, scope_id, cache_key) do
    ets_key = {account_id, scope_id, cache_key}

    case Cache.fetch(ets_key) do
      {:ok, projection} ->
        {projection, true}

      :error ->
        projection =
          Projection
          |> Ash.Query.filter(cache_key == ^cache_key and dirty == false)
          |> Ash.Query.set_tenant(account_id)
          |> Ash.read_one!(actor: actor)

        if projection, do: Cache.put(ets_key, projection)
        {projection, false}
    end
  end

  defp resolve_session_id(_account_id, _actor, _scope_ids, nil), do: nil

  defp resolve_session_id(account_id, actor, scope_ids, external_or_id) do
    query =
      case Ecto.UUID.cast(external_or_id) do
        {:ok, id} ->
          Ash.Query.filter(
            Session,
            scope_id in ^scope_ids and (id == ^id or external_id == ^external_or_id)
          )

        :error ->
          Ash.Query.filter(Session, scope_id in ^scope_ids and external_id == ^external_or_id)
      end

    query
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
    |> case do
      nil -> nil
      session -> session.id
    end
  end

  defp fit_budget(summary, profiles, cards, knowledge, budget) do
    {summary, remaining} = reserve(summary, budget)
    {profiles, remaining} = take_values(profiles, remaining)
    {cards, remaining} = take_values(cards, remaining)
    {knowledge, _remaining} = take_values(knowledge, remaining)
    {summary, profiles, cards, knowledge}
  end

  defp reserve(nil, budget), do: {nil, budget}

  defp reserve(value, budget) do
    size = encoded_size(value)
    if size <= budget, do: {value, budget - size}, else: {nil, budget}
  end

  defp take_values(values, budget) do
    {kept, remaining} =
      Enum.reduce_while(values, {[], budget}, fn value, {kept, remaining} ->
        size = encoded_size(value)

        if size <= remaining do
          {:cont, {[value | kept], remaining - size}}
        else
          {:halt, {kept, remaining}}
        end
      end)

    {Enum.reverse(kept), remaining}
  end

  defp encoded_size(value), do: value |> Jason.encode!() |> byte_size()

  defp parse_int(value, _default) when is_integer(value) and value > 0, do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _other -> default
    end
  end

  defp parse_int(_value, default), do: default

  defp retrieval_config(key) do
    :cartulary
    |> Application.fetch_env!(:retrieval_profiles)
    |> Keyword.fetch!(key)
  end
end
