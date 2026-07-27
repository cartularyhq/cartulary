# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Mix.Tasks.Cartulary.Eval.Smoke do
  @moduledoc """
  Runs a small local memory-eval smoke pass through Cartulary's POC write/read path.

      mix cartulary.eval.smoke
      mix cartulary.eval.smoke --dataset path/to/smoke.json --profile balanced

  Dataset format:

      {
        "messages": [
          {"session_id":"s1","scope_path":"/bench/locomo","peer_key":"alice","role":"user","content":"..."}
        ],
        "questions": [
          {"id":"q1","question":"What does Alice prefer?","scope_path":"/bench/locomo"}
        ]
      }
  """

  use Mix.Task

  alias Cartulary.Memory

  @shortdoc "Runs Cartulary local memory POC smoke eval"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, _invalid} =
      OptionParser.parse(args,
        strict: [
          dataset: :string,
          profile: :string,
          account: :string,
          output: :string
        ]
      )

    profile = Keyword.get(opts, :profile, "balanced")
    account_key = Keyword.get(opts, :account, "eval-poc")
    dataset = load_dataset(Keyword.get(opts, :dataset))

    ingested =
      dataset["messages"]
      |> Enum.map(fn message ->
        message
        |> Map.put_new("scope_path", "/bench/smoke")
        |> Map.put_new("peer_key", "peer")
        |> Map.put_new("session_id", "smoke")
        |> Map.put_new("role", "user")
        |> Map.put("account_key", account_key)
        |> Map.put("sync_extract", true)
        |> Memory.ingest_message()
      end)

    answers =
      dataset["questions"]
      |> Enum.map(fn question ->
        result =
          Memory.ask(%{
            "account_key" => account_key,
            "scope_path" => Map.get(question, "scope_path", "/bench/smoke"),
            "question" => Map.fetch!(question, "question"),
            "profile" => profile
          })

        %{
          "id" => Map.get(question, "id"),
          "question" => Map.fetch!(question, "question"),
          "expected" => Map.get(question, "expected"),
          "answer" => result["answer"],
          "citations" => result["citations"],
          "abstained" => result["abstained"],
          "profile_version" => result["profile_version"],
          "contributed_strategies" => result["contributed_strategies"]
        }
      end)

    report = %{
      "benchmark" => Map.get(dataset, "benchmark", "smoke"),
      "profile" => profile,
      "profile_version" => "poc-0",
      "account_key" => account_key,
      "messages_attempted" => length(dataset["messages"]),
      "messages_ingested" => Enum.count(ingested, &match?({:ok, _}, &1)),
      "questions" => answers
    }

    encoded = Jason.encode_to_iodata!(report, pretty: true)

    case Keyword.get(opts, :output) do
      nil ->
        IO.puts(encoded)

      path ->
        File.write!(path, encoded)
        Mix.shell().info("wrote #{path}")
    end
  end

  defp load_dataset(nil) do
    %{
      "benchmark" => "cartulary-poc-smoke",
      "messages" => [
        %{
          "session_id" => "locomo-smoke-1",
          "scope_path" => "/bench/locomo",
          "peer_key" => "alice",
          "role" => "user",
          "content" =>
            "Alice prefers concise status updates. Alice moved the launch review to Friday."
        },
        %{
          "session_id" => "longmemeval-smoke-1",
          "scope_path" => "/bench/longmemeval",
          "peer_key" => "sam",
          "role" => "assistant",
          "content" =>
            "Sam confirmed that the team uses OpenRouter with openai/gpt-oss-120b for POC reasoning."
        },
        %{
          "session_id" => "beam-smoke-1",
          "scope_path" => "/bench/beam",
          "peer_key" => "dev-agent",
          "role" => "assistant",
          "content" =>
            "The BEAM smoke curve starts with tiny corpora before any 1M-token or 10M-token run."
        }
      ],
      "questions" => [
        %{
          "id" => "locomo-q1",
          "scope_path" => "/bench/locomo",
          "question" => "What kind of status updates does Alice prefer?",
          "expected" => "concise"
        },
        %{
          "id" => "longmemeval-q1",
          "scope_path" => "/bench/longmemeval",
          "question" => "Which model is used for POC reasoning?",
          "expected" => "openai/gpt-oss-120b"
        },
        %{
          "id" => "beam-q1",
          "scope_path" => "/bench/beam",
          "question" => "What scale should BEAM start with?",
          "expected" => "tiny corpora"
        }
      ]
    }
  end

  defp load_dataset(path) do
    path
    |> File.read!()
    |> Jason.decode!()
  end
end
