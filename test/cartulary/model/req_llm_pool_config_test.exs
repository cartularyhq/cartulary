# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Model.ReqLLMPoolConfigTest do
  @moduledoc """
  Pins the shared hosted-model connection-pool capacity.

  ReqLLM uses one Finch pool for every provider and generation role. Its
  library default is smaller than Cartulary's normal ingest queue, so this
  setting must remain explicit and large enough for concurrent ingest.
  """

  use ExUnit.Case, async: true

  test "ReqLLM has an explicit pool that covers the configurable ingest queue" do
    assert Application.fetch_env!(:req_llm, :stream_pool_size) == 1
    assert Application.fetch_env!(:req_llm, :stream_pool_count) >= 16

    assert Application.fetch_env!(:cartulary, Oban)
           |> Keyword.fetch!(:queues)
           |> Keyword.fetch!(:ingest) ==
             10
  end
end
