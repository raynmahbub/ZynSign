# LAN Web Workspace

A foreground listener that puts a browser dashboard and a mountable WebDAV
drive on the local network, so a `.ipa`, a tweak, or a `.p12` can be moved to
the device without a cable or a cloud drive.

It is the larger sibling of [Local Transfer](local-transfer.md), and it is the
one surface in the app that speaks an open protocol to whoever is on the
network. This record states what it answers, what it refuses, and — because a
local claim is not a device claim — which parts are proven by source and host
checks rather than by a real client.

## The surface

| Layer | Type | Responsibility |
|---|---|---|
| Domain | `WebDAVProtocol` | The HTTP/1.1 codec: a bounded request head in, one response out. Plus the constant-time Basic evaluator, the cross-origin test, the `207 Multi-Status` renderer, and the dashboard HTML. No socket, no file. |
| Domain | `WebDAVPathPolicy`, `WebDAVRequestRejection` | The one place a target becomes a location: parse, decode once, bound, resolve, and refuse by name with the status each refusal carries. |
| Application | `LANWebWorkspaceService` (MainActor) | Owns the session: credential precondition, request dispatch, mutation rules, workspace listing, and the items the screen shows. |
| Application | `LANWebWorkspaceTransport` (port) | The socket seam. |
| Platform | `NetworkLANWebWorkspaceServer` | `NWListener`, a bounded head reader, a body streamed to a temporary file, an idle clock, and a connection budget. |
| Presentation | `LANWebWorkspaceView` | Start/stop, the address, the credential, the received files, and the boundaries on the same screen. |

The four category folders — `Packages`, `Tweaks`, `Materials`, `Files` — are
created beside the other ZynSign workspaces, so they are visible to Files and
counted by the storage gauge.

## Authentication is a precondition, not an option

The listener binds the local network and speaks plaintext HTTP, so it does not
start without a credential: a username with no colon, and a password of at least
`LANWebWorkspaceService.minimumCredentialLength` characters. The screen fills in
a random one the first time it opens. There is no anonymous mode to forget to
turn off.

Every request is authenticated before anything else is decided, including
whether the method or the target exists. An unauthenticated request therefore
learns nothing about the workspace — not even which paths are real. The
comparison is constant-time over the decoded credential bytes.

The credential is verified with HTTP Basic, which on this link is **readable by
anything on the network path**. That is a property of the feature, not a bug to
be papered over: the screen says so, and the fix (TLS) is listed below as work
that has not been done.

### Cross-origin requests are refused

A browser attaches its cached Basic credential to a request another page
caused. `WebDAVProtocol.hasForeignOrigin` compares the browser-set `Origin`
authority and `Sec-Fetch-Site` against `Host`; a mismatch is answered `403`
before the method is considered, so a page on another origin cannot use the
workspace to upload or delete. A non-browser client sends neither header and is
not judged by them.

## What a target may name

`WebDAVPathPolicy.components(fromTarget:)` accepts origin-form
(`/Packages/App.ipa`) and absolute-form
(`http://192.168.1.4:8088/Packages/App.ipa`, which is what a WebDAV
`Destination` header carries). The authority is dropped rather than trusted, so
a client cannot name another host and have it honoured.

| Refusal | Status | Rule |
|---|---|---|
| Not a path | `400` | A relative target, or a scheme that is not `http(s)`. |
| Undecodable | `400` | Percent-encoding that does not decode to text. |
| Empty segment | `400` | Two targets must never name one location. |
| Traversal | `400` | `.` or `..`, however encoded — the check runs after decoding once. |
| Reserved character | `400` | Control characters, `\`, `:`, `<`, `>`, `\|`, `"`, `*`, `?`, and the device names a filesystem reinterprets (`CON`, `NUL`, `COM1`…). |
| Hidden name | `403` | A segment starting with a dot. |
| Trailing dot or space | `400` | Some filesystems normalise it away, so the name would not round-trip. |
| Segment too long | `400` | Past 255 bytes. |
| Too many segments | `400` | Past 16. |
| Path too long | `414` | Past 1,024 bytes. |
| Outside the workspace | `403` | The resolved location is not under the symlink-resolved root. |

Two checks stand behind the parse. Each existing component is tested for being a
symbolic link, and the fully resolved location must be contained by the
symlink-resolved root with a separator on the root side, so a sibling whose name
merely begins with the root's name is not mistaken for a child. Neither check
closes the window between testing and opening — that needs descriptor-relative
file access, which is not implemented — so this is narrowing, not isolation, and
is presented as such.

## Methods, and what they may not touch

`OPTIONS`, `GET`, `HEAD`, and `PROPFIND` read. `PUT`, `DELETE`, `MKCOL`, `MOVE`,
and `COPY` mutate. `DELETE`, `MKCOL`, `MOVE`, and `COPY` belong to the drive and
are answered `405` when WebDAV is off; `PUT` keeps answering, because uploading
through the browser page is exactly what the listener is for in that mode.
Availability is decided before policy, so a drive method with the drive off is
`405` whatever it names, and only a method the listener offers is judged by its
target (`403` for the root or a category folder). The dashboard
hides its delete control when the drive is off, so the page never offers what the
server would refuse.

No request replaces, moves, or deletes the workspace root or one of the four
category folders: the shell and the dashboard address those names, and a client
that removed one would leave a workspace the app no longer recognises. Files and
folders inside them are the client's.

Three further bounds hold on the body and the response:

| Bound | Answer | Why |
|---|---|---|
| `Content-Length` over the session bound | `413` | The transport refuses before writing a byte. |
| Fewer body bytes than declared | `400` | A truncated upload is refused rather than published as a shorter file. |
| A file larger than `maximumDownloadBytes` (512 MiB) | `413` | A `GET` is carried in one `Data`; unbounded would be a memory request from the network. |
| A connection idle for 30 s | closed | One stalled client must not hold the listener. |
| More than 8 connections at once | `503` + `Retry-After` | The listener keeps serving the others. |
| `PROPFIND` depth `infinity` | answered as `1` | The depth is bounded, not refused. |
| `MOVE`/`COPY` onto an existing location | `412` | Until transactional replacement exists, refusal is the only safe answer. |

## What this record does not claim

- **Not TLS.** The link is plaintext HTTP and Basic credentials travel in it.
  A TLS listener with a self-signed certificate and per-session verification is
  the outstanding work.
- **Not race-free.** The symlink and containment checks narrow a
  time-of-check/time-of-use window; descriptor-relative (`openat`) access does
  not exist here yet.
- **Not transactional.** Overwrite is refused, not done atomically.
- **Not validated against a real client.** Finder, Windows Explorer, iOS Files,
  and `cadaver` have not been run against this tree in this environment. The
  framing, the `207` body, and the `Destination` handling are covered by
  `Tests/ZynSignTests/ZynWorkspaceAndWebDAVTests.swift`; that is source
  evidence, not interoperability evidence.
- **Not an installer.** A received file is bytes. Nothing here reads, signs, or
  installs it; the Import Hub does that, and says what it found.

## Evidence

| Claim | Evidence |
|---|---|
| Target parsing, refusals, and their statuses | `ZynWorkspaceAndWebDAVTests` — origin and absolute forms, traversal however encoded, ambiguous names, length bounds |
| Authentication is required for every method | same suite, one case per method, with the file checked to still exist |
| Foreign origins are refused | same suite, `Origin` mismatch and `Sec-Fetch-Site: cross-site` |
| Root and category folders are protected | same suite, delete/move/copy/put |
| Symlinks cannot carry a request out | same suite, read, write, delete, and listing |
| Truncated uploads are not published; oversized downloads are refused | same suite |
| Connection budget and idle clock | source only — `NWConnection` is not exercisable on the host |

The device and real-client pass remains in
[private testing](../releases/private-testing.md), and the outstanding work is
tracked in [technical debt](../engineering/technical-debt.md).
