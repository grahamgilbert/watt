# NNNN. Title (imperative phrase, e.g. "Use IOReport for system power")

* **Status:** Proposed | Accepted | Superseded by NNNN | Deprecated
* **Date:** YYYY-MM-DD
* **Deciders:** Graham, Claude

## Context

What problem are we solving? What are the constraints? What was true when we made this decision (e.g. macOS 26 only, Apple Silicon only, internal distribution)?

## Decision

The actual choice in one or two sentences. Be specific — name the API, the constant, the dependency.

## Consequences

What this means in practice. Both the wins ("we don't need a privileged helper") and the costs ("we depend on a private API surface that could change").

## Alternatives considered

Each option we evaluated, in 2-3 lines:

- **Option A** — what it was, why we didn't pick it.
- **Option B** — likewise.

## Revisit triggers

Conditions that should make us reopen this ADR:

- "If Apple ships a public X API, switch to that."
- "If we measure Y to be unreliable, fall back to Z."
- "If the user-base goes wider than internal Airbnb engineers, reconsider."
