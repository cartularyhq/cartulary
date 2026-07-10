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


## Implemented issue coverage

This workflow intentionally implements the initial CI issue batch as one PR:

- [#12](https://github.com/cartularyhq/cartulary/issues/12) — Elixir formatter check.
- [#13](https://github.com/cartularyhq/cartulary/issues/13) — warnings-as-errors compile check.
- [#14](https://github.com/cartularyhq/cartulary/issues/14) — unit test check.
- [#15](https://github.com/cartularyhq/cartulary/issues/15) — Credo strict static-analysis check.
- [#16](https://github.com/cartularyhq/cartulary/issues/16) — Dialyzer type-analysis check with PLT caching.
- [#17](https://github.com/cartularyhq/cartulary/issues/17) — Sobelow security scan.
- [#18](https://github.com/cartularyhq/cartulary/issues/18) — dependency audit check.
- [#19](https://github.com/cartularyhq/cartulary/issues/19) — SQLite/single-node backend test lane.

The repository does not yet contain `mix.exs`, so each job exits with an
explicit GitHub Actions notice until the Mix/Phoenix project lands. Once
`mix.exs` exists, the same jobs install dependencies and run the commands above;
missing tool dependencies or configuration should then fail visibly rather than
being suppressed.

Sobelow false positives and dependency-audit exceptions must be documented in a
reviewable security note before being accepted. Do not suppress security or
dependency findings without human approval.
