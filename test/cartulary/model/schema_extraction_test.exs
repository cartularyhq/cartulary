# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Model.SchemaExtractionTest do
  @moduledoc """
  Pins `Cartulary.Model.Schema.Extraction.cast/2` confidence handling.

  Regression coverage for a bug where a provider that round-trips a JSON
  number as a quoted string (observed identically across unrelated backing
  models over the OpenRouter compat path) made every extraction fail
  validation with `confidence must be between 0 and 1` regardless of the
  actual value — a type problem being reported as a range problem. Numeric
  strings must now parse and range-check like native numbers; the range
  check itself, for both numbers and numeric strings, must still hold.
  """

  use ExUnit.Case, async: true

  alias Cartulary.Model.Schema.Extraction

  @account_id Ecto.UUID.generate()
  @scope_id Ecto.UUID.generate()

  defp context do
    %{
      account_id: @account_id,
      scope_id: @scope_id,
      known_peer_keys: ["avery"],
      source_peer_key: "avery"
    }
  end

  defp item(confidence) do
    %{
      "statement" => "Avery prefers weekly release summaries.",
      "kind" => "preference",
      "subject_type" => "peer",
      "subject_ref" => "avery",
      "confidence" => confidence,
      "sensitivity" => "internal",
      "target_level" => "peer",
      "update_operation" => "add",
      "hearsay" => false
    }
  end

  defp cast_confidence(confidence) do
    case Extraction.cast(%{"items" => [item(confidence)]}, context()) do
      {:ok, [candidate]} -> {:ok, candidate.confidence}
      {:error, errors} -> {:error, errors}
    end
  end

  test "accepts a native JSON number" do
    assert {:ok, 0.9} = cast_confidence(0.9)
  end

  test "accepts a numeric string, the observed provider quirk" do
    assert {:ok, 0.9} = cast_confidence("0.9")
  end

  test "accepts an integral numeric string" do
    assert {:ok, 1.0} = cast_confidence("1")
  end

  test "rejects a numeric value above 1" do
    assert {:error, ["items[0].confidence must be between 0 and 1"]} = cast_confidence(1.5)
  end

  test "rejects a numeric string above 1" do
    assert {:error, ["items[0].confidence must be between 0 and 1"]} = cast_confidence("1.5")
  end

  test "rejects a non-numeric string" do
    assert {:error, ["items[0].confidence must be between 0 and 1"]} = cast_confidence("high")
  end

  test "rejects a string with trailing garbage after the number" do
    assert {:error, ["items[0].confidence must be between 0 and 1"]} = cast_confidence("0.9abc")
  end

  test "rejects a missing confidence" do
    assert {:error, ["items[0].confidence must be between 0 and 1"]} = cast_confidence(nil)
  end
end
