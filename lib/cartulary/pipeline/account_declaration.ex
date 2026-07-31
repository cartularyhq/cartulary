# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Pipeline.Preparations.DeclareAccount do
  @moduledoc """
  Declares the queried Account to the database before a pipeline run is read.

  Every background lane begins the same way: the job runner takes a pipeline run's id out of
  the job's arguments and reads that row back to confirm the work still needs doing. That read
  happens before any Cartulary code gets control, on a pooled connection that no request ever
  touched, so nothing has told the database which Account is acting.

  The `pipeline_runs` table carries a row-level security policy comparing every row against
  exactly that declaration. Undeclared, the comparison is never true, the read returns no rows,
  and the job runner reads the empty result as "this record no longer matches the trigger" and
  cancels itself. The row is intact and the work is genuinely outstanding; the job simply
  cannot see it. Ingest looks like it succeeded and nothing is ever extracted.

  Attaching this preparation to the read action closes that gap: the declaration is installed
  inside the action's own transaction, immediately before the query runs, so the policy has
  something to compare against.

  ## Requirements on the action

  The action must declare `transaction? true`. The setting is transaction-local, so without a
  transaction it would be discarded before the query it exists to admit. The declaration
  helper raises rather than letting that pass silently.

  Reads that already run inside an Account-scoped transaction — the browser console's queue
  page, for example — are unaffected: an existing declaration is never overwritten.
  """

  use Ash.Resource.Preparation

  alias Cartulary.DataLayer

  @doc """
  Adds a before-action hook that declares the query's tenant Account.

  The hook runs inside the read action's transaction and returns the query unchanged. Raises
  when the query carries no tenant, which on a tenant-scoped resource means the caller built
  it wrong; declaring nothing there would turn a caller's mistake into an empty result set.
  """
  @impl true
  def prepare(query, _opts, _context) do
    Ash.Query.before_action(query, fn query ->
      case query.tenant do
        tenant when is_binary(tenant) ->
          DataLayer.declare_account!(tenant)
          query

        other ->
          raise "pipeline run read requires a tenant Account, got: #{inspect(other)}"
      end
    end)
  end
end

defmodule Cartulary.Pipeline.Changes.DeclareAccount do
  @moduledoc """
  Declares the run's own Account to the database before a pipeline run is written.

  The counterpart to the read-side preparation, for the same reason and against the same
  policy. A background job that has finished its work — or failed it — writes the outcome back
  onto the run row, and that write lands on a connection with no Account declared unless
  something declares one. The `pipeline_runs` policy checks the written row against the
  declaration just as it checks read rows, so an undeclared update matches nothing: PostgreSQL
  reports zero rows changed, Ash raises a stale-record error, and the job runner treats that as
  the record no longer applying and cancels. The work was done and its outcome is lost.

  The Account comes from the row being updated rather than from the changeset's tenant, since
  that is the exact value the policy compares and it is already loaded.

  ## Requirements on the action

  The action must be transactional, which every update here is. The declaration is
  transaction-local and the helper raises if no transaction is open, so a future action that
  turns transactions off will fail loudly rather than silently reintroduce this bug.
  """

  use Ash.Resource.Change

  alias Cartulary.DataLayer

  @doc """
  Adds a before-action hook that declares the updated row's Account.

  The hook runs inside the action's transaction, immediately before the row is written, and
  returns the changeset unchanged.
  """
  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      DataLayer.declare_account!(changeset.data.account_id)
      changeset
    end)
  end
end
