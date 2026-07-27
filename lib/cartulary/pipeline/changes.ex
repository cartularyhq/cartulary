# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Pipeline.Changes.ExecuteRun do
  @moduledoc false

  use Ash.Resource.Change

  alias Cartulary.Clock
  alias Cartulary.Pipeline

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      run = changeset.data

      case Pipeline.execute(run) do
        {:ok, _result} ->
          changeset
          |> Ash.Changeset.force_change_attribute(:status, "completed")
          |> Ash.Changeset.force_change_attribute(:processed_at, Clock.utc_now())
          |> Ash.Changeset.force_change_attribute(:last_error_class, nil)
          |> Ash.Changeset.force_change_attribute(:attempt_count, run.attempt_count + 1)

        {:error, error} ->
          Ash.Changeset.add_error(changeset, error)
      end
    end)
  end
end

defmodule Cartulary.Pipeline.Changes.MarkRunFailed do
  @moduledoc false

  use Ash.Resource.Change

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

  defp error_class(%module{}), do: inspect(module)
  defp error_class(_error), do: "pipeline_error"
end
