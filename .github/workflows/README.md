# GitHub Actions workflows

This directory contains deterministic PR-gate workflows introduced by the L3
automation plan. Workflows use least-privilege `contents: read` permissions and
should not be marked as required branch-protection checks until each job has
reported successfully at least once.

`ci.yml` currently defines the requested Elixir/Phoenix lanes:

- `format` — `mix format --check-formatted`
- `compile` — `mix compile --warnings-as-errors`
- `test` — `mix test`
- `credo` — `mix credo --strict`
- `dialyzer` — `mix dialyzer`, with PLT cache keyed by `mix.lock`
- `sobelow` — `mix sobelow --config`
- `deps-audit` — `mix deps.audit`
- `sqlite` — `MIX_ENV=test CARTULARY_DATA_LAYER=sqlite mix test --only sqlite`

The repository does not yet contain `mix.exs`, so each job exits with an
explicit GitHub Actions notice until the Mix/Phoenix project lands. Once
`mix.exs` exists, the same jobs install dependencies and run the commands above;
missing tool dependencies or configuration should then fail visibly rather than
being suppressed.

Sobelow false positives and dependency-audit exceptions must be documented in a
reviewable security note before being accepted. Do not suppress security or
dependency findings without human approval.
