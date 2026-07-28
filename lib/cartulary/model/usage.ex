# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Model.Usage do
  @moduledoc "The single durable usage-emission point for all F5 model calls."

  alias Cartulary.Clock
  alias Cartulary.Model.Config
  alias Cartulary.Model.Config.Role
  alias Cartulary.Operations.Metering
  alias Cartulary.Operations.UsageEvent

  @safe_metadata_keys ~w(error_class fallback repair_attempt result_count vector_count)

  def emit(%{account_id: account_id, actor: actor} = context, %Role{} = config, attrs)
      when is_binary(account_id) and not is_nil(actor) do
    usage = attrs |> Map.get(:usage, %{}) |> normalize_usage()
    metadata = attrs |> Map.get(:metadata, %{}) |> safe_metadata()
    provenance = Config.provenance(config)

    UsageEvent
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.Changeset.for_create(:record, %{
      call_id: Ecto.UUID.generate(),
      scope_id: Map.get(context, :scope_id),
      peer_id: Map.get(context, :peer_id),
      operation: to_string(Map.fetch!(attrs, :operation)),
      model_role: Atom.to_string(config.role),
      provider: provenance.provider,
      model_name: provenance.model,
      model_version: provenance.model_version,
      prompt_version: provenance.prompt_version,
      pipeline_version: provenance.pipeline_version,
      input_tokens: Map.get(usage, :input_tokens, 0),
      output_tokens: Map.get(usage, :output_tokens, 0),
      embedding_tokens: Map.get(usage, :embedding_tokens, 0),
      duration_ms: Map.fetch!(attrs, :duration_ms),
      status: to_string(Map.fetch!(attrs, :status)),
      metadata: metadata,
      occurred_at: Clock.utc_now()
    })
    |> Ash.create!(actor: pipeline_actor(actor))

    Metering.record_model(account_id, Map.get(context, :scope_id), usage)
    :ok
  end

  def emit(_context, _config, _attrs), do: :ok

  defp normalize_usage(usage) when is_map(usage) do
    %{
      input_tokens: non_negative(usage[:input_tokens] || usage["input_tokens"]),
      output_tokens: non_negative(usage[:output_tokens] || usage["output_tokens"]),
      embedding_tokens: non_negative(usage[:embedding_tokens] || usage["embedding_tokens"])
    }
  end

  defp normalize_usage(_usage), do: %{input_tokens: 0, output_tokens: 0, embedding_tokens: 0}

  defp non_negative(value) when is_integer(value) and value >= 0, do: value
  defp non_negative(_value), do: 0

  defp safe_metadata(metadata) when is_map(metadata) do
    metadata
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.take(@safe_metadata_keys)
  end

  defp safe_metadata(_metadata), do: %{}

  defp pipeline_actor(%_{} = actor) do
    actor
    |> Map.put(:role, :system)
    |> Map.put(:pipeline?, true)
  end

  defp pipeline_actor(actor) when is_map(actor) do
    actor
    |> Map.put(:role, :system)
    |> Map.put(:pipeline?, true)
  end
end
