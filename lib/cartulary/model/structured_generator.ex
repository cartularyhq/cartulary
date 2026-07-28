# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Model.StructuredGenerator do
  @moduledoc """
  Non-streaming structured generation with bounded validate-and-repair.

  Provider-native constrained decoding is used when available; this second
  Ash-backed validation loop is the portable baseline for weaker local models.
  """

  alias Cartulary.Model.Config
  alias Cartulary.Model.Gateway

  @max_repairs 2

  def generate(role, messages, schema, context, opts \\ [])
      when is_atom(schema) and is_list(messages) and is_map(context) do
    max_repairs =
      opts
      |> Keyword.get(:max_repairs, configured_max_repairs())
      |> max(0)
      |> min(@max_repairs)

    generate_attempt(role, messages, schema, context, opts, 0, max_repairs)
  end

  defp generate_attempt(role, messages, schema, context, opts, attempt, max_repairs) do
    call_opts = Keyword.put(opts, :repair_attempt, attempt)

    with {:ok, object, config} <-
           Gateway.structured_once(role, messages, schema.json_schema(), context, call_opts) do
      case schema.cast(object, context) do
        {:ok, value} ->
          {:ok, value, Config.provenance(config)}

        {:error, errors} when attempt < max_repairs ->
          generate_attempt(
            role,
            repair_messages(messages, object, errors),
            schema,
            context,
            opts,
            attempt + 1,
            max_repairs
          )

        {:error, errors} ->
          {:error, {:structured_validation_failed, errors}}
      end
    end
  end

  defp repair_messages(messages, object, errors) do
    messages ++
      [
        %{
          role: "user",
          content: """
          Repair the previous structured result so it matches the supplied schema.
          Preserve supported facts, do not invent facts, and return only the repaired object.
          Validation errors: #{Enum.join(errors, "; ")}
          Previous object: #{Jason.encode!(object)}
          """
        }
      ]
  end

  defp configured_max_repairs do
    :cartulary
    |> Application.get_env(:model_layer, [])
    |> Keyword.get(:max_repairs, @max_repairs)
  end
end
