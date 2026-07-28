# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Model.CassetteProvider do
  @moduledoc false

  @behaviour Cartulary.Model.Provider

  alias Cartulary.Model.Provider.Result

  def start!(path, scenario) do
    entries =
      path
      |> File.read!()
      |> Jason.decode!()
      |> get_in(["scenarios", scenario])
      |> Kernel.||([])

    case Agent.start(fn -> %{entries: entries, calls: []} end, name: __MODULE__) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        Agent.update(__MODULE__, fn _ -> %{entries: entries, calls: []} end)
    end
  end

  def stop do
    if pid = Process.whereis(__MODULE__), do: Agent.stop(pid)
    :ok
  end

  def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))

  @impl true
  def structured(config, _messages, _schema, opts),
    do: reply("structured", config.role, Keyword.get(opts, :task))

  @impl true
  def chat(config, _messages, _opts), do: reply("chat", config.role, nil)

  @impl true
  def embed(config, _texts, _opts), do: reply("embed", config.role, nil)

  @impl true
  def rerank(config, _query, _documents, _opts), do: reply("rerank", config.role, nil)

  defp reply(operation, role, task) do
    Agent.get_and_update(__MODULE__, fn
      %{entries: [entry | rest], calls: calls} = state ->
        expected = {entry["operation"], entry["role"], entry["task"]}
        actual = {operation, Atom.to_string(role), task && Atom.to_string(task)}

        if expected != actual do
          raise "cassette mismatch: expected #{inspect(expected)}, got #{inspect(actual)}"
        end

        result =
          case entry do
            %{"error" => error} ->
              {:error, String.to_atom(error)}

            _other ->
              {:ok,
               %Result{
                 value: entry["value"],
                 usage: atomize_keys(entry["usage"] || %{}),
                 metadata: atomize_keys(entry["metadata"] || %{})
               }}
          end

        {result, %{state | entries: rest, calls: [actual | calls]}}

      %{entries: []} ->
        raise "model cassette exhausted for #{operation}/#{role}"
    end)
  end

  defp atomize_keys(map), do: Map.new(map, fn {key, value} -> {String.to_atom(key), value} end)
end
