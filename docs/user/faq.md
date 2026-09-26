# FAQ

## General

**What is ZynSign?**
An on-device iOS app for importing, inspecting, signing, and delivering
IPA packages. Certificates, provisioning profiles, entitlements, and
signing are handled in a first-party-style interface — with no desktop
helper and no server.

**Does ZynSign install apps onto my iPhone?**
No. No app can install arbitrary IPAs on stock iOS. ZynSign signs and
packages on-device and hands the signed IPA to you
(`Documents/Signed/` + share, or an OTA manifest + QR for a host *you*
control). Installation happens through the platform's own routes
(TestFlight, MDM, Finder/Apple Configurator, user-confirmed `itms-services`).
See [`docs/architecture/installation-compatibility.md`](../architecture/installation-compatibility.md).

**Is my `.p12` safe here?**
Yes — by construction. Import goes through `SecPKCS12Import` into the
Keychain with `WhenUnlockedThisDeviceOnly` and non-extractable keys.
ZynSign cannot export the private key (exports are public metadata only),
and the repository refuses key material in CI hygiene scans. Details:
[`docs/security/signing-identities.md`](../security/signing-identities.md).

**Does anything leave my device?**
No. There is no analytics, telemetry, or crash reporting. The only network
activity is what you initiate: fetching AltSource repositories you added,
downloads you started, and install links you host. The activity journal is
local and never transmitted. Details: [`PRIVACY.md`](../../PRIVACY.md).

**What does the release train mean — is the app unfinished?**
The app is fully built. Each release *switches on* more of the finished
interface; `Settings → Diagnostics → Build` shows exactly what your build
exposes. See [`docs/releases/release-train.md`](../releases/release-train.md).

## Signing

**Which identity and profile should I choose?**
One whose team matches the profile, whose certificate the profile lists,
and whose scope (bundle ID / wildcard) covers the app you are signing. The
wizard's suggestion and the profile compatibility badge do these checks
for you — they are pre-sign *compatibility* checks, not Apple trust
verdicts.

**What is the DER 0x20400 toggle?**
iOS 15+ supports DER-encoded entitlements in the CodeDirectory's slot 7
alongside the classic XML slot 5. Leave the toggle off unless your target
expects DER entitlements; on means ZynSign emits both (slots 5 + 7).

**Why does signing refuse at “verification”?**
The pipeline signs in an isolated working copy, then re-reads and
independently verifies the result before delivering anything. If the
verification stage disagrees, nothing is delivered — by design. The error
names the stage and category; see
[Troubleshooting](troubleshooting.md).

**Can I pause a running signing?**
No. The pipeline has no safe resume checkpoint, so the queue offers
Cancel (cooperative) and Retry (always a clean fresh run) instead of a
Pause that could corrupt state.

**What does “Signed” mean in the Library?**
A successful ZynSign signing recorded in the on-device journal — not a
claim about Apple's trust or installability. “Verify” in the library
compares bytes against your import fingerprint.

## Certificates & profiles

**What does “Expiring Soon” mean?**
A provisioning profile within 30 days of expiry (or already expired).
Expiration is read from the profile's own declarations.

**Can ZynSign tell me my app will install and run?**
No, and it won't pretend to. Compatibility checks cover identifiers, team,
certificate matching, entitlements, and expiry. Apple's trust evaluation,
App Store review, and install acceptance are outside what any iOS app can
observe.

## Where is my stuff?

| Thing | Location |
|---|---|
| Imported apps + catalog | `Application Support/ZynSignLibrary` |
| Signed IPAs | `Documents/Signed/` |
| Downloads | App `Downloads` (cache policy: 500 MiB / 7 days) |
| Inspection / entitlements / certificate reports | shared from `tmp/ZynSign-Export/` when you export them |
| Activity journal | On-device, Settings → Analytics |

Reset & Recovery in Settings can restore defaults, clear the workspace,
rebuild the library index, or (with confirmation) remove everything —
see [Troubleshooting](troubleshooting.md).
