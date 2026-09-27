# Audit Records

Dated, point-in-time verification passes over the repository. An audit record
describes what was checked, what was found, and what changed because of it —
it is never updated after the fact; a new pass adds a new file.

| Record | Scope |
|---|---|
| [2026-09-25-horizon-0.1.0-audit.md](2026-09-25-horizon-0.1.0-audit.md) | Full pre-public audit of the Horizon `0.1.0` milestone: workflows, host vectors, documentation claims |
| [rc2-ux-refinement-checklist.md](rc2-ux-refinement-checklist.md) | The sixteen RC 2 UX-polish criteria, each with its verification |

## Running the audits yourself

The scripted portions run anywhere Python 3 runs, and in CI:

```sh
python3 Scripts/audit_crash_surface.py        # crash-surface inventory vs baseline
python3 Scripts/audit_accessibility.py        # colours, touch targets, text scaling
python3 Scripts/audit_regression_coverage.py  # regression catalogue names real tests
python3 Scripts/generate_hardening_report.py  # browsable hardening report
```

The Compatibility Lab suites that require a device are documented in
[../hardening/README.md](../hardening/README.md).
