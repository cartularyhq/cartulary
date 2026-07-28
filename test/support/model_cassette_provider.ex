# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Model.CassetteProvider do
  @moduledoc """
  Offline model provider that replays a recorded JSON script instead of calling a model.

  Every remote or local model capability in the system — structured extraction,
  chat, embedding, reranking — goes through one behaviour, and the gateway picks
  the implementation from the call context, then from the `:model_provider`
  application environment key, then from the role's configured default. This
  module contains no HTTP client and no fallback path to a real provider, so a
  test that installs it cannot reach a model endpoint. Tests that do not install
  it fall back to whatever the role names, which in the suite is the offline
  deterministic provider.

  ## Installing and removing it

  A test arms a scenario with `start!/2`, points the application at this module,
  and must undo both in an `on_exit` callback: call `stop/0` and restore (or
  delete) the previous `:model_provider` value. The recorded state lives in an
  `Agent` registered under this module's name, so only one cassette is armed per
  node and every test that uses it must run with `async: false`. The agent is
  started unlinked, so it outlives a failing test process; the explicit `stop/0`
  in `on_exit` is what keeps a half-consumed cassette from leaking into the next
  test.

  ## Cassette file shape

  The file is JSON with a top-level `"scenarios"` object. Each key is a scenario
  name and each value is an ordered list of entries consumed one per model call:

      {
        "scenarios": {
          "provider_outage": [
            {"operation": "structured", "role": "ingest_extractor",
             "task": "extraction", "error": "provider_unavailable"}
          ]
        }
      }

  `"operation"` is one of `structured`, `chat`, `embed`, `rerank`. `"role"` is one
  of the four account-level model roles: `embedder`, `ingest_extractor`,
  `dream_reasoner`, `dialectic_agent`. `"task"` is the caller-supplied task label
  for structured calls — the committed fixtures use `extraction`, `reasoning`,
  `dialectic`, and `eval_judge` — and `null` for every other operation, because
  only `structured/4` forwards a task. A success entry carries `"value"` plus optional
  `"usage"` and `"metadata"` objects; a failure entry carries `"error"`, whose
  string becomes the error atom the calling code receives, letting a test drive
  the real provider-failure path where raw input stays durable and the job stays
  retryable.

  ## Order is the contract

  Entries are consumed strictly in order, and each call's operation, role, and
  task must equal the head entry's triple. A mismatch raises inside the agent
  rather than replaying the next recorded answer, and running past the end of the
  list raises rather than returning an empty result. The caller therefore sees the
  agent's exit, not the exception itself. Both are deliberate: a silent
  fallback would let a test keep passing after the pipeline started making a
  different sequence of model calls, which is the single failure this seam exists
  to catch. When a legitimate change alters the call sequence, re-record the
  scenario; do not relax the matching.

  Only operation, role, and task are matched. Prompts, messages, schemas, and
  document lists are ignored here, so a test that needs to assert on prompt
  content must assert it at the module that builds the prompt.

  ## Content safety

  Cassette files are checked-in fixtures and are the only input this module
  trusts. They must contain synthetic text only — never real user content, API
  keys, or account keys — because their values flow into recorded usage events and
  test assertions. Map keys inside `"usage"` and `"metadata"` are converted to
  atoms unconditionally, matching the atom-keyed shape a provider `Result` is
  expected to carry. Unbounded atom creation is acceptable for a fixture under
  version control and would not be for attacker-controlled input, so never point
  this module at a file received at runtime.
  """

  @behaviour Cartulary.Model.Provider

  alias Cartulary.Model.Provider.Result

  @doc """
  Loads one scenario from a cassette file and arms it as the next responses.

  `path` is a filesystem path to the JSON cassette, relative to the project root,
  and `scenario` is a key under its `"scenarios"` object. An unknown scenario name
  arms an empty script, which means the first model call will raise as exhausted
  rather than silently succeed.

  Returns `:ok`. Raises if the file is missing or is not valid JSON. Safe to call
  again while a cassette is already armed: the entries and the recorded call log
  are replaced, which is how a test switches scenarios part-way through.
  """
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

  @doc """
  Disarms the cassette, discarding any unconsumed entries and the call log.

  Always returns `:ok`, including when nothing is armed, so it is safe to call
  unconditionally from `on_exit`. Note that it does not assert the script was
  fully consumed: a test that cares about leftover entries must check `calls/0`.
  """
  def stop do
    if pid = Process.whereis(__MODULE__), do: Agent.stop(pid)
    :ok
  end

  @doc """
  Returns the calls served so far, oldest first, as `{operation, role, task}` tuples.

  Operation and role are strings and task is a string or `nil`, matching the
  cassette entries. Use it to assert which model roles a code path actually
  invoked — for example that answering a question consulted exactly one reasoning
  role and nothing else. Exits with `:noproc` if no cassette is armed.
  """
  def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))

  @doc """
  Serves the next recorded response for a structured-output call.

  The task label from `opts` participates in matching, so extraction, reasoning,
  and judging calls made by the same role stay distinguishable in the script.
  Messages and the requested schema are ignored.
  """
  @impl true
  def structured(config, _messages, _schema, opts),
    do: reply("structured", config.role, Keyword.get(opts, :task))

  @doc """
  Serves the next recorded response for a free-form chat call. Matched with a nil task.
  """
  @impl true
  def chat(config, _messages, _opts), do: reply("chat", config.role, nil)

  @doc """
  Serves the next recorded response for an embedding call. Matched with a nil task.

  The recorded value is returned verbatim, so a cassette used with embedding must
  supply vectors whose length matches the dimensions the caller expects.
  """
  @impl true
  def embed(config, _texts, _opts), do: reply("embed", config.role, nil)

  @doc """
  Serves the next recorded response for a rerank call. Matched with a nil task.

  The query and the candidate documents are ignored, so the recorded ordering is
  whatever the cassette says regardless of what was passed in.
  """
  @impl true
  def rerank(config, _query, _documents, _opts), do: reply("rerank", config.role, nil)

  # Consumes exactly one entry per call under the agent's serialised update, so
  # concurrent callers cannot both read the same head entry. The triple check
  # runs before the entry is turned into a result: an out-of-order or unexpected
  # call must fail the test loudly instead of receiving another step's answer.
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
            # An "error" entry drives the real failure path in the caller, which
            # must leave durable input intact and the job retryable.
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

      # Running past the end is a test failure, never a default response: an
      # unrecorded call means the code under test changed its model usage.
      %{entries: []} ->
        raise "model cassette exhausted for #{operation}/#{role}"
    end)
  end

  # JSON gives string keys; a provider Result carries atom-keyed usage and
  # metadata. Only ever applied to committed fixture files, so unbounded atom
  # creation is not a concern here.
  defp atomize_keys(map), do: Map.new(map, fn {key, value} -> {String.to_atom(key), value} end)
end
