# Build

How the project is structured for building, and which settings matter.

## Project shape

- `ZynSign.xcodeproj` with two targets: the application (`ZynSign`) and the
  unit-test target (`ZynSignTests`).
- **Synchronized folder groups** — sources are picked up directly from
  `ZynSign/` and `Tests/ZynSignTests/`. Adding a file to those folders is
  enough; there is no per-file project entry to maintain.
- **No external dependencies.** Apple frameworks and the Swift standard
  library only. There is no package resolution step and no network fetch
  during build.

## Configurations

| Configuration | Behaviour |
|---|---|
| Debug | Every release-train feature is visible regardless of `ReleaseTrain.current`; the Compatibility Lab is available (`Settings → Compatibility Lab`) |
| Release | Only the entry points `ReleaseTrain.isAvailable(_:)` admits; the train state lives in `ZynSign/Application/ReleaseTrain.swift` |

A Release build is the only release evidence. Debug builds are for
development, and the Compatibility Lab is validation apparatus — never a user
feature.

## Key build settings

| Setting | Value | Note |
|---|---|---|
| `IPHONEOS_DEPLOYMENT_TARGET` | 17.0 | Provisional; the deployment-target decision is tracked in the architecture (Section 6, item 17) |
| `MARKETING_VERSION` | from the release train | Purely numeric (Apple requirement); the pre-release suffix lives only in the tag |
| `CURRENT_PROJECT_VERSION` | increments per release | See `docs/releases/version-strategy.md` |

## Where things live

```
ZynSign/
  App/            CompositionRoot — the only place layers are wired
  Application/    Use cases and ports
  Domain/         Pure models and policies
  Platform/       Apple implementations of the ports
  Presentation/   SwiftUI · DesignSystem · the tab shell
Tests/
  ZynSignTests/   Unit and fixture tests
  Host/           Host-run vectors and external validation
```

The four-layer rule (`Presentation → Application → Domain ← Platform`, no
reach-through) is defined in
[../architecture/architecture.md](../architecture/architecture.md) and drawn
in [../architecture/diagrams/](../architecture/diagrams/).

## Release builds

The private → public gate — build, test privately, tag the same binary — is
documented in [../releases/private-testing.md](../releases/private-testing.md).
The Release workflow refuses a tag that is not `ReleaseTrain.current`.
