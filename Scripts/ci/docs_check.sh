#!/usr/bin/env bash
#
# ZynSign CI — documentation protection.
#
# Validates the documentation set so it stays healthy automatically:
#
#   broken links   — relative Markdown/HTML targets that do not exist   (error)
#   missing images — image references whose file is absent              (error)
#   orphaned pages — docs pages no other page links to                  (warning)
#   markdown quality — missing final newline, CRLF, unbalanced fences   (warning)
#
# Broken links and missing images fail the run; warnings are reported
# for the maintenance bot. Workflows call this script; CI logic lives
# here, never in YAML.
#
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

METRICS_DIR="build/metrics"
mkdir -p "${METRICS_DIR}"

python3 - "${METRICS_DIR}/docs.txt" <<'PYEOF'
import re, sys, pathlib

metrics_path = sys.argv[1]
root = pathlib.Path(".")

md_files = [
    p for p in list(root.glob("*.md")) + list(pathlib.Path("docs").rglob("*.md"))
]
md_files += list(pathlib.Path(".github").rglob("*.md"))
md_files = sorted(set(p for p in md_files if ".git" not in p.parts and "node_modules" not in p.parts))

md_link = re.compile(r"(?<!\!)\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
md_image = re.compile(r"!\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
html_ref = re.compile(r"(?:src|srcset|href)\s*=\s*\"([^\"]+)\"")

def is_external(target: str) -> bool:
    return target.startswith(("http://", "https://", "mailto:", "tel:", "#"))

errors = []
warnings = []
referenced = set()

for md in md_files:
    text = md.read_text(encoding="utf-8")

    # --- markdown quality ------------------------------------------------
    if text and not text.endswith("\n"):
        warnings.append(f"{md}: missing final newline")
    if "\r\n" in text:
        warnings.append(f"{md}: CRLF line endings")
    if text.count("```") % 2 != 0:
        warnings.append(f"{md}: unbalanced code fences")

    targets = []
    for rx, kind in ((md_link, "link"), (md_image, "image"), (html_ref, "link")):
        for m in rx.finditer(text):
            raw = m.group(1)
            for target in raw.split(","):  # srcset lists
                target = target.strip().split()[0] if target.strip() else ""
                if target:
                    targets.append((target, kind))

    line_of = {}
    lines = text.splitlines()
    for target, kind in targets:
        if is_external(target):
            continue
        clean = target.split("#")[0].split("?")[0]
        if not clean:
            continue
        dest = (md.parent / clean).resolve()
        if kind == "image":
            if not dest.is_file():
                errors.append(f"{md}: missing image '{target}'")
        else:
            # Directories link to their GitHub file listing; index pages
            # stand in for the folder when present.
            if dest.is_file():
                pass
            elif dest.is_dir():
                if (dest / "README.md").is_file():
                    dest = (dest / "README.md").resolve()
            else:
                errors.append(f"{md}: broken link '{target}'")
                continue
        try:
            referenced.add(dest.relative_to(root.resolve()).as_posix())
        except ValueError:
            pass

# --- orphaned pages --------------------------------------------------------
docs_pages = [p for p in md_files if "docs" in p.parts and p.name != "README.md"]
orphans = []
for page in docs_pages:
    rel = page.resolve().relative_to(root.resolve()).as_posix()
    if rel not in referenced:
        # The top-level docs index counts as a parent for every page it lists.
        orphans.append(page)
for page in orphans:
    warnings.append(f"{page}: orphaned page (not linked from any other page)")

for w in warnings:
    print(f"::warning title=docs-check::{w}")
for e in errors:
    print(f"::error title=docs-check::{e}")

with open(metrics_path, "w") as fh:
    fh.write(f"pages_checked={len(md_files)}\n")
    fh.write(f"broken_links={sum(1 for e in errors if 'broken link' in e)}\n")
    fh.write(f"missing_images={sum(1 for e in errors if 'missing image' in e)}\n")
    fh.write(f"orphaned_pages={len(orphans)}\n")
    fh.write(f"quality_warnings={len(warnings) - len(orphans)}\n")

print(f"Docs check: {len(md_files)} pages, {len(errors)} error(s), {len(warnings)} warning(s).")
sys.exit(1 if errors else 0)
PYEOF
