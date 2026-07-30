# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Model.Providers.ReqLLMTest do
  @moduledoc """
  Pins that `reasoning_effort` reaches the underlying `req_llm` library as the
  atom its option schema requires, not the string role configuration stores it
  as.

  Role options are always string-valued (see `Cartulary.Model.Config.Role`),
  because they must stay printable/exportable regardless of source. `req_llm`
  validates `reasoning_effort` with `NimbleOptions` against a fixed atom enum
  and rejects a string outright. Every call that reaches this option must
  therefore convert it before it leaves the adapter; a regression here fails
  every single generation call for any role that sets it, which is exactly
  what shipped in `a566d30` before this file existed.
  """

  use ExUnit.Case, async: true

  alias Cartulary.Model.Config.Role
  alias Cartulary.Model.Providers.ReqLLM, as: Adapter

  defp role(options) do
    %Role{
      role: :ingest_extractor,
      provider: "openrouter",
      model: "openai/gpt-oss-120b",
      model_version: "unversioned",
      prompt_version: "1",
      pipeline_version: "f5-1",
      config_version: 1,
      options: options
    }
  end

  test "a string reasoning_effort from configuration does not fail NimbleOptions validation" do
    config = role(%{"reasoning_effort" => "low"})

    # `reasoning_effort` validation happens before credential resolution, so a
    # missing API key here (this role has no `api_key_ref`) proves the option
    # cleared NimbleOptions validation and the call reached the next stage,
    # rather than failing on this option's type as it did before the fix.
    assert_raise ReqLLM.Error.Invalid.Parameter, ~r/api_key/, fn ->
      Adapter.chat(config, [%{role: "user", content: "hi"}], [])
    end
  end
end
