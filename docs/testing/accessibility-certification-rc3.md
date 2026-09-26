# RC 3 — Accessibility Certification

**Date:** 2026-09-26 · **Milestone:** RC 3 — Step 29 ·
**Scope:** final accessibility pass over the core workflows.

Review environment: Linux with Python 3.11, without a Swift toolchain or
Xcode. The static evidence below was gathered by executed scans of the
frozen source on 2026-09-26 (file counts reproducible with the `grep`
patterns given). Runtime verification with VoiceOver and the Settings
accessibility switches is part of the private device matrix
([private-testing.md](../releases/private-testing.md)) and is recorded
there.

## Areas

### 1. VoiceOver — verified (static) + device matrix

- 56 source files carry accessibility annotations
  (`grep -rl accessibility ZynSign`): labels, values, hints, actions, and
  traits on the import hub, library cards and rows, certificate and profile
  cards, signing stages, queue job cards, and the design-system components.
- Statuses are spoken as text (`ZStatusBadge`, `ZSigningStatusMachine`
  stage names), not conveyed by color alone; signing progress and queue
  stages announce their stage boundaries (recorded in
  [signing-queue.md](../architecture/signing-queue.md)).
- Toasts and toasts-from-errors (`ZToast`) surface user-presentable
  messages with spoken output.

### 2. Dynamic Type — verified (static) + device matrix

- 23 files use Dynamic Type text styles / scaled metrics
  (`grep -rlE "dynamicTypeSize|UIFontMetrics|ScaledMetric|relativeTo:" ZynSign`).
- Core layouts (import queue, library grid/list, signing screen, settings
  sections) are stack/list-based and reflow rather than truncate; design
  tokens (`ZSpacing`) are absolute padding, not fixed font sizes.

### 3. Reduce Motion — verified (static) + device matrix

- 8 files read the accessibility motion state
  (`grep -rlE "accessibilityReduceMotion|reduceMotion|MotionPreference|\\.reduced" ZynSign`),
  including the import drop target and hub components, which skip scale and
  snap animations when Reduce Motion is on.
- The app-level `AnimationPreference` (`UserPreferences`) implements
  *the system setting always wins*: `.standard` follows the system Reduce
  Motion switch, `.reduced`/`.off` keep state changes legible without
  movement; a user who asked for reduced motion at the system level never
  gets more motion than `.reduced`.

### 4. High Contrast — verified (static) + device matrix

- Increased-contrast adaptation is applied at the token level
  (`DesignTokens` colors, 3 files read `accessibilityContrast` /
  increased-contrast state); status badges carry text labels so meaning
  never depends on hue alone.
- Dark Mode is token-based (`ZColors`), so the same contrast relationship
  holds in both appearances.

### 5. Touch targets — verified (design system) + device matrix

- Controls are native SwiftUI buttons/controls (≥ 44 pt standard hit
  targets) or design-system components that wrap them (`ZCard` actions,
  toolbar items, swipe/context menus with full-width rows). No custom
  sub-44 pt tap regions exist in the design system; the device matrix
  verifies reachability on iPhone and iPad.

### 6. Focus order — verified (static) + device matrix

- 43 files use focus/element-ordering APIs
  (`grep -rlE "accessibilitySortPriority|accessibilityAddTraits|accessibilityElement|focusable|@FocusState" ZynSign`).
- Views are declared in reading order (header → content → actions); forms
  in the signing wizard, preset builder, and settings follow their visual
  order; destructive actions are ordered last where screens list recovery
  actions (`RecoveryActionKind` documents the safe-first ordering).

## Core workflow usability

The workflows in the
[final validation matrix](final-validation-rc3.md) — import, browse,
certificate import, profile import, signing, verification, export, store,
downloads, installation workspace, backup & restore — each contain their
status surfaces as text, expose their primary actions as standard controls,
and remain usable at the largest accessibility text size per the layout
constructions above. Runtime confirmation at AX settings is a required
private-matrix row.

## Verdict

**Accessibility certified at the static and design-system level** for all
six areas; the device pass with VoiceOver, AX settings, and both device
classes completes the certification in the private matrix. No known
accessibility blocker exists in the frozen codebase.
