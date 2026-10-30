# Signing interoperability report

Status: **Partially implemented; independent and device acceptance blocked**. This is a code-path review, not proof that all source files or real IPA variants were audited.

## Separate stages

| Stage | Current evidence / limitation |
| --- | --- |
| PKCS#12 and key | iOS Security importer parses a bounded container, extracts a `SecIdentity`, and registers its certificate and persistent private-key reference; store/resolver checks are present. No current Apple execution or diverse identity corpus was run. |
| Profile and authorization | CMS/profile parsing, team and identifier policy, and entitlement comparison exist. Trust, expiry, actual profile/certificate association and unusual profiles must be exercised with Apple tools and authorized fixtures. Raw entitlement overrides still require the downstream policy to reject unauthorized claims. |
| Execution | The pipeline has nested planning/signing, resource sealing, explicit unsupported-form checks, working-copy isolation and packaging. The single-image signer accepts only supported thin forms and refuses active encryption; many real binaries remain unsupported or unmeasured. Inline and queue now share entitlement preparation, with conservative refusal when binary claims cannot be extracted. |
| Verification | The implementation rechecks signature structures and cryptographic signatures; the external harness also runs macOS `codesign`, OpenSSL, `otool`, and package checks on generated artifacts. Local self-verification is not independent acceptance. |
| Install and launch | No physical installation or launch evidence for this working tree. Signing success does not imply device install or launch success. |

Historical external validation (`docs/architecture/external-validation.md`) recorded macOS acceptance of synthetic single images but rejection of the tested application and framework, and failures of iOS format checks. Those results are historical, not results for the current tree. DER, resource seals, Info.plist binding, requirements, nested signatures and existing-signature handling need fresh independent measurement before deciding which historical divergences remain.

## Required validation

Run current XCTest and external-validation workflows on macOS; inspect report verdicts even if the harness job is green. With licensed/consented fixtures, cover thin and universal executables, existing signatures, frameworks, dylibs, extensions, entitlements, certificate/key mismatch, expired or mismatched profiles, nested order, resource mutations, malformed archives, repackaging and independent verification. Keep real private keys, P12 files and provisioning profiles out of artifacts. Record each stage separately and use supported physical devices for installation and launch outcomes. No such tests were run here.

Single-image slot-7 experiment and pending validation: [DER review](single-image-der-review.md).
