# Release Train — shipping a finished app one release at a time

ZynSign is fully built. Instead of publishing everything at once, each release
**switches on** more of the finished app. The code for every feature is
compiled into every build; what changes between releases is only which entry
points (tabs, Settings rows, menu actions) the interface shows.

This keeps one codebase and one branch. There are no per-release branches, no
cherry-picks, and no deleted code to restore later.

## The plan

| Release | Tag | Switches on | Users see |
|---|---|---|---|
| Dev 1 | `v0.0.1-dev.1` | — | Core only. Proved the pipeline end to end against a real tag: quality gate → build + tests → version-stamped assets → publish. |
| Dev 2 | `v0.0.1-dev.2` | — | **Current stop.** Core only; fixes, and the private device matrix for the core |
| Dev 3 | `v0.0.1-dev.3` | — | Core only; the last rehearsal before the first build |
| **First build** | `v0.0.1` | Core | Files · Import (`ipa`/`tipa`) · Library · Bundle Explorer · Home · Settings (About, Archive, Pairing/Analytics honesty, Appearance, Storage, Diagnostics) |
| Alpha 1 | `v0.1.0-alpha.1` | Certificate Studio | Settings → Certificates (`.p12`/`.pfx` import, detail, public JSON export) |
| Alpha 2 | `v0.1.0-alpha.2` | Smart Sign, Professional Signing Queue, Intelligent Signing Presets | `Sign Application…` (Library menu + detail), 9-stage pipeline, DER toggle, Live Activity, Signing Options, Library “Signed” segment, Settings → Installation, Settings → Signing Queue, Settings → Presets, recommended preset with a required confirmation that enqueues on the signing queue |
| Alpha 3 | `v0.1.0-alpha.3` | App Store, Downloads, Entitlements Studio, Identity Center | App Store (validated sources, repository health), the Download Center (queue, validation, updates; resume is reported only when resume data was captured), the Entitlements Studio (read-only inspection, DER `0x20400`) and the Developer Identity Center. Cumulative with Alpha 1 and 2: seven of the ten staged features are on in a Release build here. |
| Beta 1 | `v0.9.0-beta.1` | Mission Control, Delivery Hand-off, Activity Journal | Home → Refresh Everything · Sign → Deliver… (OTA manifest, link, QR) · Settings → Analytics → Local Activity Journal. **Feature complete.** |
| Beta 2 | `v0.9.0-beta.2` | Installation Workspace | Settings → Browse → Install · Home → Install · signing success → Installation Workspace… (readiness checklists, Installed Apps Library, confirmed deliveries and history, bulk preparation, storage) |
| Beta 3–4 | `v0.9.0-beta.3…4` | Batch Signing (Beta 3) | Fixes plus the batch signing workspace |
| RC 1 | `v1.0.0-rc.1` | — | Fixes; Compatibility Lab |
| RC 2 | `v1.0.0-rc.2` | `.smartWorkspace` | UX pass: the Smart Workspace home (Mission Control) |
| RC 3 | `v1.0.0-rc.3` | — | Fixes only |
| Stable | `v1.0.0` | — | Everything |
| Professional | `v2.0.0` | — | Depth and fixes; no new gate |
| Nova preview | `v3.0.0-nova.1` | `.nova1` | Nova Assistant |
| Nova | `v3.0.0` | `.nova` | The remaining areas — see [../product/ROADMAP-v3.0-nova.md](../product/ROADMAP-v3.0-nova.md) |

This follows [version-strategy.md](version-strategy.md): signing arrives within
Alpha (Alpha's exit criteria need it), and the app is feature complete by the
first Beta.

The three development stops switch on nothing on purpose. They exist so the
release machinery is proven against a real tag before a single feature is
exposed publicly. Every feature below them is already compiled into a
development build — a Debug build shows all of them, and
`-ZynSignReleaseStage <stage>` previews any later stop — so a development stop
is a pipeline proof, not a smaller app.

Run `python3 Scripts/release_train.py status` to print this table from the
code, or `python3 Scripts/release_train.py current` (`--tag`, `--stage`) to
print just the current stop — that one-line answer is what
`Scripts/ci/release_meta.sh` and the release workflows consume, so no version
is ever hardcoded in YAML.

## How it works

The single source of truth is
[`ZynSign/Application/ReleaseTrain.swift`](../../ZynSign/Application/ReleaseTrain.swift):

- `ReleaseFeature` — each gateable feature and its prerequisites (for example,
  Smart Sign needs Certificate Studio, and App Store needs Downloads).
- `ReleaseStage` — the ordered releases, their tags, their numeric marketing
  versions, and `introducedFeatures`.
- `ReleaseTrain.current` — **the one line that decides what a build shows.**
- `ReleaseTrain.isAvailable(_:)` — what the Presentation layer checks.

Gated entry points:

| Feature | Where it is checked |
|---|---|
| `certificateStudio` | `SettingsView` → Certificates row |
| `smartSign` | `ApplicationDetailView` + `LibraryTabView` “Sign Application…”, “Signed” segment, Settings → Signing Options / Installation, Home “Signed” stat |
| `appStore` | `RootView` App Store tab, Home “Sources” stat and tip |
| `downloads` | `RootView` Downloads tab, Settings → Browse, Home source refresh |
| `missionControl` | `HomeView` Mission Control card |
| `deliveryHandoff` | `SigningView` “Deliver…”, Settings → Installation hand-off section |
| `activityJournal` | Settings → Analytics journal sections, **and** `ApplicationEnvironment.recordAnalyticsEvent`, so nothing is recorded before users can see and clear it |
| `libraryPowerFeatures` | `LibraryFeatureAvailability` in the Library: statistics card, scope bar (smart collections and collections), filter menu and chips, the four extra orders, collection sheets, bulk actions beyond Delete, quick actions beyond Favorite/Details/Delete; `HomeView` Favorites card. Signing-derived parts (Signed/Unsigned/Recently Signed/Expiring Soon, the Sign action) also require `smartSign` |

Settings → Diagnostics → Build shows the active release (`v0.1.0 · 0 of 7
staged features`), so testers can confirm what they're running.

### Debug vs Release builds

- **Release configuration** (TestFlight, ad-hoc IPA, GitHub release): exposes
  exactly `ReleaseTrain.current`.
- **Debug configuration** (running from Xcode, unit tests): exposes
  **everything**, so development is never blocked.
- **Preview a release in Debug:** in *Edit Scheme → Run → Arguments*, add
  `-ZynSignReleaseStage alpha2` (or `0.1.0-alpha.2`). The app then shows exactly
  what that release will show.

> Hidden features are still inside the binary. They cannot be reached through
> the UI, but someone who reverse-engineers the IPA could find them. The
> repository is private, so that's acceptable for this project. If it ever
> matters, switch the gates to `#if` compilation conditions.

## Shipping the next release

```sh
# 1. Switch on the next features (edits ReleaseTrain.current,
#    MARKETING_VERSION, and bumps CURRENT_PROJECT_VERSION by one)
python3 Scripts/release_train.py promote            # or: promote alpha2
python3 Scripts/release_train.py status             # confirm

# 2. Write what users get
#    - CHANGELOG.md: move the promoted features from “Staged” into
#      a new “## [0.1.0-alpha.1] - YYYY-MM-DD” section
#    - docs/releases/notes-v0.1.0-alpha.1.md: the GitHub release body

# 3. Private build + private matrix (private-testing.md), focused on
#    the newly visible features — Release configuration, not Debug

# 4. Commit, open a PR, merge to main
git commit -am "release: v0.1.0-alpha.1"

# 5. Tag the merged commit on main — 🚀 Release (03-release.yml) does the rest
git tag -a v0.1.0-alpha.1 -m "ZynSign 0.1.0-alpha.1"
git push origin v0.1.0-alpha.1
```

Safety rails:

- `release_train.py check` runs in CI (`01-build.yml` → hygiene). It fails when
  `MARKETING_VERSION` disagrees with `ReleaseTrain.current`.
- Both release workflows derive their version through
  `Scripts/ci/release_meta.sh`, whose first job runs
  `release_train.py check --tag <tag>`. Pushing `v0.1.0-alpha.2` while the
  code still says `alpha1` fails the release rather than publishing the wrong
  feature set — and it fails before a macOS runner starts building. Its
  `--self-test` runs in `01-build.yml` → hygiene.
- Dispatching **🚀 Release** — with or without `dry_run` — with no version releases
  the train's current stop (`release_train.py current`), so nobody has to
  retype — or misremember — a version.
- `promote` refuses to move backwards, because users would lose features.
- `ReleaseTrainTests` pin the order, that features only accumulate, that each
  feature is introduced once, and that no release exposes a feature without its
  prerequisites.
- Development, alpha, beta and rc tags are published as GitHub
  **pre-releases** — `Scripts/ci/release_meta.sh` detects the channel from the
  tag. `v0.0.1` and `v1.0.0` are not.

### Build numbers

Apple requires `CFBundleShortVersionString` to be numeric, so the three
development stops and the first build report `0.0.1`, all three alphas report
`0.1.0`, and all betas report `0.9.0`. The pre-release suffix lives only in
the tag. `CFBundleVersion` goes up by one with every `promote` and restarts at
`1` when the marketing version restarts, which is the scope TestFlight's
monotonic-build rule applies to.

## Changing the plan

Edit `introducedFeatures` in `ReleaseTrain.swift` (and the table above). The
tests make sure the new plan still makes sense. For example, you can't ship
Smart Sign before Certificate Studio. After `1.0.0`, new features follow normal
SemVer (`1.1.0`, …). Add a new `ReleaseFeature` and gate it the same way while
it's being built.
