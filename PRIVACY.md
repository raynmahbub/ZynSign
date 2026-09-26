# Privacy

**ZynSign is an on-device app. It has no analytics, no telemetry, no
accounts, and no server of its own.** This document says exactly what data
exists, where it lives, and what leaves the device (almost nothing).

Last reviewed: 2026-09-26 (RC 3 security lockdown,
[`docs/security/rc3-security-lockdown.md`](docs/security/rc3-security-lockdown.md)).

## What ZynSign collects

Nothing. There is no analytics SDK, no crash-reporting SDK, no advertising
identifier, no account, and no first-party endpoint in the app. The
project's three standing promises ([`docs/product/WHAT_DOES_NOT_EXIST.md`](docs/product/WHAT_DOES_NOT_EXIST.md))
include *off-device measurement is never*.

## What stays on your device

Everything ZynSign handles stays inside its iOS sandbox:

| Data | Where it lives | Leaves the device? |
|---|---|---|
| Imported apps (`.ipa`/`.tipa`/archives) | `Application Support/ZynSignLibrary` | No |
| Library records, collections, favourites | `Application Support/ZynSignLibrary` (versioned catalog) | No |
| Signing identities (`.p12`/`.pfx`) | iOS Keychain — `WhenUnlockedThisDeviceOnly`, non-extractable | **Never** (private keys cannot be exported) |
| Provisioning profiles (`.mobileprovision`) | App container, beside the profile catalog | No |
| Signed IPAs you export | `Documents/Signed/` (yours to share) | Only if *you* share them |
| Activity journal | On-device, clearable and exportable by you | **Never transmitted** |
| Technical diagnostics log | On-device, **opt-in** (off by default), fixed-word slugs only | No |
| Certificate public-metadata backups (JSON) | `tmp/ZynSign-Export/`, shared only when you tap Export | Only if *you* share them |

Reports you export (entitlements reports, certificate JSON backups,
inspection reports) are credential-free: they contain public metadata,
fingerprints, and states — never key material, profile bytes, or device
identifiers.

## Network activity

ZynSign talks to the network only when you ask it to:

- **Store Browser / Repository health** — you add AltSource repository
  URLs; ZynSign fetches their `apps.json` and measures latency
  (`Fast`/`Slow`/`Offline`). The repository operator can see a normal HTTPS
  request from your device, like any browser fetch.
- **Download Center** — you start downloads (or install via
  `itms-services` links you provide). The host of that file sees the
  request.
- **Installation delivery** — ZynSign builds an OTA `manifest.plist` and
  install link locally and never uploads, hosts, or learns whether an
  install happened.

There is no other traffic. A network monitor shows only the hosts you
configured. The local activity journal records your in-app activity and
never sends it anywhere.

## What ZynSign cannot see

- Your Apple ID, other apps, or anything outside its sandbox.
- Whether a delivered app was ever installed (no delivery outcome is
  reported back).
- The contents of files you never open in the app.

## Backups

If you back up your device through iCloud or a computer, iOS decides what
of the app container is included. ZynSign adds no backup of its own and no
cloud sync. Signing private keys live in the Keychain with
`WhenUnlockedThisDeviceOnly` accessibility and are not extractable.

## Children

ZynSign collects no data from anyone, so it has no age-gated data
practices to describe.

## Changes

Any change to this policy must match the implementation before it ships
(documentation lock, [`docs/releases/release-lock-rc3.md`](docs/releases/release-lock-rc3.md));
the RC 3 security lockdown re-verified every row above against the code.

## Questions and problems

Privacy questions and suspected leaks are security-relevant: report them
privately as described in [`SECURITY.md`](SECURITY.md) (the repository's
private reporting channel, or the maintainer directly). Do not open a
public issue with sensitive material attached.
