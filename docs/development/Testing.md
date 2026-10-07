# Testing

What is verified, where, and by whom. The reporting rule applies to your own
work too: name the check you ran and what it returned — a clean exit code on a
check that never touched the change is not a verification.

## Layers of verification

| Layer | Runs on | Entry point |
|---|---|---|
| Unit + fixture tests (`ZynSignTests`) | iOS Simulator | `xcodebuild test` — domain, archive, import, library, certificates, provisioning, MachO, signing metadata |
| Host vector scripts (`Tests/Host/verify_*.py`) | macOS, any Python 3 | `python3 Tests/Host/verify_macho_signing_vector.py`, `verify_nested_code_signing_vector.py`, `verify_zip_writer_vectors.py` |
| External validation (`Tests/Host/external_validation.py`) | macOS with Xcode | `python3 Tests/Host/external_validation.py run` — the produced artifacts are judged by Apple's own `codesign` / `otool` / `openssl` |
| Repository audits (`Scripts/audit_*.py`) | anywhere | crash surface, accessibility, regression coverage — also CI gates |
| Compatibility Lab | a real device, Debug build | `Settings → Compatibility Lab` — ten suites, one verdict |
| Store-browser checklist | Simulator/device | [../testing/store-browser.md](../testing/store-browser.md) |

## The audits, standalone

```sh
python3 Scripts/audit_crash_surface.py        # the crash-surface inventory vs baseline
python3 Scripts/audit_accessibility.py --strict
python3 Scripts/audit_regression_coverage.py  # the regression catalogue names real tests
python3 Scripts/audit_identity_stability.py    # identities stay put between re-renders
python3 Scripts/generate_hardening_report.py --output build/hardening/index.html
```

The hardening report is the browsable form of the audits; CI builds and
uploads it on every pull request and manual Build run.

## What CI enforces

The workflow (`.github/workflows/01-build.yml`, described in
[continuous-integration.md](continuous-integration.md)) runs for pull
requests and manual runs, not branch pushes. The pull-request run tests the
proposed merge commit; the Quality workflow separately runs static checks on
`main`/`develop` pushes. Its checks are:

1. **Hygiene** — no generated artifacts or machine state; the release
   metadata and verdict self-tests pass; the host vectors pass; the three
   audits pass; the hardening report builds. The full source-tree secret
   scan and release-train consistency check run in `02-quality.yml`; manual
   Build runs retain the secret scan and the release-metadata self-test also
   exercises the current-stop validation.
2. **Build and test** — the application target builds and the unit-test
   target passes on an iPhone simulator.
3. **External validation** — the job reports Apple's verdicts on
   ZynSign-signed artifacts; a `codesign` rejection is a *finding recorded
   in the report*, not a failed build. The job fails only when the harness
   cannot do its job.

## Expectations for new work

- New functionality arrives with tests. The regression catalogue
  (`Scripts/audit_regression_coverage.py`) freezes behaviours by name — a
  change that touches a frozen behaviour names the test that covers it.
- A check that did not run is an open question, not a pass. If a tool is
  unavailable in your environment, say so rather than implying it ran.
