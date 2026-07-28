# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Model.Reasoner do
  @moduledoc "Structured dream-time reasoner capability for the F2 slow lane."

  alias Cartulary.Model
  alias Cartulary.Model.Schema.Reasoning

  @prompt_version "reason-1"

  def reason(delta_and_working_set, context, opts \\ []) do
    messages = [
      %{
        role: "system",
        content: """
        Revisit the supplied delta and working set. Return only supported
        deductions, update candidates, and supports/contradicts/derived_from
        relations in the supplied schema. Never overwrite contradictions.
        """
      },
      %{role: "user", content: Jason.encode!(delta_and_working_set)}
    ]

    Model.generate_structured(
      :dream_reasoner,
      messages,
      Reasoning,
      context,
      Keyword.merge([task: :reasoning, prompt_version: @prompt_version], opts)
    )
  end
end
