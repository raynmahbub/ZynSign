# Security cleanup — initial increment

Status: **Partially implemented**, with XCTest validation **Blocked** on this host.

## Changes under review

- `ZipCentralDirectoryScanner.scan` intentionally returns at most one record beyond the entry limit, allowing inspection to report the over-limit condition. `ZipEntryStreamExtractor` previously passed that partial table to `uniqueRecord`, so a later duplicate could be missed. It now refuses over-limit results before looking up or creating an output file. `testEntryLimitRejectsPartialTableBeforeDuplicateCheck` covers a duplicate after the scan cutoff and checks no output exists; it has not been executed here.
- ZIP64 record-offset and directory-range validation used addition on attacker-controlled values that can overflow `Int` before rejection. Bounds now use subtraction after validating the offset. `testZip64LocatorWithUnaddressableRecordDoesNotOverflow` covers an extreme locator; not executed here.

## Follow-up: central directory consistency

The scanner now requires a unique end-record candidate whose declared comment reaches EOF, checks that the directory does not overlap that record, and checks the declared entry count and directory size after a complete scan. An over-limit scan still returns the established one-extra-record sentinel, which extraction refuses. Six synthetic XCTest cases cover comment signatures and length, ambiguous end records, count mismatch, partial records and overlap. These tests are **Blocked** until run on Xcode.

This is intentionally fail-closed: archives with ambiguous end-record signatures, trailing data after the ZIP comment, or central-directory structures other than the supported entry records may be refused. Compatibility against real IPA and ZIP64 corpora remains unverified.

## Follow-up: local header consistency

`ZipArchiveReader` and `ZipEntryStreamExtractor` now share a local-header validator. Before content is read, it compares the signature, flags, compression method, and exact UTF-8 name against the selected central record; when the data-descriptor flag is absent it also compares the CRC and non-placeholder 32-bit sizes. Reader bounds use overflow-safe subtraction. Four XCTest cases cover mismatch refusal in both consumers and data-descriptor fixtures; they are **Blocked** until run on Xcode. Prefix inspection still does not establish a whole-entry CRC. The descriptor itself and local ZIP64 extra fields are not independently validated by this change, and ZIP64 placeholders rely on central metadata and subsequent content checks. Compatibility with real archives remains unverified.

## Follow-up: ZIP64 structure relationships

The scanner now rejects multi-disk ordinary and ZIP64 metadata, invalid ZIP64 end-record sizes, a ZIP64 end record overlapping its locator, and a central directory overlapping the ZIP64 end record. ZIP64 extensible data remains accepted within the declared record bounds. Synthetic XCTest cases cover a ZIP64 archive with extensible data and malformed disk, count, size and overlap fields. These cases have **not** been executed in Xcode.

## Follow-up: compression ratio boundary

`ArchiveLimits.exceedsCompressionRatio` previously compared only the integer quotient, accepting a fraction above the configured maximum. It now also checks the remainder, avoiding multiplication overflow. An exact-boundary XCTest was added but is **Blocked** until Xcode validation.

## Follow-up: download transport

`URLSessionDownloadTransfer` now reuses the existing HTTPS redirect policy, validates the initial request at the transport boundary, and refuses to report a finished download unless its response has an accepted HTTPS URL and successful HTTP status. Two XCTest cases cover initial HTTP refusal and redirect decisions, but have **not** been run in Xcode. This does not establish real-network or device behavior. Resume blobs remain opaque URLSession data; a response check is not proof that an unsafe request was never attempted before completion.

## Follow-up: host simulator resource handling

The Python host-only simulated device bridge now closes sockets when setup or lockdown interrogation fails, and uses a scoped temporary directory for TLS identity files instead of leaving private-key files in a persistent temporary directory. Four host tests cover socket cleanup and identity-file removal on both successful and failed context creation. These are test-harness changes, not proof of iOS device-transport security or interoperability.

## Follow-up: device transport safety gate

`DeviceTransport` requires pairing-identity TLS, but the composed `NetworkDeviceBridgeTransport` opens a plain TCP tunnel and does not authenticate the peer. `DeviceBridgeService` also assumes some partial network receives are complete frames. The production adapter now fails closed before networking, the controller rejects direct connection and installation before file reads when unavailable, and the UI reports the limitation. Pairing-record import and the experimental protocol code remain. Two XCTest cases were added but are **Blocked** until Xcode runs them; this is not a TLS implementation or a device interoperability claim.

## Remaining risks

- A correctly bounded declared directory does not prove there are no unreferenced structures or differing interpretations in the rest of the file. ZIP64 local extra fields, descriptors, disagreements between legacy and ZIP64 metadata, and duplicate detection across parser interpretations require further format analysis and adversarial tests; do not treat this change as a complete archive-security audit.
- Full extraction, symlink and race resistance, archive totals, credential handling, redaction, TLS/pairing, and all download integrity paths need independent review. These are **Planned**, not verified by the present patch.
- External signing tools and physical devices remain necessary to establish real signing and installation behavior. A passing mock or host test cannot establish this.

## Guest staging and executable probes — Experimental

Staging now rejects unsafe bundle identifiers and executable components, refuses to replace an existing guest, and prepares a temporary container before moving it to the destination. Stored descriptor identifiers and slot components are validated during discovery. Removal requires a known guest and valid identifier. These are narrow safeguards, not a guarantee against symlink races or hostile changes to the filesystem. Staging now prepares a hidden sibling of the final container before publication, and the hub asks for confirmation before guest or profile deletion. Cleanup, same-volume moves and these UI changes need Apple-platform tests; descriptor-relative filesystem operations remain to be reviewed.

A probe uses in-process dynamic loading and may run code; separate directories and environment variables do not provide a security boundary. A successful probe does not establish app execution, compatibility, isolation, or a three-app-budget exemption. Preparation failures now stop the probe and are surfaced; a probe no longer updates the last-launch timestamp. The hub no longer infers account type from the presence of an identity or app limits from local history. The legacy strategy advisor remains unverified and is not shown in the hub. Guest XCTest additions have not been run without Xcode.

## Follow-up: transfer attempts and Debian archives

Download delegate events and pause callbacks now require the currently registered task, and starting a replacement cancels and invalidates the previous task. Cancellation settles the current attempt without allowing a later pause callback to override it. A controlled stale-task XCTest was added but is **Blocked** until run with Xcode. This does not establish behavior for every URLSession callback ordering, paused resume data, redirects or real networking.

Debian parsing rejects duplicate data/control members, trailing truncated ar data, malformed or truncated TAR records, incorrect TAR checksums, unsafe regular-file paths and flattened payload path collisions. Unimplemented global PAX and sparse records are refused. File-manager extraction stages beside its destination and cleans temporary output on failure; file-manager and tweak import reads cap compressed `.deb` input at 128 MiB. New tests are **Blocked** until run with Xcode. These changes can reject archives previously tolerated; interoperability needs corpus testing.

**Follow-up, unverified:** the former whole-result `NSData.decompressed` path has been replaced by an output-bounded Compression stream; gzip trailer CRC and length are checked. Tests for limits, truncated deflate and gzip corruption are added but **not run**. Input and expanded TAR are still held in memory up to their bounds. Zlib wrapper checksums, xz/lzma compatibility, PAX and GNU extensions, filesystem races, real filesystem normalization and cleanup failures remain open. Do not treat compressed untrusted `.deb` handling as validated until Apple-platform tests and corpus review pass.

## LAN workspace safety follow-up — partially implemented

The LAN WebDAV server had destructive failure paths: MOVE/COPY deleted the destination before checking whether the operation could succeed, and PUT removed existing files before the new body was committed. It now refuses existing destinations rather than overwriting, rejects root PUT/MOVE/COPY, reports deletion failures, and refuses existing symbolic-link path components. Basic authentication is on by default and an empty password no longer turns a requested authentication check into access. Duplicate HTTP headers and PUT without Content-Length are refused; failed temporary-file writes do not dispatch partial uploads. The dashboard no longer inserts a filename into an inline JavaScript string, and the UI shows the actual root mount URL.

A second pass replaced the ad-hoc path handling with `WebDAVPathPolicy` and made
the remaining findings structural rather than incidental: authentication is a
precondition of listening (no anonymous mode, minimum credential length, checked
before the method or target is considered), the target is parsed once and
decoded once with the complete refusal vocabulary and status for each, the
drive's own methods (`DELETE`, `MKCOL`, `MOVE`, `COPY`) are refused when WebDAV
is off while the browser page's upload keeps working, the workspace root and its
four category folders cannot be replaced, moved or deleted, requests carrying a
foreign `Origin` or `Sec-Fetch-Site` are refused, a truncated upload is never
published, downloads past the served bound are refused instead of being read
into memory, `PROPFIND` depth is bounded, and connections have an idle clock and
a budget. What remains open is stated rather than implied: TLS, descriptor-
relative file access, transactional overwrite, and validation against a real
WebDAV client. See [the LAN Web Workspace record](../architecture/lan-web-workspace.md).

These are **not** a complete WebDAV or security implementation. The server uses plaintext HTTP, including Basic credentials and uploaded content; authentication is optional, so it must not be exposed to an untrusted network or used to transfer signing credentials. Symlink checks are not descriptor-relative and remain raceable; there are no verified connection deadlines, CSRF defenses, bounded response streaming, or transactional replacements. Configuration is frozen at startup. New XCTest cases have not been run and actual transport behavior and Finder/Files interoperability have not been verified on Apple platforms.

## Installation handoff address validation

The manifest handoff now applies the shared HTTPS URL policy as well as checking the scheme, refusing hostless URLs and embedded username/password material rather than placing them in a shareable manifest. An XCTest was added but is **not run** here. Passing this policy does not prove a server is reachable, trusted, or capable of serving an install, nor that iOS accepted the artifact.

## Core workflow follow-up — unverified

- Signing now decodes encryption-info load commands and admits a well-formed, in-bounds record only when `cryptid` is zero. Encrypted, malformed, duplicate and out-of-bounds records remain refused. This is only an admission improvement; it does not fix the historical resource-seal, DER, existing-signature replacement or device-acceptance findings. XCTest added, **not run**.
- Plist and AFC reads now assemble bounded fragments and reject truncated or oversized responses. Package names and bundle identifiers are validated before device upload. The subsequent AFC codec revision uses total/this lengths and packet numbers but has not established interoperability. Neither change implements TLS, verifies device identity or validates the complete protocol; production transport remains blocked. New XCTest added, **not run**.
- Guest probes now serialize their own environment changes, restore prior values after probing and surface setting errors. This does not isolate guest code, prevent other threads from seeing environment changes, or establish a functional guest launch. XCTest added, **not run**.
- Installation handoff creates distinct manifest files and uses the `itms-services://?` form. It still neither hosts nor installs anything. Tests added, **not run**.

## AFC framing revision — Experimental

The Swift header now models total length, current-message length, transaction and operation; lengths are bounded before reading. The upload path checks transaction IDs and response kinds, uses an explicit file-open mode, writes in chunks and checks mkdir/write/close status. No source code was incorporated from another project. Format details were cross-checked against the public [libimobiledevice AFC protocol definitions](https://github.com/libimobiledevice/libimobiledevice/blob/master/src/afc.h) and its API. The Python host simulator is not a direct test of this Swift implementation and uses a different opcode subset. The new Swift codec tests are **not run**; TLS, connection lifecycle, true AFC interoperability and device validation remain open, and the production safety gate stays closed.

## Lockdown / usbmux follow-up — Experimental

Swift usbmux requests now encode port byte order in the request codec, consistently bound payloads, and reject port zero. Lockdown result-less replies require a matching request name, and `GetValue` for all values omits empty selectors. Service operations now request a session first and reject an unsupported in-place TLS upgrade rather than proceed. Lockdown transports close before the call returns, including errors. XCTest added but **not run**. Service TLS, session shutdown semantics, pairing, identity validation, cancellation and real device behavior remain unresolved; the production transport is blocked. Protocol behavior was cross-checked against [libimobiledevice's lockdown implementation](https://github.com/libimobiledevice/libimobiledevice/blob/master/src/lockdown.c); no source code was copied.

## Signing entitlement merge follow-up — Partially implemented

Informed by the feature-level entitlement workflows in Feather and related projects, ZynSign's existing merge path now preserves value types, refuses to merge a true boolean against false, scopes wildcard matching to the actual pattern, and checks profile keychain-group authorization before isolation. A malformed embedded entitlement plist and failed merge now stop the inline signing request rather than silently falling back to profile claims. Explicit user overrides remain subject to the pipeline's separate profile validation; a raw XML override takes precedence over merge/isolation. No competitor code was copied. XCTest coverage is added but **not run**; the inline path and downstream signing behavior still require Xcode and independent Apple-tool validation. The queue now uses the same entitlement preparation as inline signing, but this has not been tested on Apple platforms.

## Queued signing options — Partially implemented

Inline and queued signing now share preparation of merge, isolation, removal and override options. Both refuse a requested binary merge when the current extractor returns no entitlements, rather than silently ignoring it. The extractor currently cannot distinguish an unsigned binary from an unreadable or unsupported one, so this is intentionally conservative. A queued run now refuses an unreadable profile instead of substituting an empty entitlement set. Final profile authentication and authorization remain separate pipeline responsibilities. New XCTest coverage is **not run**.
