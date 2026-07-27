# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Resource do
  @moduledoc false

  defmacro __using__(opts) do
    domain = Keyword.fetch!(opts, :domain)
    table = Keyword.fetch!(opts, :table)
    extensions = Keyword.get(opts, :extensions, [])

    quote do
      use Ash.Resource,
        otp_app: :cartulary,
        domain: unquote(domain),
        data_layer: AshPostgres.DataLayer,
        authorizers: [Ash.Policy.Authorizer],
        extensions: unquote(extensions)

      postgres do
        table unquote(table)
        repo Cartulary.Repo
      end
    end
  end
end

defmodule Cartulary.Policy.ScopeAccess do
  @moduledoc false

  use Ash.Policy.FilterCheck

  @impl true
  def describe(opts), do: "actor may read the #{opts[:attribute] || :scope_id} scope"

  @impl true
  def filter(%{scope_ids: :all}, _context, _opts), do: true

  def filter(%{scope_ids: scope_ids}, _context, opts) when is_list(scope_ids) do
    attribute = Keyword.get(opts, :attribute, :scope_id)
    expr(^ref(attribute) in ^scope_ids)
  end

  def filter(_actor, _context, _opts), do: false
end

defmodule Cartulary.Policy.RoleIn do
  @moduledoc false

  use Ash.Policy.SimpleCheck

  @impl true
  def describe(opts), do: "actor role is one of #{inspect(Keyword.fetch!(opts, :roles))}"

  @impl true
  def match?(%{role: role}, _context, opts), do: role in Keyword.fetch!(opts, :roles)
  def match?(_actor, _context, _opts), do: false
end
