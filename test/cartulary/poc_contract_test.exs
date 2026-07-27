# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.PocContractTest do
  use Cartulary.DataCase, async: false

  alias Cartulary.Memory

  setup do
    original_api_key = System.get_env("OPENROUTER_API_KEY")
    original_models = Application.fetch_env!(:cartulary, :models)

    System.delete_env("OPENROUTER_API_KEY")
    Application.put_env(:cartulary, :models, Keyword.put(original_models, :api_key, nil))

    on_exit(fn ->
      if original_api_key do
        System.put_env("OPENROUTER_API_KEY", original_api_key)
      else
        System.delete_env("OPENROUTER_API_KEY")
      end

      Application.put_env(:cartulary, :models, original_models)
    end)

    :ok
  end

  test "ingest persists the raw message and pipeline-created knowledge lifecycle" do
    assert {:ok, message} =
             Memory.ingest_message(%{
               "account_key" => "contract-persistence",
               "session_id" => "session-1",
               "scope_path" => "/contract/persistence",
               "peer_key" => "agent-1",
               "role" => "user",
               "content" => "Avery prefers concise weekly release summaries."
             })

    assert message["content"] == "Avery prefers concise weekly release summaries."
    assert [knowledge] = message["knowledge"]
    assert knowledge["statement"] == "Avery prefers concise weekly release summaries."
    assert knowledge["extracting_model"] == "fallback:poc-0"
    assert knowledge["pipeline_version"] == "poc-0"
    assert knowledge["source_message_ids"] == [message["id"]]

    assert %{
             rows: [
               [
                 message_id,
                 "Avery prefers concise weekly release summaries.",
                 knowledge_id,
                 "active",
                 "poc_auto_gate"
               ]
             ]
           } =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT m.id, m.content, k.id, event.to_state, event.reason
               FROM messages AS m
               JOIN knowledge_items AS k ON m.id = ANY(k.source_message_ids)
               JOIN knowledge_lifecycle_events AS event ON event.knowledge_item_id = k.id
               WHERE m.id = $1
               """,
               [Ecto.UUID.dump!(message["id"])]
             )

    assert Ecto.UUID.load!(message_id) == message["id"]
    assert Ecto.UUID.load!(knowledge_id) == knowledge["id"]
  end

  test "knowledge inherits from ancestors down to descendants but never upward" do
    assert {:ok, parent_message} =
             Memory.ingest_message(%{
               "account_key" => "contract-inheritance",
               "session_id" => "parent-session",
               "scope_path" => "/contract/team",
               "peer_key" => "parent-agent",
               "content" => "The team architecture uses an append-only audit ledger."
             })

    assert {:ok, child_message} =
             Memory.ingest_message(%{
               "account_key" => "contract-inheritance",
               "session_id" => "child-session",
               "scope_path" => "/contract/team/project",
               "peer_key" => "child-agent",
               "content" => "The project release review happens every Friday."
             })

    parent_knowledge_id = parent_message["knowledge"] |> hd() |> Map.fetch!("id")
    child_knowledge_id = child_message["knowledge"] |> hd() |> Map.fetch!("id")

    descendant_ids =
      "contract-inheritance"
      |> knowledge_ids("/contract/team/project")
      |> MapSet.new()

    ancestor_ids =
      "contract-inheritance"
      |> knowledge_ids("/contract/team")
      |> MapSet.new()

    assert MapSet.member?(descendant_ids, parent_knowledge_id)
    assert MapSet.member?(descendant_ids, child_knowledge_id)
    assert MapSet.member?(ancestor_ids, parent_knowledge_id)
    refute MapSet.member?(ancestor_ids, child_knowledge_id)
  end

  defp knowledge_ids(account_key, scope_path) do
    %{"account_key" => account_key, "scope_path" => scope_path}
    |> Memory.query_knowledge()
    |> Enum.map(& &1["id"])
  end
end
