# Accessibility audit

Six items, and an honest split: three of them a machine can check, and three a
machine cannot. A screen cannot hear itself read, so the Lab reports those rows
as `Not run` and names the protocol that settles them.

## Where each item is checked

| Item | Checked by | Status before a human pass |
|---|---|---|
| Dynamic Type | The app: the preference and the size category the device reports | Executed |
| Reduce Motion | The app: the rule itself, with the system setting winning | Executed |
| Increase Contrast | The app: both the system's value and ZynSign's own | Executed |
| Colour contrast | The host script for hard-coded colours; the Accessibility Inspector for ratios | Partial |
| Touch targets | The host script for fixed frames; the Inspector for rendered geometry | Partial |
| VoiceOver | A person, with the device | Not run |
| Focus order | A person, with VoiceOver and a keyboard | Not run |

## What the app checks, and why it is worth checking

**Dynamic Type.** ZynSign follows the system text size by default. The check
records the preference and the size category the device is actually set to, and
reports a warning when the app has been told not to follow it — a decision a
reviewer should see rather than discover.

**Reduce Motion.** The rule is that the system always wins:
`AnimationPreference.permitsAnimation(systemReduceMotion:)` is the only place
the answer may come from. The check asserts it directly. If Reduce Motion is on
at the system level and ZynSign would still animate, the row **fails** — the
rule, not the rendering, is what broke.

**Increase Contrast.** A warning when the system asks for more contrast and
ZynSign's own setting is off. ZynSign's setting adds to the system's; it never
replaces it.

## What the host script checks

`python3 Scripts/audit_accessibility.py` looks for two things that are true in
the source and decide what a screen can do:

1. **A hard-coded colour.** A colour built from numbers cannot adapt to
   Increase Contrast or Dark Appearance, so it is a contrast defect by
   construction. Every colour in ZynSign comes from the token system or the
   platform's semantic colours, whose contrast the platform maintains in both
   appearances. `0` found outside DesignSystem today.
2. **A control with a fixed frame below 44×44 points.** The interactive window
   is deliberately narrow — two lines above, one below — so a decorative icon
   in a row is not blamed for the menu further down. `0` found today.

It also reports, as review items rather than findings, every
`minimumScaleFactor` below 0.75: text that may shrink that far is
uncomfortable at the smaller Dynamic Type sizes. Five are reported.

### Waivers

A waiver is a decision, not a silence. It is printed whenever the audit runs,
with the file, the shape, and the reasoning, so a reviewer can disagree:

- **`AppIconView` — derived hues.** A synthesised application icon, derived
  from the bundle identifier so the same application always shows the same
  mark. It is decoration standing in for an icon the package declared, not
  interface chrome: it carries no text, and it is marked as an image for
  VoiceOver. Keeping it out of the token system is what keeps it recognisable
  as a placeholder.

Add a waiver by editing `WAIVERS` in the script. Use the shape of the line, not
its number, so the waiver survives an edit to the file.

## The human pass

1. **VoiceOver.** Every primary screen, one swipe at a time. Every control is
   reachable, labelled, and reads its state; no row depends on a gesture alone;
   the order follows the visual order; sheets take focus and return it where it
   came from.
2. **Contrast.** Accessibility Inspector, or screenshots through a contrast
   tool: 4.5:1 for body text, 3:1 for large text and control boundaries, in
   light and dark appearance.
3. **Touch targets.** Every tappable control is at least 44×44 points, and
   adjacent targets do not overlap.
4. **Focus order.** VoiceOver and a hardware keyboard, on iPad.
5. **Dynamic Type, largest size.** Every primary screen: nothing clipped,
   nothing unreachable, no horizontal scroll traps.

Record what you found as an overlay, or in the release notes, with the device
and iOS version it was made on:

```json
{
  "source": "Accessibility Inspector, iPhone 15 Pro Max, iOS 18.1",
  "statuses": {
    "accessibility.voiceOver": "passed",
    "accessibility.focusOrder": "passed"
  }
}
```

## The rule that decides the release

An accessibility issue that breaks a core workflow is a release blocker. A
screen a VoiceOver user cannot complete is not a "nice to have": it is a
`High` at minimum, and `Critical` when there is no other route through the
workflow. The checklist in [release-blockers.md](release-blockers.md) carries
the item.
