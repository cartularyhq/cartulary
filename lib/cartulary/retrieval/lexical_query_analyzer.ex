# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Retrieval.LexicalQueryAnalyzer do
  @moduledoc """
  Produces the bounded, deterministic query representation used by lexical retrieval.

  Plain English questions lose only reviewed interrogative boilerplate. Names, dates, and
  ordinary content terms remain. Explicit websearch operators bypass normalization so quoted
  phrases and negation keep PostgreSQL's documented semantics.
  """

  @version "lexical-question-v1"
  @websearch_operators ~r/"|(?:^|\s)-\S|(?:^|\s)or(?:\s|$)/i
  @boilerplate MapSet.new(
                 ~w(a an are could did do does for from how is me tell that the to was what when where which who why would you your)
               )
  @synonym_groups [~w(destress stress relax calming therapeutic)]

  @doc "The version recorded with content-free retrieval diagnostics."
  def version, do: @version

  @doc """
  Analyzes one lexical query without calling a model or constructing SQL.

  `matching_text` is an OR-style term set. `proximity_text` is limited to the first four retained
  terms, keeping the ranking bonus bounded even for a long question.
  """
  def analyze(text) when is_binary(text) do
    if Regex.match?(@websearch_operators, text) do
      %{version: @version, mode: :websearch, matching_text: text, proximity_text: nil}
    else
      terms =
        text
        |> tokens()
        |> Enum.reject(&(String.downcase(&1) in @boilerplate))

      expanded = terms ++ Enum.flat_map(terms, &synonyms/1)

      %{
        version: @version,
        mode: :normalized,
        matching_text: expanded |> Enum.uniq_by(&String.downcase/1) |> Enum.join(" "),
        proximity_text: terms |> Enum.take(4) |> proximity_text()
      }
    end
  end

  def analyze(_text), do: analyze("")

  defp tokens(text), do: Regex.scan(~r/[\p{L}\p{N}][\p{L}\p{N}'-]*/u, text) |> List.flatten()

  defp synonyms(term) do
    normalized = String.downcase(term)

    Enum.find_value(@synonym_groups, [], fn group ->
      if normalized in group, do: List.delete(group, normalized)
    end)
  end

  defp proximity_text([]), do: nil
  defp proximity_text([_term]), do: nil
  defp proximity_text(terms), do: Enum.join(terms, " <4> ")
end
