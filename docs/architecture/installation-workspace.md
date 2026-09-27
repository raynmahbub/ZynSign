# Installation Workspace

The Installation Workspace is the area between "signed" and "on the
device": one place where ZynSign states what it validated, the user
records what they delivered and confirmed, and the two are never
conflated. It ships with `v0.9.0-beta.2`
(`ReleaseFeature.installationWorkspace`, prerequisite
`.deliveryHandoff`).

This document records what each part of the workspace establishes, what
it explicitly does not, and why the seams fall where they do. The
authoritative statement on installation itself remains
[`installation-compatibility.md`](installation-compatibility.md); where
the two disagree, that record governs.

## The workspace's one rule

**ZynSign's validation and the user's confirmations are different
kinds of fact, and the workspace labels which is which everywhere it
shows either.**

- ZynSign's validation — signing, verification, package readability,
  export completion, identity currency, metadata — is evidence ZynSign
  produced itself, about the artifact's own bytes.
- The Installed Apps Library exists because the user said a delivery
  happened. ZynSign cannot install (`noDeliveryMechanism` is a platform
  fact) and cannot observe a device's application list, so a record is a
  ledger the user maintains — never an observation ZynSign made.

Every screen carries this distinction in its own words. No screen says
"installed" about anything ZynSign did not see the user confirm.

## Parts

| Part | What it is | Entry |
| --- | --- | --- |
| Dashboard | Ready to Install · Installed · Updates counts, pending deliveries, preparation queue, recent installs, history, storage | Settings → Browse → Install; Home → Install; signing success → Installation Workspace… |
| Readiness card | Per signed app: the six checks as pills, with Checklist / Deliver / Verify Again as the report allows | Dashboard → Ready to Install / Needs Attention |
| Pre-install checklist | Every check with its state and reason, fixed-language guidance, and the actions the report permits | Readiness card → Checklist |
| Installed Apps Library | One record per bundle identifier, with version, channel, last installation, update status; search, scopes, orders, bulk selection | Dashboard → Installed |
| Delivery attempts | Pending, user-resolved records of deliveries started but not yet confirmed | Dashboard → Deliveries Awaiting Confirmation |
| History | Flattened events, newest first, paged; a row opens the app, version, timestamp, verification at the time, and artifact used | Dashboard → Installation History |
| Relationship view | Import → Signed → Exported → Delivery → Installed, drawn only from recorded facts | Installed app → Artifact Relationship |
| Bulk preparation | The preparation queue: Verify All, Prepare All, Queue Selected, Retry Failed, Clear Completed | Dashboard toolbar / Library toolbar |
| Storage | Installed records, signed IPAs (exports), temporary data — with cleanups that never touch imported apps | Dashboard → Storage |

## Readiness: six checks ZynSign actually performs

`InstallationReadinessCheck` names exactly the facts ZynSign establishes,
and `InstallationReadinessReport.evaluate(_:)` derives the report from
`InstallationReadinessEvidence` the stores already hold:

1. **Signed** — the journal's most recent run for the app delivered
   output (by record identifier, falling back to bundle identifier for
   pre-linkage journal entries). No run reads *not performed*.
2. **Verified** — the export record's last independent verification is
   `valid`. `warning` is attention; `invalid` and `unsupported` block;
   **no verification blocks**, because ZynSign verifies artifacts before
   presenting them as ready.
3. **Package** — the artifact's bytes are held in export storage at the
   recorded size (`ExportAvailability`). Deep readability is what
   verification establishes when it runs; this check establishes that
   the bytes are there to read.
4. **Export** — the commit completed with a measured size and, for every
   record this build writes, a fingerprint. A pre-fingerprint record is
   attention, not a block.
5. **Identity** — the profile and certificate expiry dates the signing
   run recorded are in the future. Expired blocks; **unrecorded dates
   read *not performed*** — an open question, never a pass.
6. **Metadata** — the declared identifier, name, and version delivery
   needs are present. A missing identifier blocks; a missing name or
   version is attention.

States are narrow on purpose: `passed`, `attention` (never blocks),
`blocked` (holds the report back), `notPerformed` (no evidence — shown
as an open question, blocking only for verification, where "verify
before ready" is the rule). A check with no evidence is never dropped
and never guessed. The report's `guidance` and `spokenSummary` are fixed
language: "the package appears ready", never "will install"; the
platform's acceptance is named as the platform's, every time.

## Delivery attempts: interrupted work stays interrupted

An attempt is created when the user commits to delivering an artifact
through a channel (over-the-air link, managed distribution, host tool,
or an after-the-fact record). Its semantics are the recovery story:

- An attempt is **pending** until the user resolves it. It persists
  across relaunches exactly as pending; no timer, launch path, or
  notification resolves one, because ZynSign observes no delivery
  signal at all.
- **Confirm** appends the attempt's intent (`installed` / `updated` /
  `reinstalled`) as an event on the bundle identifier's record, then
  resolves the attempt. Confirmation snapshots what ZynSign can still
  see — the export and signing run if held — and never invents facts
  for artifacts removed since the attempt started.
- **Abandon** resolves the attempt with no event: the history never
  gains an installation that did not happen.
- The signed IPA, its export, and every other record are untouched in
  both paths. `Documents/Signed` bytes are never removed to make an
  attempt's bookkeeping tidy.
- An interrupted delivery therefore degrades to what it is: an open
  question the dashboard keeps visible, never a silent success.

## Records: one app, one record, events only

`InstalledApplicationRecord` is keyed by declared bundle identifier; a
second delivery of the same app appends an event instead of creating a
second record. Events (`InstalledApplicationEvent`) carry what ZynSign
knew at confirmation: artifact export identifier and file name,
declared version, the signing run, and the verification verdict at that
time. Each record keeps at most 20 events; the store keeps at most
1,000 records, trimming the least recently updated. History is
*projected* from events, never stored separately, so a row cannot
disagree with its record.

Update state (`InstallationUpdateState`) compares the recorded
installation against the newest **held** export for the same bundle
identifier using `DeclaredVersionOrder` — advisory, like everywhere else
it is used. Equal versions under a different export are a re-sign, not
an update; incomparable versions and missing exports read `unknown`,
making no claim in either direction. The device's actual version is
unknown to ZynSign and is never guessed at.

## Bulk preparation and its boundary with the Signing Queue

`InstallationPreparationQueue` is the workspace's job list: one job at
a time, in the order asked, each job a readiness re-evaluation plus —
where the artifact is held — an independent verification through the
same `VerifyExportedArtifact` the signing pipeline and Export Center
use, recorded on the export record like any other verification.

It is deliberately **not** the Signing Queue. Signing jobs are
expensive, stateful, and persisted because an interrupted one matters;
preparation is cheap, read-only, and safe to re-run with one tap, so
its queue is in-memory and says so. The *shape* — jobs, states, retry
as a fresh run, clear completed — mirrors the Signing Queue so the two
dashboards read the same way. Cancelling one job never stops the queue:
cancellation targets the running job's work task, at verification's own
safe points, and the next waiting job starts when it settles.

The bulk boundary: **preparation is bulk; delivery never is.** Queue
Selected, Verify All, and Prepare All prepare many apps at once, and
*only apps whose readiness passes* are ever offered to the delivery
flow. Starting a delivery is a deliberate, readiness-gated act, one app
at a time — bulk "install everything" is not a control the workspace
offers, and no bulk path can start an attempt.

## Storage

The workspace reports three rows it can act on and names the one it
cannot: installed records (the catalog's own size — safe to clear),
signed IPAs (export storage, removed through the Export Center), and
temporary data (removed through the temporary-data boundary). Imported
applications are listed in the library, never cleaned here; no code
path in the workspace can reach them.

## Security posture

- Artifacts are verified before being presented as ready; unverified
  blocks.
- Source IPAs and library artifacts are read-only to every workspace
  path; only export records' verification fields and the workspace's
  own catalog are written.
- Temporary delivery manifests stay in `tmp/ZynSign-Delivery/` (the
  hand-off's existing convention), outside every durable store.
- No identity, key, password, profile bytes, team secrets, or absolute
  paths appear in any record, event, or rendering. Records store
  identifiers and file *names*, never locations.
- Success indicators only appear for facts that exist: a record exists
  because the user confirmed it and the screens say so.

## Accessibility

- Every readiness card, installed card, history row, and relationship
  step reads as one spoken sentence (`spokenSummary` /
  `accessibilityLabel`); the checklist announces the full readiness
  summary when it appears, and Verify Again announces the fresh verdict.
- Dynamic Type: cards and rows scale with text; no fixed-height text.
- Dark Mode: all color is semantic (`ZStatusBadge`, system colors,
  ZDL tokens); nothing hard-codes light-only values.
- Large touch targets: bordered buttons, ≥44 pt rows.
- Keyboard on iPad: ⌘⇧P runs Prepare All; standard list navigation and
  the menu system work throughout.
- VoiceOver notices accompany confirmations and failures as toasts plus
  `AccessibilityNotification` announcements.

## Future-proofing

The architecture leaves the seams open without rework:

- **Additional installation methods** — `InstallationChannel` is a
  closed enum today; a new mechanism enters as a channel plus a
  delivery flow, and the attempt/confirm ledger already carries it.
- **Enterprise workflows** — attempts, records, and history are
  value types behind one port (`InstalledApplicationStore`); a managed
  or synchronized store is a second conformer, not a redesign.
- **Richer update management** — update state is a pure domain
  evaluation over (record, newest export); a future feed of upstream
  versions slots into the same evaluation.
- **Synchronized history** — events are already append-only value
  documents; a sync engine can treat the catalog as a CRDT-ish merge
  target without changing the presentation.

What stays fixed: ZynSign's validation and the user's confirmations
remain different kinds of fact, and the workspace keeps labelling
which is which — whatever new capabilities arrive.
