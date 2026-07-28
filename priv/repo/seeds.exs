# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

# Database seed script. Run it with:
#
#     mix run priv/repo/seeds.exs
#
# It is intentionally empty. Cartulary has no seed data: a fresh install is
# bootstrapped by `mix cartulary.identity.bootstrap`, which creates the
# community Account and its first administrator through the ordinary
# authentication actions.
#
# If you ever do add seeding here, write through Ash actions, not through
# `Cartulary.Repo.insert!/1`. Every durable row in this system belongs to an
# Account and is subject to Ash policies, row-level security, and — for
# knowledge — the extraction pipeline and the governance gates. Inserting with
# Ecto bypasses all of that and produces rows that the application will not
# treat as valid: unattributed, ungoverned, and invisible to retrieval.
#
# Prefer the bang variants (`Ash.create!/2`, `Ash.update!/2`) so a broken seed
# aborts loudly instead of leaving the database half-populated.
