# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Pipeline.Changes.ExecuteRun do
  @moduledoc """
  Runs a pipeline run's workflow and records how it ended, as one update.

  This is the body of every background pipeline job. The work itself and the
  bookkeeping that says the work is done are the same update, so a run cannot be
  marked completed by a job that never finished, and finished work cannot be
  left looking pending.

  ## Ordering

  The workflow is invoked in `before_transaction`, so it runs before this row's
  update is issued and its outcome decides what that update contains. Success
  stamps `completed`, the processing time, and a bumped attempt count, and
  clears any previous error class. Failure adds the error to the changeset,
  which aborts the update and lets the job runner's failure path record the
  attempt instead.

  `before_transaction` rather than `before_action` is what keeps the workflow
  out of the enclosing action's transaction, and that placement is load-bearing:
  lanes open and commit their own transactions — raw writes, governance
  decisions, cache rebuilds — and holding one transaction across all of them
  would keep locks for the entire duration of the work. Moving this hook to
  `before_action` would put it back inside. The consequence to remember is that
  a lane's own commits survive even if this row's status update later fails;
  that is safe only because every lane is replay-safe under its deterministic
  key.

  The attempt count is incremented from the row as it was read, not with a
  database-side increment, which is accurate because a run only ever has one
  job in flight at a time.
  """

  use Ash.Resource.Change

  alias Cartulary.Clock
  alias Cartulary.Pipeline

  @doc """
  Attaches the execute-then-record behaviour to the changeset.

  Returns the changeset with a `before_transaction` hook. The hook returns an
  updated changeset on success, or a changeset carrying the workflow's error on
  failure, which prevents the row from being marked completed.
  """
  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_transaction(changeset, fn changeset ->
      run = changeset.data

      case Pipeline.execute(run) do
        {:ok, _result} ->
          changeset
          |> Ash.Changeset.force_change_attribute(:status, "completed")
          |> Ash.Changeset.force_change_attribute(:processed_at, Clock.utc_now())
          |> Ash.Changeset.force_change_attribute(:last_error_class, nil)
          |> Ash.Changeset.force_change_attribute(:attempt_count, run.attempt_count + 1)

        # The error travels no further than the changeset: the row keeps its
        # current status and stays eligible for retry and reconciliation.
        {:error, error} ->
          Ash.Changeset.add_error(changeset, error)
      end
    end)
  end
end

defmodule Cartulary.Pipeline.Changes.MarkRunFailed do
  @moduledoc """
  Records a failed attempt on a pipeline run without leaking why it failed.

  Invoked by the job runner's failure path. It marks the run failed and bumps
  the attempt count, leaving the row visible to a retry or to the reconciliation
  sweep — a failed run is unfinished work, not discarded work.

  ## Content safety

  Only a *class* of error is stored, never the error itself. Error messages
  routinely embed the values that caused them — message text, statements,
  document fragments, provider payloads, occasionally credentials — and this row
  is durable, operator-visible, and outside the reach of erasure. The class is
  the error's struct name, or a generic label for anything that is not a struct,
  which is enough to distinguish a provider outage from a validation failure
  without recording content.
  """

  use Ash.Resource.Change

  @doc """
  Marks the run failed and increments its attempt count.

  Reads the `:error` argument supplied by the job runner and stores only its
  classification. Returns the updated changeset; it never fails, because the
  failure path must always be able to record an outcome.
  """
  @impl true
  def change(changeset, _opts, _context) do
    error = Ash.Changeset.get_argument(changeset, :error)
    class = error_class(error)

    changeset
    |> Ash.Changeset.force_change_attribute(:status, "failed")
    |> Ash.Changeset.force_change_attribute(:last_error_class, class)
    |> Ash.Changeset.force_change_attribute(
      :attempt_count,
      changeset.data.attempt_count + 1
    )
  end

  # The struct's module name is a content-free classification. Everything else,
  # including bare strings and tuples that may embed content, collapses to a
  # single generic label rather than being inspected into the row.
  defp error_class(%module{}), do: inspect(module)
  defp error_class(_error), do: "pipeline_error"
end
