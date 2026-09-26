# Troubleshooting

Every ZynSign failure is a typed error with a category, a plain-language
message, and (where useful) technical detail that never contains key
material or profile bodies. The category tells you which family of problem
you have:

| Category | Means | What to do |
|---|---|---|
| `invalidInput` | The file is malformed, damaged, or fails a structural check | Re-export or re-download the package; verify it opens elsewhere |
| `unsupportedInput` | Well-formed but outside ZynSign's declared support | See the bounds below; convert or split the archive |
| `ambiguousInput` | More than one interpretation exists (e.g. two app bundles) | Resolve the named conflict and retry |
| `capabilityUnavailable` | The platform cannot do this (e.g. in-app install) | Use the documented alternative (delivery hand-off, host tooling) |
| `cancelled` | You (or the system) cancelled the operation | Just retry |
| `storageFailure` | Disk full, file moved, permission lost | Free space; check the file still exists in Files |
| `internalFailure` | A defect in ZynSign | Report it ([below](#reporting-a-problem)) with the diagnostic detail |

Content refusals (`invalidInput`, `unsupportedInput`, `ambiguousInput`)
are never offered a Retry because a clean re-run would refuse again — fix
the input first.

## Import problems

**“Not a valid package” / structural refusal.**
The archive is damaged or not really an IPA/TIPA/zip. Re-download it. If
it is a `.zip`, ZynSign classifies it before extraction and refuses unsafe,
duplicate, or linked entries on purpose.

**Refused for size or complexity.**
ZynSign's bounds: ≤ 100 000 archive entries, nesting depth ≤ 32,
≤ 4 MiB per inspection read, ≤ 512 MiB extracted per package,
≤ 10 MiB for `.p12` files. Packages beyond these are refused to keep the
device safe (`unsupportedInput`).

**Duplicate import.**
The Duplicate Resolution Center offers Keep Both / Replace Existing /
Skip with suggestions from version rules — nothing is applied silently.

**Import vanished after a crash/interruption.**
Interrupted items resume from surviving working copies on next launch; if
the source file is gone, the item fails with a storage message and the
original is never touched. Staged copies live in `tmp` and can be cleared
in Settings → Reset & Recovery.

## Certificate problems

**Wrong password / import fails.**
The `.p12` password is wrong or the file is not PKCS#12. Re-export from
Keychain Access / your CA with the correct password.

**“Already in the store” / duplicate.**
ZynSign rejects a second identity with the same SHA-256 certificate
fingerprint. Find the existing one in the Certificates tab.

**Readiness badge says “needs attention”.**
The identity is missing its key pair, is expired, or its key is not
usable on this device. Re-import a current `.p12` that contains both the
certificate and its private key.

## Profile problems

**Expired / Expiring Soon.**
Renew the profile with Apple and import the new one — ZynSign never edits
a profile.

**Compatibility badge is red / signing refuses at “profile”.**
Run the profile's five pre-sign checks (detail screen): team mismatch,
bundle-ID out of scope, certificate not listed in the profile, entitlement
conflicts, and expiry are the usual causes. Each failure names the fact
that disagrees.

## Signing problems

**Refused at `integrity` or `discovery`.**
The source package failed structural validation or its layout is not one
ZynSign supports. Import succeeds only for structurally valid bundles —
re-import the original.

**Refused at `nested` or `sealing`.**
A nested framework/extension failed its own signing or resource sealing.
The stage name points at the target; the diagnostic detail carries the
target's name.

**Refused at `verification` (nothing delivered).**
The independent re-read disagreed with the signed output. Nothing is
delivered on purpose — this is ZynSign failing closed. Retry once (a retry
is always a clean run in a fresh working directory); if it repeats, report
it with the diagnostic detail.

**Queue job failed; can I continue it?**
No — and the UI doesn't offer it. A failed attempt delivered nothing, so
**Retry** starts a clean operation. Pause is not offered because the
pipeline has no safe resume checkpoint.

## Download problems

**Download keeps failing after retries.**
The Download Center retries three times with resume data, then stops and
says so. Check connectivity and the source URL; restart the download.

**Checksum mismatch.**
The transferred bytes don't match the declared checksum; the file is not
committed. Re-download from the source.

## Delivery & installation

**Where is my signed IPA?**
`Documents/Signed/<name>_signed.ipa` — share it from the result screen or
open it in Files.

**“No delivery mechanism” in Settings → Installation.**
Correct and permanent on stock iOS: ZynSign composes no in-app
installation. Use the Deliver… hand-off (OTA manifest + link + QR),
TestFlight, MDM, or Finder/Apple Configurator. See
[FAQ](faq.md).

## Storage

**“Storage failure” during import or signing.**
Free device space (iOS needs headroom), then retry. Settings → Storage
shows the footprint; Reset & Recovery can clear the workspace (staged
files and working copies) without touching imported apps.

## Reporting a problem

Include: what you tapped, the stage (for signing), the category, the
diagnostic detail (it is already redacted — safe to paste), your device/OS,
and the build from Settings → Diagnostics → Build. Security-sensitive
reports go privately per [`SECURITY.md`](../../SECURITY.md); everything
else can be a GitHub issue.
