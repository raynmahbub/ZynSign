# Sideloading: installation, containers and package parity

> Scope: the device bridge, the guest container, and the package edits that
> sign-time rewriting needs. Code: `ZynSign/Domain/Sideloading`,
> `ZynSign/Domain/DeviceBridge`, `ZynSign/Domain/Containers`,
> `ZynSign/Application/DeviceBridgeService.swift`,
> `ZynSign/Application/SideloadPackageEditor.swift`,
> `ZynSign/Application/SideloadingCapability.swift`,
> `ZynSign/Presentation/SideloadingView.swift`.
> Executable specification and suite: `Tests/Host/zynsim`,
> `Scripts/sim/run_unified_suite.py`.

This record covers three capabilities that used to be answered with one word.
Feather, ksign and zsign rewrite a package while signing it; SideStore installs
a signed package on a device through `lockdownd`; LiveContainer runs a guest
application inside the host instead of installing it. ZynSign now implements
all three — with the requirements each one actually has, stated per capability
rather than as a single disclaimer.

## 1. Package parity (zsign / Feather / ksign)

The signing engine already produced signatures. What it could not do was change
the package while signing it. `SideloadSigningOptions` adds the edits those
tools expose, and `SideloadPackageEditor` applies them **inside the signing
working copy, after extraction and before the first binary is signed**, because
the CodeDirectory hashes the header the editor rewrites.

| Option | Effect | Where |
| --- | --- | --- |
| `bundleIdentifier`, `displayName`, `name`, `shortVersion`, `version`, `minimumOSVersion` | Info.plist overrides; an app extension's identifier follows a renamed parent | `InfoPlistOverrides` |
| `removesPlugIns`, `removesWatchApps`, `removesAppExtensions` | Nested code is deleted before anything is signed | `SideloadPackageEditor.apply` |
| `removesURLSchemes` | `CFBundleURLTypes`, `LSApplicationQueriesSchemes` removed | `InfoPlistOverrides` |
| `injectedLibraries` | `LC_LOAD_DYLIB` / `LC_LOAD_WEAK_DYLIB` written into header padding | `DylibInjectionPlanner` |
| `injectsIntoNestedCode` | The same commands in every nested thin image | `SideloadPackageEditor` |
| `adHoc` | `CS_ADHOC` in the CodeDirectory, no CMS slot | `AdHocSignaturePolicy` |
| `hardenedRuntime` | `CS_RUNTIME` | `AdHocSignaturePolicy` |
| `entitlementOverrides` | Merged over the profile's dictionary, typed | `EntitlementValue` |

Injection is refused, not half-done: an image with fewer padding bytes than the
commands need, a universal binary, a non-64-bit slice, or an image that already
carries a signature is rejected with the arithmetic (`insufficientHeaderSpace`
reports required vs available).

### The CodeDirectory version fix

`CodeDirectoryVersion.v20400.headerLength` was `52`. Apple's `cs_blobs.h`
defines `0x20400` as ending with `execSegBase`, `execSegLimit` and
`execSegFlags`, which is **88** bytes — and `ReadOnlyMachOParser` already read
88. A signature produced with a 52-byte header declared `0x20400` puts the
identifier where a device reads `codeLimit64`; the writer also refused the
version outright because the header length and the bytes written disagreed.
Both sides now agree: 44 (`0x20001`), 52 (`0x20200`), 88 (`0x20400`), with the
trailing fields written in `cs_blobs.h` order.

## 2. Device bridge (SideStore)

`DeviceBridgeService` speaks the four layers between the app and a device's
installer. Every frame is a codec in `DeviceBridgeProtocols`; the socket lives
behind `DeviceTransport` in the platform layer.

| Layer | Framing | Messages |
| --- | --- | --- |
| usbmuxd | 16-byte little-endian header: `length`, `version`, `message`, `tag` + property list | `Connect`, `ListDevices`, `Result` |
| lockdownd (62078) | 4-byte **big-endian** length + property list | `QueryType`, `GetValue`, `Pair`, `StartSession`, `StartService`, `StopSession` |
| AFC | 40-byte little-endian header: `CFA6LPAA` + entry, operation, transaction, size | `HELLO`, `MAKE_DIR`, `FILE_OPEN`, `FILE_WRITE`, `FILE_CLOSE`, `GET_INFO` |
| installation_proxy | lockdownd framing | `Install`, `Upgrade`, `Uninstall`, `ListApps`, then a progress stream |

Transport security is the pairing record, not a pinned certificate: the host
presents `HostCertificate` + `HostPrivateKey`, and accepts the device only when
its certificate chains to `RootCertificate`. `HostID` is uppercase hex SHA-1 of
the host certificate; `PairingRecordCoding.decode` recomputes it and refuses a
record that disagrees with itself.

Installation is evidence, not a claim. `DeviceInstallOutcome.isInstalled` is
true only when the device's last message is `Complete`; a stream that ends early
is an interrupted attempt, which is what the Installation Workspace already
models.

### What the bridge needs, and why it is not a single "unsupported"

`SideloadingCapability` reports requirements per capability:

| Capability | Requirements |
| --- | --- |
| `devicePairing` | a pairing record · a local-tunnel entitlement · an entitled build |
| `deviceSession` | the above, plus a composed transport |
| `packageInstallation` | the same three, because it is the session that installs |
| `guestContainer` | a bundled `TweakLoader.dylib` · a decrypted guest |
| `libraryInjection` | header padding in the target image |
| `adHocSigning` | always possible; whether a device trusts the result is separate |

The local tunnel is the honest core of this: a sandboxed app has no route to
the device's own `lockdownd`, and a Network Extension (packet tunnel)
entitlement is what provides one. That entitlement is a distribution fact — an
App Store build cannot carry it, and this repository cannot grant it to itself.
A self-signed build whose provisioning profile carries it can compose
`DeviceTransport` and the whole bridge above starts working. This record does
not claim any build currently does.

## 3. Guest container (LiveContainer)

A container runs a guest inside ZynSign's process instead of installing it.
Two transformations make the guest loadable, and both happen before signing so
the CodeDirectory covers them:

1. the Mach-O file type changes from `MH_EXECUTE` to `MH_DYLIB`, because dyld
   will not map an executable inside another process;
2. the loader is added as `LC_LOAD_DYLIB`.

The layout is `Applications/<BundleID>/` with `App.app`, `Tweaks/`, `Data/`
(`Documents`, `Library/Preferences`, `Library/Caches`, `tmp`), `LCAppInfo.plist`
and `LCContainer.json`.

`GuestContainer.assess` blocks a guest for facts, not opinions: FairPlay
encryption, no position independence, a universal binary, a missing declared
executable, app extensions, a watchOS bundle, or no bundled loader. JIT and
Metal are warnings. `GuestContainer.launchPlan` names every runtime step —
`dlopen`, `dlsym("main")`, the container redirect, the main-thread entry, the
bundle swizzles — with the prerequisite each one carries.

## 4. Where each piece lives

| Piece | In the app | In the host reference |
| --- | --- | --- |
| Signing options and validation | `Domain/Sideloading/SideloadSigningOptions.swift` | `zynsim/bundle.py` (`Overrides`) |
| Dylib injection arithmetic | `Domain/Sideloading/DylibInjectionPlan.swift` | `zynsim/macho.py` |
| Package edits inside the working copy | `Application/SideloadPackageEditor.swift` | `zynsim/bundle.py` |
| Capability requirements | `Application/SideloadingCapability.swift` | `Tests/Host/test_device_bridge.py` |
| Wire codecs | `Domain/DeviceBridge/DeviceBridgeProtocols.swift`, `DevicePairingRecord.swift` | `zynsim/protocol.py`, `zynsim/pairing.py` |
| Session and installation orchestration | `Application/DeviceBridgeService.swift` | `zynsim/device.py` |
| Container rules and launch plan | `Domain/Containers/GuestContainer.swift` | `zynsim/container.py` |
| Screen | `Presentation/SideloadingView.swift` | — |

The host reference is where the byte-level work is executed and verified in this
repository; the app holds the same rules behind its own types, and its transport
is the one piece that needs the entitlement described above. Neither claims the
other's evidence: the Swift build is not compiled here, and the reference is not
shipped.

## 5. What is proven, and what is not

`Tests/Host/zynsim` is an independent implementation of the engine, the wire
protocols and a simulated device. It is not a mock: it re-parses the bytes it
is handed, recomputes page hashes, verifies CMS with the host OpenSSL binary,
refuses an unpairing host at the TLS layer, and refuses an ad-hoc signature on
stock policy.

| Fact | Proven by |
| --- | --- |
| CodeDirectory fields, page hashes, superblob layout | `test_sideload_signing.py` against the Swift engine's own public vector |
| CMS signatures verify | `openssl cms -verify` on every signed image |
| Tampering is detected | a flipped byte inside the hashed region is rejected |
| Injection lands in header padding and is covered by the signature | `test_injection_adds_the_load_command_without_moving_content` |
| Profiles, entitlements, wildcard matching | `test_sideload_signing.py` |
| Pairing records, mutual TLS, sessions, AFC upload, installation_proxy | `test_device_bridge.py` against `simulator.SimulatedDevice` |
| Ad-hoc refusal on stock policy, acceptance on a permissive device | `test_device_bridge.py` |
| Container patching, signing, metadata, launch plan | `test_app_container.py` |

Not proven here, and named as open:

1. **Swift build and XCTest.** `swift` and `xcodebuild` are absent from this
   environment. `Tests/ZynSignTests/SideloadingTests.swift` mirrors the
   byte-level expectations above.
2. **A physical device.** The simulator speaks the recorded framing and
   terminates real mutual TLS, but a device's exact AFC header and service
   ports are asserted, not confirmed.
3. **In-process launch.** `dlopen`, the entry-point call and the swizzles need a
   device; the container is prepared and verified, the launch is not performed.
4. **The tunnel entitlement.** See above.

## 6. Security posture

- A pairing record is a bearer credential. It is parsed and validated in
  memory, never logged; `redactedSummary` exposes eight hex characters and no
  key material. The platform store is the Keychain-backed one.
- Injection rewrites bytes before they are signed. An image that is already
  signed is refused unless the run was asked to re-sign, in which case the old
  `LC_CODE_SIGNATURE`, its `_CodeSignature` directory and the embedded profile
  are removed from the working copy first — never overwritten in place.
- A guest's data container is inside the container; nothing in the container
  path reads the host's library or identity material.
- The app installs nothing it did not send, and lists nothing as installed
  without the device reporting `Complete`.
- OpenSSL remains a host-test binary. It is still not linked into the app.
