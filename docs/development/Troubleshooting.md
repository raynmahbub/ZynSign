# Troubleshooting

Common refusals and states, what causes them, and what to do. ZynSign refuses
rather than half-succeeds: a refusal is the typed answer to a real condition,
not a defect in the tool. Find the category the interface reported, then the
row.

## Import

| Symptom | Category / cause | What to do |
|---|---|---|
| An `.ipa`/`.tipa` is refused at intake | `invalidInput` — the container failed bounded structural validation | Re-export the archive; check it opens in `Files`; over-size archives (> the documented bounds) are refused by design |
| "Already in the library" on import | The SHA-256 fingerprint matches an existing record | Choose in the Duplicate Resolution Center: Keep Both / Replace / Skip — never applied silently |
| A `.zip` archive of packages is refused | The archive was classified unsafe, duplicated, or link-bearing | Re-zip with plain package entries; links and unsafe entries are rejected before extraction |
| Import stalls with the app in background | Imports continue only while ZynSign is open (plus iOS's short background extension) | Return to the app; interrupted items resume from surviving working copies |
| "Not enough free space" | `storageFailure` — checked before every copy | Free space (Settings → Advanced can move the workspace) |

## Certificates and profiles

| Symptom | Category / cause | What to do |
|---|---|---|
| `.p12` import fails on the password | `invalidInput` — decryption failed | Re-enter the password; the file is not modified by a failed attempt |
| Identity shows *needs attention* | Expired, not-yet-valid, or unsupported algorithm | Re-export from the issuing portal; see [../security/signing-identities.md](../security/signing-identities.md) |
| Profile shows *Expired / Expiring Soon* | The embedded expiry passed or is within 30 days | Renew the profile in the developer portal and re-import; see [../security/provisioning-profiles.md](../security/provisioning-profiles.md) |
| Pre-sign compatibility check fails | Team, bundle ID, device, or entitlement mismatch against the selected profile | Open the profile's diagnostics panel; use the suggested profile for the app or override deliberately |

## Signing

| Symptom | Category / cause | What to do |
|---|---|---|
| "Refused at <stage>" during a run | The pipeline stopped at that stage; nothing later ran | The toast names the stage; `ZErrorView` states what to do next — fix the named condition and re-run |
| Signature verification reports a mismatch | The re-read artifact did not match what the signing stages believed | Do not deliver the output; re-run. Independent verification exists to catch exactly this |
| No ready identity available | No Keychain identity passes readiness | Import a `.p12` in Certificate Studio first |
| Nested code refuses to sign | A framework/extension failed inner-first ordering checks | The stage list names the binary; check that it belongs to the package |

## Store and downloads

| Symptom | Category / cause | What to do |
|---|---|---|
| A source fails to refresh | Unreachable source, malformed feed, or offline (repository health reports which) | Check the source URL; Fast/Slow/Offline health is measured, not assumed |
| A download cannot resume | Resume data was not captured for that job | Restart the download; resume is offered only when resume data exists |
| A download is refused before import | It failed validation on completion | Re-download from the source; ZynSign validates before the file becomes an import |

## Delivery

| Symptom | Category / cause | What to do |
|---|---|---|
| The install link does nothing | The manifest is not served over HTTPS, or the device does not trust the host | Publish both files on your HTTPS host; the QR and link are only as reachable as your host |
| "Delivery unavailable" | `noDeliveryMechanism` — a recorded platform fact | ZynSign hands off (manifest, QR, guides) and never installs in-app; see [../architecture/installation-compatibility.md](../architecture/installation-compatibility.md) |

## Still stuck

- Reproduce with a Debug build, capture the exact `ZynSignError` text and
  stage, and check [../audits/](../audits/) for a known finding.
- Open a bug report with the exact code and stage
  ([the template asks for precisely that](https://github.com/raynmahbub/ZynSign/issues/new?template=bug_report.yml)).
