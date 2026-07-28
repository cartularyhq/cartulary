# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Eval.Runtime do
  @moduledoc """
  Switches the node into offline, deterministic mode for reproducible evaluation runs.

  A run that is meant to gate a release must produce the same numbers every time and must
  not depend on a network, a provider account, or a background queue's timing. This module
  makes that true by rewriting application environment before the supervision tree boots.

  It is a Mix-task helper, not a library: it mutates global application environment and the
  OS environment of the whole node, which is acceptable for a one-shot command and would be
  actively harmful in a running server.
  """

  @doc """
  Repoints the node at local deterministic models and disables queue-driven job execution.

  Four things change:

    * Background job execution switches to manual, so nothing is dequeued behind the run's
      back. Evaluation ingests with inline extraction instead, keeping the work ordered and
      finished before questions are asked.
    * The provider credential in application configuration is cleared, and the environment
      variable it is read from is deleted, so nothing left in the environment can rebuild
      it and reach a live provider by accident.
    * The extraction, reasoning, and answering roles are repointed at the local structured
      fallback so no request leaves the machine.
    * The embedding role is deliberately left untouched. Retrieval still needs real vectors
      whose provider, model, version, and dimension identity match the installed vector
      indexes; substituting a stub there would not make the run deterministic, it would
      make retrieval wrong. The default embedder already runs locally with no network call.

  Call this **before** the application starts. The supervision tree reads this environment
  once at boot, so invoking it afterwards leaves a running system still pointed at whatever
  it was configured with — the run would then quietly use a live provider.

  Always returns `:ok`. Raises `ArgumentError` when the job-queue or model-role
  configuration is absent, which means the node was never configured to run Cartulary.
  """
  def use_deterministic_models do
    oban = Application.fetch_env!(:cartulary, Oban)
    Application.put_env(:cartulary, Oban, Keyword.put(oban, :testing, :manual))

    models = Application.get_env(:cartulary, :models, [])
    Application.put_env(:cartulary, :models, Keyword.put(models, :api_key, nil))

    roles =
      :cartulary
      |> Application.fetch_env!(:model_roles)
      |> Enum.map(fn
        # The embedder is absent from this list on purpose. Its provider, model, version,
        # and dimension identity has to keep matching the installed vector indexes, so
        # swapping it for a stub would break retrieval rather than make the run offline.
        {role, config} when role in [:ingest_extractor, :dream_reasoner, :dialectic_agent] ->
          {role,
           config
           |> Map.put(:provider, "deterministic")
           |> Map.put(:model, "local-structured-fallback")
           |> Map.put(:model_version, "1")}

        role_config ->
          role_config
      end)

    Application.put_env(:cartulary, :model_roles, roles)
    # Clearing the configured key is not enough on its own: the credential is configured as
    # a reference to this variable, so the variable itself has to go too.
    System.delete_env("OPENROUTER_API_KEY")
    :ok
  end
end
