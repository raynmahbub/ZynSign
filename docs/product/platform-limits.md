# Platform limits — the three things this app does not do, and why

> Honest inventory companion to [`WHAT_DOES_NOT_EXIST.md`](WHAT_DOES_NOT_EXIST.md).
> In-app text lives in `ZynSign/Application/PlatformLimitDetail.swift` and is
> rendered by **Settings → Features → Not supported**. Where this page and the
> source disagree, the source governs and a test fails first
> (`PlatformLimitDetailTests`).

ZynSign carries eighteen release-gated features and, at the current stop,
switches all of them on. Three rows in the capability catalogue are **never**
rows, and this page is the explanation behind each: what the capability would
need, whose decision that need is, and what ships in its place. None of the
three is a bug, a backlog item, or a feature waiting on a sprint — each is
either a platform fact or a product decision recorded in advance.

Nothing on this page is a claim that the alternative *is* the missing
capability. A hand-off is not an installer. A protocol implementation behind a
missing entitlement is not a working device link. A local journal is not
telemetry.

## 1. In-app installation

**What it would need.** A supported way to hand an installation to the system —
an application-facing install API — or the private installation entitlement and
the daemon access that a pairing record grants.

**What would have to change.** Apple would have to publish an install API for
apps the person supplied, or grant this app the entitlement that
mobile-installation clients rely on. On stock iOS the only public path is a
signed package delivered to a device that already trusts the signing team: over
the air, over a cable from Xcode or Apple Configurator, or from a tool that runs
on a host. That is a platform decision, not something an app can decide for it.

**What ships instead.** `ReleaseFeature.deliveryHandoff` signs the package,
writes the over-the-air manifest, encodes the `itms-services:` link, renders the
QR code, and records the delivery. `ReleaseFeature.installationWorkspace` shows
readiness, attempts, and history. `InstallationLimitation.noDeliveryMechanism`
is always present, and no row anywhere in the app offers an install button that
could not work.

## 2. Pairing, JIT, and device mux

**What it would need.** A pairing record for the specific device, the
network-extension local-tunnel entitlement that lets a signed build reach its
own `lockdownd`, and — for JIT — a debug relationship the device will honour.

**What would have to change.** Apple would have to make the local-tunnel
entitlement available to a self-signed build, and the device would have to accept
a JIT request outside a debugger-attached session. Device muxing needs
`usbmuxd`'s UNIX-domain socket, which a sandboxed app cannot reach at all.

**What ships instead.** The bridge in `ZynSign/Application/DeviceBridgeService.swift`
speaks the published wire format — usbmux framing, `lockdownd`, AFC, and
`installation_proxy` — over its own transport, so what is missing is one
entitlement rather than a missing capability. `PairingCapabilityAssessment`
reports it, and `CoreFeature.sideloading`'s delivery report is where a person
reads it, with the anchor into
[the feasibility record](../architecture/pairing-jit-mux-feasibility.md).
JIT is never requested: no `get-task-allow`, no debugger relationship, no
executable memory. OpenSSL stays host-side, in `Tests/Host` only.

## 3. Cloud sync and telemetry

**What it would need.** An endpoint to send to, and a policy that says sending
is acceptable.

**What would have to change.** Nothing on Apple's side. This is the app's own
decision and it is permanent rather than a flag: `AnalyticsPolicy.isEnabled` is
`false`, `AnalyticsPolicy.endpoint` is `nil`, and the sent-event count is zero on
every path. Turning measurement on would be a different product with its own
disclosure, not a setting someone flips.

**What ships instead.** Encrypted backups the person exports themselves
(`CoreFeature.encryptedBackups`), a journal that stays on the device
(`ReleaseFeature.activityJournal`), and the on-device privacy statement
(`CoreFeature.onDevicePrivacy`). Moving your own data between your own devices is
your file transfer, not a service of ours.

## What the app does about it

- The catalogue row states the limit in its summary, and expands into the
  four-part explanation above — requirement, whose decision, what ships instead,
  and which live surfaces carry the alternative.
- Every alternative named in the source is checked by a test to be a surface
  that is actually on at the current release stop, so the explanation cannot
  point at something that does not ship.
- The typed limitations (`InstallationLimitation`, `PairingCapabilityAssessment`,
  `AnalyticsPolicy.Guarantee`) are quoted into that explanation rather than
  re-worded, so diagnostics and the catalogue cannot drift apart.
