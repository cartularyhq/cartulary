# Evaluation Documentation

The local POC includes a tiny smoke harness for the LoCoMo, LongMemEval, and
BEAM-style memory paths. It exercises the durable message write path, pipeline
knowledge extraction, scoped retrieval, grounded answering, and citation
validation against Postgres.

The broader POC implementation log and refactor list is maintained in
`docs/poc-local-proof.md`.

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

This is not a full benchmark adapter yet. The production-grade LoCoMo,
LongMemEval, and BEAM runners still need fixture importers, scoring metrics,
latency/deadline reporting, larger corpus lanes, and backend parity evidence
against an operator-run Postgres environment. The governing eval architecture is
defined by `AD-EVAL-*` in `specs/memory-system-architecture-and-nfr.md`.
