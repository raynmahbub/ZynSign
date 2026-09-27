# Download Center & Update Engine

**Status:** Implemented · gated by `ReleaseFeature.downloads` (visible from `v0.1.0-alpha.3`; the center itself is the Beta 1 Step 22 transfer pipeline)
**Scope:** Beta 1 — Step 22

This document records how ZynSign downloads, validates, and hands off packages
without treating a repository listing as trust, and without claiming resume
behavior the platform did not provide.

## 1. Shape

```
Presentation                         Application                          Platform
────────────                         ───────────                          ────────
DownloadsView ──────── observe ──▶   DownloadCenter (@MainActor)          FileDownloadCenterStore (actor)
DownloadDetailView                   jobs · notices · updates             center.json + Incoming/Isolated/Artifacts/Resume
AppStoreView ── enqueue ──────────▶  RepositoryDirectory                  URLSessionDownloadTransfer
RootView (toasts, VoiceOver)         UpdatePlanner (pure)                 IPADownloadValidator
                                     │                                    URLSessionRepositoryClient
                                     ▼                                    LocalDownloadNotifier (opt-in)
                                ImportHub.receive (only after validation,
                                only when the user asks)
```

- **`DownloadCenter`** is the job queue. Screens submit requests and watch
  jobs. Navigating away cancels nothing. Progress is delivered a few times a
  second so a large package does not stall scrolling.
- **`RepositoryDirectory`** is the only reader of configured sources. A
  document is offered only after `RepositoryCatalogParser` accepts it.
- **`UpdatePlanner`** compares installed declarations with those catalogs.
  It does not guess when `DeclaredVersionOrder` cannot compare, and it does
  not look at sources the user has not configured.
- **`DownloadTransferring`** is the transfer port. The production
  implementation is a foreground `URLSession`. A test double stands in for
  the queue tests. A future source or scheduler replaces the port, not the
  center.
- **`IPADownloadValidator`** reuses the archive reader, structure validator,
  and metadata reader. It does not extract and does not import.

## 2. Job lifecycle

```
queued ──▶ connecting ──▶ downloading ──▶ validating ──▶ import ready
                              │
                              └──▶ failed ──(retry)──▶ queued
```

Pause is offered only while connecting or downloading. It is not a claim
that the bytes can continue:

| Resume fact | Meaning |
|---|---|
| `held` | URLSession produced resume data. Continuing *may* work. If the server refuses it, the next attempt starts over. |
| `notCaptured` | No resume data. Resume starts the download again. |

A background session that relaunches the app is not installed.
`DownloadTransferHonesty.claimsBackgroundRelaunch` and
`claimsUniversalResume` are both false.

## 3. Scheduling

- `maximumConcurrentTransfers` defaults to 2 and is clamped to 1...4.
- New waiting jobs are inserted High → Normal → Low, then in the order they
  were asked. Move Up, Move Down, and Send to Top apply only to waiting jobs
  and then list order wins. A running transfer is never preempted.
- The snapshot may carry a reserved scheduler record (`automationLabel`,
  `syncGeneration`). This build stores it and does not execute it.

## 4. Trust boundary

Before a repository download starts:

1. The address must be https, have a host, and embed no credentials.
2. The address must appear in a catalog that already passed metadata
   validation. "Refresh the source" is the refusal when it does not.

After the bytes arrive, regardless of source:

1. Size is within the 4 GiB ceiling.
2. A declared SHA-256 matches, or the artifact is isolated.
3. The archive entry table can be read.
4. Structure examination accepts one application bundle and no unsafe path.
5. The bundle information file parses to metadata.

Import Ready means those checks passed. It does not mean the package is
signed, trusted, or installable. Failure keeps the original file under
`Isolated/` and does not call the Import Hub.

Install manifests (`itms-services` or an https `.plist` link) are parsed as
property lists. Only a `software-package` asset with an https address is
followed. Text scanning is not used. The manifest itself is not imported.

## 5. Handoff

| Action | What it does | What it does not do |
|---|---|---|
| Import Now | `ImportHub.receive` with origin `downloadCenter` | Sign, or delete the download |
| Queue for Signing | Import, then tell the user signing has not started | Enqueue or run a signing job |
| Keep Downloaded | Record the choice | Import |
| Remove / Clear Completed / Clear Temporary | Delete center-owned files | Delete library artifacts |

Replace, Keep Both, and Skip are required when the same version is already
downloaded, the same version is imported, a newer copy is held, or another
source already has the app. Replace deletes a previous *download* only after
the new file validates. An imported application is never the replace target.

## 6. Recovery

`FileDownloadCenterStore` writes
`Application Support/ZynSignLibrary/DownloadCenter/center.json` atomically,
with a revision. Stale saves are refused. Paths are confined to that root.

| Persisted state | Restored as |
|---|---|
| import ready / failed / cancelled | As settled |
| queued | Queued |
| paused | Paused. Resume data is loaded only if the file is still there |
| connecting / downloading / validating | **Failed: interrupted.** Never import ready |

## 7. Updates and notifications

Updates are `UpdatePlanner` output: installed version strictly older than a
configured catalog's latest comparable version, and not ignored. Ignore is
per bundle identifier and version, so a later version still appears. Two
sources that list the same app stay two updates and two App Store rows.
Nothing picks a source silently.

In-app notices: download completed, validation failed, update available,
queue finished. RootView shows each once as a toast and a VoiceOver
announcement. Local notifications are opt-in, off by default, and ask for
permission only when the user turns them on.

## 8. Accessibility

Cards expose a combined label and a progress value. Stage changes and
quarter-progress crossings are announced. Controls use at least 44-point
targets. Semantic colors follow Dark Mode. Dynamic Type can stack card
metrics. Add Download is ⌘⇧N and Update All is ⌘U when the Downloads screen
is focused.
