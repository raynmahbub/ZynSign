# iOS compatibility matrix

## The honest shape of this matrix

The matrix is built from what the build supports, not from a table someone
filled in. The deployment target is **iOS 17.0**, which settles two rows
immediately and puts a duty on the rest:

| Release | State | Why |
|---|---|---|
| iOS 16 | **Not supported** | Below the deployment target. ZynSign does not install or launch there. |
| iOS 17 | Supported | At the deployment target. |
| iOS 18 | Supported | Above it. |
| iOS 26 | Supported | Above it. |

iOS 16 is in the table rather than left out on purpose: a release decision
should see the limit written down. The Lab records that row as *Not
applicable* with the reason, never as a pass nobody earned.

Lowering the deployment target is a product decision, not a test decision. It
would need its own justification — a real iOS 16 device, and every API the
build uses re-checked against it. Nothing in this pack pretends otherwise.

## What each supported release is checked for

Six workflows, per release:

| Workflow | What executes on the running release |
|---|---|
| Launch | The Lab running at all means the app launched, read its preferences and composed its environment |
| Import | A synthetic package is read and identified through the production boundary — the read half of an import, without touching the library |
| Signing | The identity store is asked what is available; without an identity the row is *Not run* with that reason |
| Store | A probe through a transport that cannot reach anything must finish, never throw, and be classified offline |
| Export | The export location is checked as writable and the export catalog as readable — read only, nothing written |
| Installation | The OTA manifest is built and checked as well-formed — the whole of the hand-off ZynSign performs |

## Where each row is executed

Only the release ZynSign is running on can be checked, and the Lab says so for
every other row:

- The row matching the running release: **executed**.
- Every other supported release: **Not run**, with the next step — run the Lab
  on a device with that iOS and import its report.

A simulator run is a simulator run. The report names the device class and
whether the run was made on a simulator, and simulator figures are never
compared against device figures.

## Known platform limitations

These are facts about the platform, not defects, and the Lab records them
rather than working around them:

- **In-app installation has no available mechanism.** ZynSign builds the
  manifest, the link and the QR code and hands off. `Settings → Installation`
  shows the typed assessment with its reasons. No check in this pack claims an
  installation.
- **Pairing, JIT and usbmux stay unavailable.** `PairingCapabilityAssessment`
  reports every pairing route as unavailable, and no Lab check contradicts it.
- **Off-device analytics stays off.** `AnalyticsPolicy.isEnabled` is `false`
  and there is no endpoint.

## Filling the matrix in

1. Build the Debug configuration on a device running each supported release —
   iOS 17 at minimum, since that is the floor.
2. Settings → Compatibility Lab → Run the Lab.
3. Export the report; run
   `python3 Scripts/generate_hardening_report.py --input <report>…`.
4. The page shows every executed row with its evidence and every unrun row
   with the action that would settle it.

The release verdict stays `Incomplete` until every row is settled. That is the
system working, not the system being awkward.
