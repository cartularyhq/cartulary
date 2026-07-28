# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.F6DocumentsConnectorsSyncTest.Provider do
  @moduledoc false

  @behaviour Cartulary.Model.Provider

  alias Cartulary.Model.Provider.Result

  @impl true
  def structured(_config, _messages, _schema, opts) do
    items =
      opts
      |> Keyword.fetch!(:observation)
      |> String.split(~r/(?<=[.!?])\s+|\n+/, trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(String.length(&1) < 8))
      |> Enum.map(fn statement ->
        %{
          "statement" => statement,
          "kind" => "fact",
          "subject_type" => "peer",
          "subject_ref" => Keyword.fetch!(opts, :source_peer_key),
          "confidence" => 0.82,
          "sensitivity" => "internal",
          "target_level" => "peer",
          "update_operation" => "add",
          "hearsay" => false,
          "expires_at" => nil,
          "revalidate_after" => nil,
          "relevant_from" => nil,
          "relevant_until" => nil
        }
      end)

    {:ok,
     %Result{
       value: %{"items" => items},
       usage: %{input_tokens: 12, output_tokens: length(items) * 6}
     }}
  end

  @impl true
  def embed(_config, texts, _opts) do
    vectors = Enum.map(texts, fn text -> [String.length(text) / 1_000, 0.5, 1.0] end)

    {:ok,
     %Result{
       value: vectors,
       usage: %{embedding_tokens: Enum.sum(Enum.map(texts, &String.length/1))}
     }}
  end

  @impl true
  def chat(_config, _messages, _opts), do: {:error, :not_used}

  @impl true
  def rerank(_config, _query, _documents, _opts), do: {:error, :not_used}
end

defmodule Cartulary.F6DocumentsConnectorsSyncTest.Connector do
  @moduledoc false

  @behaviour Cartulary.Documents.Connector

  def start! do
    case Agent.start(fn -> %{items: [], cursor: %{"page" => 0}, has_more?: false} end,
           name: __MODULE__
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  def stop do
    if pid = Process.whereis(__MODULE__), do: Agent.stop(pid)
    :ok
  end

  def put(page), do: Agent.update(__MODULE__, fn _state -> page end)

  @impl true
  def pull(_config, _cursor), do: {:ok, Agent.get(__MODULE__, & &1)}
end

defmodule Cartulary.F6DocumentsConnectorsSyncTest do
  use Cartulary.DataCase, async: false

  alias Cartulary.Actor
  alias Cartulary.DataLayer
  alias Cartulary.Documents
  alias Cartulary.Documents.BlobStore
  alias Cartulary.Documents.ConnectorConfig
  alias Cartulary.Documents.DocumentChunk
  alias Cartulary.Documents.Parser
  alias Cartulary.Knowledge.KnowledgeItem
  alias Cartulary.Knowledge.Provenance
  alias Cartulary.Memory
  alias Cartulary.Observations.Document
  alias Cartulary.Observations.DocumentVersion
  alias Cartulary.Pipeline.Idempotency

  require Ash.Query

  setup do
    original_documents = Application.fetch_env!(:cartulary, :documents)
    original_provider = Application.get_env(:cartulary, :model_provider)
    original_roles = Application.fetch_env!(:cartulary, :model_roles)
    blob_root = Path.join(System.tmp_dir!(), "cartulary-f6-#{System.unique_integer([:positive])}")

    documents =
      original_documents
      |> Keyword.put(:blob_adapter, Cartulary.Documents.BlobStore.Local)
      |> Keyword.put(:blob_root, blob_root)
      |> Keyword.put(:chunk_size, 48)
      |> Keyword.put(:chunk_overlap, 8)
      |> Keyword.put(:connector_adapters, %{
        "fixture" => Cartulary.F6DocumentsConnectorsSyncTest.Connector
      })

    roles =
      original_roles
      |> Keyword.update!(:embedder, fn config ->
        config
        |> Map.put(:provider, "fixture")
        |> Map.put(:model, "fixture-embedding")
        |> Map.put(:model_version, "1")
        |> Map.put(:embedding_dimensions, 3)
      end)
      |> Keyword.update!(:ingest_extractor, fn config ->
        config
        |> Map.put(:provider, "fixture")
        |> Map.put(:model, "fixture-extractor")
        |> Map.put(:model_version, "1")
      end)

    Application.put_env(:cartulary, :documents, documents)

    Application.put_env(
      :cartulary,
      :model_provider,
      Cartulary.F6DocumentsConnectorsSyncTest.Provider
    )

    Application.put_env(:cartulary, :model_roles, roles)
    Cartulary.F6DocumentsConnectorsSyncTest.Connector.start!()

    on_exit(fn ->
      Cartulary.F6DocumentsConnectorsSyncTest.Connector.stop()
      Application.put_env(:cartulary, :documents, original_documents)
      Application.put_env(:cartulary, :model_roles, original_roles)

      if original_provider do
        Application.put_env(:cartulary, :model_provider, original_provider)
      else
        Application.delete_env(:cartulary, :model_provider)
      end

      File.rm_rf(blob_root)
    end)

    :ok
  end

  test "native parsing, RAG chunking, pinned embeddings, and governed knowledge form one dual ingest" do
    %{account: account, actor: actor, scope: scope} = context!("f6-dual")

    assert {:ok, %{status: :created, document: document, version: version}} =
             Documents.ingest_bytes(actor, %{
               scope_id: scope.id,
               external_id: "handbook",
               title: "Release handbook",
               media_type: "text/markdown",
               bytes:
                 "# Release handbook\n\nFriday is the normal release day. Escalations use email."
             })

    assert version.content == nil
    assert version.blob_ref =~ "local://#{account.id}/"
    assert {:ok, _bytes} = BlobStore.get(version.blob_ref)

    assert {:ok, processed} =
             Documents.process_version_for_account(version.id, account.id)

    assert processed.processing_status == "complete"
    assert processed.chunk_count >= 2
    assert processed.embedded_chunk_count == processed.chunk_count

    %{chunks: chunks, provenances: provenances, knowledge: knowledge} =
      document_derivations(account.id, actor, document.id)

    assert Enum.all?(chunks, &(&1.embedding_dimensions == 3 and length(&1.embedding) == 3))
    assert Enum.all?(chunks, &(&1.status == "active"))
    assert Enum.all?(provenances, &(&1.source_type == "document"))
    assert Enum.all?(provenances, &(&1.document_version_id == version.id))
    assert Enum.all?(knowledge, &(&1.state in ~w(provisional held active)))
    assert Enum.all?(knowledge, &(&1.source_message_ids == []))

    assert {:ok, %{metadata: %{"parser" => "mdex"}, format: :markdown}} =
             Parser.extract("# Native markdown", "text/markdown")

    assert {:ok, %{text: extracted, metadata: %{"parser" => "extractous_ex"}}} =
             Parser.extract(
               "<html><body>Native office-style extraction</body></html>",
               "text/html"
             )

    assert extracted =~ "Native office-style extraction"
  end

  test "incremental connector sync detects hashes, supersedes prior knowledge, and tombstones deletes" do
    %{account: account, actor: actor, peer: peer, scope: scope} = context!("f6-sync")

    connector =
      Documents.register_connector(actor, %{
        scope_id: scope.id,
        name: "fixture-sync",
        kind: "fixture",
        schedule_seconds: 60,
        config: %{"folder" => "handbooks"},
        secret_ref: "env:F6_CONNECTOR_TOKEN"
      })

    put_connector_page(
      [
        connector_item(
          "policy",
          "Friday is the release day. The escalation policy is stable. Cross-source guidance remains authoritative."
        )
      ],
      1
    )

    assert {:ok, %{counts: %{created: 1}}} =
             Documents.sync_connector_for_account(connector.id, account.id)

    {document, [version_one]} = connector_document(account.id, actor, connector.id)
    assert {:ok, _processed} = Documents.process_version_for_account(version_one.id, account.id)

    assert {:ok, _message} =
             Memory.ingest_message(%{
               "account_key" => account.key,
               "session_id" => "f6-shared-provenance",
               "scope_path" => scope.path,
               "peer_key" => peer.key,
               "content" => "Cross-source guidance remains authoritative.",
               "sync_extract" => true
             })

    put_connector_page(
      [
        connector_item("policy", "Monday is the release day. The escalation policy is stable.")
      ],
      2
    )

    assert {:ok, %{counts: %{created: 1}}} =
             Documents.sync_connector_for_account(connector.id, account.id)

    {updated_document, [_processed_version_one, version_two]} =
      connector_document(account.id, actor, connector.id)

    assert updated_document.id == document.id
    assert version_two.version == 2
    assert {:ok, _processed} = Documents.process_version_for_account(version_two.id, account.id)

    knowledge = document_derivations(account.id, actor, document.id).knowledge
    friday = Enum.find(knowledge, &String.contains?(&1.statement, "Friday"))
    monday = Enum.find(knowledge, &String.contains?(&1.statement, "Monday"))
    stable = Enum.find(knowledge, &String.contains?(&1.statement, "stable"))
    shared = Enum.find(knowledge, &String.contains?(&1.statement, "Cross-source"))

    assert friday.state == "superseded"
    assert monday.state in ~w(provisional held active)
    refute stable.state == "superseded"
    refute shared.state == "superseded"

    assert provenance_count(account.id, actor, stable.id) == 2
    assert provenance_count(account.id, actor, shared.id) == 1

    assert {:ok, %{counts: %{unchanged: 1}}} =
             Documents.sync_connector_for_account(connector.id, account.id)

    {_document, versions_after_noop} = connector_document(account.id, actor, connector.id)
    assert length(versions_after_noop) == 2

    put_connector_page([%{external_id: "policy", deleted?: true}], 3)

    assert {:ok, %{counts: %{tombstoned: 1}}} =
             Documents.sync_connector_for_account(connector.id, account.id)

    {tombstoned, _versions} = connector_document(account.id, actor, connector.id)
    assert tombstoned.status == "tombstoned"
    assert %DateTime{} = tombstoned.tombstoned_at

    synced =
      ConnectorConfig
      |> Ash.Query.filter(id == ^connector.id)
      |> Ash.Query.set_tenant(account.id)
      |> Ash.read_one!(actor: actor)

    assert synced.cursor == %{"page" => 3}
    assert %DateTime{} = synced.last_synced_at

    assert Enum.all?(document_derivations(account.id, actor, document.id).chunks, fn chunk ->
             chunk.status == "tombstoned"
           end)

    shared_after_tombstone =
      document_derivations(account.id, actor, document.id).knowledge
      |> Enum.find(&String.contains?(&1.statement, "Cross-source"))

    refute shared_after_tombstone.state in ~w(retracted superseded)
  end

  test "document export carries verified blobs, excludes chunks, and import rebuilds after erasure" do
    %{account: account, actor: actor, scope: scope} = context!("f6-portability")

    assert {:ok, %{document: document, version: version}} =
             Documents.ingest_bytes(actor, %{
               scope_id: scope.id,
               external_id: "portable",
               title: "Portable document",
               media_type: "text/plain",
               bytes: "Portable source bytes produce governed document knowledge."
             })

    assert {:ok, _processed} = Documents.process_version_for_account(version.id, account.id)
    assert document_derivations(account.id, actor, document.id).chunks != []

    assert {:ok, bundle} = Documents.export_document(actor, document.id)
    assert bundle["manifest"]["schema"] == "f6-document-1"
    assert bundle["manifest"]["derived_chunks"] == "excluded_rebuild_on_import"
    assert [%{"bytes" => bytes}] = bundle["blobs"]
    assert bytes == "Portable source bytes produce governed document knowledge."

    blob_ref = version.blob_ref
    assert :ok = Documents.erase_document(actor, document.id)
    assert {:error, :enoent} = BlobStore.get(blob_ref)
    assert nil == read_document(account.id, actor, document.id)

    assert {:ok, [_imported]} = Documents.import_document(actor, bundle)

    imported =
      Document
      |> Ash.Query.filter(external_id == "portable")
      |> Ash.Query.set_tenant(account.id)
      |> Ash.read_one!(actor: actor)

    imported_versions = versions(account.id, actor, imported.id)
    assert length(imported_versions) == 1
    assert document_derivations(account.id, actor, imported.id).chunks == []

    assert {:ok, _processed} =
             Documents.process_version_for_account(hd(imported_versions).id, account.id)

    assert document_derivations(account.id, actor, imported.id).chunks != []
  end

  test "connector configs reject raw secrets and retain only references" do
    %{account: account, actor: actor, scope: scope} = context!("f6-secrets")

    assert_raise Ash.Error.Invalid, fn ->
      Documents.register_connector(actor, %{
        scope_id: scope.id,
        name: "unsafe",
        kind: "fixture",
        config: %{"client_secret" => "raw-secret"}
      })
    end

    assert_raise Ash.Error.Invalid, fn ->
      Documents.register_connector(actor, %{
        scope_id: scope.id,
        name: "unsafe-reference",
        kind: "fixture",
        secret_ref: "raw-secret"
      })
    end

    assert [] =
             ConnectorConfig
             |> Ash.Query.set_tenant(account.id)
             |> Ash.read!(actor: actor)
  end

  defp context!(account_key) do
    assert {:ok, _message} =
             Memory.ingest_message(%{
               "account_key" => account_key,
               "session_id" => "#{account_key}-setup",
               "scope_path" => "/f6/#{account_key}",
               "peer_key" => "#{account_key}-owner",
               "content" => "F6 setup observation is durable.",
               "sync_extract" => false
             })

    DataLayer.with_account_key(account_key, fn account, system_actor ->
      peer_key = "#{account_key}-owner"
      scope_path = "/f6/#{account_key}"

      peer =
        Cartulary.Accounts.Peer
        |> Ash.Query.filter(key == ^peer_key)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: system_actor)

      scope =
        Cartulary.Topology.Scope
        |> Ash.Query.filter(path == ^scope_path)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: system_actor)

      actor =
        Actor.for_account(account,
          peer_id: peer.id,
          role: :system,
          pipeline?: true,
          scope_ids: :all
        )

      %{account: account, actor: actor, peer: peer, scope: scope}
    end)
  end

  defp document_derivations(account_id, actor, document_id) do
    chunks =
      DocumentChunk
      |> Ash.Query.filter(document_id == ^document_id)
      |> Ash.Query.sort(position: :asc)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read!(actor: actor)

    version_ids = versions(account_id, actor, document_id) |> Enum.map(& &1.id)

    provenances =
      Provenance
      |> Ash.Query.filter(document_version_id in ^version_ids)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read!(actor: actor)

    knowledge_ids = provenances |> Enum.map(& &1.knowledge_item_id) |> Enum.uniq()

    knowledge =
      KnowledgeItem
      |> Ash.Query.filter(id in ^knowledge_ids)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read!(actor: actor)

    %{chunks: chunks, provenances: provenances, knowledge: knowledge}
  end

  defp connector_document(account_id, actor, connector_id) do
    document =
      Document
      |> Ash.Query.filter(connector_config_id == ^connector_id)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read_one!(actor: actor)

    {document, versions(account_id, actor, document.id)}
  end

  defp versions(account_id, actor, document_id) do
    DocumentVersion
    |> Ash.Query.filter(document_id == ^document_id)
    |> Ash.Query.sort(version: :asc)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
  end

  defp provenance_count(account_id, actor, knowledge_id) do
    Provenance
    |> Ash.Query.filter(knowledge_item_id == ^knowledge_id and source_type == "document")
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> length()
  end

  defp put_connector_page(items, page) do
    Cartulary.F6DocumentsConnectorsSyncTest.Connector.put(%{
      items: items,
      cursor: %{"page" => page},
      has_more?: false
    })
  end

  defp connector_item(external_id, bytes) do
    %{
      external_id: external_id,
      title: "Policy",
      media_type: "text/plain",
      bytes: bytes,
      source_uri: "fixture://policy",
      metadata: %{"revision" => Idempotency.content_hash(bytes)}
    }
  end

  defp read_document(account_id, actor, document_id) do
    Document
    |> Ash.Query.filter(id == ^document_id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
  end
end
