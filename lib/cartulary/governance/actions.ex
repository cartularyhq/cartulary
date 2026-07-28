# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Governance.Actions.McpIngest do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context) do
    attrs = stringify(input.arguments)

    case Cartulary.Memory.ingest_message(attrs, context.actor) do
      {:ok, message} -> {:ok, message}
      {:error, error} -> {:error, error}
    end
  end

  defp stringify(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
end

defmodule Cartulary.Governance.Actions.McpRead do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, opts, context) do
    attrs = Map.new(input.arguments, fn {key, value} -> {to_string(key), value} end)
    operation = Keyword.fetch!(opts, :operation)

    result =
      case operation do
        :get_context -> Cartulary.Memory.get_context(attrs, context.actor)
        :search -> Cartulary.Memory.search(attrs, context.actor)
        :ask -> Cartulary.Memory.ask(attrs, context.actor)
        :query_knowledge -> %{"data" => Cartulary.Memory.query_knowledge(attrs, context.actor)}
        :check_readiness -> Cartulary.Memory.check_readiness(attrs, context.actor)
      end

    topic = attrs["query"] || attrs["question"]

    pending =
      Cartulary.Governance.PeerQueue.attach(
        context.actor,
        attrs["session_id"],
        Atom.to_string(operation),
        topic
      )

    result =
      if pending && is_map(result) do
        Map.put(result, "pending_validation", pending)
      else
        result
      end

    {:ok, result}
  end
end

defmodule Cartulary.Governance.Actions.ResolveValidation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context) do
    arguments = input.arguments

    case Cartulary.Governance.PeerQueue.resolve(
           context.actor,
           arguments.id,
           arguments.verdict,
           arguments.shown_text,
           arguments.correction_text
         ) do
      {:ok, result} -> {:ok, Map.new(result)}
      {:error, :not_found} -> {:error, "not found"}
      {:error, reason} -> {:error, to_string(reason)}
    end
  end
end

defmodule Cartulary.Governance.Actions.SetAskPreference do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  alias Cartulary.Clock

  @impl true
  def run(input, _opts, context) do
    args = input.arguments

    attrs = %{
      max_per_session: args.max_per_session,
      max_per_day: args.max_per_day,
      paused_until:
        if(is_integer(args.pause_for_hours),
          do: DateTime.add(Clock.utc_now(), max(args.pause_for_hours, 0), :hour)
        )
    }

    preference = Cartulary.Governance.PeerQueue.restrict_preferences(context.actor, attrs)

    {:ok,
     %{
       max_per_session: preference.max_per_session,
       max_per_day: preference.max_per_day,
       paused_until: preference.paused_until
     }}
  end
end
