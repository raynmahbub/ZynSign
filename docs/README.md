<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../Assets/Brand/Banner/banner-dark.svg">
  <img src="../Assets/Brand/Banner/banner-light.svg" alt="ZynSign — on-device iOS signing, made Apple-quality" width="100%">
</picture>

</div>

# ZynSign Documentation

Everything the project knows about itself lives in this folder. Start here;
every section below is browsable on GitHub and every page is written to be
read, not skimmed past.

![Version](https://img.shields.io/badge/version-1.0.0-orange)
![Architecture](https://img.shields.io/badge/architecture-ZAS%20v1.0-lightgrey)
![Design](https://img.shields.io/badge/design-ZDL%20v1.0-blueviolet)

<p align="center">
  <img src="architecture/diagrams/layers-light.svg" alt="ZynSign four-layer architecture" width="640">
</p>

## Sections

| Section | What it answers | Start with |
|---|---|---|
| [architecture/](architecture/) | *How is it built?* — ZAS v1.0, the signing pipeline, every subsystem decision | [architecture.md](architecture/architecture.md) |
| [product/](product/) | *What is it, and what does it refuse to claim?* — value proposition, the honest anti-roadmap, the v3.0 Nova roadmap | [WHAT_DOES_NOT_EXIST.md](product/WHAT_DOES_NOT_EXIST.md) · [ROADMAP-v3.0-nova.md](product/ROADMAP-v3.0-nova.md) |
| [internal/](internal/) | *What did a milestone touch, and what did the audit find?* — design-system audit, architecture preservation report | [ArchitecturePreservationReport.md](internal/ArchitecturePreservationReport.md) |
| [design/](design/) | *How does it look and move?* — ZDL v1.0 tokens, components, motion, the brand book | [zynsign-design-language.md](design/zynsign-design-language.md) · [brand/](design/brand/README.md) |
| [security/](security/) | *How is sensitive material handled?* — identities, profiles, release review | [signing-identities.md](security/signing-identities.md) |
| [releases/](releases/) | *How does it ship?* — version strategy, the release train, the private → public gate | [release-train.md](releases/release-train.md) |
| [hardening/](hardening/) | *How is a candidate judged?* — Compatibility Lab, matrices, release blockers | [compatibility-lab.md](hardening/compatibility-lab.md) |
| [testing/](testing/) | *How is it verified?* — unit suites, host vectors, store-browser checks | [store-browser.md](testing/store-browser.md) |
| [development/](development/) | *How do you work on it?* — CI, toolchain, release readiness | [continuous-integration.md](development/continuous-integration.md) |
| [audits/](audits/) | *What did independent passes find?* — dated audit records | [2026-09-25-horizon-0.1.0-audit.md](audits/2026-09-25-horizon-0.1.0-audit.md) |

## Diagrams

Drawn once, in SVG, in light and dark variants — the same assets the README
uses. Never screenshot the app to explain the architecture.

| Diagram | Light | Dark |
|---|---|---|
| The four layers (`Presentation → Application → Domain ← Platform`) | [layers-light.svg](architecture/diagrams/layers-light.svg) | [layers-dark.svg](architecture/diagrams/layers-dark.svg) |
| The nine-stage signing pipeline | [signing-pipeline-light.svg](architecture/diagrams/signing-pipeline-light.svg) | [signing-pipeline-dark.svg](architecture/diagrams/signing-pipeline-dark.svg) |

## Reading paths

New here? Three paths cover almost every question:

- **"What does this app actually do?"** → [product/UNIQUE_VALUE_PROPOSITION.md](product/UNIQUE_VALUE_PROPOSITION.md), then the README's *Honest limitations* section, then [product/WHAT_DOES_NOT_EXIST.md](product/WHAT_DOES_NOT_EXIST.md).
- **"How does signing work?"** → [architecture/application-signing-pipeline.md](architecture/application-signing-pipeline.md), then [architecture/signing-engine-execution.md](architecture/signing-engine-execution.md), then [architecture/external-validation.md](architecture/external-validation.md).
- **"How do I build and test it?"** → the README's *Development* section, then [development/continuous-integration.md](development/continuous-integration.md), then [CONTRIBUTING.md](../CONTRIBUTING.md).

## House rules for these pages

- Write only what was verified. A page describes behaviour that exists; plans
  are labelled *planned* or left out.
- No emoji as structure — headings, tables, and honest sentences carry the
  meaning.
- Diagrams are SVG in `architecture/diagrams/`, never photos of screens, and
  every diagram ships in light and dark variants.
- Every claim that could rot links to its source: a Swift file, a script, or a
  recorded decision.
