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
| **Horizon** | `v0.1.0` | Core | Files · Import (`ipa`/`tipa`) · Library · Bundle Explorer · Home · Settings (About, Archive, Pairing/Analytics honesty, Appearance, Storage, Diagnostics) |
| Alpha 1 | `v0.1.0-alpha.1` | Certificate Studio | Settings → Certificates (`.p12`/`.pfx` import, detail, public JSON export) |
| Alpha 2 | `v0.1.0-alpha.2` | Smart Sign, Professional Signing Queue, Intelligent Signing Presets | `Sign Application…` (Library menu + detail), 9-stage pipeline, DER toggle, Live Activity, Signing Options, Library “Signed” segment, Settings → Installation, Settings → Signing Queue, Settings → Presets, recommended preset with a required confirmation that enqueues on the signing queue |
| Alpha 3 | `v0.1.0-alpha.3` | App Store + Downloads | App Store tab (sources, repository health) and Downloads tab (background, pause/resume/retry) |
| Beta 1 | `v0.9.0-beta.1` | Mission Control, Delivery Hand-off, Activity Journal | Home → Refresh Everything · Sign → Deliver… (OTA manifest, link, QR) · Settings → Analytics → Local Activity Journal. **Feature complete.** |
| Beta 2–4 | `v0.9.0-beta.2…4` | — | Fixes only |
| RC 1–3 | `v1.0.0-rc.1…3` | — | Fixes only |
| Stable | `v1.0.0` | — | Everything |

This follows [version-strategy.md](version-strategy.md): signing arrives within
Alpha (Alpha's exit criteria need it), and the app is feature complete by the
first Beta.

Run `python3 Scripts/release_train.py status` to print this table from the code.

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
| `downloads` | `RootView` Downloads tab, Home tip, Library empty-state copy |
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

# 5. Tag the merged commit on main — release.yml does the rest
git tag -a v0.1.0-alpha.1 -m "ZynSign 0.1.0-alpha.1"
git push origin v0.1.0-alpha.1
```

Safety rails:

- `release_train.py check` runs in CI (`ci.yml` → hygiene). It fails when
  `MARKETING_VERSION` disagrees with `ReleaseTrain.current`.
- `release.yml` runs `release_train.py check --tag <tag>` first. Pushing
  `v0.1.0-alpha.2` while the code still says `alpha1` fails the release rather
  than publishing the wrong feature set.
- `promote` refuses to move backwards, because users would lose features.
- `ReleaseTrainTests` pin the order, that features only accumulate, that each
  feature is introduced once, and that no release exposes a feature without its
  prerequisites.
- Alpha, beta and rc tags are published as GitHub **pre-releases**. `v0.1.0`
  and `v1.0.0` are not.

### Build numbers

Apple requires `CFBundleShortVersionString` to be numeric, so all three alphas
report `0.1.0` and all betas report `0.9.0`. The pre-release suffix lives only in
the tag. `CFBundleVersion` goes up by one with every `promote`, and TestFlight
needs that.

## Changing the plan

Edit `introducedFeatures` in `ReleaseTrain.swift` (and the table above). The
tests make sure the new plan still makes sense. For example, you can't ship
Smart Sign before Certificate Studio. After `1.0.0`, new features follow normal
SemVer (`1.1.0`, …). Add a new `ReleaseFeature` and gate it the same way while
it's being built.

## Legacy tags

The GitHub releases `v0.1.0-dev`, `v0.1.1-dev` and `v0.2.0-dev` (all at
`58e604c`) predate this train. They have no binary assets. `v0.2.0-dev` is
currently marked **Latest** and sorts *above* `0.1.0`, which will confuse
anyone who compares versions. Before publishing `v0.1.0`, mark them as
pre-releases or delete them:

```sh
gh release edit v0.2.0-dev --prerelease --latest=false
gh release edit v0.1.1-dev --prerelease
```
