# Quick Start

From a fresh install to a signed, delivered IPA. Everything happens on
your iPhone or iPad — there is no desktop helper.

## Before you begin

- **Device:** iOS/iPadOS 17.0 or later.
- **What ZynSign accepts:** `.ipa` and `.tipa` packages, `.zip` archives of
  packages, `.p12`/`.pfx` signing identities, `.mobileprovision`
  provisioning profiles. Bounds: ≤ 100 000 archive entries, depth ≤ 32,
  ≤ 4 MiB per inspection read, ≤ 512 MiB extracted per package.
- **What you need for signing:** a signing identity (`.p12`) and a
  provisioning profile that matches the app's bundle identifier and your
  team — the same material you would use with Xcode.
- **Installation reality:** ZynSign signs and packages on-device; it does
  not install IPAs into iOS (platform limitation — see
  [FAQ](faq.md) and [`docs/architecture/installation-compatibility.md`](../architecture/installation-compatibility.md)).
  You deliver the signed IPA yourself (AirDrop, Files, a host you control,
  MDM).

## 1 · Import your first IPA

Open **Home** and tap **Import IPA** (or **Library → +**, or drop a file
on iPad). Pick the `.ipa`/`.tipa`. ZynSign stages the file, validates its
structure, fingerprints it with SHA-256, shows a preview — confirm to
finish, or cancel and nothing is stored. Duplicates are recognised;
oversize or damaged packages are refused with a plain-language error.

## 2 · Browse the Library

The **Library** tab shows every imported app: icon, name, bundle ID,
version + build, import date, signing status, favourite star. Search by
name or bundle ID, sort, swipe for **Favorite · Details · Delete**. Open
**Details → Explore IPA** for a read-only look inside the bundle
(structure tree, search, bounded preview of any single file).

## 3 · Import a certificate

Open the **Certificates** tab → **Import** → pick your `.p12`/`.pfx` →
enter its password. The identity is stored in the iOS Keychain
(`WhenUnlockedThisDeviceOnly`, non-extractable). The detail screen shows
subject, issuer, serial, SHA-256, validity, public-key info, and a
readiness badge. **Export public JSON** backs up public metadata only —
the private key never leaves the Keychain.

## 4 · Import a provisioning profile

Open the **Profiles** tab → **Import** → pick the `.mobileprovision`. The
import summary shows what was read; cards show team, type, device count,
expiry (Healthy / Expiring Soon / Expired) and a compatibility badge.
Open a profile for its facts, five pre-sign checks, and diagnostics.
**Use for Signing** pins it; an app's detail screen suggests the best
match for its bundle ID.

## 5 · Sign

From the Library: **⋯ → Sign** (or the detail screen). Then:

1. Choose a **ready** identity.
2. Choose a provisioning profile (the suggested match is pre-selected).
3. Entitlements are derived from the profile — review the 8-key preview.
4. Leave **DER 0x20400** off unless you know you need it (on for iOS 15+
   targets that expect DER entitlements).
5. Tap **Sign Application** and watch the nine stages
   (integrity → profile → discovery → extraction → nested → sealing →
   main → packaging → verification). A Live Activity mirrors progress.

The imported package is never modified. Success delivers
`Documents/Signed/<name>_signed.ipa` with **Share**, **Open Details**,
**Verify Again**. Failure shows `Refused at <stage>` with a category and
delivers nothing.

## 6 · Deliver (install by hand)

**Sign → Deliver…** → enter the HTTPS address where *you* will host the
signed IPA. ZynSign builds the OTA `manifest.plist`, the
`itms-services://` install link, a QR code, and step guides for OTA / MDM
/ host tooling. Publish the two files on your host; the device installs on
user confirmation. ZynSign never uploads anything and never claims an
install happened.

## 7 · Maintain

- **App Store tab** — add AltSource sources; health shows
  `Fast`/`Slow`/`Offline`; **Get** hands off to **Downloads**
  (pause/resume/retry).
- **Home → Refresh Everything** — one-tap maintenance (sources, library
  re-read, cache cleanup) with a completion report.
- **Settings → Analytics** — the on-device activity journal: clearable,
  exportable, never transmitted.

## Where to go next

- [FAQ](faq.md) — the questions everyone asks first.
- [Troubleshooting](troubleshooting.md) — when something refuses.
- [`docs/releases/notes-v1.0.0-rc.1.md`](../releases/notes-v1.0.0-rc.1.md) —
  what this release contains and its known limitations.
- [`SECURITY.md`](../../SECURITY.md) · [`PRIVACY.md`](../../PRIVACY.md) —
  material handling and privacy.
