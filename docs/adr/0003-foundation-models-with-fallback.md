# 0003. On-device verdict via FoundationModels with deterministic fallback

* **Status:** Accepted
* **Date:** 2026-05-12
* **Deciders:** Graham, Claude

## Context

A Watt report needs a plain-language verdict ("Battery dropped 47% in 58 min because…"). We had three places this could come from:

1. A cloud LLM (OpenAI/Anthropic) — would require network egress, API keys, and a privacy review for an app that watches a user's processes.
2. The on-device Apple Intelligence Foundation Model exposed via `FoundationModels` (macOS 26+).
3. A handcrafted templated string built from the suspect ranking.

The user wants the report to be useful even when Apple Intelligence is disabled.

## Decision

`ReportGenerator` always renders the deterministic Markdown body — at-a-glance table, timeline, suspects, raw data. Only the **verdict paragraph** and **per-suspect rationale strings** are AI-generated. They flow through a `@Generable DrainVerdict` struct, sent to a `LanguageModelSession` with `GenerationOptions(temperature: 0.2)`.

If `SystemLanguageModel.availability` is anything other than `.available`, `Templater.fallbackVerdict(...)` produces a deterministic, rule-based verdict from the same inputs. Reports rendered via the fallback path are byte-identical to AI-rendered ones in every section *except* the verdict and the per-suspect rationales — there's a snapshot test enforcing this.

## Consequences

- Apple Intelligence off: report still renders correctly, just with a labelled "Templated — Apple Intelligence is off" verdict.
- All inference is on-device. No network egress, no API keys, no third-party data sharing.
- The deterministic-Markdown contract means we can iterate on the verdict prompt independently of the layout.
- AI output is constrained to a small, structured surface (4 fields). The model can't drift the report's structure even if it hallucinates wildly in the verdict.
- We pay a build-time dependence on the `FoundationModels` framework. `canImport(FoundationModels)` guards the whole module so a hypothetical non-macOS-26 build would still compile.

## Alternatives considered

- **Cloud LLM** — better quality verdicts (Claude/GPT). Rejected: privacy + procurement complexity for an app that's specifically about telling engineers what's spying on them.
- **Templater only** — simplest. Rejected: the prose feels mechanical and doesn't capture the "Falcon is reading every file Claude wrote" insight that an LLM articulates well.
- **Fine-tuned or external on-device model (mlx, llama.cpp)** — full control, but heavy dependency, separate model weights, separate update cycle. Rejected: FoundationModels does the job and ships with the OS.

## Revisit triggers

- If FoundationModels output quality regresses on a macOS update, lean harder on the templater while we figure out a better prompt.
- If we want to ship to consumers (not just internal Airbnb engineers) and they expect verdicts even on older Macs, add a cloud option behind an explicit user toggle.
- If Apple ships a higher-quality "system server" model that's a better fit, swap the model reference.
