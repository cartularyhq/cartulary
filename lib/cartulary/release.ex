# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Release do
  @moduledoc "Release migration entry points shared by pg0 and external Postgres."

  @app :cartulary

  def migrate do
    load_app()
    Cartulary.RuntimeConfig.validate!()
    pg0 = start_pg0()

    try do
      for repo <- Application.fetch_env!(@app, :ecto_repos) do
        {:ok, _pid, _apps} =
          Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
      end
    after
      stop_pg0(pg0)
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _pid, _apps} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  def export!(output_path) do
    result =
      Cartulary.DataLayer.with_existing_free_account(fn _account, actor ->
        {:ok, export} = Cartulary.Portability.export(actor, output_path)
        export
      end)

    IO.puts("portability export: #{Jason.encode!(result)}")
  end

  def validate_archive!(input_path) do
    {:ok, result} = Cartulary.Portability.validate(input_path)
    IO.puts("portability archive: #{Jason.encode!(result)}")
  end

  def import!(input_path) do
    {:ok, result} = Cartulary.Portability.import(input_path)
    IO.puts("portability import: #{Jason.encode!(result)}")
  end

  defp load_app do
    case Application.load(@app) do
      :ok -> :ok
      {:error, {:already_loaded, @app}} -> :ok
    end
  end

  defp start_pg0 do
    if Cartulary.RuntimeConfig.pg0?() do
      {:ok, pid} = Cartulary.Pg0.start_link()
      pid
    end
  end

  defp stop_pg0(nil), do: :ok
  defp stop_pg0(pid), do: GenServer.stop(pid, :normal, 35_000)
end

defmodule Cartulary.Release.Migrator do
  @moduledoc false

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    if Cartulary.RuntimeConfig.auto_migrate?() do
      migrations_path = Application.app_dir(:cartulary, "priv/repo/migrations")
      Ecto.Migrator.run(Cartulary.Repo, migrations_path, :up, all: true)
    end

    {:ok, %{}}
  end
end
