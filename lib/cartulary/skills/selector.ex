# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Skills.Selector do
  @moduledoc """
  The small declarative language a human uses to say what a skill requires, and the validator
  that normalizes it.

  A requirement answers four questions: what to call this rule (`key`), what kind of governed
  knowledge counts (`selector`), whether missing it stops the skill (`level`), and where the
  answer is allowed to come from (`source_policy`). An optional `freshness` window and an
  optional `prompt` complete it.

  ## Why metadata and not text

  A selector matches recorded fields — statement kind, subject, sensitivity, target level,
  verification state, minimum confidence, minimum corroboration, provenance source type. It
  cannot express "a statement mentioning the launch date", because that would require search or
  a model, and readiness must be deterministic, cheap, and explainable. If a rule cannot be
  written in these terms, the missing concept belongs in the knowledge metadata, not here.

  ## The shape

      %{
        "key" => "brand-voice",
        "description" => "Current brand voice",
        "selector" => %{
          "kind" => ["preference"],
          "subject" => "scope",
          "sensitivity" => ["internal"],
          "target_level" => ["scope"],
          "source_types" => ["message"],
          "verification" => ["auto_verified"],
          "minimum_confidence" => 0.7,
          "minimum_corroboration" => 1
        },
        "level" => "required",
        "source_policy" => "either",
        "freshness" => %{"revalidated_within_seconds" => 2_592_000},
        "prompt" => "How should this scope's brand voice sound?",
        "enabled" => true
      }

  Every selector field is optional and an omitted one is dropped rather than enforced — except
  `subject`, which is always stored and defaults to `"either"`, meaning the statement must be
  about the peer under check or about a scope. `key`, `level`, and `source_policy` are mandatory
  for an enabled requirement.

  ## Normalization is part of the contract

  Validation does not merely accept or reject — it returns a canonical form, and the resource
  refuses to store anything that is not already identical to that canonical form. Scalars become
  one-element lists, `subject` is filled in with its default, absent selector clauses are
  dropped, and a prompt is synthesized when the author did not write one. Because storage
  matches the canonical form exactly, the readiness engine can evaluate stored requirements
  verbatim with no normalization step of its own, and a reviewer reading a stored card sees
  precisely what will be evaluated.

  ## Levels and source policies

  * `level` — `required` blocks the skill when unsatisfied; `preferred` only warns.
  * `source_policy` — `ask-peer` requires the answer to have come from the checked peer's own
    message; `from-memory` and `either` accept any governed source. An unsatisfied `ask-peer` or
    `either` gap carries an elicitation prompt; a `from-memory` gap never does.

  ## Mistakes to avoid

  * Do not add a free-text matching clause. That would make readiness depend on a model.
  * Do not weaken the "stored equals normalized" rule to accept convenient shorthand from a UI;
    normalize at the edge instead, before publishing.
  * A disabled requirement is not a comment — it is a tombstone that deletes an inherited key,
    so its `key` still matters even though the rest of it is discarded.
  """

  # The version identity of this language, currently `f9-1`. It is stored on every published
  # card and echoed in every readiness report so a client can tell which grammar it is reading.
  # Changing it is a deliberate contract transition: publishing rejects cards whose version
  # differs from this value, so a change obliges migrating or re-publishing existing cards and
  # recording the transition in the changelog.
  @schema_version "f9-1"

  # `required` blocks the skill when unsatisfied; `preferred` only produces a warning.
  @levels ~w(required preferred)

  # Where an answer may come from. `ask-peer` demands the checked peer's own message as the
  # source and so may prompt them; `from-memory` accepts any governed source and never prompts.
  @source_policies ~w(from-memory ask-peer either)

  # The vocabularies below are closed rather than free-form so that a typo in an authored card
  # is rejected at publish time instead of quietly matching nothing forever, which would look
  # like a permanent gap with no explanation.
  #
  # `@kinds`, `@sensitivities`, and `@target_levels` are the same lists the knowledge resource
  # validates its own attributes against. `@source_types` matches the two values a provenance
  # row can carry. `@subjects` is a matching mode of this language, not a stored field.
  #
  # `@verification_states` is neither a superset nor a subset of what governance writes:
  # `peer_verified` and `curator_verified` are accepted here but are not values the engine
  # produces (it writes `subject_confirmed` and `curator_approved`), and several states it does
  # write are not selectable. A selector naming a state nothing carries matches nothing.
  @kinds ~w(fact preference event relation skill)
  @subjects ~w(peer scope either)
  @sensitivities ~w(public internal personal restricted)
  @target_levels ~w(peer scope account)
  @source_types ~w(message document)
  @verification_states ~w(
    pending pending_human auto_verified peer_verified curator_verified stale
  )

  # Allowlists of accepted map keys. Anything else is an error rather than being ignored: a
  # misspelled constraint that is silently dropped would widen a requirement without anyone
  # noticing, which is the failure mode this language most needs to avoid.
  @requirement_keys ~w(
    key description selector level source_policy freshness prompt enabled
  )
  @selector_keys ~w(
    kind subject sensitivity target_level source_types verification
    minimum_confidence minimum_corroboration
  )
  @freshness_keys ~w(revalidated_within_seconds)

  @doc """
  Returns the version identity of the selector language this build implements.

  Cards are published with this value and rejected if they carry any other, so it is also the
  compatibility check between a stored card and the running code.
  """
  def schema_version, do: @schema_version

  @doc """
  Validates and normalizes a whole requirement list.

  Returns `{:ok, normalized}` with the requirements in their canonical form and original order,
  or `{:error, message}` with a human-readable message naming the offending requirement.
  Validation stops at the first error rather than collecting all of them.

  Rejects duplicate keys across the list: a key identifies a requirement for inheritance and
  override, so two requirements sharing one within a single card would make the effective
  contract depend on evaluation order.

  A non-list argument is an error, not a crash.
  """
  def validate_requirements(requirements) when is_list(requirements) do
    requirements
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn {requirement, index},
                                                     {:ok, normalized, keys} ->
      case normalize_requirement(requirement, index) do
        {:ok, %{"key" => key} = value} ->
          if MapSet.member?(keys, key) do
            {:halt, {:error, "requirement #{index} duplicates key #{inspect(key)}"}}
          else
            {:cont, {:ok, [value | normalized], MapSet.put(keys, key)}}
          end

        {:error, message} ->
          {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, normalized, _keys} -> {:ok, Enum.reverse(normalized)}
      {:error, _message} = error -> error
    end
  end

  def validate_requirements(_requirements), do: {:error, "requirements must be a list"}

  @doc """
  Validates and normalizes one requirement map.

  Accepts string or atom keys. `index` only appears in error messages, to identify which entry
  of a list failed; it has no effect on the result.

  Returns `{:ok, normalized}` or `{:error, message}`. A requirement with `"enabled" => false`
  normalizes to just its key and that flag — the rest is discarded — because a disabled
  requirement exists solely to remove an inherited key of the same name in a descendant scope,
  and keeping a body would suggest it still constrains something.

  Enabled requirements come back with every optional selector field either normalized or
  removed, `subject` defaulted to `"either"`, and a `prompt` synthesized from the description or
  the key when the author supplied none.
  """
  def normalize_requirement(requirement, index \\ 0)

  def normalize_requirement(requirement, index) when is_map(requirement) do
    requirement = stringify_keys(requirement)

    with :ok <- reject_unknown(requirement, @requirement_keys, "requirement #{index}"),
         {:ok, key} <- slug(requirement["key"], "requirement #{index} key"),
         {:ok, enabled} <- boolean(Map.get(requirement, "enabled", true), key) do
      if enabled do
        normalize_enabled_requirement(requirement, key)
      else
        {:ok, %{"key" => key, "enabled" => false}}
      end
    end
  end

  def normalize_requirement(_requirement, index),
    do: {:error, "requirement #{index} must be an object"}

  # An enabled requirement always comes out with the full key set, even where the value is nil,
  # so every stored requirement has the same shape and the readiness engine never has to guess
  # whether an absent key means "unset" or "older card".
  #
  # An omitted selector normalizes to `%{"subject" => "either"}` — the default subject is always
  # written out — so it matches any governed knowledge in scope that is about the peer under
  # check or about a scope. That is a legitimate requirement ("we must know something here"),
  # not a mistake.
  defp normalize_enabled_requirement(requirement, key) do
    with {:ok, level} <- member(requirement["level"], @levels, "requirement #{key} level"),
         {:ok, source_policy} <-
           member(
             requirement["source_policy"],
             @source_policies,
             "requirement #{key} source_policy"
           ),
         {:ok, selector} <- normalize_selector(requirement["selector"] || %{}, key),
         {:ok, freshness} <- normalize_freshness(requirement["freshness"], key) do
      description = optional_string(requirement["description"])

      prompt =
        requirement["prompt"]
        |> optional_string()
        |> default_prompt(description, key)

      {:ok,
       %{
         "key" => key,
         "description" => description,
         "selector" => selector,
         "level" => level,
         "source_policy" => source_policy,
         "freshness" => freshness,
         "prompt" => prompt,
         "enabled" => true
       }}
    end
  end

  # Each clause is validated against its closed vocabulary and then compacted away if it was
  # absent, so the stored selector contains only the constraints the author actually wrote.
  # `subject` is the one exception: it is always present, defaulted to `either`, because the
  # matcher has no clause for a missing subject.
  defp normalize_selector(selector, key) when is_map(selector) do
    selector = stringify_keys(selector)

    with :ok <- reject_unknown(selector, @selector_keys, "requirement #{key} selector"),
         {:ok, kinds} <- members(selector["kind"], @kinds, "requirement #{key} kind"),
         {:ok, subject} <-
           optional_member(selector["subject"], @subjects, "either", "requirement #{key} subject"),
         {:ok, sensitivities} <-
           members(
             selector["sensitivity"],
             @sensitivities,
             "requirement #{key} sensitivity"
           ),
         {:ok, target_levels} <-
           members(
             selector["target_level"],
             @target_levels,
             "requirement #{key} target_level"
           ),
         {:ok, source_types} <-
           members(selector["source_types"], @source_types, "requirement #{key} source_types"),
         {:ok, verification} <-
           members(
             selector["verification"],
             @verification_states,
             "requirement #{key} verification"
           ),
         # Bounds are 0.0 and 1.0 because statement confidence is a probability-like fraction on
         # that scale. A value outside it would silently match everything or nothing.
         {:ok, minimum_confidence} <-
           bounded_number(
             selector["minimum_confidence"],
             0.0,
             1.0,
             "requirement #{key} minimum_confidence"
           ),
         {:ok, minimum_corroboration} <-
           positive_integer(
             selector["minimum_corroboration"],
             "requirement #{key} minimum_corroboration"
           ) do
      {:ok,
       compact(%{
         "kind" => kinds,
         "subject" => subject,
         "sensitivity" => sensitivities,
         "target_level" => target_levels,
         "source_types" => source_types,
         "verification" => verification,
         "minimum_confidence" => minimum_confidence,
         "minimum_corroboration" => minimum_corroboration
       })}
    end
  end

  defp normalize_selector(_selector, key),
    do: {:error, "requirement #{key} selector must be an object"}

  # Freshness is optional, but writing the block and leaving it empty is an error: a requirement
  # that mentions recency and then constrains nothing is almost certainly a mistake in the card.
  # The window is in seconds and must be positive; zero or a negative window is unsatisfiable.
  defp normalize_freshness(nil, _key), do: {:ok, nil}

  defp normalize_freshness(freshness, key) when is_map(freshness) do
    freshness = stringify_keys(freshness)

    with :ok <- reject_unknown(freshness, @freshness_keys, "requirement #{key} freshness"),
         {:ok, seconds} <-
           positive_integer(
             freshness["revalidated_within_seconds"],
             "requirement #{key} revalidated_within_seconds",
             required?: true
           ) do
      {:ok, %{"revalidated_within_seconds" => seconds}}
    end
  end

  defp normalize_freshness(_freshness, key),
    do: {:error, "requirement #{key} freshness must be an object"}

  # Unknown keys are rejected rather than ignored. Silently dropping a misspelled constraint
  # would publish a requirement weaker than the one the author reviewed.
  defp reject_unknown(map, allowed, label) do
    case Map.keys(map) -- allowed do
      [] -> :ok
      unknown -> {:error, "#{label} has unknown keys: #{Enum.join(Enum.sort(unknown), ", ")}"}
    end
  end

  # Requirement keys are lowercase slugs: a letter, then letters, digits, and single dashes or
  # underscores between segments. Keys are the join field for inheritance across scopes, so they
  # have to be stable, comparable, and free of case or whitespace variants that would look
  # identical to a human but fail to override an inherited rule.
  defp slug(value, label) when is_binary(value) do
    value = String.trim(value)

    if Regex.match?(~r/\A[a-z][a-z0-9]*(?:[-_][a-z0-9]+)*\z/, value) do
      {:ok, value}
    else
      {:error, "#{label} must be a lowercase slug"}
    end
  end

  defp slug(_value, label), do: {:error, "#{label} is required"}

  defp member(value, allowed, label) do
    if value in allowed do
      {:ok, value}
    else
      {:error, "#{label} must be one of #{inspect(allowed)}"}
    end
  end

  defp optional_member(nil, _allowed, default, _label), do: {:ok, default}
  defp optional_member(value, allowed, _default, label), do: member(value, allowed, label)

  # A scalar is accepted and normalized to a one-element list, so authors may write
  # `"kind" => "preference"` and the matcher only ever deals with lists. An explicitly empty
  # list is rejected: it would match nothing, which is an unsatisfiable requirement rather than
  # the "no constraint" the author probably meant — omitting the key expresses that.
  defp members(nil, _allowed, _label), do: {:ok, nil}

  defp members(value, allowed, label) do
    values = if is_list(value), do: value, else: [value]

    if values != [] and Enum.all?(values, &(&1 in allowed)) do
      {:ok, Enum.uniq(values)}
    else
      {:error, "#{label} must contain only #{inspect(allowed)}"}
    end
  end

  # Integers are coerced to floats so that a card written with `1` and one written with `1.0`
  # normalize to the same stored value; otherwise two identical-looking cards would differ
  # byte-for-byte and the "stored equals normalized" check would reject one of them.
  defp bounded_number(nil, _minimum, _maximum, _label), do: {:ok, nil}

  defp bounded_number(value, minimum, maximum, _label)
       when is_number(value) and value >= minimum and value <= maximum,
       do: {:ok, value / 1}

  defp bounded_number(_value, minimum, maximum, label),
    do: {:error, "#{label} must be between #{minimum} and #{maximum}"}

  defp positive_integer(value, label, opts \\ [])

  defp positive_integer(nil, label, opts) do
    if Keyword.get(opts, :required?, false) do
      {:error, "#{label} must be a positive integer"}
    else
      {:ok, nil}
    end
  end

  defp positive_integer(value, _label, _opts) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp positive_integer(_value, label, _opts),
    do: {:error, "#{label} must be a positive integer"}

  defp boolean(value, _key) when is_boolean(value), do: {:ok, value}
  defp boolean(_value, key), do: {:error, "requirement #{key} enabled must be boolean"}

  defp optional_string(nil), do: nil

  defp optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp optional_string(value), do: to_string(value)

  # Every enabled requirement ends up with a prompt, even when the author wrote none, so a gap
  # that is allowed to ask the peer always has something to say. The generated fallbacks are
  # deliberately bland: they are derived from the description or from the key with its
  # separators turned into spaces, never from any stored knowledge.
  defp default_prompt(nil, nil, key),
    do: "Please provide current information for #{String.replace(key, ~r/[-_]/, " ")}."

  defp default_prompt(nil, description, _key), do: "Please provide: #{description}"
  defp default_prompt(prompt, _description, _key), do: prompt

  # Absent selector clauses are dropped rather than stored as nil, so a stored selector lists
  # only real constraints and two authors who omitted different optional fields produce the same
  # canonical map.
  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end

defmodule Cartulary.Skills.Validations.Requirements do
  @moduledoc """
  Ash validation that a skill requirement card is written in the selector language this build
  implements, and is already in canonical form.

  Two checks, both refusals rather than repairs:

  * The card's schema version must equal the language version the running code implements. A
    card written against a different grammar is rejected instead of being interpreted with
    today's rules.
  * The requirements must be byte-for-byte identical to what validation would normalize them to.
    The changeset is never rewritten to fix this.

  The second check is the load-bearing one. Because storage equals the canonical form, the
  readiness engine evaluates stored requirements verbatim, a reviewer reading a card sees exactly
  what will be enforced, and the same card cannot be stored in two spellings that behave alike.
  Callers are expected to normalize before publishing; "must be normalized" means the caller
  submitted a form that would have been rewritten.
  """

  use Ash.Resource.Validation

  alias Cartulary.Skills.Selector

  @impl true
  def validate(changeset, _opts, _context) do
    requirements = Ash.Changeset.get_attribute(changeset, :requirements)
    schema_version = Ash.Changeset.get_attribute(changeset, :requirement_schema_version)

    if schema_version != Selector.schema_version() do
      {:error,
       field: :requirement_schema_version, message: "must be #{Selector.schema_version()}"}
    else
      case Selector.validate_requirements(requirements) do
        {:ok, ^requirements} -> :ok
        {:ok, _normalized} -> {:error, field: :requirements, message: "must be normalized"}
        {:error, message} -> {:error, field: :requirements, message: message}
      end
    end
  end
end
