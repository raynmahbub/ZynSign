<!--
ZynSign pull request template.
Title must be a Conventional Commit: feat: fix: refactor: perf: docs: ci: test: build: chore: style:
Example: feat(signing): introduce Install Health diagnostics
-->

# Summary

What changed and why.

# Related Issues

Closes #<!-- issue number, or remove -->

# Type of Change

- [ ] ✨ Feature (`feat`)
- [ ] 🐛 Bug fix (`fix`)
- [ ] ♻️ Refactor (`refactor`)
- [ ] ⚡ Performance (`perf`)
- [ ] 🎨 UI (`ui`)
- [ ] 🔒 Security (`security`)
- [ ] 📚 Documentation (`docs`)
- [ ] 🛠 CI / tooling (`ci`)
- [ ] ✅ Tests (`test`)

# Changes

- <!-- One important change per line. -->

# Architecture

<!--
The Architecture Guard enforces the layered contract automatically.
Tick what applies:
-->

- [ ] Domain stays free of SwiftUI / UIKit / Security / WebKit
- [ ] No new Presentation → Platform concrete-type dependency (or the allowlist change is explained)
- [ ] No signing behaviour changed

# Testing

What was actually tested (unit tests, simulator, device, Compatibility Lab).

# Checklist

- [ ] Commits follow Conventional Commits (commitlint runs in CI)
- [ ] Tests added or updated for behaviour changes
- [ ] `CHANGELOG.md` `[Unreleased]` updated for user-visible changes
- [ ] Documentation updated where relevant
- [ ] Branch follows the naming convention (`feature/…`, `fix/…`, `docs/…`, `refactor/…`)
