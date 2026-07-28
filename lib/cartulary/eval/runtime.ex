# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Eval.Runtime do
  @moduledoc "Runtime controls shared by deterministic evaluation tasks."

  def use_deterministic_models do
    oban = Application.fetch_env!(:cartulary, Oban)
    Application.put_env(:cartulary, Oban, Keyword.put(oban, :testing, :manual))

    models = Application.get_env(:cartulary, :models, [])
    Application.put_env(:cartulary, :models, Keyword.put(models, :api_key, nil))

    roles =
      :cartulary
      |> Application.fetch_env!(:model_roles)
      |> Enum.map(fn
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
    System.delete_env("OPENROUTER_API_KEY")
    :ok
  end
end
