# 0004. Markdown report body is the source of truth

* **Status:** Accepted
* **Date:** 2026-05-12
* **Deciders:** Graham, Claude

## Context

Watt's purpose is to give an engineer evidence to bring to their security team. That evidence has to be:

- Readable by humans without running Watt.
- Pasteable into Slack/email/Jira intact.
- Diffable (so "before vs. after we excluded /tmp from Falcon" is a meaningful comparison).
- Greppable for follow-up audits.

The alternative would be a structured representation (JSON / Codable values) where the UI renders it on demand and "exporting" means serializing the structure.

## Decision

Generate Markdown once during report generation and persist it as the canonical body in `Report.markdown`. Every consumer reads from this string:

- The in-app `ReportWindow` renders it via `Textual.StructuredText`.
- "Copy for Slack" puts it on the pasteboard verbatim.
- The on-disk mirror at `~/Library/Application Support/Watt/Reports/episode-<timestamp>-<ai|templated>.md` is the same string.
- "Export .md" writes it byte-for-byte.

`MarkdownReportBuilder` is the single producer. Sections (At a glance, Timeline, Prime suspects, Recommended actions, Raw data) follow a fixed structure so a future report can be diffed against an earlier one.

## Consequences

- The Markdown is what survives. If a future version of the schema changes, old reports remain readable as plain text.
- Re-rendering an old report after a code change isn't possible — the persisted Markdown reflects whatever the builder was doing at generation time. (This is a feature, not a bug: it's a forensics record, not a live view.)
- The "Regenerate report" button explicitly creates a new `Report` row, preserving the prior one for diffing.
- We can't reformat the body without writing a migration that re-renders historical reports. Acceptable.

## Alternatives considered

- **Persist a structured `ReportPayload` and render Markdown on demand** — flexible but invites schema drift, and the rendered output would change retroactively whenever the renderer changes. Rejected: forensics records need to be stable.
- **Persist HTML** — better for in-app rendering but bad for Slack and `grep`. Rejected.
- **Persist both Markdown and JSON** — extra storage with no clear win. Rejected.

## Revisit triggers

- If users start asking to "reformat all my old reports with the new style," reconsider — but probably the right answer is still "click Regenerate."
- If the report grows complex enough that templating in Swift becomes painful, consider moving to a separate template language (e.g., Stencil) but keep Markdown as the output format.
