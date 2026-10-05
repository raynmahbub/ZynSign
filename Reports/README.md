# Reports

Machine-generated engineering reports. The files in this
directory are produced by `Scripts/ci/` and consumed by developers —
they are never hand-edited and are excluded from version control (CI
uploads them as artifacts; `Scripts/ci/metrics_report.sh` records their
trends in `docs/internal/`).

| Report | Generator | Meaning |
| --- | --- | --- |
| `DeadCodeReport.md` | `Scripts/ci/dead_code_scan.sh` (Periphery) | Unused classes, methods, protocols, properties. **Review before deleting anything — nothing is removed automatically.** |
| Metrics (`build/metrics/`) | every `Scripts/ci/*.sh` | Machine-readable summaries aggregated into `docs/internal/RepositoryHealth.md` and `docs/internal/EngineeringCommandCenter.md` |

Regenerate locally:

```sh
Scripts/ci/architecture_guard.sh
Scripts/ci/complexity_check.sh
Scripts/ci/dead_code_scan.sh
Scripts/ci/metrics_report.sh
```
