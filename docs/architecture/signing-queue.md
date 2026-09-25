# Professional Signing Queue

**Status:** Implemented · ships in `v0.1.0-alpha.2` (`ReleaseFeature.signingQueue`, prerequisite `.smartSign`)
**Scope:** Alpha 2 — Step 14

This document records how ZynSign turns signing from one blocking action
into a job-based system. Users can queue several apps, watch each job on its
own, and keep using the rest of the app while jobs run.

## 1. Shape

```
Presentation                       Application                         Platform
────────────                       ───────────                         ────────
SigningQueueView ─┐                SigningQueue (@MainActor)           FileSigningQueueStore (actor)
SigningJobDetailView ├─ observe ──▶  jobs · notices · scheduler  ──▶   queue.json + Profiles/<job>.mobileprovision
SigningQueueConfigurationView ─┘     │  enqueue / cancel / retry        LocalSigningQueueNotifier (@MainActor)
Library · Details · Import ──enqueue─┘  │                                UserNotifications, opt-in only
RootView (toasts, VoiceOver)            ▼
                                   SigningQueueExecuting (port)
                                        │
                                   PipelineSigningExecutor
                                        │  stage observer
                                   SignApplicationPipeline (unchanged 9 stages)
```

- **`SigningQueue`** is the job queue manager. Screens don't own signing
  work. They submit `SigningJobSubmission` values and watch published
  `Job` values. The queue lives in `ApplicationEnvironment`, so it keeps
  running when the user navigates away from a screen.
- **`SigningQueueExecuting`** is the port the queue runs jobs through.
  `PipelineSigningExecutor` is its only production implementation. It wraps
  the same `SignApplicationPipeline` that inline Smart Sign uses: one set of
  signing machinery with two entry points.
- **`SigningQueueStore`** and **`SigningQueueNotifying`** are the
  persistence and local-notification ports.

## 2. Job lifecycle

```
queued ──▶ running ──▶ completed
   │          ├──────▶ failed ──(retry: fresh, clean run)──▶ queued
   │          └──────▶ cancelled ──(retry)──▶ queued
   └─(cancel)─▶ cancelled
```

While a job is `running`, its progress moves through the job stages in
order: **Preparing → Preflight Validation → Extracting Working Copy →
Signing Frameworks → Signing App → Packaging → Verification →
Completed.** The mapping from the pipeline's nine stages is fixed:

| Pipeline stage | Job stage |
|---|---|
| (executor setup) | Preparing |
| integrity, profile | Preflight Validation |
| discovery, extraction | Extracting Working Copy |
| nestedSigning | Signing Frameworks |
| resourceSealing, mainExecutable | Signing App |
| packaging | Packaging |
| verification | Verification |

### Honest progress

`SignApplicationPipeline.sign(_:reportingStage:)` calls an optional observer
right before each stage starts. The call is additive: the default is `nil`,
and existing call sites don't change. So the overall fraction only moves when
a stage actually begins.

- Each stage has a declared weight (`SigningJobStage.weight`), and the
  weights add up to 1.
- If a stage reports countable units, its bar is determinate. If it reports
  only its boundaries, the UI shows "In progress" with an activity
  indicator. The UI never shows a percentage the pipeline didn't establish.
- The queue applies reports monotonically. A late or out-of-order report
  can't move a job backwards.
- A time estimate appears only after the run has been going for at least
  3 s and has passed at least 3 % of the weighted work. Before that, the
  estimate is the stage position ("Stage 2 of 7").

## 3. Scheduling and priorities

- `maximumConcurrentJobs = 1`. Signing is heavy on CPU and I/O. Running jobs
  in parallel would multiply peak memory and battery use, which is the same
  reasoning `BatchSigningCoordinator` gives. The scheduler loop is written
  against this bound, and jobs are fully isolated (§5). Raising the bound is
  a policy change, not an architecture change.
- Waiting order is **High → Normal → Low**, then the order the user asked.
  A new job goes in before the first waiting job of strictly lower priority.
- **Move Up / Move Down / Send to Top / Priority** apply only to waiting
  jobs. A running job is never preempted or reordered.

## 4. Controls

| Control | Offered when | Behaviour |
|---|---|---|
| Cancel | queued / running | Cancelling a queued job settles it right away, without ever opening the container. Cancelling a running job is cooperative: the job shows **"Cancelling…"** until the pipeline reaches its next stage boundary. |
| Retry | failed (retryable) / cancelled | Re-queues the job by priority. When it runs, it's a **fresh, clean run** (§5). |
| View Details | always | `SigningJobDetailView` |
| Remove | settled only | Discards the queue's copy of the request and its profile copy. **Never** touches the delivered container. |
| Pause | **never offered** | The pipeline has no checkpoint a half-signed working copy could safely resume from, so this control isn't exposed. The safe alternatives are a clean cancellation and a clean retry. |

Retryability comes from `DiagnosticCategory`. `invalidInput`,
`unsupportedInput` and `ambiguousInput` are content refusals: re-reading an
unchanged package can't change the result, so no retry is offered. Storage,
internal, capability and interruption failures can be retried.

Bulk operations (dashboard ⋯ menu): **Cancel All Waiting**, **Retry All
Failed**, **Clear Completed**, **Clear Failed**. Destructive ones ask for
confirmation, and each confirmation says what the action won't touch.
**Queue Selected** lives in the Library's selection bar.

## 5. Isolation and concurrent safety

Each job has:

- **Its own workspace.** The pipeline creates
  `tmp/ZynSignSigningQueue/zynsign-signing-<UUID>/` for every *attempt* and
  removes it when the attempt ends. `CompositionRoot` passes this root as
  `workingDirectoryRoot`.
- **Its own output.** The output name is `<SafeName>_signed_<jobID8>.ipa` in
  `Documents/Signed`. It's fixed per job, so a retry replaces only that
  job's earlier output. The executor removes that one stale file before the
  run starts.
- **Read-only source.** The library artifact is only ever read.
- **Its own log.** `Job.log` holds fixed diagnostic language. It never
  contains identities, keys, profile content or paths.
- **Its own verification.** Each run's `VerifySignedApplication` pass runs
  against that run's expectations.

State shared between jobs is limited to the queue's `@MainActor` arrays.
Profile bytes and identity identifiers stay in a private `submissions`
dictionary and are never exposed in `Job`.

## 6. Persistence and recovery

`FileSigningQueueStore` writes
`Application Support/ZynSignLibrary/SigningQueue/queue.json`. It's a
versioned envelope (schema 1), replaced atomically, and each save carries a
**revision**. The store refuses stale saves, so writes that arrive out of
order can't roll the queue back. Queue-owned profile copies live beside it
as `Profiles/<jobID>.mobileprovision`.

`restore()` runs once per launch, from `RootView`, and only when the feature
is exposed.

| Persisted state | Restored as |
|---|---|
| completed / failed / cancelled | Exactly as it settled |
| queued, setup + profile copy present | Queued (origin `Restored`), runs again |
| queued, profile copy missing | Failed, not retryable ("configuration could not be restored") |
| running | **Failed: "interrupted"** at the last reported stage. Retryable only if the setup survived. **Never completed.** |

Recovery removes profile copies that no restored job references. It also
removes working directories **created before this session**. Directories
created during this session belong to live runs (inline Smart Sign shares the
root) and are never touched. Nothing runs, and nothing is persisted, until
restoration finishes. This prevents two problems: a partial list overwriting
the snapshot, and a fresh working copy being swept.

## 7. Notifications

The queue posts `SigningQueueNotice` values: **job completed**, **job
failed**, and **queue finished**. "Queue finished" is posted only after runs
settle, never when the user just clears the list. `RootView` shows each
notice once as a `ZToast`, posts a VoiceOver announcement
(`AccessibilityNotification.Announcement`), and then acknowledges it.

Local notifications are **opt-in**. The toggle is "Notify When Jobs Finish"
in the dashboard menu, and it's off by default. Turning it on is the only
thing that asks the system for permission. A notification is posted only when
UserNotifications exists, authorization is granted or provisional, and the
preference is on. The content is the app's name and the outcome, nothing
else.

## 8. Entry points

| Entry point | How |
|---|---|
| Library row | Swipe **Queue** · context menu **Queue for Signing…** |
| Library bulk selection | Select → **Queue Selected** |
| Library toolbar | **Signing Queue** button with an active-job badge (⌘⇧Q) |
| Application Details | **Add to Signing Queue…** |
| Smart Sign | **Add to Signing Queue Instead** (uses the screen's current configuration) |
| Smart Import Hub | Per-row queue button, plus **Queue for Signing** on the batch summary |
| Settings | Signing → **Signing Queue** |
| Tab bar | Library tab badge counts active jobs |

All of these present one `SigningQueueConfigurationView`: identity, a profile
(from the profile library or from Files), the DER layout, and priority. The
dashboard itself is shell-owned (`SigningQueuePresentation`), the same way
`ImportPresentation` works.

## 9. Accessibility

- **VoiceOver.** Each job card is read as one sentence (name, stage,
  percent, remaining work, attempt), with every control available as a
  custom action. Stage rows are read individually. Settled jobs are
  announced.
- **Dynamic Type.** Badge rows and button rows stack at accessibility sizes,
  and titles and subtitles get extra lines.
- **Reduce Motion.** List and progress animations are turned off.
- **Keyboard (iPad).** ⌘⇧Q opens the queue. In the detail screen: ⌘↑ / ⌘↓
  move the job, ⌘⇧↑ sends it to the top, ⌘R retries, ⌘. cancels. Context
  menus work with a pointer or keyboard.

## 10. Performance

- Only the **running** card and the detail screen redraw on a 1 s
  `TimelineView` tick. Other cards redraw only when their job changes.
- Snapshots are written when the list or its states change, not on every
  progress report.
- Job logs are capped at 64 lines and pending notices at 20.
- Rendering only filters arrays, which is cheap for dozens of jobs.

## 11. Planned extensions

The architecture already leaves room for these:

- **Scheduled signing.** Add a `notBefore` date to the submission. The
  scheduler already picks "the first eligible waiting job".
- **Automatic retries.** A policy can call `retry(_:)` for retryable
  failures. `attemptCount` is already tracked.
- **Cloud queue sync.** `SigningQueueStore` is a port, and snapshots are
  Codable values with revisions.
- **Background task improvements.** A `BGProcessingTask` can call
  `restore()` and drain the queue. Jobs are resumable because restoration
  requeues them honestly.
- **Enterprise workflows and presets (Step 15).** `presetID` already flows
  through the submission, the snapshot and the history record.

## 12. What this doesn't claim

A completed job means the container the run produced passed that run's
independent verification. It's not a claim about trust, authorization or
installability. See `application-signing-pipeline.md` and
`installation-compatibility.md`.
