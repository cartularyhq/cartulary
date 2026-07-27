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

defmodule Cartulary.Policy.HumanRoleIn do
  @moduledoc false

  use Ash.Policy.SimpleCheck

  @impl true
  def describe(opts),
    do: "authenticated human actor has one of #{inspect(Keyword.fetch!(opts, :roles))}"

  @impl true
  def match?(%{identity_kind: :password, role: role}, _context, opts),
    do: role in Keyword.fetch!(opts, :roles)

  def match?(_actor, _context, _opts), do: false
end

defmodule Cartulary.Policy.HumanScopeRole do
  @moduledoc false

  use Ash.Policy.FilterCheck

  @impl true
  def describe(opts),
    do: "authenticated human has a permitted role at #{opts[:attribute] || :scope_id}"

  @impl true
  def filter(%{identity_kind: :password, scope_roles: scope_roles}, _context, opts)
      when is_map(scope_roles) do
    attribute = Keyword.get(opts, :attribute, :scope_id)
    roles = Keyword.fetch!(opts, :roles)

    scope_ids =
      for {scope_id, role} <- scope_roles,
          role in roles,
          do: scope_id

    expr(^ref(attribute) in ^scope_ids)
  end

  def filter(_actor, _context, _opts), do: false
end

defmodule Cartulary.Policy.HumanOwns do
  @moduledoc false

  use Ash.Policy.FilterCheck

  @impl true
  def describe(opts),
    do: "authenticated human owns #{opts[:attribute] || :subject_peer_id}"

  @impl true
  def filter(%{identity_kind: :password, peer_id: peer_id}, _context, opts)
      when is_binary(peer_id) do
    attribute = Keyword.get(opts, :attribute, :subject_peer_id)
    expr(^ref(attribute) == ^peer_id)
  end

  def filter(_actor, _context, _opts), do: false
end

defmodule Cartulary.Policy.ScopeRelationAccess do
  @moduledoc false

  use Ash.Policy.FilterCheck

  @impl true
  def describe(_opts), do: "actor may read both ends of the scope relation"

  @impl true
  def filter(%{scope_ids: :all}, _context, _opts), do: true

  def filter(%{scope_ids: scope_ids}, _context, opts) when is_list(scope_ids) do
    source_attribute = Keyword.fetch!(opts, :source_attribute)
    target_attribute = Keyword.fetch!(opts, :target_attribute)

    expr(
      ^ref(source_attribute) in ^scope_ids and
        ^ref(target_attribute) in ^scope_ids
    )
  end

  def filter(_actor, _context, _opts), do: false
end

defmodule Cartulary.Policy.ScopeRole do
  @moduledoc false

  use Ash.Policy.FilterCheck

  @impl true
  def describe(opts), do: "actor has a permitted role at #{opts[:attribute] || :scope_id}"

  @impl true
  def filter(%{role: :system}, _context, _opts), do: true

  def filter(%{scope_roles: scope_roles}, _context, opts) when is_map(scope_roles) do
    attribute = Keyword.get(opts, :attribute, :scope_id)
    roles = Keyword.fetch!(opts, :roles)

    scope_ids =
      for {scope_id, role} <- scope_roles,
          role in roles,
          do: scope_id

    expr(^ref(attribute) in ^scope_ids)
  end

  def filter(_actor, _context, _opts), do: false
end
