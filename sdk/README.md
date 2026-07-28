<!-- SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0 -->

# Cartulary SDK readiness helpers

The TypeScript and Python modules in this directory implement the
provider-neutral F9 helper contract around the server's `f9-1` readiness
report. They intentionally contain no generated transport client; F8 owns
generation of the complete HTTP/MCP clients.

Both helpers:

- refuse to continue when `blocked` is true;
- preserve preferred gaps as non-blocking warnings;
- turn `ask-peer` and `either` gaps into elicitation prompts;
- identify `from-memory` blockers that cannot be filled by elicitation; and
- direct callers to submit elicited answers through ordinary raw `ingest`,
  then rerun `check_readiness`.

The server remains the authority for matching, lifecycle freshness, Account and
scope authorization, and the inherited card version. SDK code must never
override a server blocker.
