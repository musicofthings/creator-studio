# ADR 0003: Deterministic edit graph and suggestions

**Status:** Accepted for bootstrap

## Decision

Keep automatic analysis as versioned `Suggestion` records. Only an explicit acceptance or high-confidence policy produces ordinary edit commands in the canonical timeline.

## Rationale

AI/rule outputs evolve and may be wrong. Users need reproducibility, manual precedence, undo, and clear provenance.

## Consequences

Suggestion schemas include evidence, confidence, source version, status, and input hash. Re-analysis merges rather than overwrites accepted edits. Metrics can measure acceptance without uploading content.
