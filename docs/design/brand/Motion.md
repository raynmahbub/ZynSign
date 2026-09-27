# Motion & Haptics

## The gesture

The brand moves the way the pen writes: **bottom-left to top-right along the
Z diagonal**, arriving with an ease-out and stopping cleanly. The launch
splash (`ZynSplashView`), the README hero (`hero.gif`), the success state and
the Install Health ring all use that one gesture; nothing pulses, bounces or
loops while the user is working.

## Timing — `ZMotion`

| Preset | Curve | Use |
|---|---|---|
| `fast` | ease-out 200 ms | Content replacing content in place, a row toggling, list reorders |
| `standard` | ease-in-out 300 ms | A state change the user caused |
| `interactive` | spring 350 ms, damping 0.80 | Following a finger; settling after a tap; a toast arriving |
| `relaxed` | spring 450 ms, damping 0.82 | The ribbon drawing itself, a success tick, a ring filling |
| `fade` | opacity only | Rows appearing in lists — never an offset per row |

The 300–500 ms window belongs to hero moments; list and navigation changes
stay at 200 ms so a long library never feels slow. All curves are ease-out
or springs; there is no linear motion (except a progress bar, which must
not ease) and no "random fade". `quick`, `arrive` and `hero` remain as
aliases of `fast`, `interactive` and `relaxed`.

## Reduce Motion

`ZMotion(reduceMotion:preference:)` resolves every preset to `nil` when the
system setting or the in-app preference asks for it, and SwiftUI then applies
the change immediately. `RootView` publishes the same decision to
`ZMotion.permitsAnimationGlobally`, so `withAnimation(ZMotion.fast)` in a
view model or a static helper obeys it too. Decorative loops (skeleton
shimmer) do not start at all. The splash shows the finished mark; the hero GIF is
replaced by `hero-still.png` where `prefers-reduced-motion` is honoured.

## Haptic language — `ZHaptics.play(_:)`

| Moment | Feedback | Where |
|---|---|---|
| `imported` | light impact | A package, certificate or profile was added |
| `sign` | medium impact | The user started a signing run |
| `succeeded` | notification success | Signing / import / verification finished well |
| `failed` | notification error | A run failed |
| `attention` | notification warning | A refusal or a partial result — not a crash |
| `select` | selection change | Pickers, segmented controls, reorder |
| `navigate` | light impact | Opening a section from the workspace |

Rules: one haptic per moment, never on scroll, never repeated for the same
outcome, always behind the Haptics preference. `ZHaptics` is stateless; no
view retains a generator.
