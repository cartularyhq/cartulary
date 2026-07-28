# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Mix.Tasks.Cartulary.Portability.Import do
  @moduledoc """
  Loads a previously exported Account archive into a fresh installation, or verifies one
  without touching the database.

      mix cartulary.portability.import --input /secure/path/account.tar.gz
      mix cartulary.portability.import --input /secure/path/account.tar.gz --validate-only

  ## Switches

    * `--input PATH`, `-i` — required. The archive to read.
    * `--validate-only` — verify and report, then stop. Default off. Run this at the source
      before transferring and again at the destination before importing; it is read-only and
      safe against a live installation.

  ## Verification happens first, always

  In both modes the archive is unpacked to a temporary directory and fully checked before
  any durable write: the manifest hash, every per-resource file hash, every blob hash, and
  the entire audit hash chain. A tampered or truncated archive is rejected while the
  database is still untouched, which is the whole point of doing verification up front
  rather than row by row during the load.

  ## Import requires a fresh target

  The destination must be migrated and must not already hold an Account with the archived
  id or occupying the community slot. Import is not a merge and not an upgrade-in-place: it
  refuses rather than blending two histories. All rows are written through private
  Account-scoped actions inside one transaction, so a mid-import failure rolls back
  completely.

  Ordinary rebuild jobs for the derived data the archive deliberately omits — document
  chunks, embedding vectors, projections, entities — are enqueued inside that same
  transaction, so a rollback takes the jobs with it. They carry replay keys, so re-running
  them is a no-op rather than a duplication.

  Once the command returns, the installation is not yet fully usable: wait for readiness to
  report healthy and for the rebuild jobs to drain, confirm the destination's embedding
  identity (vectors are recomputed in the destination vector space and never reused from the
  source), and recreate human passwords and API keys, which are intentionally not exported.
  Keep the source installation until resource counts, audit head and count, blobs, and a few
  representative reads have been compared.

  ## Output and failure behaviour

  Validation mode prints the Account id and manifest hash. Import mode prints the imported
  Account id and confirms that derived rebuilds were enqueued. Any checksum mismatch,
  broken audit chain, non-fresh target, or write failure raises and exits non-zero with the
  destination database unchanged. Blobs are staged into the destination blob store just
  before the transaction opens, so a failure inside it can leave unreferenced blobs behind;
  they are harmless, and a later successful import addresses them by content hash.
  """

  use Mix.Task

  @shortdoc "Import an Account archive"

  @switches [input: :string, validate_only: :boolean]
  @aliases [i: :input]

  @doc """
  Parses the switches described in the module documentation and either validates the
  archive or imports it.

  Raises when the switches are invalid, `--input` is absent, verification fails, or the
  target is not fresh, which surfaces as a non-zero exit status.
  """
  @impl true
  def run(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)
    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    input = Keyword.get(opts, :input) || Mix.raise("--input is required")
    Mix.Task.run("app.start")

    # Both branches match strictly on `{:ok, _}`: an unexpected result must abort loudly
    # rather than print a success line over a partially applied import.
    if Keyword.get(opts, :validate_only, false) do
      {:ok, result} = Cartulary.Portability.validate(input)
      Mix.shell().info("Archive valid: #{result.account_id} (#{result.manifest_hash})")
    else
      {:ok, result} = Cartulary.Portability.import(input)
      Mix.shell().info("Imported #{result.account_id}; derived rebuilds enqueued")
    end
  end
end
