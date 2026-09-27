# Release notes — template

Copy this file to `notes-v<version>.md` for every release. The sections are
not optional: the ones that feel skippable are the ones a reader needs.

```markdown
## [<version>] — <stage> · <one-line theme>

Market `<marketing>` build `<build>` (`CFBundleShortVersionString <marketing>`,
`CFBundleVersion <build>`), tag `v<version>`. Release train `.<stage>`:
<which features this release switches on, and which stay hidden>.

<One paragraph on what this release is for.>

### Added

- **<Feature>** *(visible from `<stage>`)* — <what it does, in the user's
  terms>. <The bound or policy that matters: a size limit, a refusal, a
  storage location.> See `docs/architecture/<topic>.md`.

### Changed

- **<Change>** — <what changed and why a user would notice>.

### Fixed

- **<Fix>** — <the symptom, then the cause>.

### Known limitations

Carried in `ReleaseBlockerRecord.registry` and shown in the Compatibility Lab:

- <Limitation>. *(Severity, accepted/open — <what ZynSign does instead>.)*

### What this release deliberately does not claim

- <A capability ZynSign does not have, stated plainly.>
- <A result nobody measured.>

### Testing

New unit tests: <names>. **Their results belong to CI** — the
`Build and test (Xcode)` job is the judge, and this note claims nothing about
them until it has run.

Host audits, run on the machine that produced this note:

| Audit | Result |
|---|---|
| `Scripts/audit_crash_surface.py` | <constructs, justified> |
| `Scripts/audit_accessibility.py` | <findings, waived, review> |
| `Scripts/audit_regression_coverage.py` | <behaviours, executed, deferred> |

Device rows: <which device classes and iOS versions ran the Compatibility Lab,
and what the verdict was>. No row is filled in from anything but a run.
```

## Rules for filling it in

1. **Every entry names a stage.** A feature that is built but hidden is
   described as built and hidden, with the stage that switches it on.
2. **Every limitation is listed**, with what ZynSign does instead. A limitation
   nobody has to discover twice is the point.
3. **The "does not claim" section is never empty.** If it would be, look again:
   something is being overclaimed.
4. **No test result is claimed before CI has run it.** Say whose job it is to
   judge, and let that job speak.
5. **No device row is filled in from a simulator run** — or from a wish.
