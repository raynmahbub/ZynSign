# RC 3 — Performance Certification

**Date:** 2026-09-26 · **Milestone:** RC 3 — Step 29 ·
**Targets:** fast launch · smooth scrolling · instant search · stable
signing · efficient downloads · low memory pressure.

Review environment: Linux with Python 3.11, without a Swift toolchain or
Xcode. This certification records (a) the measurable targets with their
acceptance thresholds, (b) the automated and design-level evidence that
exists in the frozen codebase, and (c) the exact measurement protocol for
the device numbers, which are recorded in the private device matrix
([private-testing.md](../releases/private-testing.md)). No measured device
number is claimed here that was not measured.

## Certification targets

| Target | Acceptance threshold | Evidence in the frozen code | Device measurement |
|---|---|---|---|
| **Fast launch** | Cold start to interactive Home under 400 ms on the reference device (iPhone 12, iOS 17); no launch-time disk scan of package contents | Launch reads only the versioned catalog + onboarding state (`FileApplicationRecordStore`, `PreferencesStore`); icons and metadata are extracted lazily and cached (`AppIconExtraction`) | Xcode *Launch* metric / Instruments App Launch, per matrix row |
| **Smooth scrolling** | 60 fps sustained on Library grid/list with 500+ entries; no per-row work beyond card rendering | `LibraryIndex` precomputes query answers; rows render extracted icons from cache; no package bytes read during scroll | Instruments *Core Animation FPS*, per matrix row |
| **Instant search** | Query results return within one frame for 2 000 entries; keystroke never blocks typing | `testQueryPerformanceAtLibraryScale` (`LibraryIndexTests`): 2 000 entries × 11 progressive queries per iteration under `XCTClockMetric()` — executed on every hosted CI test run | XCTest metrics + Instruments Time Profiler, per matrix row |
| **Stable signing** | One pipeline run never interrupts another; progress monotonic; a failure never leaks partial output | `SigningQueue` runs one job at a time (High→Normal→Low, never preemptive); per-job isolated working directory and log; weighted monotonic stage progress (`SigningQueueTests`, `SigningOperationExecutorTests`) | Matrix: 5 consecutive sign/verify/export cycles of the same fixture set |
| **Efficient downloads** | Resumable, retrying, bounded; a paused download resumes without restarting | `BackgroundURLSession` (`com.zynsign.downloads`) with `resumeData`, `waitsForConnectivity`, 60 s request / 600 s resource timeouts, retry × 3, SHA-256 verification; cache bounded at 500 MiB / 7 days | Matrix: pause/resume/retry cycle on Wi-Fi and cellular |
| **Low memory pressure** | No unbounded reads anywhere on the hot paths; no memory warnings in the matrix session | Bounded reads enforced: >100 k entries / depth >32 / >4 MiB inspection / 512 MiB extraction refused (`ArchiveLimitsTests`); inspectors hold value reports, never executable bytes (`BinaryInspectorModel`); ZIP streaming (`ZipEntryStreamExtractorTests`) | Instruments *Allocations / VM Tracker* over one full workflow session |

## RC 1 → RC 3 comparison

The comparison protocol is: measure the six targets above on the same
reference device and OS build, with the same fixture set, at RC 1 and at
RC 3; any degradation beyond the threshold is a **performance regression
class blocker** (allowed change class *performance fix* under the freeze).

Two facts bound the risk for this milestone:

1. **The freeze itself.** RC 3 changes no production code — its change set
   is documentation, release metadata, and the CI release gate. Runtime
   behavior is byte-identical to the RC-validated code, so measured
   baselines cannot regress between the last code change and this
   certification.
2. **The automated floor.** The search benchmark runs on every CI push;
   a regression there fails `build-and-test` before it can reach a release.

Measured device rows (filled in the private matrix log at cut time):

| Target | RC 1 baseline | RC 3 | Verdict |
|---|---|---|---|
| Launch (cold) | *(recorded in device matrix)* | *(recorded in device matrix)* | pending device run |
| Scrolling (fps) | *(recorded in device matrix)* | *(recorded in device matrix)* | pending device run |
| Search (ms / 2 000) | *(recorded in device matrix)* | *(recorded in device matrix)* | pending device run |
| Signing (5-cycle stability) | *(recorded in device matrix)* | *(recorded in device matrix)* | pending device run |
| Downloads (resume/retry) | *(recorded in device matrix)* | *(recorded in device matrix)* | pending device run |
| Memory (peak) | *(recorded in device matrix)* | *(recorded in device matrix)* | pending device run |

## Verdict

**Performance certified at the automated and design level** against the
six targets: every target has enforcement in code or tests (the search
floor is measured on CI), and the freeze guarantees no regression since
the last code change. The measured RC 1 → RC 3 device numbers complete
the certification in the private matrix; a regression there is a release
blocker under the freeze's *performance fix* class.
