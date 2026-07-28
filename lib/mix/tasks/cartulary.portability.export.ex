# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Mix.Tasks.Cartulary.Portability.Export do
  @moduledoc """
  Writes the configured community Account out as a self-contained, checksum-verified
  archive.

  The archive is what moves an installation between machines, deployment modes, or blob
  storage adapters: a gzip-compressed tar holding a manifest, one JSON-lines file per
  durable resource, and content-addressed original document blobs. It is read inside a
  single Account-scoped database transaction, so the snapshot is internally consistent.

      mix cartulary.portability.export
      mix cartulary.portability.export --output /secure/path/cartulary-account.tar.gz

  ## Switches

    * `--output PATH`, `-o` — destination file. Default:
      `cartulary-export-YYYY-MM-DD.tar.gz` in the current working directory, dated with
      today's UTC date. An existing file at that path is overwritten.

  ## What is and is not inside

  Included: the durable system of record — the Account, scopes, peers, raw observations,
  governed knowledge, lifecycle and audit history, document version metadata, and the
  original document blobs, each covered by a SHA-256 in the manifest.

  Excluded on purpose: password hashes, API keys, and every other secret value; and all
  rebuildable derived state — embedding vectors, document chunks, projections, entities and
  entity mentions, and extracted-text caches. Derived data is recomputed at the destination,
  which is also why the destination's embedding identity matters: vectors are never carried
  across and silently reused in a different vector space.

  Because credentials are absent, this is not an operational backup and cannot serve as
  point-in-time recovery. Treat the file itself as sensitive user data regardless — it holds
  the full content of one Account.

  ## Output and failure behaviour

  On success the task prints one line with the exported Account id and the absolute archive
  path. If the community Account does not exist yet, or a read or write fails, the task
  raises and exits non-zero; the temporary staging directory it builds the archive in is
  removed either way. The tar is written to a `<output>.tmp-N` sibling and renamed into place
  only after it is complete, so a failure leaves that sibling behind rather than a truncated
  file at the destination path.

  Validate the result before and after transferring it with
  `mix cartulary.portability.import --input PATH --validate-only`.
  """

  use Mix.Task

  @shortdoc "Export the free Account"

  @switches [output: :string]
  @aliases [o: :output]

  @doc """
  Parses `--output`, exports the community Account, and prints the account id and archive
  path.

  Raises when the switches are invalid, when no community Account exists, or when the
  archive cannot be produced, which surfaces as a non-zero exit status.
  """
  @impl true
  def run(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)
    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    output =
      Keyword.get(opts, :output) ||
        "cartulary-export-#{Date.utc_today() |> Date.to_iso8601()}.tar.gz"

    Mix.Task.run("app.start")

    # The wrapper looks up the community Account that already exists rather than creating
    # one, sets the tenant for the surrounding transaction, and hands back an actor whose
    # authority is scoped to that Account. Export therefore cannot read across tenants, and
    # running this against an empty database fails instead of emitting an empty archive.
    result =
      Cartulary.DataLayer.with_existing_free_account(fn _account, actor ->
        {:ok, result} = Cartulary.Portability.export(actor, output)
        result
      end)

    Mix.shell().info("Exported #{result.account_id} to #{result.path}")
  end
end
