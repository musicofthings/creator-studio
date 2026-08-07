# ADR 0001: Local-first project package

**Status:** Accepted for bootstrap

## Decision

Use a versioned directory package containing JSON authority documents and immutable source media. Use a database only as a rebuildable library/search index.

## Rationale

The project must work offline, move through Files/external storage, survive application/database replacement, and open on macOS later. Media-heavy projects are poorly suited to a monolithic database or opaque cloud document.

## Consequences

Atomic manifest writes, strict path validation, schema migration fixtures, cache rebuilds, and archive safety are mandatory. Cross-device simultaneous write/merge is not promised in the initial release.
