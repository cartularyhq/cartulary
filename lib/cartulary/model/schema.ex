# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Model.Schema do
  @moduledoc "Structured-output schema contract used by bounded validation and repair."

  @callback json_schema() :: map()
  @callback cast(map(), map()) :: {:ok, term()} | {:error, [String.t()]}
end

defmodule Cartulary.Model.Schema.Extraction do
  @moduledoc """
  Structured extraction schema derived from the authoritative KnowledgeItem
  Ash attributes and validated through its pipeline create action.
  """

  @behaviour Cartulary.Model.Schema

  alias Cartulary.Knowledge.KnowledgeItem

  @knowledge_fields ~w(statement kind confidence sensitivity target_level)a
  @temporal_fields ~w(expires_at revalidate_after relevant_from relevant_until)a
  @subject_types ~w(peer scope)
  @operations ~w(add merge supersede_candidate no_op)
  @allowed %{
    kind: ~w(fact preference event relation skill),
    sensitivity: ~w(public internal personal restricted),
    target_level: ~w(peer scope account)
  }

  @impl true
  def json_schema do
    knowledge_properties =
      Map.new(@knowledge_fields, fn name ->
        {Atom.to_string(name), attribute_schema(name)}
      end)

    temporal_properties =
      Map.new(@temporal_fields, fn name ->
        {Atom.to_string(name),
         %{
           "anyOf" => [
             %{"type" => "string", "format" => "date-time"},
             %{"type" => "null"}
           ]
         }}
      end)

    candidate =
      %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" =>
          knowledge_properties
          |> Map.merge(temporal_properties)
          |> Map.merge(%{
            "subject_type" => %{"type" => "string", "enum" => @subject_types},
            "subject_ref" => %{"type" => "string", "minLength" => 1},
            "update_operation" => %{"type" => "string", "enum" => @operations},
            "hearsay" => %{"type" => "boolean"}
          }),
        "required" =>
          ~w(statement kind subject_type subject_ref confidence sensitivity target_level update_operation hearsay)
      }

    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "items" => %{"type" => "array", "items" => candidate, "maxItems" => 24}
      },
      "required" => ["items"]
    }
  end

  @impl true
  def cast(object, context) when is_map(object) and is_map(context) do
    case fetch(object, "items") do
      items when is_list(items) ->
        items
        |> Enum.with_index()
        |> Enum.reduce({[], []}, fn {item, index}, {valid, errors} ->
          case cast_item(item, context) do
            {:ok, casted} -> {[casted | valid], errors}
            {:error, item_errors} -> {valid, errors ++ prefix_errors(item_errors, index)}
          end
        end)
        |> case do
          {valid, []} -> {:ok, Enum.reverse(valid)}
          {_valid, errors} -> {:error, errors}
        end

      _other ->
        {:error, ["items must be an array"]}
    end
  end

  def cast(_object, _context), do: {:error, ["response must be an object"]}

  defp cast_item(item, context) when is_map(item) do
    with {:ok, statement} <- non_empty_string(item, "statement"),
         {:ok, kind} <- enum(item, "kind", allowed(:kind)),
         {:ok, subject_type} <- enum(item, "subject_type", @subject_types),
         {:ok, subject_ref} <- valid_subject_ref(item, subject_type, context),
         {:ok, confidence} <- confidence(item),
         {:ok, sensitivity} <- enum(item, "sensitivity", allowed(:sensitivity)),
         {:ok, target_level} <- enum(item, "target_level", allowed(:target_level)),
         {:ok, operation} <- enum(item, "update_operation", @operations),
         {:ok, hearsay} <- boolean(item, "hearsay"),
         {:ok, temporal} <- temporal(item),
         :ok <- temporal_order(temporal),
         casted <-
           %{
             statement: statement,
             kind: kind,
             subject_type: subject_type,
             subject_ref: subject_ref,
             confidence: hearsay_confidence(confidence, hearsay, subject_ref, context),
             sensitivity: sensitivity,
             target_level: target_level,
             update_operation: operation,
             hearsay: hearsay
           }
           |> Map.merge(temporal),
         :ok <- validate_ash_action(casted, context) do
      {:ok, casted}
    end
  end

  defp cast_item(_item, _context), do: {:error, ["candidate must be an object"]}

  defp validate_ash_action(item, context) do
    attrs =
      item
      |> Map.take(@knowledge_fields ++ @temporal_fields)
      |> Map.merge(%{
        scope_id: Map.fetch!(context, :scope_id),
        subject_peer_id: Map.get(context, :source_peer_id),
        state: "proposed",
        source_message_ids: List.wrap(Map.get(context, :message_id)),
        extracting_provider: "schema-validation",
        extracting_model: "schema-validation",
        extracting_model_version: "schema-validation",
        prompt_version: "schema-validation",
        pipeline_version: "f5-1"
      })

    changeset =
      KnowledgeItem
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_tenant(Map.fetch!(context, :account_id))
      |> Ash.Changeset.for_create(:create_from_pipeline, attrs)

    if changeset.valid? do
      :ok
    else
      {:error, ["candidate does not satisfy KnowledgeItem.create_from_pipeline"]}
    end
  end

  defp attribute_schema(name) do
    attribute = Ash.Resource.Info.attribute(KnowledgeItem, name)
    constraints = attribute.constraints || []

    base =
      case attribute.type do
        :float -> %{"type" => "number"}
        :integer -> %{"type" => "integer"}
        _other -> %{"type" => "string"}
      end

    base
    |> maybe_put("enum", Map.get(@allowed, name))
    |> maybe_put("minimum", constraints[:min])
    |> maybe_put("maximum", constraints[:max])
    |> maybe_put("minLength", constraints[:min_length])
  end

  defp allowed(name), do: Map.fetch!(@allowed, name)

  defp non_empty_string(item, key) do
    case fetch(item, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, ["#{key} must not be blank"]}
          trimmed -> {:ok, trimmed}
        end

      _other ->
        {:error, ["#{key} must be a string"]}
    end
  end

  defp valid_subject_ref(item, "peer", context) do
    with {:ok, ref} <- non_empty_string(item, "subject_ref") do
      if ref in Map.get(context, :known_peer_keys, []) do
        {:ok, ref}
      else
        {:error, ["subject_ref must name a known peer"]}
      end
    end
  end

  defp valid_subject_ref(item, "scope", context) do
    with {:ok, ref} <- non_empty_string(item, "subject_ref") do
      if ref == Map.fetch!(context, :scope_path) do
        {:ok, ref}
      else
        {:error, ["subject_ref must be the current scope path"]}
      end
    end
  end

  defp enum(item, key, allowed) do
    case fetch(item, key) do
      value when is_binary(value) ->
        normalized = String.downcase(value)
        if normalized in allowed, do: {:ok, normalized}, else: {:error, ["#{key} is invalid"]}

      _other ->
        {:error, ["#{key} must be a string"]}
    end
  end

  defp confidence(item) do
    case fetch(item, "confidence") do
      value when is_number(value) and value >= 0.0 and value <= 1.0 ->
        {:ok, value / 1}

      _other ->
        {:error, ["confidence must be between 0 and 1"]}
    end
  end

  defp boolean(item, key) do
    case fetch(item, key) do
      value when is_boolean(value) -> {:ok, value}
      _other -> {:error, ["#{key} must be a boolean"]}
    end
  end

  defp temporal(item) do
    @temporal_fields
    |> Enum.reduce_while({:ok, %{}}, fn field, {:ok, acc} ->
      case datetime(fetch(item, Atom.to_string(field))) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, field, value)}}
        {:error, reason} -> {:halt, {:error, ["#{field} #{reason}"]}}
      end
    end)
  end

  defp datetime(nil), do: {:ok, nil}
  defp datetime(""), do: {:ok, nil}
  defp datetime(%DateTime{} = value), do: {:ok, value}

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, "must be an ISO-8601 timestamp or null"}
    end
  end

  defp datetime(_value), do: {:error, "must be an ISO-8601 timestamp or null"}

  defp temporal_order(%{relevant_from: from, relevant_until: until})
       when not is_nil(from) and not is_nil(until) do
    if DateTime.compare(from, until) in [:lt, :eq],
      do: :ok,
      else: {:error, ["relevant_from must not be after relevant_until"]}
  end

  defp temporal_order(_temporal), do: :ok

  defp hearsay_confidence(confidence, hearsay, subject_ref, context) do
    if hearsay or subject_ref != Map.get(context, :source_peer_key) do
      Float.round(confidence * 0.75, 4)
    else
      confidence
    end
  end

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(map, fn
          {candidate, value} when is_atom(candidate) ->
            if Atom.to_string(candidate) == key, do: {:found, value}

          {_candidate, _value} ->
            nil
        end)
        |> case do
          {:found, value} -> value
          nil -> nil
        end
    end
  end

  defp prefix_errors(errors, index), do: Enum.map(errors, &"items[#{index}].#{&1}")

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

defmodule Cartulary.Model.Schema.Reasoning do
  @moduledoc "Dream-time structured output reusing the Ash extraction candidate schema."

  @behaviour Cartulary.Model.Schema

  @impl true
  def json_schema do
    extraction = Cartulary.Model.Schema.Extraction.json_schema()

    extraction
    |> put_in(["properties", "relations"], %{
      "type" => "array",
      "items" => %{
        "type" => "object",
        "properties" => %{
          "source_id" => %{"type" => "string"},
          "target_id" => %{"type" => "string"},
          "kind" => %{"type" => "string", "enum" => ~w(supports contradicts derived_from)}
        },
        "required" => ~w(source_id target_id kind)
      }
    })
    |> Map.put("required", ["items", "relations"])
  end

  @impl true
  def cast(object, context) do
    with {:ok, items} <- Cartulary.Model.Schema.Extraction.cast(object, context),
         relations when is_list(relations) <- Map.get(object, "relations", []) do
      {:ok, %{items: items, relations: relations}}
    else
      {:error, errors} -> {:error, errors}
      _other -> {:error, ["relations must be an array"]}
    end
  end
end

defmodule Cartulary.Model.Schema.DialecticAnswer do
  @moduledoc false

  @behaviour Cartulary.Model.Schema

  @impl true
  def json_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "answer" => %{"type" => "string"},
        "citations" => %{"type" => "array", "items" => %{"type" => "string"}},
        "abstained" => %{"type" => "boolean"}
      },
      "required" => ~w(answer citations abstained)
    }
  end

  @impl true
  def cast(object, _context) when is_map(object) do
    answer = Map.get(object, "answer", Map.get(object, :answer))
    citations = Map.get(object, "citations", Map.get(object, :citations))
    abstained = Map.get(object, "abstained", Map.get(object, :abstained))

    if is_binary(answer) and is_list(citations) and Enum.all?(citations, &is_binary/1) and
         is_boolean(abstained) do
      {:ok, %{answer: answer, citations: citations, abstained: abstained}}
    else
      {:error, ["dialectic answer does not satisfy its response schema"]}
    end
  end

  def cast(_object, _context), do: {:error, ["response must be an object"]}
end
