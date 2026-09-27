# Performance verification

## The benchmarks

These are internal policy. They are not Apple's numbers, not a measurement of
any particular device, and not a promise to a user: they are the thresholds
the Lab compares its own measurements against, so a change in performance is a
change somebody has to explain.

They were chosen to be generous enough that an ordinary device passes
comfortably, and tight enough that a regression is visible.

| What is measured | Benchmark | Where |
|---|---|---|
| First data read — preferences and the library catalog | 1 500 ms | In-app |
| Search — one query against the live library index, averaged over a run | 120 ms | In-app |
| Import speed — preparing one ordinary package | 600 ms | In-app |
| Signing preparation — preparing a package with frameworks | 1 500 ms | In-app |
| Large import — a package at ordinary large-application size | 4 000 ms | In-app |
| Resident memory in ordinary use | 384 MB | In-app |
| A bounded spike retained after release | 64 MB | In-app |
| Temporary footprint that earns a look | 512 MB | In-app |
| Repository probe latency under which a source counts as fast | 800 ms | In-app |
| Memory a device should have for a signing run | 2 GB | In-app |

Every measurement carries its threshold into the report, so a reader can see
the number, the benchmark, and whether it was met. A measurement with no
threshold is recorded as information, never as a verdict.

## What "first data read" is, and why it is not "launch time"

Launch time starts before any of ZynSign's code runs, and a process cannot
time its own launch honestly. What the Lab measures is the part ZynSign
controls: reading the preferences document and the library catalog, which is
the work a cold start does before the first list appears.

Total launch time is measured with Instruments (App Launch) or an XCTest
launch metric. `docs/hardening/performance-verification.md` names that as the
protocol rather than inventing a number.

## The one number ZynSign will not invent

**Frame rate during scrolling is not measured in-process.** A process cannot
honestly measure its own frame rate: the figure would depend on the observer,
and no reviewer could reproduce it. The Lab reports that row as `Not run`,
names the check that settles it, and accepts an imported result.

Protocol:

1. Instruments → Core Animation, on a device, with at least 50 applications in
   the library.
2. Scroll the Library grid and the Library list, at the default text size and
   again at the largest.
3. Sustained 60 fps (or the device's refresh rate). Drops are recorded with
   the screen, the size, and the content count.
4. Record the result as an overlay:

```json
{
  "source": "Instruments Core Animation, iPhone 15 Pro Max, iOS 18.1, 62 items",
  "statuses": { "performance.scrolling": "passed" }
}
```

## Reading a figure honestly

Three rules the report enforces:

- **A simulator result is labelled as one** and is never compared against a
  device benchmark.
- **A run made while the device is hot** is flagged: thermal throttling makes
  every timing figure meaningless.
- **A measurement that missed its benchmark is a warning, not a failure**,
  with the next step "re-measure on a device with a cool thermal state". A
  single slow run on a busy simulator is not a regression, and the report does
  not pretend it is.

## If a benchmark is missed

1. Re-measure on a device, not a simulator, at a nominal thermal state.
2. If it holds, profile before changing anything: the usual causes are a
   catalog that has grown, an index rebuilding more than it should when a term
   changes, and a cache that holds what it should evict.
3. If the benchmark itself is wrong, change it in `PerformanceBenchmark` and
   say why in the release notes. A benchmark nobody can meet is a benchmark
   that gets ignored.
