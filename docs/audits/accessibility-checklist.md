# Accessibility checklist — the human half

`Scripts/audit_accessibility.py --strict` proves two things in source: no
colour outside the token system, no fixed control under 44 × 44 pt. It passes
on every commit. Everything below needs a person, a device, and the
Accessibility Inspector, and is signed off per release in
[`rc2-ux-refinement-checklist.md`](rc2-ux-refinement-checklist.md)'s successor
for that tag.

Run on: iPhone SE (smallest), iPhone 16 Pro Max (largest), iPad (split view).
Settings under test: VoiceOver · Dynamic Type at AX5 · Reduce Motion ·
Reduce Transparency · Increase Contrast · Smart Invert · Bold Text ·
Button Shapes · Color filters (deuteranopia, grayscale).

## VoiceOver

- [ ] Every screen title is read first and once (`.isHeader` on the title).
- [ ] Every card on the Smart Workspace reads as one element with title, value and hint (`accessibilityElement(children: .combine)`).
- [ ] Every button says what it does, not what it looks like ("Sign Example", not "bolt").
- [ ] Every status (health check, badge, queue state) is spoken with its word, not only its colour.
- [ ] Progress and completion are announced (`AccessibilityNotification.Announcement`) — import, sign, verify, download.
- [ ] Custom empty-state illustrations are hidden (`accessibilityHidden(true)`); the title and message carry the meaning.
- [ ] Focus lands on the new sheet's title when a sheet opens, and returns to the trigger when it closes.
- [ ] The rotor lists headings for Library, Certificates, Profiles, Settings.

## Dynamic Type

- [ ] At AX5 nothing truncates that carries meaning; long titles wrap, rows grow, grids collapse to lists.
- [ ] Number displays (score, counts) keep `monospacedDigit()` and do not overlap labels.
- [ ] Line-art illustrations scale with the text (they are vector; check they do not dominate the screen at AX5).
- [ ] Toolbar items with text labels remain tappable; icon-only items have labels.

## Motion, transparency, contrast

- [ ] Reduce Motion: splash shows the finished mark; no ribbon draw, no spring; sheets and toasts still appear.
- [ ] Reduce Transparency: `.thinMaterial` cards fall back to opaque system backgrounds (system handles it — verify visually).
- [ ] Increase Contrast: secondary text and hairlines remain visible; the indigo accent darkens under labels.
- [ ] Smart Invert: the app icon, the mark and screenshots are not inverted (`accessibilityIgnoresInvertColors` on images).
- [ ] Grayscale filter: every status is still distinguishable by symbol and word.

## Touch and layout

- [ ] All controls ≥ 44 × 44 pt in practice, including list-row trailing buttons and card action links.
- [ ] Swipe actions have long-press / context-menu equivalents.
- [ ] Keyboard (iPad): focus ring visible, Tab order follows reading order, ⌘-shortcuts listed in the Discoverability HUD.
- [ ] One-handed reach: primary action on every screen is in the lower half or in the navigation bar's trailing slot, never only at the top of a long scroll.

## Sign-off

| Release | Device set | Tester | Date | Notes |
|---|---|---|---|---|
| `v1.0.0-rc.3` | | | | |
