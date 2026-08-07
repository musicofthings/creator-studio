# ADR 0002: Framework-neutral capture boundary

**Status:** Accepted for bootstrap

## Decision

Define capture capabilities, state, events, artifacts, and errors in a portable module. Implement ReplayKit/broadcast and ScreenCaptureKit as adapters outside the domain.

## Rationale

Capture API availability, deprecation, background behavior, and permissions vary by Apple platform and OS. Product features must check capabilities instead of framework names.

## Consequences

Framework buffers are translated at the edge. The project records capability metadata. New picker/framework support can replace an adapter without a project migration.
