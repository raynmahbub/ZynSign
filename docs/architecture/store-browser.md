# Store Browser & Repository Ecosystem

Beta 1 · Step 21 implementation. This does not change the release train or claim
that an imported package is installed, trusted, or accepted by iOS.

## Entry points and user experience

**Settings → Browse → Store** opens the storefront. Sources, Updates, and Download
Jobs are dedicated destinations. **Downloads → Store Download Jobs** opens the
same app-owned queue. Mission Control uses the same incremental refresh service.

Home includes Featured Apps, Recently Updated, Trending, New Releases, Categories,
Installed Apps, Continue Browsing, and the unified catalog. Empty sections explain
missing data instead of inventing recommendations. Featured means declared by a
source; Trending means most visited **on this device**. New Releases uses the
oldest release date available in each listing's history, not an inferred publication
date. Installed Apps matches the Library: iOS does not expose a general installed-app
inventory to ZynSign. These distinctions are visible in the UI.

Search includes names, developers, bundle IDs, category, and source names. Category
filters combine with the query. A pre-normalized index supports case/diacritic folding
and bounded one-edit matching for tokens of four or more characters. Input is debounced
100 ms; queries are bounded to 200 characters / 16 tokens. Submitted recent searches
(maximum 12), browsing history (30), and local visit counts are clearable on Home.
No community activity or ratings are fabricated or transmitted.

App details contain source-aware identity, artwork, description, size, compatibility
claims, a screenshot carousel, full-screen paging/pinch/pan with accessible zoom controls,
and expandable release history. Download, explicit Import, View Source, and Share are
separate actions. The detail page lets the user compare source versions and explicitly
choose the source used by Updates.

## Ownership and boundaries

```
CompositionRoot → ApplicationEnvironment.storeBrowser
    StoreBrowserModel (@MainActor, observable)
        StoreRepository (actor)
            StoreFetching → StoreHTTPClient
            StoreManifestValidator → source-scoped CatalogApp / CatalogRelease
            StorePersisting → FileStoreCache
        StoreDownloadQueue (@MainActor, observable, app-owned)
            StoreTransferCreating → StorePackageTransfer
            UUID-isolated quarantine + persisted job journal
            explicit Import → ImportHub.receive(origin: .storeDownload)
                existing inspection / duplicate review / library admission
                existing user-confirmed SigningQueue path
    StoreImageCache (actor, coalescing, bounded disk + decoded-memory caches)
```

Downloading is **not** a signing job. `SigningQueue` retains its signing admission,
profile, lock, and verification rules. The two queues share `JobQueueCapacity`, not
signing state enums or unsigned-package bypasses. The Import Hub is the integration
boundary into the existing job architecture. Store services outlive their screens;
the old detached transfer plus download-notification double-start path is removed.
The legacy direct-URL Downloads implementation is not rewritten in this milestone.

`CatalogApp.id` is source UUID + bundle ID. Enabled sources form the unified catalog;
disabling/removing a source removes its listings, never another source's version.
Atomic, monotonically revisioned commits are serialized independently from network waits. In-flight refreshes
cannot resurrect removed sources or overwrite enabled/preferred-source choices.
Removal leaves preferred-source IDs as tombstones: no silent fallback. Existing
user-requested transfer jobs retain their original source and release.

The transport, manifest adapter, store persistence, transfer factory, catalog search,
and update policy are separate seams. Future verified-source evidence, developer
profiles, collections, ratings, and synchronization can extend versioned models and
ports without replacing this architecture. Source health must not become verification.

## Supported manifest contract

An independent AltSource-style JSON adapter, not a claim of exhaustive support for
all third-party source dialects:

- Required source fields: `name` and `apps` (an empty app list is valid, with Warning
  health). Optional `identifier`, `iconURL`, `subtitle`/`description`, `featuredApps`.
- Required app fields: `name`, `bundleIdentifier`, `developerName`, plus nonempty
  `versions` or legacy `version` + `downloadURL` fields.
- Modern releases: `version`, `downloadURL`, optional `date`, `localizedDescription`,
  positive `size` in bytes, `minOSVersion`, and `maxOSVersion`. Arrays are newest-first,
  as declared by the publisher. Versions within one app must be unique.
- Legacy release fields: `versionDate`, `versionDescription`, `size`, and OS bounds.
- App metadata: `localizedDescription`, `subtitle`, `iconURL`, `category`, `featured`.
  Missing category defaults to Utilities. Unknown categories remain searchable.
- `screenshotURLs` supports a URL array or `iphone`/`ipad` URL-array groups.
- Dates: ISO 8601 (including fractional seconds) or strict `yyyy-MM-dd`.
- Unknown extension keys are ignored. Malformed **known** fields reject the entire
  source; malformed apps are never silently dropped. Referenced featured IDs must exist.

Limits: 64 sources; 8 MiB per response; 5,000 apps/source; 200 releases/app;
30 screenshots/app; bounded names, descriptions, URLs and version strings. Source
and asset URLs require absolute HTTPS without embedded credentials, fragments, or
custom ports. URL canonicalization normalizes host/scheme/default port/root path;
source URL and declared source identifier prevent duplicate admission. Sources with
no declared identifier are distinguished by their canonical configured URL. Arbitrary
mirror equivalence is not guessed.

Old `Documents/ZynSignSources.json` is preserved. Sources offers those URLs for explicit
validation into the new catalog. Unvalidated prototype records are never silently trusted.

## Refresh, health, and offline behavior

The catalog is an atomic, versioned JSON snapshot in
`Application Support/Store/catalog-v1.json` (128 MiB bound), including descriptions,
release metadata, preferences, ignores and browsing history. Corrupt/unknown-schema
caches are reported and left untouched, not silently replaced with an empty catalog.
Safety-critical cached invariants and URLs are checked on restoration.

Normal load/pull-to-refresh only checks enabled sources whose last attempt is over
one hour old, one request at a time. Individual Refresh Source bypasses the interval.
ETag and Last-Modified enable 304 responses without parsing/replacing the app catalog.
Requests have bounded request/resource timeouts and streamed response-size checks.
Failed refreshes preserve the last accepted snapshot and attach an error. Cancelled
view tasks do not mark a source offline.

- **Healthy**: last accepted metadata is recent, nonempty, and the last check succeeded.
- **Warning**: empty catalog, parsing/server failure, or no successful refresh in seven days.
- **Offline**: network request failure. This is observed availability, not trust.

The UI shows last success, last attempt, app count, newest declared release, errors,
and whether metadata was saved rather than fetched during the current session.
Offline metadata is immediately browsable; updates based on it are labeled as such.

Artwork is lazy, URL-keyed, SHA-256 filename-addressed and coalesced per in-flight URL.
Cache limits: 12 MiB encoded/image, 150 MiB disk (oldest-written eviction), 40 MiB decoded
memory. Images are downsampled to 1,600 pixels with dimension and 16-megapixel decode bounds. Only requested
artwork is cached; the OS may evict it. Missing offline images show placeholders;
the gallery explains unavailable images. Metadata is not in the evictable image cache.

## Updates and downloads

Updates only compare Library marketing versions with enabled configured repositories
for which the user explicitly selected a preferred source. Numeric dotted versions
are compared numerically with trailing zero equivalence; arbitrary/prerelease strings
require manual review. Missing version facts do not create an update. Ignore Version
is scoped to source + bundle + version; ignored versions can be restored.

Update and confirmed Update All enqueue downloads, not automatic imports/installations.
Each transfer retains source ID/name, bundle, release URL/version and optional size.
The persisted FIFO queue runs at most two transfers; paused live transfers retain their
slots. Identical source/release requests deduplicate. Progress is determinate only
when Content-Length is known, and callbacks are throttled. Cancel and clean Retry
are explicit. Terminal jobs/packages can be removed.

Packages are UUID-named under `Application Support/Store/Quarantine`, never named from
server paths or Content-Disposition. HTTP success, a 4 GiB limit, optional declared-size
match, and a ZIP local-header signature are required before “Ready for inspection.”
These are intake checks, **not cryptographic integrity or authenticity verification**.
Import then enters the normal Import Hub for structural inspection and user review.
Downloaded code is never executed by the Store. No source-add success or health badge
implies publisher/package trust. Cookies and credential storage are disabled, and
redirects may not downgrade HTTPS or introduce disallowed URLs.

Journal restoration marks waiting/running/paused work interrupted and retryable; it
never asserts background resumption. Completed files must still exist. This Step 21
queue supports **live-session pause**, not HTTP-range resume or background relaunch.
Step 22 owns resumable/background transfer orchestration, stronger integrity checks,
and the professional unified download-to-installation-ready pipeline.

## Verification status

See [the test and device checklist](../testing/store-browser.md). Synthetic XCTest
coverage was added for parser, search/version/health policies, update source locking,
repository refresh/cache behavior, concurrency races, and download queue lifecycle.
The Linux editing environment cannot run Xcode, SwiftUI, UIKit, or device accessibility
checks. Syntax parsing and existing host checks passing do not establish simulator
compilation, rendered UI quality, or complete accessibility. Those are release gates.
