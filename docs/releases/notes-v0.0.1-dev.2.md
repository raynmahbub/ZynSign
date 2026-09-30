# ZynSign `v0.0.1-dev.2`

Market `0.0.1` · build `3` · channel **development** · pre-release.

A development stop. Staged capabilities remain gated, while the Store and Downloads stay visible as stable navigation destinations and Certificates and Profiles remain reachable for importing.

## What this stop is for

`dev.1` proved the pipeline against a real tag. This stop proves it again with
the release gate actually **closing**. The previous build was cut while four
entry points ignored the gate, so "core only" was not true of the binary it
shipped. That is what changed here.

## Fixed

- Staged signing, identity-center and installation workflows remain behind
  their release stops, but the core import routes for Certificates and Profiles
  are always accessible in Settings → Browse.
- Store and Downloads remain visible in the tab bar at every stop. Their
  presence no longer depends on a release-stage override, and saved landing
  preferences continue to select their matching tabs.
- Smart Workspace no longer runs before its stop. It had been writing
  `SmartWorkspace.json` on every signing session at every stage since `dev.1`,
  for a screen nothing presents.
- The README version badge updates again — it had been silently frozen since
  the first suffixed version.

## Still not offered

The three recorded *never* are unchanged: ZynSign never installs an app, never
pairs a device or speaks usbmuxd, and never measures off-device. See
[`../product/WHAT_DOES_NOT_EXIST.md`](../product/WHAT_DOES_NOT_EXIST.md).

## Verification

`Scripts/ci/release_validate.sh 0.0.1-dev.2` and the full local gate set pass.
The private device matrix in [`private-testing.md`](private-testing.md) covers
the core and the always-visible repository and identity import entry points.
