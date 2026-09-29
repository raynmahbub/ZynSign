## [0.1.0-alpha.3] — Alpha 3 · the first build with features in it

Market `0.1.0` build `2` (`CFBundleShortVersionString 0.1.0`,
`CFBundleVersion 2`), tag `v0.1.0-alpha.3`. Release train `.alpha3`: switches on
**ten** staged features.

`v0.0.1-dev.1` proved the release machinery and shipped no features at all — the
train's first stops exist to prove the machinery against a real tag. This is the
stop where the app becomes usable in a Release build.

A Release build of this stop shows the core — Files, Library, Home, App Store,
Downloads, Settings — plus the seven features listed as newly reachable below.
The other three staged features (Mission Control, the delivery hand-off, the
local activity journal) are `beta1`: compiled in, tested, reachable in Debug, and
absent in Release. A Debug build exposes all of them, and
`-ZynSignReleaseStage <stage>` previews any later stop.

### Switched on in a Release build

- **Certificate Studio** — `.p12`/`.pfx` import into the Keychain
  (`WhenUnlockedThisDeviceOnly`, non-extractable), expiry forecasting, and
  public-metadata JSON export. The private key never leaves the device.
- **Smart Sign** — the nine-stage pipeline: isolated working copy → validation →
  frameworks, dylibs, extensions and nested apps (inner code first) → host app →
  independent verification → deterministic packaging. It refuses at the exact
  stage something is wrong, and a failed run never leaves a partial artifact
  where it could look complete.
- **Library Power Features** — favourites, recent imports, collections, advanced
  search, filters, bulk selection, quick actions.
- **Provisioning Profile Manager** — `.mobileprovision` parsing with CMS
  verification, per-app compatibility, and read-only Entitlements diagnostics.
- **Professional Signing Queue** — the job-based system: priorities, per-job
  controls, live stage progress, failure recovery, persistence, bulk operations.
- **Intelligent Signing Presets** — preset library, builder, matching, one-tap
  confirmation, bulk planning into the queue.
- **App Store & Repository Health** — AltSource-compatible catalogs with
  `Fast`/`Slow`/`Offline` health and latency.
- **Download Center** — queue, validation before import, honest resume. Foreground
  session: `claimsBackgroundRelaunch` and `claimsUniversalResume` are both
  `false`, and a killed process restores as *interrupted*, never completed.
- **Entitlements Studio** — read-only entitlements inspection and diagnostics,
  including the iOS 15+ `0x20400` DER encoding.
- **Developer Identity Center** — teams, certificate and profile inspectors,
  relationship graph, health centre, conflict detection, expiration forecast.

### Still staged for `beta1`

Mission Control's "Refresh Everything", the installation delivery hand-off, and
the local activity journal. All three are compiled, tested, and reachable in
Debug. `docs/product/WHAT_DOES_NOT_EXIST.md` names which stop switches each on
rather than letting the count imply they ship here.

### Fixed

- **Settings crashed on open.** Three views embedded a `NavigationStack` while
  being pushed as destinations from inside Settings' own stack. Nesting a stack
  inside a pushed destination crashes at runtime — it compiles, passes all
  2,700+ unit tests, and is invisible to static typing. All three now take an
  `embedsNavigationStack` flag.
- **Two further crashes of the same class**, found while writing the gate that
  prevents them: `ProfilesView` and `InstallationWorkspaceView`, both pushed from
  Settings → Browse. The second was dormant only because its feature was gated
  off; promoting to `alpha3` would have activated it.
- **The Import button could silently do nothing** when the Import Hub sheet took
  longer than 400 ms to present. The picker is now requested from the sheet's
  own appearance.
- **`audit_navigation_stack.py`** now refuses a pushed destination that opens its
  own navigation stack, and runs in the hygiene job.

### Changed

- The tab bar is `Files · Library · Home · App Store · Downloads · Settings`, and
  is no longer gated: a tab that comes and goes between releases is not one a
  user can rely on. Certificates and Profiles moved to Settings; a saved landing
  tab naming one of them coalesces to Library instead of selecting nothing.
- Home was rebuilt as a command center — wordmark, three counts, an updates row
  that appears only when something needs it, the import target, a direct-link
  field, and the action list. Counts that have not been read show a neutral
  block rather than a fabricated zero.

### Still never

In-app installation, device pairing / JIT / usbmuxd, and off-device analytics
remain recorded decisions, not missing features. `deliveryMechanismAvailable` is
`false` on every path, `PairingCapabilityAssessment.allUnavailable` reports
`supported == false`, and `AnalyticsPolicy.isEnabled` is `false` with
`endpoint == nil`. Promoting a release stage does not change any of them, and
the tests that pin them run on every build.
