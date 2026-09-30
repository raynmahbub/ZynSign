# ZynSign `v0.0.1-dev.2`

Market `0.0.1` · build `3` · channel **development** · pre-release.

A development stop. It switches on **no** staged feature: a Release build here
shows the core — Files, Library, Home, Settings — and nothing else. Every
feature is compiled in and reachable in Debug, and each switches on at its own
stop.

## What this stop is for

`dev.1` proved the pipeline against a real tag. This stop proves it again with
the release gate actually **closing**. The previous build was cut while four
entry points ignored the gate, so "core only" was not true of the binary it
shipped. That is what changed here.

## Fixed

- Certificate Studio, Profiles, the Store and Downloads are now behind their
  release stops. Before this, a development build showed all four.
- The tab bar follows the gate. At this stop it is Files · Library · Home ·
  Settings; the Store and Downloads tabs arrive at `v0.1.0-alpha.3`. A saved
  landing preference naming a hidden tab is clamped to Library instead of
  selecting nothing.
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
the core only at this stop.
