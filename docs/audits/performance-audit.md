# Performance audit — procedure and budgets

Static gates cannot measure time. This is the Instruments pass that runs on a
release candidate, on a real device, before a tag. Results are recorded in a
dated file next to this one; budgets that fail block the tag.

## Budgets

| Metric | Budget | How measured |
|---|---|---|
| Cold launch to first frame of Home | **≤ 1.0 s** on iPhone 12, ≤ 0.6 s on iPhone 15 Pro | App Launch template, 5 runs, median |
| Warm launch | ≤ 0.3 s | same |
| Smart Workspace snapshot (`SmartWorkspaceService.snapshot`) | ≤ 50 ms with 200 apps, 20 identities, 30 profiles | `os_signpost` around `snapshot`, Time Profiler |
| Library scroll, 1 000 entries | ≥ 58 fps sustained, 0 hitches > 8 ms | Animation Hitches template |
| Memory after import of a 300 MB IPA | peak ≤ 180 MB above baseline, returns to baseline ±10 MB | Allocations, mark generations |
| Leaks | 0 | Leaks template over: import → inspect → sign → deliver → back to Home, ×3 |
| Retain cycles | 0 | Memory Graph Debugger on the same path |
| Signing a 50 MB IPA (5 frameworks) | ≤ 12 s on iPhone 12 | Signing diagnostics report, `SigningDiagnosticsService` |
| Background download resume | resumes within 2 s of foreground | Network template |
| Energy | "Low" during idle Home; no timers firing while backgrounded | Energy Log |
| Binary size (thinned, arm64) | ≤ 12 MB | App Thinning size report |

## Procedure

1. Release configuration, on device, `-ZynSignReleaseStage rc3`, Library seeded with synthetic IPAs (the host vectors under `Tests/Host/` build valid ones) — never personal certificates.
2. **Launch** — Instruments › App Launch. Kill the app between runs. Record the five cold runs and three warm runs.
3. **Hitches** — Animation Hitches. Scroll the Library from top to bottom and back at normal speed; then the Smart Workspace; then the Downloads list with 50 items.
4. **Allocations + Leaks** — one instrument session across the whole import → sign → deliver path, three times, marking a generation before each import. Every generation after the first must be ~0 persistent.
5. **Time Profiler** — with `os_signpost` intervals (the Compatibility Lab already signposts; add the same to) `SmartWorkspaceService.snapshot`, `ApplicationLibrary.entries`, `NovaAdvisor.recommendations`, the nine signing stages. Anything on the main thread longer than 16 ms is a defect.
6. **Energy** — leave the app on Home for 10 minutes, then backgrounded for 10 minutes.
7. Record in `docs/audits/<date>-performance-<tag>.md` with the table above filled in and the `.trace` bundle's SHA-256 (the bundle itself is not committed).

## Known hot paths and their guards

| Path | Guard |
|---|---|
| Library listing | Actor-isolated catalog, paged reads, thumbnail cache bounded by count |
| Workspace snapshot | Read-only over existing stores; facts capped (5 most recent apps for advice); no work on the main actor except the final publish |
| Advisor | O(apps × profiles × patterns) with small constants; runs off the main actor inside `snapshot` |
| Health preview | Pure, computed per render for one app; cache in the view if the profiler shows it |
| Nested signing | Streams each Mach-O; never loads a whole IPA into memory |

## Automated companions

* `Tests/Host/*` vectors keep the signing pipeline's byte output deterministic — a perf regression there shows up as a time-out first.
* `ZynSignTests` has no `measure {}` blocks yet; the first candidates are the ZIP writer, the Mach-O parser, and `WorkspaceLayoutPolicy.order` with 10 000 usage signals. Add them when this audit first runs so later runs have a baseline.
* A UI test target with `XCTApplicationLaunchMetric` is the next addition once the project has a UI-test scheme (tracked in the roadmap under Developer Console).
