# Pairing / JIT / Mux / OpenSSL Linkage — Feasibility Record

> **Status: Rejected — never composed** · Scope: `0.1.0-dev → 0.2.0 Horizon` ·
> Code boundary: `ZynSign/Application/PairingCapability.swift` ·
> Product statement: [`docs/product/WHAT_DOES_NOT_EXIST.md`](../product/WHAT_DOES_NOT_EXIST.md)

This record is the architecture-decision companion to
`PairingCapabilityAssessment`: for each capability it states what the
capability is, what private surface it would need, why that surface is out
of reach for a sandboxed iOS app, what ZynSign does instead, and what would
have to change for the decision to be reopened. The assessment code and
this record must agree; where they disagree, a test fails first
(`PairingCapabilityTests`), and this record governs.

## Decision

ZynSign does **not** implement, compose, link, or partially ship pairing,
JIT execution brokering, the usbmuxd multiplexer, or an OpenSSL linkage in
the application binary. Every `PairingCapabilityAssessment.assess(_:)`
call returns `supported == false` with a typed, ordered limitation list.
This is a platform fact first and a product decision second: the surfaces
below are private, entitled, or host-bound, and no public API reaches them
from a sandboxed app — sideloaded or App Store alike.

The consequence is stated plainly in the product: ZynSign signs inside the
sandbox with no desktop helper, and delivery of a signed package is an
operator hand-off (`InstallationDeliveryService`), not a pairing session.

## Pairing

**What it is.** Establishing a trusted lock/control relationship with an
iOS device — what iTunes/Finder, Xcode, and tools built on libimobiledevice
do: a pairing record negotiated with the device over USB (or Wi-Fi), stored
by the host, and used to talk to locked-down services.

**Private surface required.**

- The **MobileDevice framework** (Apple's private USB/USB-C device stack)
  or an equivalent reimplementation of its protocol.
- The **`usbmuxd`** daemon's UNIX-domain socket, reachable only from
  unsandboxed host processes.
- **Lockdown-class entitlements** (`com.apple.mobile.lockdown` family) that
  Apple grants to its own binaries — not to App Store apps, and not to
  sideloaded sandboxed apps either.

**Why it is out of reach.** A sideloaded app holds no mobile-provisionable
entitlement for lockdown; the socket is outside the container; and shipping
a private-framework shim would violate the App Review rules ZynSign is
designed to respect. There is no configuration of a stock iOS device in
which ZynSign the app can become a pairing host.

**Instead.** ZynSign never pairs. Signed output leaves through the delivery
hand-off (OTA / MDM / host tooling), and the host tool — not ZynSign — does
any installing.

**Reopen triggers.** Apple publishing a public pairing/lockdown API
entitled for third-party apps, or a credible managed-app configuration
channel. Neither exists today.

## JIT

**What it is.** On-demand just-in-time compilation inside a running
process — the reason emulators, some language runtimes, and debugging
tools need executable-memory and task-control powers.

**Private surface required.**

- **`get-task-allow`** in the target's entitlements — a development-only
  entitlement the distribution tooling strips from every releasable build.
- A **debugger relationship**: `debugserver`, `PT_TRACE_ME`, task ports —
  granted only to a **paired development host** with **Developer Mode**
  enabled on the device.

**Why it is out of reach.** A JIT broker inside ZynSign would need to
attach to another process — itself or a peer — without a paired debugger,
which the kernel refuses. Debugserver exists on-device but is only
launchable in the Developer-Mode/paired-host configuration. No public API
grants task-control of another app to a sandboxed app.

**Instead.** ZynSign makes no JIT claim anywhere in the product. Nothing
about the signing pipeline depends on, requests, or enables JIT.

**Reopen triggers.** A public, entitled execution-broker API for
third-party apps. A sandbox escape, a kernel exploit, or a jailbreak is
explicitly **not** an acceptable trigger: ZynSign implements no security
circumvention.

## Mux

**What it is.** The USB multiplexing layer — `usbmuxd` — that lets one
host cable carry concurrent sessions to device services (lockdown,
notification proxy, syslog, and so on).

**Private surface required.** The daemon's UNIX-domain socket plus its
binary protocol; on iOS, apps are sandboxed away from it entirely, and the
usual workarounds are host-side tools outside this product.

**Why it is out of reach.** Same socket, same sandbox wall, same private
protocol as Pairing — with the added problem that any in-app reimplementation
would need raw USB access apps do not have.

**Instead.** `PairingCapability.assess(.mux)` reports
`[.requiresLockdownDaemon, .requiresHostTool, .notComposed]`. The
`Tests/Host` external-validation scripts exercise ZynSign's output from the
host side — which is exactly where multiplexing belongs.

**Reopen triggers.** As for Pairing.

## OpenSSL Linkage

**What it is.** Linking the OpenSSL library into the app binary for CMS,
TLS, or certificate work.

**Decision.** OpenSSL is used **only** in `Tests/Host` external validation
(`openssl cms -verify` judging ZynSign's signatures from the host). It is
never linked into the application binary.

**Why.** Apple's `Security`/`CryptoKit` frameworks cover everything the
sandboxed pipeline needs; every linked third-party crypto library grows the
audit surface, the binary size, and the supply-chain review burden, in
exchange for zero in-sandbox capability. Keeping the binary to Apple
frameworks only is what makes "dependencies: Apple frameworks + Swift
stdlib" a checkable claim in CI and in the README.

**Reopen triggers.** A concrete signing/verification requirement the Apple
frameworks demonstrably cannot meet, with an ADR showing the audit plan for
the linked build.

## The Boundary in Code

- `ZynSign/Application/PairingCapability.swift` — the typed capability,
  limitation, and assessment types; `allUnavailable` is the only list the
  presentation layer renders.
- `ZynSign/Presentation/SettingsView.swift` — Settings → Pairing / JIT /
  Mux renders `Never` with per-capability limitations, feasibility notes,
  and this record's anchors.
- `Tests/ZynSignTests/PairingCapabilityTests.swift` — pins every
  `supported == false`, every limitation set, and the note/anchor text.

Extending any of these capabilities requires, per `CONTRIBUTING.md`: an ADR
with feasibility evidence, a new `Application` port, a `Platform`
implementation that does not weaken the sandbox, tests, and honest product
copy — in that order of proof.
