#!/usr/bin/env python3
"""
audit_navigation_stack.py — keep a pushed destination from owning a stack.

Nesting a `NavigationStack` inside a view that is *pushed* onto a stack the
host already owns crashes at runtime. It compiles, it passes every unit test
in the repository, and it is invisible to static typing — the screen simply
dies the first time it is navigated to. That is the exact shape of the bug
that made Settings unusable, and the reason it is worth a gate rather than a
code review convention.

The rule this script enforces:

    A view that is pushed as a `NavigationLink` destination or a
    `navigationDestination` must not itself open a `NavigationStack` —
    directly or through a view it builds in its own body.

Presenting the same view in a `sheet` is fine and is not reported: a sheet
is a fresh presentation context, so a stack inside it is correct. A view is
also allowed to own a stack when it takes an `embedsNavigationStack` flag and
supplies its own container only when the host does not — that is the
sanctioned pattern, and these three views use it.

The direct form is the one that is easy to see. The *indirect* form is the
one that shipped: a pushed screen built a second screen in its body, and that
second screen opened a `NavigationStack` (`BundleExplorerView` →
`IPAExplorerScreen`). Neither view is wrong on its own, the compiler is happy,
and every unit test passes — the explorer simply died the first time it was
opened. A finding therefore means one of three things: the pushed view needs
the `embedsNavigationStack` treatment, the view it builds there does, or the
call site should present it as a sheet instead of pushing it.

Usage:
    python3 Scripts/audit_navigation_stack.py            # compare and report
    python3 Scripts/audit_navigation_stack.py --list     # every finding
    python3 Scripts/audit_navigation_stack.py --json     # machine-readable
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, asdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP_DIR = ROOT / "ZynSign"
PRESENTATION_DIR = APP_DIR / "Presentation"

# A top-level type declaration. Nested types are not treated as pushable
# screens, so only declarations that begin a line at column zero are captured.
TYPE_DECL = re.compile(
    r"^(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:public\s+|internal\s+|fileprivate\s+|private\s+|final\s+)*"
    r"(struct|class|enum|extension|actor)\s+([A-Za-z_]\w*)",
    re.MULTILINE,
)

# The two ways a view gets pushed onto a stack the host already owns.
PUSHED = (
    re.compile(r"NavigationLink\s*\{\s*([A-Za-z_]\w*)\s*\("),
    re.compile(r"navigationDestination\s*(?:\([^)]*\)\s*)?\{\s*([A-Za-z_]\w*)\s*\("),
    re.compile(r"navigationDestination\s*\([^)]*\)\s*\{\s*([A-Za-z_]\w*)\s*\("),
)

# Modifiers whose closure content is a separate presentation context. A
# `NavigationStack` inside one of these is not nested into the host's stack.
# `zBottomSheet` is the design system's own sheet, so it opens a fresh
# presentation context exactly like `.sheet` does.
FRESH_CONTEXT = re.compile(
    r"\.(?:sheet|fullScreenCover|popover|alert|confirmationDialog|zBottomSheet)\b"
)

# The sanctioned opt-out: a view that can be handed a host-owned stack.
SELF_MANAGED = re.compile(r"\bembedsNavigationStack\s*:\s*Bool")


@dataclass(frozen=True)
class Finding:
    """One pushed view that opens its own navigation stack."""

    view: str
    pushed_from: str
    line: int
    detail: str

    def render(self) -> str:
        return (
            f"{self.view} opens a NavigationStack but is pushed from "
            f"{self.pushed_from}:{self.line} — {self.detail}"
        )


def strip_comments_and_literals(text: str) -> str:
    """Blank out comments and string literals, preserving offsets and newlines.

    Offsets must survive because findings are reported by line number, and a
    `"NavigationStack"` inside a doc comment or a string must not be read as
    code.
    """
    out: list[str] = []
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        if text.startswith('"""', i):
            end = text.find('"""', i + 3)
            end = n if end == -1 else end + 3
            out.append("".join(c if c == "\n" else " " for c in text[i:end]))
            i = end
            continue
        if ch == '"':
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == '"':
                    j += 1
                    break
                if text[j] == "\n":
                    break
                j += 1
            out.append("".join(c if c == "\n" else " " for c in text[i:j]))
            i = j
            continue
        if text.startswith("//", i):
            end = text.find("\n", i)
            end = n if end == -1 else end
            out.append(" " * (end - i))
            i = end
            continue
        if text.startswith("/*", i):
            end = text.find("*/", i + 2)
            end = n if end == -1 else end + 2
            out.append("".join(c if c == "\n" else " " for c in text[i:end]))
            i = end
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def brace_span(text: str, open_index: int) -> int:
    """Index just past the `}` matching the `{` at `open_index`."""
    depth = 0
    for i in range(open_index, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return i + 1
    return len(text)


def drop_fresh_contexts(text: str) -> str:
    """Remove the closures of sheet-like modifiers, keeping everything else.

    A `NavigationStack` a view opens inside `.sheet { ... }` is in a new
    presentation context and is not nested into the host's stack, so those
    closures are blanked before the search runs.
    """
    out = list(text)
    for match in FRESH_CONTEXT.finditer(text):
        i = _skip_arguments(text, match.end())
        if i is None or text[i] != "{":
            continue
        for j in range(i, brace_span(text, i)):
            if out[j] != "\n":
                out[j] = " "
    return "".join(out)


def _skip_arguments(text: str, index: int) -> int | None:
    """Index of the `{` that opens a modifier's closure, or None.

    A modifier is written `.sheet(isPresented: $flag) { ... }`, so the
    closure is preceded by an argument list that has to be stepped over
    before the brace can be found.
    """
    n = len(text)
    i = index
    while i < n and text[i] in " \t":
        i += 1
    if i < n and text[i] == "(":
        depth = 0
        while i < n:
            if text[i] == "(":
                depth += 1
            elif text[i] == ")":
                depth -= 1
                if depth == 0:
                    i += 1
                    break
            i += 1
        while i < n and text[i] in " \t":
            i += 1
    return i if i < n else None


@dataclass
class ScreenInfo:
    name: str
    path: Path
    owns_stack: bool
    self_managed: bool
    #: Types this screen constructs in its own body — sheet closures already
    #: dropped — mapped to whether the construction opted out of the built
    #: view's own container (`embedsNavigationStack: false`).
    builds: dict[str, bool]


def constructions(body: str) -> dict[str, bool]:
    """Every type constructed in `body`, and whether the call opted out.

    `body` must already have its sheet-like closures dropped: a stack built
    inside a sheet is a fresh presentation context and is not nested into the
    host's stack, so it is not the script's business.

    The opt-out is the sanctioned `embedsNavigationStack: false` argument at
    the construction site, which is how a view that owns a container is told
    the host already has one.
    """
    found: dict[str, bool] = {}
    for match in re.finditer(r"\b([A-Z][A-Za-z0-9_]*)\s*\(", body):
        name = match.group(1)
        argument_end = _skip_arguments(body, match.end() - 1)
        if argument_end is None:
            continue
        arguments = body[match.end() - 1 : argument_end]
        found[name] = bool(re.search(r"embedsNavigationStack\s*:\s*false", arguments))
    return found


def scan_screens() -> dict[str, ScreenInfo]:
    """Every top-level type in the presentation layer, and whether it owns a stack."""
    screens: dict[str, ScreenInfo] = {}
    for path in sorted(PRESENTATION_DIR.rglob("*.swift")):
        raw = path.read_text(encoding="utf-8")
        text = strip_comments_and_literals(raw)
        for match in TYPE_DECL.finditer(text):
            name = match.group(2)
            brace = text.find("{", match.end())
            if brace == -1:
                continue
            body = text[brace : brace_span(text, brace)]
            rendered = drop_fresh_contexts(body)
            screens[name] = ScreenInfo(
                name=name,
                path=path,
                # A real use opens a container (`NavigationStack {` or
                # `NavigationStack(path:) {`). The plain substring test also
                # matched `embedsNavigationStack`, the flag that says the host
                # owns the container, which is the opposite of a stack here.
                owns_stack=bool(re.search(r"\bNavigationStack\s*[({]", rendered)),
                self_managed=bool(SELF_MANAGED.search(body)),
                builds=constructions(rendered),
            )
    return screens


def scan_push_sites() -> list[tuple[str, Path, int, bool]]:
    """Every push site: `(view, file, line, opted_out)`.

    `opted_out` records whether the call itself passed
    `embedsNavigationStack: false` — the sanctioned way to hand a view that can
    own a container the host's stack instead.
    """
    sites: list[tuple[str, Path, int, bool]] = []
    for path in sorted(PRESENTATION_DIR.rglob("*.swift")):
        text = strip_comments_and_literals(path.read_text(encoding="utf-8"))
        line_starts = [0]
        for index, ch in enumerate(text):
            if ch == "\n":
                line_starts.append(index + 1)

        def line_of(index: int) -> int:
            low, high = 0, len(line_starts) - 1
            while low < high:
                mid = (low + high + 1) // 2
                if line_starts[mid] <= index:
                    low = mid
                else:
                    high = mid - 1
            return low + 1

        for pattern in PUSHED:
            for match in pattern.finditer(text):
                open_paren = match.end() - 1
                end = _skip_arguments(text, open_paren)
                arguments = text[open_paren:end] if end is not None else ""
                sites.append(
                    (
                        match.group(1),
                        path,
                        line_of(match.start()),
                        bool(re.search(r"embedsNavigationStack\s*:\s*false", arguments)),
                    )
                )
    return sites


def nested_stack_chain(name: str, screens: dict[str, ScreenInfo]) -> list[str] | None:
    """The construction chain from `name` to a stack owner, if there is one.

    Follows what a screen builds in its own body, skipping any construction
    that passed `embedsNavigationStack: false` — that view is being handed the
    host's container on purpose. Depth is bounded: this is a gate, not a
    whole-program analysis, and a chain longer than a few screens is not a
    shape anyone should have to reason about.
    """
    queue: list[tuple[str, list[str]]] = [(name, [name])]
    seen = {name}
    while queue:
        current, chain = queue.pop(0)
        info = screens.get(current)
        if info is None or len(chain) > 4:
            continue
        for built, opted_out in info.builds.items():
            if opted_out or built in seen:
                continue
            target = screens.get(built)
            if target is None:
                continue
            seen.add(built)
            if target.owns_stack:
                return chain + [built]
            queue.append((built, chain + [built]))
    return None


def audit() -> list[Finding]:
    screens = scan_screens()
    findings: list[Finding] = []
    reported: set[tuple[str, str, int]] = set()
    for name, path, line, opted_out in scan_push_sites():
        info = screens.get(name)
        if info is None or opted_out:
            continue
        key = (name, path.relative_to(ROOT).as_posix(), line)
        if info.owns_stack:
            findings.append(
                Finding(
                    view=name,
                    pushed_from=key[1],
                    line=line,
                    detail=(
                        "give it an embedsNavigationStack flag and pass false, "
                        "or present it as a sheet instead of pushing it"
                    ),
                )
            )
            reported.add(key)
            continue
        chain = nested_stack_chain(name, screens)
        if chain is None or key in reported:
            continue
        reported.add(key)
        findings.append(
            Finding(
                view=name,
                pushed_from=key[1],
                line=line,
                detail=(
                    "it builds " + " → ".join(chain[1:]) + ", which opens its own "
                    "NavigationStack; give that view an embedsNavigationStack flag "
                    "and pass false where it is built, or present this screen as a "
                    "sheet instead of pushing it"
                ),
            )
        )
    return sorted(findings, key=lambda f: (f.view, f.pushed_from, f.line))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true", help="show every finding")
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    args = parser.parse_args()

    findings = audit()

    if args.json:
        print(json.dumps([asdict(f) for f in findings], indent=2))
        return 1 if findings else 0

    if not findings:
        print("No pushed view opens its own NavigationStack.")
        return 0

    print(
        f"{len(findings)} pushed destination(s) open their own NavigationStack. "
        "Nesting a stack inside a pushed destination crashes at runtime.\n"
    )
    for finding in findings:
        print(f"  - {finding.render()}")

    if not args.list:
        print("\nRun with --list for every finding.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
