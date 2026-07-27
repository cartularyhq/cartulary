# Evaluation Documentation

The local POC includes a tiny smoke harness for the LoCoMo, LongMemEval, and
BEAM-style memory paths. It exercises the durable message write path, pipeline
knowledge extraction, scoped retrieval, grounded answering, and citation
validation against Postgres.

The broader POC implementation log and refactor list is maintained in
`docs/poc-local-proof.md`.

For development traces, experiment labels, Langfuse forwarding, and the
measurement checklist that should accompany eval reports, read
`docs/observability/README.md`.

Minimal LoCoMo, LongMemEval, and BEAM benchmark results are checked in at
`docs/eval/minimal-benchmark-results.md`, with raw JSON reports under
`docs/eval/results/`.

F0 also freezes the four tiny input fixtures independently of volatile database
UUIDs and latency values. `test/fixtures/eval/poc-contract-baseline.json`
records each Cartulary, LoCoMo, LongMemEval, and BEAM fixture's SHA-256 plus its
normalized case, message, and question IDs.

```bash
mix test test/cartulary/eval/fixture_contract_test.exs
```

```bash
mix cartulary.eval.smoke --profile balanced --account eval-poc
```

To write a JSON report:

```bash
mix cartulary.eval.smoke \
  --profile balanced \
  --account eval-poc \
  --output /private/tmp/cartulary-smoke-report.json
```

The built-in fixture is intentionally small. Custom fixtures use this shape:

```json
{
  "benchmark": "local-smoke",
  "messages": [
    {
      "session_id": "s1",
      "scope_path": "/bench/locomo",
      "peer_key": "alice",
      "role": "user",
      "content": "Alice prefers concise status updates."
    }
  ],
  "questions": [
    {
      "id": "q1",
      "scope_path": "/bench/locomo",
      "question": "What does Alice prefer?",
      "expected": "concise status updates"
    }
  ]
}
```

Run a fixture with:

```bash
mix cartulary.eval.smoke --dataset path/to/smoke.json --profile balanced
```

## Full Benchmark Ingestion And Scoring

The POC also includes a full benchmark runner for fixture ingestion and
deterministic scoring:

```bash
mix cartulary.eval.benchmark \
  --benchmark locomo \
  --dataset path/to/locomo10.json \
  --profile balanced \
  --account eval-locomo \
  --output /private/tmp/cartulary-locomo-report.json
```

Supported source formats:

- `--benchmark locomo`: LoCoMo `locomo10.json` samples with `conversation`
  sessions and `qa` evidence refs such as `D1:3`.
- `--benchmark longmemeval`: LongMemEval cleaned JSON files with
  `haystack_sessions`, `haystack_session_ids`, `answer_session_ids`, and
  per-question metadata.
- `--benchmark beam`: BEAM-style chat/probing-question JSON. The adapter accepts
  common generated-artifact field names such as `messages`, `conversation`,
  `probing_questions`, `questions`, `chat_size`, and `ability`.
- `--benchmark cartulary`: the local JSON shape used by the smoke harness.

Useful options:

```bash
mix cartulary.eval.benchmark \
  --dataset path/to/fixture.json \
  --limit-cases 1 \
  --limit-messages 200 \
  --limit-questions 10 \
  --no-model
```

`--no-model` forces the deterministic extractor and fallback answerer so local
regression runs do not depend on a model provider. Without it, the runner uses
the configured POC model path for extraction/answering, then scores the outputs
deterministically.

The JSON report includes:

- Per-question answer metrics: exact match, expected-answer containment,
  token-F1, abstention correctness, citation hit, citation recall, latency, and
  contributed retrieval strategies.
- Aggregate metrics overall, by category, and by scale.
- For BEAM, a `beam_degradation_curve` grouped by corpus scale.
- Profile version and run-limit evidence, per ADR-0004 / `AD-EVAL-3`.

The runner uses the real local POC write/read path (`Cartulary.Memory`) and
therefore records raw messages, pipeline-created knowledge, lifecycle events,
retrieval, answers, and citations in Postgres. It is still a POC harness: it
does not yet implement upstream LLM-judge parity, held-out weight tuning,
strategy ablation matrices beyond the currently configured profiles, release
thresholds, explicit deadline-disable/fixed-clock reporting, or operator-run
Postgres parity evidence.
