# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Pipeline.Workflows.IngestExtraction do
  @moduledoc "Ash.Reactor flow for message and document ingest-time extraction."

  use Ash.Reactor

  input(:pipeline_run)

  step :extract do
    argument :pipeline_run, input(:pipeline_run)
    async? false

    run fn %{pipeline_run: run}, _context ->
      case run.target_type do
        "message" ->
          Cartulary.Memory.extract_message_for_account(run.target_id, run.account_id)

        "document_version" ->
          # F6 owns native document parsing/model extraction. F2 provides the
          # durable, idempotent execution lane now.
          {:ok, %{document_version_id: run.target_id, deferred_to: "F6"}}
      end
    end
  end

  return :extract
end

defmodule Cartulary.Pipeline.Workflows.DreamTimeReasoning do
  @moduledoc "Ash.Reactor continuation seam for dream-time and derived-cache work."

  use Ash.Reactor

  input(:pipeline_run)

  step :reason do
    argument :pipeline_run, input(:pipeline_run)
    async? false

    run fn %{pipeline_run: run}, _context ->
      case run.kind do
        "dream_time" -> Cartulary.Governance.Sweeper.run(run.account_id, "dream_time")
        _other -> Cartulary.Pipeline.Workflows.Stage.run(run)
      end
    end
  end

  return :reason
end

defmodule Cartulary.Pipeline.Workflows.ValidationContinuation do
  @moduledoc "Ash.Reactor flow resumed by a durable governance decision."

  use Ash.Reactor

  input(:pipeline_run)

  step :continue_validation do
    argument :pipeline_run, input(:pipeline_run)
    async? false

    run fn %{pipeline_run: run}, _context ->
      Cartulary.Pipeline.Workflows.Stage.run(run)
    end
  end

  return :continue_validation
end

defmodule Cartulary.Pipeline.Workflows.AnswerCorrelationContinuation do
  @moduledoc "Ash.Reactor flow for transcript-backed answer correlation."

  use Ash.Reactor

  input(:pipeline_run)

  step :correlate_answer do
    argument :pipeline_run, input(:pipeline_run)
    async? false

    run fn %{pipeline_run: run}, _context ->
      Cartulary.Pipeline.Workflows.Stage.run(run)
    end
  end

  return :correlate_answer
end

defmodule Cartulary.Pipeline.Workflows.Maintenance do
  @moduledoc "Ash.Reactor flow for lifecycle, connector, portability, and reconciliation jobs."

  use Ash.Reactor

  input(:pipeline_run)

  step :maintain do
    argument :pipeline_run, input(:pipeline_run)
    async? false

    run fn %{pipeline_run: run}, _context ->
      case run.kind do
        "reconciler" ->
          Cartulary.Pipeline.Reconciler.run(run.account_id)

        kind when kind in ["revalidation", "expiry"] ->
          Cartulary.Governance.Sweeper.run(run.account_id, kind)

        _other ->
          Cartulary.Pipeline.Workflows.Stage.run(run)
      end
    end
  end

  return :maintain
end

defmodule Cartulary.Pipeline.Workflows.Stage do
  @moduledoc false

  def run(run) do
    {:ok,
     %{
       kind: run.kind,
       target_type: run.target_type,
       target_id: run.target_id,
       continuation: "durable"
     }}
  end
end
