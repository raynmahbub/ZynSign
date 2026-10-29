# Local Transfer

A short-lived, token-gated way to put a file on this device from another
machine on the same network. It exists because the alternative — a cable, a
cloud drive, or an always-on file server — is either unavailable on iOS or a
much larger surface than the job needs.

This record states what the feature actually does, what it refuses, and which
parts are proven by source and host checks rather than by a device.

## What it is

| Layer | Type | Responsibility |
|---|---|---|
| Domain | `LocalTransferHTTP` | The HTTP/1.1 subset as a pure codec: parse a bounded head into a typed request, refuse a malformed one by name, serialize one response. No socket, no file, no clock. |
| Domain | `LocalTransferSession`, `LocalTransferLimits`, `LocalTransferToken`, `LocalTransferReceipt`, `LocalTransferFileName`, `LocalTransferRejection` | The session value, its bounds, its credential, the names it accepts, and the whole vocabulary of refusals — each carrying the HTTP status it is answered with. |
| Application | `LocalTransferService` (actor) | Owns the session: opens it with a drawn token, hands requests to the transport, authenticates, validates the destination name, moves accepted bytes into the transfer workspace, records receipts, enforces the request budget and the session window. |
| Application | `LocalTransferTransport` (port) | The socket seam. The platform composes it; the service never learns what kind of transport it has. |
| Platform | `NetworkLocalTransferServer` | `NWListener` on one port, one bounded read loop per connection, a temporary file for a declared body, one response, then close. |
| Platform | `SystemSecureRandomSource` | `SecRandomCopyBytes` behind `SecureRandomSource`; a failure is thrown, never replaced with weaker entropy. |
| Presentation | `LocalTransferModel`, `LocalTransferView` | Start, stop, address, token, upload command, received files, and the boundaries stated on the same screen. |

## The surface

Three routes, all under the session token:

| Request | Answer |
|---|---|
| `GET /<token>/` | The session page: the exact `curl` command, the accepted extensions, the files received so far, and the statement that a received file is not an import. |
| `HEAD /<token>/` | The same page without a body. |
| `PUT`/`POST /<token>/upload/<name>` | Raw bytes, one request body, `Content-Length` required. `201` with a small JSON acknowledgement when stored. |

The token is accepted in the path (so one URL can be pasted) or as
`Authorization: Bearer <token>` (so a script can keep it out of a URL). The
comparison is constant-time over the token bytes.

There is no upload form and no multipart parser. A form would promise a second
grammar with its own failure modes, and the transfer does not need it.

## What it refuses, and why

| Refusal | Status | Reason |
|---|---|---|
| Unknown method | `405` | The method is not echoed back; the vocabulary is fixed and this surface answers three of them. |
| Malformed request line, folded header, header with no colon | `400` | Obsolete line folding is a request-smuggling primitive, and this code does not unfold it. |
| `Content-Length` sent twice | `400` | Two lengths is no length. |
| `Transfer-Encoding` | `411` | Chunked framing is not implemented; accepting the header without decoding it would misread the body. |
| A write with no `Content-Length` | `411` | An upload that cannot be bounded is not accepted. |
| Head beyond `maximumHeadBytes` | `431` | The listener never buffers more than the session allows. |
| Body beyond `maximumUploadBytes` | `413` | Checked from the declared length *and* again from the bytes that arrived, so a transport bug cannot store an oversized file. |
| Bytes behind a declared body | `400` | Pipelined bytes are refused rather than read as a second request. |
| A stalled connection | `408` | Every connection has a deadline. |
| A name that is not a package or signing material | `415` | No separators, no traversal, no control characters, no leading dot, no reserved device name, 255-byte cap, and an extension the app routes (`ipa`, `tipa`, `p12`, `pfx`, `mobileprovision`, `provisionprofile`). |
| A request without the token | `401` | Checked before anything else is decided. |
| A request after the session closed, or in its closing minute | `503` | An expired session stops the listener and refuses what is already in flight. |
| More than `maximumRequests` in one session | `429` | A budget, so a hostile client cannot keep the listener busy indefinitely. |

A refused upload's temporary file never reaches the workspace, and the
transport removes it when the connection closes.

## Lifecycle

The session is foreground-only, stated in the interface: the listener stops
when the screen closes, when the user stops it, or when its thirty-minute
window ends. iOS does not keep this kind of listener running reliably once the
app is suspended, so nothing here claims to.

The workspace is `Library/Application Support/ZynSignLibrary/LocalTransfer`,
beside the other ZynSign workspaces — visible to Files, counted by the storage
gauge, and not in a temporary directory the system may reclaim. Files that
arrive are kept when a session stops; starting a session again re-reads the
workspace so what an earlier session received is still listed.

An accepted upload is *bytes*, not an import. Nothing in this feature reads,
inspects, signs, or installs what it receives; the Import Hub does that, and
says what it found.

## What it is not

- **Not WebDAV.** No listing, no browsing, no rename, no remote delete.
- **Not a background service.** See lifecycle.
- **Not an installer.** Receiving a package does not install it, and nothing
  here records an installation.
- **Not a general file drop.** Only the extensions ZynSign actually routes are
  accepted; anything else is refused by name rather than stored and forgotten.

## Verification

Source and host checks in this checkout:

- `Scripts/ci/architecture_guard.sh` — layer boundaries (Domain stays pure;
  Presentation does not reach into the platform listener).
- `Scripts/ci/local_lint.py` — force-unwrap, whitespace and balance rules.
- `Scripts/audit_accessibility.py`, `Scripts/audit_crash_surface.py`,
  `Scripts/audit_design_tokens.py`, `Scripts/audit_navigation_stack.py` — no
  findings in the new files.
- `Tests/ZynSignTests/LocalTransferTests.swift` — head parsing, refusal
  vocabulary, name policy, percent decoding, token comparison, session expiry,
  upload storage, collision naming, authentication by path and by header,
  request budget, status page, discard, restart re-read, and the command the
  screen prints.

Not verified here: the Swift build, XCTest execution, and anything on a
device. `swift` and `xcodebuild` are unavailable in this environment, and a
listener's real behaviour on a joined network — address reporting, Wi-Fi
policy, what another machine's browser does with the page — needs the private
device pass described in
[../releases/private-testing.md](../releases/private-testing.md). Until then,
treat local transfer as source-complete and device-unverified.
