# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.F10PortabilityPackagingOperationsTest do
  use Cartulary.DataCase, async: false

  alias Cartulary.DataLayer
  alias Cartulary.Memory
  alias Cartulary.Operations.Health
  alias Cartulary.Operations.Metering
  alias Cartulary.Portability
  alias Cartulary.Portability.AuditVerifier
  alias Cartulary.Portability.Registry

  test "logical export is self-describing, checksum verified, and excludes secrets and caches" do
    account_key = "f10-export-#{System.unique_integer([:positive])}"

    assert {:ok, _message} =
             Memory.ingest_message(%{
               "account_key" => account_key,
               "session_id" => "portable-session",
               "scope_path" => "/f10/portable",
               "peer_key" => "portable-peer",
               "role" => "user",
               "content" => "Avery prefers portable weekly summaries."
             })

    {_account, actor} =
      DataLayer.with_account_key(
        account_key,
        [role: :system, pipeline?: true],
        fn account, actor -> {account, actor} end
      )

    path = temp_path("account.tar.gz")
    on_exit(fn -> File.rm(path) end)

    assert {:ok, exported} = Portability.export(actor, path)
    assert exported.schema == "cartulary-account-1"
    assert exported.resource_counts["messages"] == 1
    assert exported.resource_counts["audit_events"] >= 4
    assert exported.blob_count == 0
    assert File.regular?(path)

    assert {:ok, validated} = Portability.validate(path)
    assert validated.account_id == actor.account_id
    assert validated.audit["last_hash"] == exported.audit["last_hash"]

    refute Cartulary.Accounts.ApiKey in Enum.map(Registry.resources(), &elem(&1, 1))
    assert Cartulary.Knowledge.Projection in Registry.derived_resources()
    assert :hashed_password in Registry.excluded_attributes(Cartulary.Accounts.Peer)
    assert :embedding in Registry.excluded_attributes(Cartulary.Knowledge.KnowledgeItem)
  end

  test "audit verification rejects any changed event" do
    events = [
      audit_row(nil, "one", "2026-07-28T10:00:00.000000Z"),
      audit_row(:previous, "two", "2026-07-28T10:00:01.000000Z")
    ]

    [first, second] = events
    first_hash = event_hash(first)
    first = Map.put(first, "event_hash", first_hash)

    second =
      second
      |> Map.put("previous_hash", first_hash)
      |> then(&Map.put(&1, "event_hash", event_hash(&1)))

    assert {:ok, %{count: 2}} = AuditVerifier.verify([first, second])

    changed = Map.put(second, "metadata", %{"count" => 999})
    assert {:error, {:audit_event_hash_mismatch, "two"}} = AuditVerifier.verify([first, changed])
  end

  test "readiness covers database, Oban, queues, and model role configuration" do
    result = Health.readiness()

    assert result.status == "ready"
    assert result.checks.database.status == "ok"
    assert result.checks.oban.status == "ok"
    assert result.checks.queues.status == "ok"
    assert result.checks.model_roles.status == "ok"
    assert map_size(result.checks.model_roles.configured) == 4
  end

  test "exact API metering feeds self-host cost and budget visibility" do
    account_key = "f10-metering-#{System.unique_integer([:positive])}"

    {_account, actor} =
      DataLayer.with_account_key(
        account_key,
        [role: :account_admin, pipeline?: true],
        fn account, actor -> {account, actor} end
      )

    assert :ok =
             Metering.record_api(actor, %{
               operation: "api.ingest",
               http_status: 200,
               status: "ok"
             })

    summary = Metering.summary(actor)
    assert summary.event_count == 1
    assert summary.api_requests == 1
    assert summary.ingests == 1
    assert summary.tokens == %{input: 0, output: 0, embedding: 0}
    assert is_integer(summary.logical_storage_bytes)
    assert summary.estimated_model_cost == 0.0
  end

  test "production JSON logs redact credentials and drop unreviewed metadata" do
    line =
      Cartulary.Observability.JSONFormatter.format(
        %{
          level: :info,
          msg:
            {:string,
             "authorization=Bearer secret-token password=hunter2 api_key=provider-secret"},
          meta: %{
            time: System.system_time(:microsecond),
            request_id: "request-1",
            content: "private knowledge"
          }
        },
        %{}
      )
      |> IO.iodata_to_binary()
      |> Jason.decode!()

    assert line["metadata"] == %{"request_id" => "request-1"}
    assert line["message"] =~ "[REDACTED]"
    refute line["message"] =~ "secret-token"
    refute line["message"] =~ "hunter2"
    refute line["message"] =~ "provider-secret"
    refute line["metadata"] |> Map.has_key?("content")
  end

  test "packaging pins pg0 and keeps containers on stock Postgres" do
    assert File.read!("rel/pg0/VERSION") == "0.14.2\n"

    checksums = File.read!("rel/pg0/checksums.txt")
    assert checksums =~ "pg0-darwin-aarch64"
    assert checksums =~ "pg0-linux-x86_64-gnu"
    assert checksums =~ "pg0-windows-x86_64.exe"
    assert File.read!("scripts/package-release.ps1") =~ "Get-FileHash -Algorithm SHA256"

    dockerfile = File.read!("Dockerfile")
    assert dockerfile =~ "RUST_IMAGE=rust:1.85-slim-bookworm"
    assert dockerfile =~ "USER cartulary"
    refute dockerfile =~ "pg0 start"

    compose = File.read!("compose.yml")
    assert compose =~ "pgvector/pgvector:pg18-bookworm"
    assert compose =~ "profiles: [observability]"
    refute compose =~ "redis"
  end

  defp audit_row(previous_hash, id, occurred_at) do
    %{
      "id" => id,
      "account_id" => "018fc0a0-0000-7000-8000-000000000001",
      "category" => "configuration",
      "action" => "test",
      "resource_type" => "test",
      "resource_id" => nil,
      "content_hash" => nil,
      "metadata" => %{"count" => 1},
      "occurred_at" => occurred_at,
      "inserted_at" => occurred_at,
      "previous_hash" => previous_hash,
      "event_hash" => nil
    }
  end

  defp event_hash(event) do
    Cartulary.Governance.Audit.content_hash(%{
      account_id: event["account_id"],
      category: event["category"],
      action: event["action"],
      resource_type: event["resource_type"],
      resource_id: event["resource_id"],
      content_hash: event["content_hash"],
      metadata: event["metadata"],
      occurred_at: event["occurred_at"],
      previous_hash: event["previous_hash"]
    })
  end

  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "cartulary-f10-#{System.unique_integer([:positive])}-#{name}"
    )
  end
end
