#!/usr/bin/env python3
"""Local stand-in for the two CI quality gates, derived from their configs.

SwiftLint error rules (.swiftlint.yml)   trailing_whitespace, force_unwrapping,
                                         force_cast, duplicate_imports,
                                         redundant_nil_coalescing
SwiftFormat rules (.swiftformat)         trailingSpace, consecutiveBlankLines

Scope: the app target, mirroring .swiftlint.yml's `excluded` list. This does
the checks those tools do with their pinned rule sets. It is not a compiler —
it cannot type-check — so it is evidence, not proof.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EXCLUDE = {"Tests", "build", "DerivedData", ".build", ".external-validation",
           "node_modules", "Reports", ".git"}


def swift_files():
    for path in sorted(ROOT.rglob("*.swift")):
        if EXCLUDE & set(path.relative_to(ROOT).parts):
            continue
        yield path


def strip_code(src):
    """Blank out comments and string literals, preserving line structure."""
    out, i, n = [], 0, len(src)
    state = "code"
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if state == "code":
            if c == "/" and nxt == "/":
                state = "line_comment"
                out.append("  ")
                i += 2
                continue
            if c == "/" and nxt == "*":
                state = "block"
                depth = 1
                out.append("  ")
                i += 2
                while i < n and depth:
                    if src[i] == "/" and i + 1 < n and src[i + 1] == "*":
                        depth += 1
                        out.append("  ")
                        i += 2
                        continue
                    if src[i] == "*" and i + 1 < n and src[i + 1] == "/":
                        depth -= 1
                        out.append("  ")
                        i += 2
                        continue
                    out.append("\n" if src[i] == "\n" else " ")
                    i += 1
                state = "code"
                continue
            if c == '"':
                # Triple-quoted or single-line string.
                if src.startswith('"""', i):
                    out.append("   ")
                    i += 3
                    while i < n and not src.startswith('"""', i):
                        out.append("\n" if src[i] == "\n" else " ")
                        i += 1
                    out.append("   ")
                    i += 3
                    continue
                state = "string"
                out.append(" ")
                i += 1
                continue
            out.append(c)
            i += 1
            continue
        if state == "line_comment":
            if c == "\n":
                state = "code"
                out.append("\n")
            else:
                out.append(" ")
            i += 1
            continue
        if state == "string":
            if c == "\\":
                out.append("  ")
                i += 2
                continue
            if c == '"':
                state = "code"
                out.append(" ")
                i += 1
                continue
            if c == "\n":
                state = "code"  # unterminated single-line string
                out.append("\n")
                i += 1
                continue
            out.append(" ")
            i += 1
            continue
    return "".join(out)


# --- rule implementations -------------------------------------------------

def check_trailing_space(path, text, findings):
    # SwiftLint: severity error, ignores_empty_lines: false
    for lineno, line in enumerate(text.splitlines(), 1):
        if line != line.rstrip():
            findings.append(("trailing_whitespace", path, lineno, "trailing space"))


def check_consecutive_blank(path, text, findings):
    run = 0
    for lineno, line in enumerate(text.splitlines(), 1):
        if line.strip() == "":
            run += 1
            if run >= 2:
                findings.append(("consecutiveBlankLines", path, lineno,
                                 f"blank line {run} in a row"))
        else:
            run = 0


def check_force(path, code, findings):
    """Postfix `!` that is not `!=`, `as!`, or `try!`.

    `as!` belongs to force_cast and `try!` to force_try, which is not in the
    pinned rule set — flagging them here would invent findings.
    """
    keywords = {"guard", "if", "while", "return", "try", "as", "in", "for",
                "case", "let", "var", "else", "where", "await", "throw", "nil"}
    for lineno, line in enumerate(code.splitlines(), 1):
        for i, c in enumerate(line):
            if c != "!" or line[i + 1:i + 2] == "=":
                continue
            before = line[:i].rstrip()
            if not before:
                continue  # prefix `!` at the start of an expression
            if before[-1] in "=(,[{&|+-*/<>!?:;":
                continue  # prefix `!` after an operator or opener
            word = re.search(r"([A-Za-z_][A-Za-z0-9_]*)$", before)
            if word and word.group(1) in keywords:
                continue  # `guard !x`, `return !x`, `as!`, `try!`
            findings.append(("force_unwrapping", path, lineno,
                             f"force unwrap: ...{line[max(0, i - 18):i + 1]}"))


def check_nil_coalescing(path, code, findings):
    stripped = re.sub(r"\s+", " ", code)
    for m in re.finditer(r"\?\?\s*(nil|Optional\.none)\b", stripped):
        line = code[:m.start()].count("\n") + 1
        findings.append(("redundant_nil_coalescing", path, line,
                         f"'{m.group(0).strip()}'"))


def check_duplicate_imports(path, code, findings):
    seen = {}
    for lineno, line in enumerate(code.splitlines(), 1):
        m = re.match(r"\s*(?:@testable\s+)?import\s+([\w\.]+)", line)
        if m:
            mod = m.group(1)
            if mod in seen:
                findings.append(("duplicate_imports", path, lineno,
                                 f"'{mod}' also imported on line {seen[mod]}"))
            else:
                seen[mod] = lineno


def check_syntax_balance(path, code, findings):
    for opener, closer, name in (("{", "}", "brace"), ("(", ")", "paren"),
                                 ("[", "]", "bracket")):
        d = code.count(opener) - code.count(closer)
        if d:
            findings.append(("syntax", path, 0,
                             f"unbalanced {name}s: {d:+d}"))


def suppression_map(text):
    """Lines suppressed by `swiftlint:disable` directives.

    Returns (per_line, blanked). `per_line[lineno]` is the set of rules
    suppressed on that line by `:next` / `:this`; `blanked` is the set of
    line numbers covered by a `disable` ... `enable` region.
    """
    per_line, blanked, open_rules = {}, set(), set()
    for lineno, line in enumerate(text.splitlines(), 1):
        directive = re.search(r"swiftlint:(disable|enable)(:next|:this|:previous)?"
                              r"(?::(all|[\w,\s]+))?", line)
        if directive:
            verb, scope, rules = directive.group(1), directive.group(2), directive.group(3)
            rules = {r.strip() for r in (rules or "all").split(",") if r.strip()}
            if scope == ":next":
                per_line.setdefault(lineno + 1, set()).update(rules)
                continue
            if scope == ":this":
                per_line.setdefault(lineno, set()).update(rules)
                continue
            if verb == "disable":
                open_rules |= rules
            else:
                open_rules -= rules
            continue
        if open_rules:
            blanked.add(lineno)
    return per_line, blanked


def suppressed(rule, lineno, per_line, blanked):
    if lineno in blanked:
        return True
    rules = per_line.get(lineno, set())
    return rule in rules or "all" in rules


def main():
    targets = [Path(p) for p in sys.argv[1:]] or None
    findings = []
    for path in swift_files():
        if targets and path.resolve() not in {t.resolve() for t in targets}:
            continue
        text = path.read_text(encoding="utf-8")
        code = strip_code(text)
        rel = path.relative_to(ROOT)
        per_line, blanked = suppression_map(text)
        raw = []
        check_trailing_space(rel, text, raw)
        check_consecutive_blank(rel, text, raw)
        check_force(rel, code, raw)
        check_nil_coalescing(rel, code, raw)
        check_duplicate_imports(rel, code, raw)
        check_syntax_balance(rel, code, raw)
        findings.extend(f for f in raw if not suppressed(f[0], f[2], per_line, blanked))

    if not findings:
        print("clean — no blocking findings")
        return 0
    for rule, path, line, msg in sorted(findings):
        loc = f"{path}:{line}" if line else str(path)
        print(f"{rule:26} {loc}: {msg}")
    print(f"\n{len(findings)} finding(s)")
    return 1


if __name__ == "__main__":
    sys.exit(main())
