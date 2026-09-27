# Quick Start

From clone to a running build. Everything here is the same path CI executes
([continuous-integration.md](continuous-integration.md)); nothing on this page
is a workflow the repository does not already run.

## Requirements

| Tool | Version | Why |
|---|---|---|
| Xcode | 16 or later | The project uses synchronized folder groups; sources are picked up directly from `ZynSign/` and `Tests/ZynSignTests/` |
| macOS | Xcode 16-compatible | The product runs on iOS; macOS is developer tooling only |
| Python 3 | any recent 3.x | The audit and release scripts (`Scripts/`) use the standard library only |
| Simulator runtime | iOS 17+ | The deployment target is iOS 17.0 |

There are no external package dependencies — Apple frameworks and the Swift
standard library only — so there is nothing to resolve before the first build.

## Build and run

```sh
git clone https://github.com/raynmahbub/ZynSign.git
cd ZynSign
open ZynSign.xcodeproj
```

Select the shared `ZynSign` scheme and an iPhone simulator, then Product ▸
Run. The app opens on the Home dashboard with the first-launch onboarding.

Or, without the IDE:

```sh
xcodebuild build \
  -project ZynSign.xcodeproj \
  -scheme ZynSign \
  -destination 'generic/platform=iOS Simulator'
```

## Test

```sh
xcodebuild test \
  -project ZynSign.xcodeproj \
  -scheme ZynSign \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'
```

That is the exact invocation the `Build and test` CI job runs. Details of
what the suites cover: [Testing.md](Testing.md).

## What you should see

- A Debug build shows **every** release-train feature regardless of
  `ReleaseTrain.current` — Debug is not release evidence.
- To preview a specific release stage, add the launch argument
  `-ZynSignReleaseStage alpha2` (see the scheme's *Run* arguments).

## Next

- [Build.md](Build.md) — configurations, settings, and where sources live.
- [Testing.md](Testing.md) — suites, host vectors, and the audit scripts.
- [Debugging.md](Debugging.md) — how failures are represented and how to read them.
- [Troubleshooting.md](Troubleshooting.md) — common refusals and what they mean.
