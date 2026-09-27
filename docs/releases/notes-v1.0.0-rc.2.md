## [1.0.0-rc.2] — RC 2 · Final Polish & UX Refinement

Market `1.0.0` build `5` (`CFBundleShortVersionString 1.0.0`, `CFBundleVersion 5`),
tag `v1.0.0-rc.2`. Release train stays at `.rc2`: **no staged feature moves** —
the only feature still hidden is `Signing Health Score`, which ships at `v1.0.0`.

**This candidate adds no capability.** RC 2 is the pass that turns a
feature-complete engineering milestone into a native-quality application: one
design system, one onboarding story, one way of failing well — on iPhone and
iPad, in light and dark, at every Dynamic Type size.

### Added

- **Unified design system (`ZynSignTokens`)** — one typography scale
  (`ZTypography`), one 4pt spacing grid (`ZSpacing`), one radius scale
  (`ZRadius`), elevation tokens (`ZShadow`), and semantic colours (`ZColors`),
  used consistently across every screen.
- **Card system (`ZCard`)** — filled, material, and outlined variants, each
  with a subtle dark-mode edge stroke (`Color.primary.opacity(0.06)`) so cards
  keep their boundary on OLED black without a harsh line.
- **Button system (`ZButtonStyles`)** — primary, secondary, destructive, and
  large-prominent styles with spring press animation, 44×44 pt minimum touch
  targets, and haptic feedback.
- **Bespoke empty states (`ZEmptyState`)** — layered gradient illustrations,
  a human explanation, and one clear action, replacing generic placeholders
  across apps, certificates, profiles, downloads, collections, presets,
  history, and search.
- **Guided onboarding (`ZOnboardingView`)** — a six-step first-launch
  walkthrough (welcome and privacy, import, certificate, profile, library,
  ready), skippable from any step, revisitable from Settings → General.
- **Adaptive layouts** — `RootView` renders a `NavigationSplitView` with a
  sidebar on regular width classes (iPad, wide landscape); grid columns adapt
  their minimum width instead of stretching a phone layout.
- **Actionable errors (`ZErrorView`)** — what happened, why, a highlighted
  "what to do next", and an expandable technical drawer with one-tap
  diagnostic copying, on top of `ErrorRecoveryAdvisor` from RC 1.
- **Skeleton placeholders (`ZSkeleton`)** — shimmering rows and grids while
  content loads, so no screen ever goes blank.
- **Subtle haptics (`ZHaptics`)** — calibrated impacts and notifications on
  import completion, signing milestones, filter changes, and toggles,
  respecting the system haptics setting.

### Changed

- **Microcopy** — every user-facing string audited; vague notices replaced
  with concrete guidance (for example, profile-expiration warnings that say
  what to renew and where).
- **App icon and brand** — the shipping app now carries its icon:
  `ZynSign/Resources/Assets.xcassets` compiles the master artwork into the
  bundle (light, dark, and tinted appearances), and the Z·Pen mark is rendered
  from one master across the lockup, banner, favicon, and social preview.

### Verification

- `python3 Scripts/release_train.py check` — train consistent at `v1.0.0-rc.2`,
  `MARKETING_VERSION 1.0.0`, build `5`.
- CI: build + unit tests on an iPhone simulator, repository hygiene, host
  vectors, and the RC audits (crash surface, accessibility, regression
  catalogue).
- Internal record: [docs/audits/rc2-ux-refinement-checklist.md](../audits/rc2-ux-refinement-checklist.md).

### Honest limits (unchanged)

In-app installation stays unavailable (`noDeliveryMechanism`), Pairing/JIT/Mux
stays never, and off-device measurement stays none — see
[WHAT_DOES_NOT_EXIST.md](../product/WHAT_DOES_NOT_EXIST.md).
