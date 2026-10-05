# Release notes — v0.1.0-alpha.2

## [0.1.0-alpha.2] — alpha2 · the signing workflow opens on a Storefront shell

Market `0.1.0` build `8` (`CFBundleShortVersionString 0.1.0`,
`CFBundleVersion 8`), tag `v0.1.0-alpha.2`. Release train `.alpha2`:
this stop switches on **Smart Sign**, the **Professional Signing Queue**, and
**Intelligent Signing Presets**; Entitlements Studio and the Developer
Identity Center stay hidden until `.alpha3`.

Alpha 2 is the first release a user can sign with end to end: import a
package, add an identity, and drive the queue. It also re-draws the shell —
five tabs, the Storefront look, liquid glass everywhere, and a switch to turn
the glass off — and it closes the remaining import and Settings-crash defects
the private testers kept re-filing.

### Added

- **Storefront (visible from `.alpha2`)** — the new default theme and shell:
  five tabs (Home, Library, Store, Downloads, Settings), a signature gradient
  (`#FF3D71 → #FF6A3D → #FFB13D`) over deep glass, dark first. The Files
  browser moves to a Settings row; every older theme stays selectable under
  Settings → Appearance → Theme.
- **Liquid Glass, app-wide (visible from `.alpha2`)** — `ZGlass` renders every
  glass surface from one switch: cards, the tab bar, toolbars and bars,
  toasts. iOS 26 draws with the platform's `glassEffect`; iOS 17 – 18 gets
  ZynSign's ultra-thin material with a specular edge. Settings → Appearance →
  Liquid Glass defaults to on; off resolves every surface to flat system
  materials. Presentation only — it never changes what the app does.
- **Smart Sign, Professional Signing Queue, Intelligent Signing Presets**
  *(switched on by this stage)* — sign from the Library, run queued jobs with
  live stage progress and per-job controls, and plan bulk signing from
  presets. Queue notices badge the Library tab through the shell.

### Changed

- **The main screen draws exactly five tabs.** `ShellSection.allTabs` pins
  the contract (`ShellSection.tabCount`); Files, Features, presets, and the
  signing materials resolve to Settings (`ShellSectionTabTests`).

### Fixed

- **IPA / TIPA import survives a provider that has not handed over bytes.**
  An iCloud placeholder reported "empty" and "not a ZIP" and was refused
  before staging. `SecurityScopedArtifactIntake` now reports an unobservable
  read as *unknown*, triggers `startDownloadingUbiquitousItem` for a dataless
  item, and waits (bounded: 20 s, never on the main thread) before judging
  content; `ImportPreflight`'s "observation of wrong bytes refuses" policy is
  unchanged — but it can only refuse what it actually observed.
- **A certificate is judged by content, not by name.** The manager's
  extension gate and `CoordinatedPKCS12DocumentReader`'s pre-read refusal both
  rejected renamed (`.bin`, no extension, AirDrop-mangled) PKCS#12 files that
  import fine. An unknown name is now accepted when the bytes begin with the
  DER `SEQUENCE` a PKCS#12 container must carry; known non-certificate types
  are still refused by name, and the reader's size bound and coordinated read
  are unchanged.
- **Settings → Updates no longer crashes.** Its rows pushed Store screens —
  with their own links, search bars, and `navigationDestination`s — into the
  Settings stack. They now raise sheets over fresh stacks, a context each
  nested controller cannot corrupt. `PresetsView` also gated its iPad
  `NavigationSplitView` on the size class instead of the host's
  `embedsNavigationStack: false`, nesting a second container when pushed; the
  flag now gates both containers, and `audit_navigation_stack.py` treats split
  views as containers and refuses a self-managed view whose flag gates any of
  them late.

### Known limitations

Carried in `ReleaseBlockerRecord.registry` and shown in the Compatibility Lab:

- No install claim: ZynSign signs and hands off; it does not install (accepted,
  unchanged).
- The iCloud wait is bounded at 20 seconds; a provider slower than that yields
  the honest "could not be read" refusal and a retry, not a hang.

### What this release deliberately does not claim

- No device verification of any row in this file — the private-test IPA from
  CI is the artifact a tester signs and installs; source-level gates are not
  device evidence.
- No measurement of the glass rendering on hardware; iOS 26 behaviour follows
  the published `glassEffect` API, pre-26 is ZynSign's own material recipe.

### Testing

New and updated unit tests: `CoordinatedPKCS12DocumentReaderTests`
(content-not-name acceptance), `ShellSectionTabTests` (five-tab contract,
Files migration to Settings and Library), `AppThemeCatalogTests`
(six themes, Storefront default), `ReleaseTrainTests` (current stop pins
`.alpha2`). **Their results belong to CI** — and CI has ruled: on this
branch's final state the `Build and test (Xcode)` job compiled every target
and ran the full suite (2,848 tests) with all of them passing. An earlier
attempt of the same train failed three pins — a theme-count expectation and
two default-theme assertions, corrected alongside an intake fix that reads an
empty document as observed rather than unread — and the corrected suite is
what passed.

Host audits, run on the machine that produced this note:

| Audit | Result |
|---|---|
| `Scripts/audit_crash_surface.py` | ✓ 9 constructs, all justified — none new |
| `Scripts/audit_accessibility.py` | ✓ pass; VoiceOver/focus order remain a device pass |
| `Scripts/audit_regression_coverage.py` | ✓ every named test type exists in `Tests/ZynSignTests` |
| `Scripts/audit_navigation_stack.py` | ✓ no pushed view opens its own navigation container (split views included; the ungated-`PresetsView` regression was injected and caught) |
| `Scripts/release_train.py check` | ✓ train consistent: v0.1.0-alpha.2 · MARKETING_VERSION 0.1.0 · build 8 |
| `bash Scripts/ci/docs_check.sh` | ✓ 84 pages, 0 errors, 0 warnings |

Device rows: none — no device ran this build when the note was written.
