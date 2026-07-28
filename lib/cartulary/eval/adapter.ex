# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Eval.Adapter do
  @moduledoc """
  Normalizes public memory benchmark fixtures into Cartulary's eval case shape.

  The normalized representation is intentionally independent from the benchmark
  source files so every runner uses the same ingestion, answering, and scoring
  path.
  """

  @benchmark_names ~w(locomo longmemeval convomem beam cartulary)

  def load!(path, opts \\ []) do
    body = read_fixture!(path)

    dataset =
      body
      |> decode_fixture!()
      |> normalize(opts)

    Map.merge(dataset, %{
      dataset_id: Path.basename(path),
      dataset_sha256:
        body
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)
    })
  end

  def normalize(data, opts \\ []) do
    benchmark =
      opts
      |> Keyword.get(:benchmark)
      |> normalize_benchmark()
      |> case do
        nil -> detect_benchmark(data)
        benchmark -> benchmark
      end

    case benchmark do
      "locomo" -> normalize_locomo(data)
      "longmemeval" -> normalize_longmemeval(data)
      "convomem" -> normalize_convomem(data)
      "beam" -> normalize_beam(data)
      "cartulary" -> normalize_cartulary(data)
    end
  end

  # Benchmark fixture paths come from the local Mix task, not from a web request.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_fixture!(path), do: File.read!(path)

  defp decode_fixture!(body) do
    trimmed = String.trim(body)

    if String.starts_with?(trimmed, ["[", "{"]) do
      Jason.decode!(body)
    else
      trimmed
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
    end
  end

  defp normalize_benchmark(nil), do: nil

  defp normalize_benchmark(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_benchmark()

  defp normalize_benchmark(value) when is_binary(value) do
    value = value |> String.downcase() |> String.replace(~r/[^a-z]/, "")

    cond do
      value in @benchmark_names -> value
      value == "longmemevalv2" -> "longmemeval"
      value == "local" -> "cartulary"
      true -> nil
    end
  end

  defp detect_benchmark(%{"benchmark" => benchmark} = data) do
    normalize_benchmark(benchmark) || detect_benchmark(Map.delete(data, "benchmark"))
  end

  defp detect_benchmark(%{"messages" => messages, "questions" => questions})
       when is_list(messages) and is_list(questions),
       do: "cartulary"

  defp detect_benchmark([first | _]) when is_map(first) do
    cond do
      Map.has_key?(first, "conversation") and Map.has_key?(first, "qa") -> "locomo"
      Map.has_key?(first, "haystack_sessions") -> "longmemeval"
      Map.has_key?(first, "conversations") and Map.has_key?(first, "question") -> "convomem"
      true -> "beam"
    end
  end

  defp detect_benchmark(%{"haystack_sessions" => _}), do: "longmemeval"
  defp detect_benchmark(%{"conversation" => _, "qa" => _}), do: "locomo"
  defp detect_benchmark(%{"conversations" => _, "question" => _}), do: "convomem"
  defp detect_benchmark(_data), do: "beam"

  defp normalize_cartulary(%{"messages" => messages, "questions" => questions} = data) do
    benchmark = Map.get(data, "benchmark", "cartulary")
    case_id = Map.get(data, "id", benchmark)

    %{
      benchmark: benchmark,
      source_format: "cartulary",
      cases: [
        %{
          id: to_string(case_id),
          scope_path: "/bench/#{benchmark}/#{slug(case_id)}",
          category: nil,
          scale: nil,
          metadata: Map.get(data, "metadata", %{}),
          messages: Enum.map(messages, &normalize_cartulary_message(&1, case_id)),
          questions: Enum.map(questions, &normalize_cartulary_question(&1, case_id))
        }
      ]
    }
  end

  defp normalize_cartulary(data) when is_list(data) do
    %{
      benchmark: "cartulary",
      source_format: "cartulary-jsonl",
      cases:
        data
        |> Enum.with_index(1)
        |> Enum.map(fn {item, index} ->
          normalize_cartulary(Map.put_new(item, "id", "case-#{index}")).cases |> hd()
        end)
    }
  end

  defp normalize_cartulary_message(message, case_id) do
    id =
      message
      |> first_present(["id", "message_id", "benchmark_ref"])
      |> default_to("#{case_id}:message:#{stable_hash(message)}")

    %{
      id: to_string(id),
      session_id: message |> Map.get("session_id", "#{case_id}-session") |> to_string(),
      scope_path: Map.get(message, "scope_path"),
      peer_key: message |> Map.get("peer_key", "peer") |> to_string(),
      role: message |> Map.get("role", "user") |> normalize_role(),
      content: message |> Map.fetch!("content") |> to_string(),
      occurred_at: Map.get(message, "occurred_at"),
      metadata: Map.get(message, "metadata", %{})
    }
  end

  defp normalize_cartulary_question(question, case_id) do
    id = question |> Map.get("id", "#{case_id}:question:#{stable_hash(question)}") |> to_string()
    evidence_refs = listify(Map.get(question, "evidence") || Map.get(question, "evidence_refs"))

    %{
      id: id,
      scope_path: Map.get(question, "scope_path"),
      question: question |> Map.fetch!("question") |> to_string(),
      expected: expected_values(question),
      category:
        question |> first_present(["category", "question_type", "ability"]) |> maybe_string(),
      evidence_refs: Enum.map(evidence_refs, &to_string/1),
      evidence_granularity: Map.get(question, "evidence_granularity", "turn"),
      abstention_expected: abstention_expected?(question),
      metadata: Map.get(question, "metadata", %{})
    }
  end

  defp normalize_locomo(data) when is_map(data), do: normalize_locomo([data])

  defp normalize_locomo(samples) when is_list(samples) do
    %{
      benchmark: "locomo",
      source_format: "locomo10",
      cases:
        samples
        |> Enum.with_index(1)
        |> Enum.map(fn {sample, index} ->
          case_id = sample |> Map.get("sample_id", "locomo-#{index}") |> to_string()
          conversation = Map.fetch!(sample, "conversation")

          %{
            id: case_id,
            scope_path: "/bench/locomo/#{slug(case_id)}",
            category: nil,
            scale: "long-conversation",
            metadata: %{
              "speaker_a" => conversation["speaker_a"],
              "speaker_b" => conversation["speaker_b"]
            },
            messages: locomo_messages(conversation, case_id),
            questions: locomo_questions(Map.get(sample, "qa", []), case_id)
          }
        end)
    }
  end

  defp locomo_messages(conversation, case_id) do
    conversation
    |> Enum.flat_map(fn
      {"session_" <> suffix = key, turns} when is_list(turns) ->
        case Integer.parse(suffix) do
          {session_number, ""} ->
            date = Map.get(conversation, "#{key}_date_time")
            session_id = "#{case_id}-session-#{session_number}"

            turns
            |> Enum.with_index(1)
            |> Enum.map(fn {turn, index} ->
              speaker = Map.get(turn, "speaker", "speaker")
              dia_id = turn |> Map.get("dia_id", "D#{session_number}:#{index}") |> to_string()

              %{
                id: dia_id,
                session_id: session_id,
                scope_path: nil,
                peer_key: slug(speaker),
                role: locomo_role(speaker, conversation),
                content: locomo_content(turn),
                occurred_at: date,
                metadata: %{
                  "dia_id" => dia_id,
                  "speaker" => speaker,
                  "session_number" => session_number
                }
              }
            end)

          _invalid_session_key ->
            []
        end

      _other ->
        []
    end)
    |> Enum.sort_by(fn message ->
      message.metadata["dia_id"]
      |> String.replace_leading("D", "")
      |> String.split(":")
      |> Enum.map(&parse_int(&1, 0))
    end)
  end

  defp locomo_content(turn) do
    text = turn |> Map.get("text", "") |> to_string()

    case Map.get(turn, "blip_caption") do
      caption when is_binary(caption) and caption != "" -> "#{text}\nImage caption: #{caption}"
      _caption -> text
    end
  end

  defp locomo_role(speaker, %{"speaker_a" => speaker}), do: "user"
  defp locomo_role(_speaker, _conversation), do: "assistant"

  defp locomo_questions(questions, case_id) do
    questions
    |> Enum.with_index(1)
    |> Enum.map(fn {question, index} ->
      %{
        id: question |> Map.get("id", "#{case_id}-qa-#{index}") |> to_string(),
        scope_path: nil,
        question: question |> Map.fetch!("question") |> to_string(),
        expected: expected_values(question),
        category: question |> Map.get("category") |> maybe_string(),
        evidence_refs: question |> Map.get("evidence", []) |> listify() |> Enum.map(&to_string/1),
        evidence_granularity: "turn",
        abstention_expected: abstention_expected?(question),
        metadata: Map.drop(question, ["question", "answer", "evidence"])
      }
    end)
  end

  defp normalize_longmemeval(data) when is_map(data), do: normalize_longmemeval([data])

  defp normalize_longmemeval(instances) when is_list(instances) do
    %{
      benchmark: "longmemeval",
      source_format: "longmemeval-cleaned",
      cases:
        instances
        |> Enum.with_index(1)
        |> Enum.map(fn {instance, index} ->
          question_id = instance |> Map.get("question_id", "longmemeval-#{index}") |> to_string()
          category = longmemeval_category(instance)

          %{
            id: question_id,
            scope_path: "/bench/longmemeval/#{slug(question_id)}",
            category: category,
            scale: longmemeval_scale(instance),
            metadata:
              Map.take(instance, ["question_date", "haystack_session_ids", "answer_session_ids"]),
            messages: longmemeval_messages(instance, question_id),
            questions: [
              %{
                id: question_id,
                scope_path: nil,
                question: instance |> Map.fetch!("question") |> to_string(),
                expected: expected_values(instance),
                category: category,
                evidence_refs:
                  instance
                  |> Map.get("answer_session_ids", [])
                  |> listify()
                  |> Enum.map(&to_string/1),
                evidence_granularity: "session",
                abstention_expected: category == "abstention" or abstention_expected?(instance),
                metadata: Map.take(instance, ["question_date"])
              }
            ]
          }
        end)
    }
  end

  defp longmemeval_messages(instance, question_id) do
    session_ids = Map.get(instance, "haystack_session_ids", [])
    dates = Map.get(instance, "haystack_dates", [])

    instance
    |> Map.get("haystack_sessions", [])
    |> Enum.with_index()
    |> Enum.flat_map(fn {session, session_index} ->
      session_id =
        session_ids
        |> Enum.at(session_index, "#{question_id}-session-#{session_index + 1}")
        |> to_string()

      occurred_at = Enum.at(dates, session_index)

      session
      |> Enum.with_index(1)
      |> Enum.map(fn {turn, turn_index} ->
        role = turn |> Map.get("role", "user") |> normalize_role()

        %{
          id: "#{session_id}:#{turn_index}",
          session_id: "#{question_id}-#{session_id}",
          scope_path: nil,
          peer_key: role,
          role: role,
          content: turn |> Map.get("content", "") |> to_string(),
          occurred_at: occurred_at,
          metadata: %{"source_session_id" => session_id, "turn_index" => turn_index}
        }
      end)
    end)
  end

  defp longmemeval_category(instance) do
    if longmemeval_abstention_id?(instance) do
      "abstention"
    else
      case Map.get(instance, "question_type") do
        nil -> nil
        value -> to_string(value)
      end
    end
  end

  defp longmemeval_abstention_id?(%{"question_id" => id}) when is_binary(id),
    do: String.ends_with?(id, "_abs")

  defp longmemeval_abstention_id?(_instance), do: false

  defp longmemeval_scale(instance) do
    count = instance |> Map.get("haystack_sessions", []) |> length()

    cond do
      count >= 400 -> "m"
      count > 0 -> "s"
      true -> nil
    end
  end

  defp normalize_convomem(data) when is_map(data) do
    rows =
      cond do
        is_list(data["data"]) -> data["data"]
        is_list(data["questions"]) -> data["questions"]
        true -> [data]
      end

    normalize_convomem(rows)
  end

  defp normalize_convomem(rows) when is_list(rows) do
    %{
      benchmark: "convomem",
      source_format: "convomem",
      cases:
        rows
        |> Enum.with_index(1)
        |> Enum.map(fn {row, index} ->
          case_id =
            row
            |> first_present(["id", "question_id", "sample_id"])
            |> default_to("convomem-#{index}")
            |> to_string()

          category =
            row
            |> first_present(["category", "question_type", "type"])
            |> maybe_string()

          conversations =
            row
            |> first_present(["conversations", "conversation_history", "history", "messages"])
            |> listify()

          %{
            id: case_id,
            scope_path: "/bench/convomem/#{slug(case_id)}",
            category: category,
            scale: conversations |> length() |> Integer.to_string(),
            metadata: Map.take(row, ["split", "category", "question_type"]),
            messages: convomem_messages(conversations, case_id),
            questions: [
              %{
                id: case_id,
                scope_path: nil,
                question: row |> Map.fetch!("question") |> to_string(),
                expected: expected_values(row),
                category: category,
                evidence_refs:
                  row
                  |> first_present(["evidence", "evidence_ids", "supporting_message_ids"])
                  |> listify()
                  |> Enum.map(&to_string/1),
                evidence_granularity: "turn",
                abstention_expected:
                  category in ["abstention", "unanswerable"] or abstention_expected?(row),
                metadata: Map.take(row, ["split"])
              }
            ]
          }
        end)
    }
  end

  defp convomem_messages(conversations, case_id) do
    conversations
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {conversation, conversation_index} ->
      if is_map(conversation) do
        session_id =
          conversation
          |> first_present(["id", "conversation_id", "session_id"])
          |> default_to("#{case_id}-conversation-#{conversation_index}")
          |> to_string()

        case first_present(conversation, ["messages", "turns", "conversation"]) do
          turns when is_list(turns) ->
            convomem_turns(turns, case_id, session_id)

          _turns ->
            convomem_turns([conversation], case_id, session_id)
        end
      else
        []
      end
    end)
  end

  defp convomem_turns(turns, case_id, session_id) do
    turns
    |> Enum.with_index(1)
    |> Enum.map(fn {turn, index} ->
      role = turn |> first_present(["role", "speaker"]) |> default_to("user") |> normalize_role()

      id =
        turn
        |> first_present(["id", "message_id", "turn_id"])
        |> default_to("#{session_id}:#{index}")
        |> to_string()

      %{
        id: id,
        session_id: "#{case_id}-#{session_id}",
        scope_path: nil,
        peer_key: role,
        role: role,
        content:
          turn
          |> first_present(["content", "text", "message"])
          |> default_to("")
          |> to_string(),
        occurred_at: first_present(turn, ["occurred_at", "timestamp", "date"]),
        metadata: %{"source_session_id" => session_id, "turn_index" => index}
      }
    end)
  end

  defp normalize_beam(data) when is_map(data) do
    cond do
      is_list(data["chats"]) -> normalize_beam(data["chats"])
      is_list(data["conversations"]) -> normalize_beam(data["conversations"])
      is_list(data["data"]) -> normalize_beam(data["data"])
      true -> normalize_beam([data])
    end
  end

  defp normalize_beam(chats) when is_list(chats) do
    %{
      benchmark: "beam",
      source_format: "beam",
      cases:
        chats
        |> Enum.with_index(1)
        |> Enum.map(fn {chat, index} ->
          case_id = beam_case_id(chat, index)

          %{
            id: case_id,
            scope_path: "/bench/beam/#{slug(case_id)}",
            category: nil,
            scale: beam_scale(chat),
            metadata: Map.take(chat, ["chat_size", "scale", "domain", "topic"]),
            messages: beam_messages(chat, case_id),
            questions: beam_questions(chat, case_id)
          }
        end)
    }
  end

  defp beam_case_id(chat, index) do
    chat
    |> first_present(["chat_id", "conversation_id", "id", "sample_id"])
    |> default_to("beam-#{index}")
    |> to_string()
  end

  defp beam_messages(chat, case_id) do
    chat
    |> first_present(["conversation", "messages", "chat", "dialogue", "turns"])
    |> listify()
    |> Enum.with_index(1)
    |> Enum.map(fn {turn, index} ->
      role =
        turn
        |> first_present(["role", "speaker"])
        |> default_to(if(rem(index, 2) == 1, do: "user", else: "assistant"))
        |> normalize_role()

      turn_id =
        turn
        |> first_present(["id", "turn_id", "message_id", "dia_id"])
        |> default_to("#{case_id}:turn:#{index}")
        |> to_string()

      %{
        id: turn_id,
        session_id: case_id,
        scope_path: nil,
        peer_key: role,
        role: role,
        content:
          turn
          |> first_present(["content", "text", "message", "utterance", "answer"])
          |> default_to("")
          |> to_string(),
        occurred_at: first_present(turn, ["timestamp", "date", "created_at"]),
        metadata: %{"turn_index" => index}
      }
    end)
    |> Enum.reject(&(&1.content == ""))
  end

  defp beam_questions(chat, case_id) do
    chat
    |> first_present(["probing_questions", "questions", "qa"])
    |> listify()
    |> Enum.with_index(1)
    |> Enum.map(fn {question, index} ->
      %{
        id:
          question
          |> first_present(["question_id", "id"])
          |> default_to("#{case_id}:question:#{index}")
          |> to_string(),
        scope_path: nil,
        question: question |> Map.fetch!("question") |> to_string(),
        expected: expected_values(question),
        category:
          question
          |> first_present(["ability", "category", "question_type", "type"])
          |> maybe_string(),
        evidence_refs: beam_evidence_refs(question),
        evidence_granularity: "turn",
        abstention_expected: abstention_expected?(question),
        metadata: Map.take(question, ["difficulty", "rubric", "chat_size", "scale"])
      }
    end)
  end

  defp beam_evidence_refs(question) do
    question
    |> first_present([
      "evidence",
      "evidence_refs",
      "evidence_turns",
      "evidence_ids",
      "source_turn_ids"
    ])
    |> listify()
    |> Enum.flat_map(fn
      value when is_map(value) ->
        value
        |> first_present(["id", "turn_id", "message_id", "dia_id"])
        |> listify()

      value ->
        [value]
    end)
    |> Enum.map(&to_string/1)
  end

  defp beam_scale(chat) do
    chat
    |> first_present(["chat_size", "scale", "token_size", "size"])
    |> maybe_string()
  end

  defp expected_values(map) do
    map
    |> first_present([
      "answer",
      "expected",
      "expected_answer",
      "golden_answer",
      "reference_answer",
      "target"
    ])
    |> listify()
    |> Enum.map(&to_string/1)
  end

  defp abstention_expected?(map) do
    expected = expected_values(map) |> Enum.map(&String.downcase/1)

    category =
      map |> first_present(["category", "question_type", "ability", "type"]) |> maybe_string()

    Map.get(map, "abstention_expected", false) == true or
      category == "abstention" or
      Enum.any?(
        expected,
        &(&1 in [
            "not answerable",
            "no information available.",
            "no information available",
            "unknown"
          ])
      )
  end

  defp first_present(nil, _keys), do: nil

  defp first_present(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        nil -> nil
        "" -> nil
        value -> value
      end
    end)
  end

  defp listify(nil), do: []
  defp listify(value) when is_list(value), do: value
  defp listify(value), do: [value]

  defp default_to(nil, default), do: default
  defp default_to("", default), do: default
  defp default_to(value, _default), do: value

  defp maybe_string(nil), do: nil
  defp maybe_string(value), do: to_string(value)

  defp normalize_role(role) when is_binary(role) do
    case String.downcase(role) do
      "assistant" -> "assistant"
      "system" -> "system"
      "tool" -> "tool"
      _other -> "user"
    end
  end

  defp normalize_role(_role), do: "user"

  defp slug(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "case"
      slug -> slug
    end
  end

  defp stable_hash(value) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(value))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, _rest} -> integer
      :error -> default
    end
  end

  defp parse_int(value, _default) when is_integer(value), do: value
  defp parse_int(_value, default), do: default
end
