# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Pipeline.ExtractWorker do
  @moduledoc false

  use Oban.Worker, queue: :ingest, max_attempts: 3

  alias Cartulary.Memory

  @impl true
  def perform(%Oban.Job{
        args: %{"message_id" => message_id, "account_key" => account_key}
      }) do
    Memory.extract_message(message_id, account_key)
  end

  def perform(%Oban.Job{args: %{"message_id" => message_id}}) do
    Memory.extract_message(message_id)
  end
end
