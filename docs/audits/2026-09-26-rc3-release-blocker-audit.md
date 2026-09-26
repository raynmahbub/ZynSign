# RC 3 — Release Blocker Audit

**Date:** 2026-09-26 · **Milestone:** RC 3 — Step 29 ·
**Scope:** every open issue, plus every known defect or limitation recorded
in the documentation.

## Method

1. **Issue tracker:** `gh issue list --state open` and `--state all` on
   `raynmahbub/ZynSign` on 2026-09-26. Both returned **zero issues** — the
   tracker has no open and no closed issues. Nothing is pending in it.
2. **Documentation sweep:** the known findings recorded in
   `docs/architecture/external-validation.md`,
   `docs/security/release-review.md`, `docs/releases/version-strategy.md`,
   `docs/releases/release-train.md`, and `docs/product/WHAT_DOES_NOT_EXIST.md`
   were classified below.
3. **Validation sweep:** coverage gaps found while building the
   [final validation matrix](../testing/final-validation-rc3.md) were
   classified below.

## Classification

| ID | Item | Priority | Action |
|---|---|---|---|
| — | *(none)* | **Critical** | — |
| High-1 | External validation: `codesign` accepts ZynSign's single-image signatures but rejects the pipeline's bundle and nested framework; the signature format fails Apple's documented iOS 15+ rules ([external-validation.md](../architecture/external-validation.md)) | **High** | Fix before Stable |
| High-2 | Real-device evidence for signing with genuine developer identities and profiles (experiments E1/E3/E4/E7, private matrix in [private-testing.md](../releases/private-testing.md)) is not yet recorded | **High** | Fix before Stable |
| Medium-1 | Packaging writer and archive extraction were added after the [release security review](../security/release-review.md) scope was fixed and remain unreviewed | **Medium** | Acceptable for RC; review before Stable |
| Medium-2 | Store Browser and Download Center have no dedicated behavioral test suites (covered by composition, release-train gating, and the device matrix) | **Medium** | Acceptable for RC; add suites in `1.0.1` |
| Medium-3 | Export Center and certificate public-backup paths have thin dedicated suites (covered indirectly by `SigningOperationExecutorTests`, store suites, and `SettingsCenterModelTests`) | **Medium** | Acceptable for RC; add suites in `1.0.1` |
| Low-1 | Directory resource store does not canonicalize intermediate symlink components ([release-review.md](../security/release-review.md), accepted risk) | **Low** | Move to `1.0.1` |
| Low-2 | Legacy dev releases `v0.2.0-dev` (marked Latest), `v0.1.1-dev`, `v0.1.0-dev` sort above `0.1.0` and confuse version comparison ([release-train.md](../releases/release-train.md), *Legacy tags*) | **Low** | Fix at publish time (mark pre-release / un-latest) |

## Known platform limitations (not defects)

These are product facts documented in
[WHAT_DOES_NOT_EXIST.md](../product/WHAT_DOES_NOT_EXIST.md) and
[installation-compatibility.md](../architecture/installation-compatibility.md).
They are **not** classified as blockers because they are platform
constraints ZynSign states rather than defects it introduced:

- In-app installation of arbitrary IPAs is unavailable
  (`noDeliveryMechanism`); signed output is delivered by the user.
- Pairing/JIT/Mux is never composed (private entitlements).
- Off-device analytics is off; the activity journal never leaves the device.

## Verdict

- **Critical blockers: 0.** RC approval is permitted.
- **High: 2.** Both are explicitly scheduled to clear before Stable
  (external-validation format work; private device matrix). Per
  [version-strategy.md](../releases/version-strategy.md), Stable ships only
  when Critical blockers reach zero **and** the High items above are done.
- **Medium: 3.** Ship-as-acceptable for RC with the recorded manual
  coverage; suites follow in maintenance releases.
- **Low: 2.** Deferred to `1.0.1` / publish-time hygiene.

Stable is **not** declared ready by this audit. RC 3 is.
