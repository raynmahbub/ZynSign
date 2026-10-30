# Regression test report — initial increment

Status: **Partially implemented**. Results are from the Linux checkout, 2026-10-30.

| Command | Result |
|---|---|
| `swift --version` / `xcodebuild -version` | Both commands unavailable; no Xcode scheme discovery, build or XCTest possible. |
| `python3 -m unittest discover -s Tests/Host -p 'test_*.py'` | 159 passed in 11.529 seconds; one unclosed socket ResourceWarning. Host tests do not validate iOS. |
| `bash Scripts/ci/architecture_guard.sh` | Passed, eight rules checked. |
| `python3 Scripts/audit_crash_surface.py` | Passed, nine baselined constructs. |
| `USE_PERIPHERY=0 bash Scripts/ci/dead_code_scan.sh` | Completed, 292 heuristic candidates, no deletion. |
| `git diff --check` | Passed before documentation was written; rerun before review. |

Fifteen archive XCTest regressions, a legacy preference round-trip test, two download transport tests and two device safety-gate tests were added across these increments, but are **Blocked** until an Xcode environment runs the existing project scheme and test target. The latest host suite run (`python3 -W always::ResourceWarning -m unittest discover -s Tests/Host -p 'test_*.py'`) passed 165 tests in 15.115 seconds without the earlier socket warning. It includes two static guards against reintroducing the download keep-alive and four host-simulator cleanup tests. The architecture and crash-surface checks, documentation check, local lint and `git diff --check` also passed. These host checks do not execute the new Swift tests. Simulator, external Apple code-signing validation and physical-device tests were not run. Obtain exact schemes and destinations with `xcodebuild -list -project ZynSign.xcodeproj` and `xcodebuild -showdestinations` on macOS, then use the existing CI build script and targeted tests.

Guest staging and probe regressions have been added for existing-data preservation, invalid metadata and traversal, stored descriptors and not recording a probe as a launch. These XCTest cases are **not run** in this environment; the mock loader does not validate real dynamic loading or isolation.

A controlled stale-download-callback test and Debian malformed, duplicate and failed-extraction regressions were added; all are **not run** without Xcode. The latest host suite passed 165 tests in 13.723 seconds with `ResourceWarning` treated as an error; these tests do not execute Swift.

LAN workspace coverage now pins target parsing (origin and absolute forms, traversal however encoded, ambiguous and over-long names), mandatory authentication for every method, foreign-origin refusal, protection of the workspace root and its category folders, mutation refusal with WebDAV off, refusal to publish a truncated upload, the served-download bound, symlink containment for read/write/delete/listing, ambiguous HTTP framing, and dashboard filename rendering. The connection budget and idle clock are source-only: `NWConnection` cannot be exercised on the host. **Not run:** XCTest / Apple-platform transport and WebDAV client tests. Host suite: 165 tests passed in 12.504 seconds with ResourceWarning treated as an error.

The installation handoff has an additional hostless/embedded-credentials XCTest; it is **not run** without Xcode.

Bounded Debian deflate and gzip regressions were added (size, truncation and trailer corruption); **not run** without Xcode. LZMA/xz compatibility and zlib wrapper validation remain open.

Added XCTest coverage for decrypted Mach-O admission, fragmented and truncated device reads, guest environment restoration, and installation link/manifest handling; **not run** without Xcode. Latest host suite passed 165 tests in 13.112 seconds. No device or Apple-signing verification was run.

The AFC header test now covers byte order, declared lengths and invalid frames; **not run** without Xcode. Host simulator tests do not execute the Swift transport or establish AFC interoperability.

Entitlement merge tests were added for false boolean claims, scoped wildcard groups, rejected isolation, and malformed embedded claims. They have **not run** without Xcode.
