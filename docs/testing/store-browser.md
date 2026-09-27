# Step 21 verification

## Automated suites (Xcode required)

- `StoreManifestValidatorTests`: legacy/modern manifests, required fields, unsafe URLs,
  invalid dates/types/sizes, malformed app rejection, duplicates, byte limits, extensions.
- `StoreCatalogTests`: source-scoped duplicates, disabled-source exclusion, all search
  dimensions/category composition, one-edit tolerance, conservative versions and health.
- `StoreRepositoryTests`: validate-before-save, duplicate URL/manifest identity,
  conditional/freshness refresh, last-good offline recovery, failed persistence,
  bounded history and in-flight refresh/removal races.
- `StoreUpdatePolicyTests`: explicit preference, no disabled/removed-source fallback,
  source/version-scoped ignores and no equal-version updates.
- `FileStoreCacheTests`: cold persisted metadata/preferences, corrupt/unknown schema,
  and empty-release safety.
- `StoreDownloadQueueTests`: shared capacity, deduplication, live pause/resume/cancel,
  pinned-source clean retry, interruption recovery, isolated ready files, journal failure.

Run the repository's normal `xcodebuild build` and `xcodebuild test` workflow using the
`ZynSign` scheme on a supported iOS Simulator. Source/test groups are file-system
synchronized, so new Swift files do not need explicit project references.

Local checks on the Linux agent: changed/new Swift files parsed with the tree-sitter
Swift grammar; `git diff --check`, release-train consistency, and all four existing
host vector/self-test scripts passed. **XCTest has not been executed here.**

## Required simulator/device acceptance checklist (not yet run)

Use controlled HTTPS fixture sources and synthetic IPAs; do not execute repository
content. Keep one fixture copy offline for repeatable testing.

1. Fresh Store: all seven shelves and clear empty states; Add Source reachable.
2. Add a valid source; invalid scheme, 404, malformed JSON, missing developer/version,
   bad screenshot URL, duplicate URL and mirror identifier must fail with clear messages.
3. Add a second source with the same bundle and a different version: both rows/details
   and source names remain distinguishable. Disable/remove/re-enable each.
4. Search app/developer/bundle/category/source; combine category with search; try one typo.
   Submit a query, relaunch, verify recent searches, and clear history.
5. Verify details/size/OS/source; expand release history and check dates/version order.
6. Swipe screenshots, open full screen, pinch/pan, navigate pages, use zoom buttons,
   reset and rotate. Loading must be lazy, without losing page context.
7. Visit apps; verify Continue Browsing and local-only Trending labels/order.
8. Load artwork, go offline and relaunch: metadata/details/history remain; cached labels
   appear and unseen images explain unavailable data. Failed refresh must retain listings.
9. Confirm source health/time/error transitions. A 304 keeps apps; one failed source
   must not erase another's catalog. Add/remove/toggle while refresh is pending.
10. Import a known Library version; choose a preferred source. Only that source offers
    an update. Disable/remove it: no silent fallback. Ignore/restoring version works.
11. Update All confirmation queues the expected source/version jobs exactly once.
12. Navigate away during transfers; jobs remain in both Store and Downloads entry points.
    Pause/resume, cancel a queued and active job, retry failure, delete a ready package.
13. Terminate during downloading/paused: relaunch must say interrupted and offer retry,
    not fabricate successful completion or resumed progress.
14. Test 404 package, HTML masquerading as IPA, declared-size mismatch, excessive payload,
    denied redirect, storage exhaustion, and network interruption. None may become ready.
15. Explicit Import opens the existing Import Hub. User preview, duplicates and structural
    validation still apply. No implicit sign/install and no source trust badge.
16. Old source JSON offers migration URLs without silently adding malformed repositories.
17. With 30 sources / 1,000+ fixture apps, measure cold/warm load, scrolling, search and
    artwork memory in Instruments. Pull-to-refresh must not fetch fresh/disabled sources.
18. VoiceOver: all source/app rows announce source names and version; health includes
    text, not just color; screenshot page position and controls are discoverable.
19. Dynamic Type through accessibility XXXL, light/dark, bold text, Increase Contrast,
    Reduce Motion, iPhone landscape and iPad split view: no hidden actions or clipped
    critical metadata. Confirm touch targets are at least 44 points.
20. iPad hardware keyboard: search, tab focus, Add Source shortcut, screenshot arrows/Escape,
    all actions reachable without touch. Check VoiceOver focus after navigation/alerts.
21. Test Mission Control uses the same due-source refresh policy and reports unavailable
    refreshes without deleting metadata or describing latency as trust.

Do not mark the accessibility or production-readiness success criterion complete until
these on-device/simulator checks and the native build/test gate are recorded.
