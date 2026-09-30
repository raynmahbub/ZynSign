#!/usr/bin/env python3
"""
split_composition_root.py — decompose CompositionRoot.swift into focused files.

CompositionRoot has outgrown one file. It is 1,700 lines of static factories
and path helpers, which is past the point where a reader can hold it, and past
the repository's own 800-line warning threshold.

The split is deliberately *mechanical*: every member moves verbatim into an
`extension CompositionRoot` in a file named for its concern. No signature,
body, access level, or ordering changes meaning. The only semantic edit is that
the eleven `private` members become module-internal, because `private` is
file-scoped in Swift and a member a moved factory still calls would otherwise
stop resolving from its new file.

This script refuses to run unless every member in the original is assigned to
exactly one destination, and unless the reconstructed member set matches the
original member for member. A split that loses or duplicates a factory is worse
than a large file, so the check is the whole point.

Usage:
    python3 Scripts/split_composition_root.py            # dry run, reports plan
    python3 Scripts/split_composition_root.py --write    # perform the split
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "ZynSign" / "App" / "CompositionRoot.swift"
APP_DIR = SOURCE.parent

# Members that stay in the original file: the entry point every other
# composition calls, and the shared state the performance engine reuses.
MAIN = {
    "makeApplicationEnvironment",
    "backupFileURL",
    "sharedEntryTables",
    "sharedScheduler",
}

GROUPS: dict[str, tuple[str, set[str]]] = {
    "paths": (
        "Where ZynSign keeps things on disk",
        {
            "installedApplicationsCatalogLocation",
            "libraryArtifactFileURL",
            "identityAnnotationsCatalogLocation",
            "signingPresetCatalogLocation",
            "signingHistoryJournalLocation",
            "exportCatalogLocation",
            "exportArtifactDirectory",
            "signingWorkspaceRoot",
            "temporaryDirectories",
            "documentsDirectory",
            "provisioningProfileCatalogLocation",
            "importStagingDirectory",
            "preferencesDocumentLocation",
            "diagnosticsLogLocation",
            "diagnosticReportDirectory",
            "signingQueueDirectory",
            "importDropInboxDirectory",
            "libraryRootDirectory",
            "libraryCatalogLocation",
            "libraryArtifactDirectory",
            "downloadCenterRoot",
            "repositorySourceStoreURL",
            "libraryOrganizationLocation",
            "cachesDirectory",
        },
    ),
    "performance": (
        "The performance engine and its benchmarks",
        {"makePerformanceEngine", "makePerformanceBenchmarks"},
    ),
    "library": (
        "The application library and its stores",
        {
            "makeInstalledApplicationStore",
            "makeApplicationLibrary",
            "makeLibraryOrganizer",
            "makeApplicationProvenanceExtraction",
            "makeLibraryExportPreparation",
            "cachingLibraryReaderProvider",
        },
    ),
    "identity": (
        "Signing identities: the Keychain store, the PKCS#12 importer, and the inspector",
        {
            "makeIdentityStore",
            "makePKCS12Importer",
            "makeIdentityAnnotationsStore",
            "makeCertificateInspector",
            "makeProvisioningProfileLibrary",
        },
    ),
    "store": (
        "The Store and the Download Center",
        {"makeRepositoryDirectory", "makeDownloadCenter"},
    ),
    "signing": (
        "The signing pipeline, the queue, the presets, and exports",
        {
            "makeInstallationWorkspace",
            "makeSigningQueue",
            "makeSigningPresetWorkflow",
            "makeSigningQueueStore",
            "makeSigningQueueNotifier",
            "makeSigningPresetStore",
            "makeSigningHistoryStore",
            "makeExportCenter",
            "makeVerifyExportedArtifact",
            "makeSigningOperationCenter",
            "makeStorageManagement",
            "makeCryptographicSigningUseCase",
            "makeMessageDigest",
            "makeCryptographicSignatureVerifier",
            "makeArchiveWriter",
            "makePackageSignedApplication",
            "makeVerifySignedApplication",
            "makeSigningEngine",
            "makeSignApplicationPipeline",
            "makeNestedCodeSigningUseCase",
        },
    ),
    "inspection": (
        "Inspection: archives, bundles, profiles, and the import hub",
        {
            "makeBinaryInspection",
            "makeResourceStudioInspection",
            "makeCodeSignatureCMSVerifier",
            "makeCMSSignatureVerifier",
            "makeProvisioningProfileImporter",
            "makeAppIconExtraction",
            "makeImportHub",
            "makeArchiveInspection",
            "makeBundleMetadataInspection",
            "makePackageImport",
            "makeProvisioningProfileInspection",
            "makeProvisioningProfileCMSVerifier",
            "makeProvisioningProfileVerification",
            "makeProvisioningPolicyValidation",
            "makeProvisioningProfilePipeline",
            "makeBundleProvisioningProfileIntake",
            "makeBundleEntryInspection",
            "makeBundleContentsInspection",
            "makeApplicationDetailsInspection",
            "makeNestedCodeDiscoveryInspection",
        },
    ),
    "diagnostics": (
        "Preferences, diagnostics, and recovery",
        {
            "makePreferencesStore",
            "makeBiometricAuthenticator",
            "makeAnalyticsJournal",
            "makeSigningDiagnosticsHistoryStore",
            "makeSigningDiagnostics",
            "makeRecoveryStore",
        },
    ),
}

DECL = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:(?:public|internal|private|fileprivate|final|static|var|let|func)\s+)*"
    r"(?P<name>[A-Za-z_]\w*)\s*(?:<[^({]*>)?\s*[:(=]"
)


def strip_noise(line: str) -> str:
    code = re.sub(r'"(\\.|[^"\\])*"', '""', line)
    return re.sub(r"//.*", "", code)


def parse_members(lines: list[str]) -> list[tuple[str, int, int, int]]:
    """(name, block_start, decl_line, block_end) for every member of the enum.

    Indentation alone cannot find these boundaries: a top-level function's
    closing brace sits at the same four spaces as the enum's own. So the scan
    tracks brace depth, and a member is any declaration seen while the enum is
    exactly one level deep.
    """
    start = next(
        i
        for i, l in enumerate(lines)
        if l.strip() in ("enum CompositionRoot {", "extension CompositionRoot {")
    )
    members: list[tuple[str, int, int, int]] = []
    block_start = start + 1
    depth = 1
    i = start + 1
    while i < len(lines):
        line = lines[i]
        code = strip_noise(line)
        delta = code.count("{") - code.count("}")

        m = DECL.match(line)
        is_member = (
            m
            and re.match(r"^ {4}(?! )", line)
            and not line.strip().startswith("//")
            and depth == 1
        )
        if is_member:
            # A member is complete only when its braces have balanced *and*
            # no parameter list is still open. A multi-line signature carries
            # neither — `static func makeX(` on one line, the body three lines
            # later — so stopping at balanced braces alone severs it from its
            # body and leaves the compiler reading a fragment.
            braces = 0
            parens = 0
            j = i
            while j < len(lines):
                c = strip_noise(lines[j])
                braces += c.count("{") - c.count("}")
                parens += c.count("(") - c.count(")")
                if braces <= 0 and parens <= 0:
                    break
                j += 1
            members.append((m.group("name"), block_start, i, j))
            depth = 1
            block_start = j + 1
            i = j + 1
            continue

        depth += delta
        if depth == 0:
            break
        i += 1
    return members


def widen(text: str) -> str:
    """Drop `private` from members that move between files.

    `private` is file-scoped in Swift, so a factory that keeps it after moving
    can no longer see a sibling it calls, and the build fails with "cannot find
    X in scope" rather than anything about this refactor. `CompositionRoot` is
    an internal type in an app target, so module-internal is the right level
    for these shared helpers.
    """
    return re.sub(r"^(\s*)private static ", r"\1static ", text, flags=re.MULTILINE)


def render(group: str, title: str, members: list[tuple[str, int, int, int]], lines: list[str]) -> str:
    # Each block spans from the line after the previous member closed, so it
    # carries that gap's blank lines. Joining with a blank line as well leaves
    # two in a row, which SwiftFormat rejects. Strip the edges of every block
    # and let the join supply the single blank line.
    body = "\n\n".join(
        "\n".join(lines[s : e + 1]).strip("\n") for _, s, _, e in members
    )
    return widen(
        "import Foundation\n\n"
        f"/// {title}.\n"
        "///\n"
        "/// Part of `CompositionRoot`, which chooses every concrete\n"
        "/// implementation and wires the layers together. Split out of the\n"
        "/// original single file for readability; the members are unchanged.\n"
        "extension CompositionRoot {\n\n"
        f"{body}\n"
        "}\n"
    )


def verify(paths: dict[str, Path], expected: dict[str, list[str]]) -> list[str]:
    """Re-parse what was written and prove it is well formed.

    Counting members is not enough. A split that severs a multi-line signature
    from its body keeps every line, keeps the brace depth at zero, and still
    does not compile — which is exactly what the first run produced. So each
    written file is parsed again with the same rules, and every member block
    must both be the one that was assigned to it and end on a line whose
    parentheses and braces are closed.
    """
    problems: list[str] = []
    for label, path in paths.items():
        lines = path.read_text(encoding="utf-8").split("\n")
        parsed = parse_members(lines)
        got = [n for n, _, _, _ in parsed]
        if got != expected[label]:
            problems.append(
                f"{path.name}: expected {len(expected[label])} members {expected[label]}, "
                f"found {len(got)} {got}"
            )
            continue
        for name, _, _, end in parsed:
            last = strip_noise(lines[end])
            if last.count("(") != last.count(")") or last.count("{") != last.count("}"):
                problems.append(
                    f"{path.name}: `{name}` ends mid-declaration on "
                    f"{end + 1}: {lines[end].strip()[:60]!r}"
                )
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="write the files")
    args = parser.parse_args()

    lines = SOURCE.read_text(encoding="utf-8").split("\n")
    members = parse_members(lines)
    found = [name for name, _, _, _ in members]

    assignment: dict[str, str] = {n: "main" for n in MAIN}
    for group, (_, names) in GROUPS.items():
        for n in names:
            if n in assignment:
                print(f"✗ {n} is assigned twice", file=sys.stderr)
                return 1
            assignment[n] = group

    missing = [n for n in found if n not in assignment]
    unknown = [n for n in assignment if n not in found]
    if missing:
        print(f"✗ members with no destination: {missing}", file=sys.stderr)
        return 1
    if unknown:
        print(f"✗ destinations with no member: {unknown}", file=sys.stderr)
        return 1

    buckets: dict[str, list] = {k: [] for k in ["main", *GROUPS]}
    for member in members:
        buckets[assignment[member[0]]].append(member)

    print(f"{len(found)} members, all assigned.")
    for name in ["main", *GROUPS]:
        span = [f"{s}-{e}" for _, s, _, e in buckets[name]]
        print(f"  {name:12s} {len(buckets[name]):3d}  {span[0]}..{span[-1]}")

    if not args.write:
        print("\n(dry run — pass --write to perform the split)")
        return 0

    # The header runs to the enum's own opening brace, so no member can be
    # duplicated into it — taking it up to the first *main* member instead
    # would copy every earlier member into the file as well.
    enum_line = next(
        i for i, l in enumerate(lines) if l.strip() == "enum CompositionRoot {"
    )
    header = "\n".join(lines[: enum_line + 1]).rstrip()
    main_body = "\n\n".join(
        "\n".join(lines[s : e + 1]).strip("\n") for _, s, _, e in buckets["main"]
    )
    SOURCE.write_text(
        widen(f"{header}\n\n{main_body}\n}}\n"), encoding="utf-8"
    )
    print(f"\nwrote {SOURCE.relative_to(ROOT)} ({len(lines)} -> {SOURCE.read_text().count(chr(10))} lines)")

    for group, (title, _) in GROUPS.items():
        path = APP_DIR / f"CompositionRoot+{group.capitalize()}.swift"
        path.write_text(render(group, title, buckets[group], lines), encoding="utf-8")
        print(f"wrote {path.relative_to(ROOT)} ({path.read_text().count(chr(10))} lines)")

    written = {"main": SOURCE}
    for group in GROUPS:
        written[group] = APP_DIR / f"CompositionRoot+{group.capitalize()}.swift"
    expected = {
        label: [n for n, _, _, _ in buckets[label]] for label in written
    }
    problems = verify(written, expected)
    if problems:
        print("\n✗ the split is not well formed:", file=sys.stderr)
        for p in problems:
            print(f"  {p}", file=sys.stderr)
        return 1
    print(f"\nverified: {sum(len(v) for v in expected.values())} members, "
          "each ending on a closed declaration")
    return 0


if __name__ == "__main__":
    sys.exit(main())
