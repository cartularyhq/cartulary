# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Pipeline.ExtractorTest do
  use ExUnit.Case, async: false

  alias Cartulary.Pipeline.Extractor

  setup do
    original = System.get_env("OPENROUTER_API_KEY")
    original_models = Application.fetch_env!(:cartulary, :models)
    System.delete_env("OPENROUTER_API_KEY")
    Application.put_env(:cartulary, :models, Keyword.put(original_models, :api_key, nil))

    on_exit(fn ->
      if original, do: System.put_env("OPENROUTER_API_KEY", original)
      Application.put_env(:cartulary, :models, original_models)
    end)
  end

  test "fallback extractor emits natural-language proposed knowledge" do
    items =
      Extractor.extract(%{
        "content" =>
          "Alice prefers concise status updates. Her phone number should not be shared."
      })

    assert [
             %{statement: "Alice prefers concise status updates.", kind: "preference"},
             %{statement: "Her phone number should not be shared.", sensitivity: "personal"}
           ] = items
  end
end
