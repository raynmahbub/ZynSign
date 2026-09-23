# Secure signing identity boundary

## Scope and release gate

ZS-016 refines the ZS-014 identity ports using ZS-015 certificate inspection.
It adds deterministic store logic and an **experimental**, deliberately
uncomposed Keychain adapter. It is not a code-signing engine. Production use
remains blocked by feasibility experiment E7; see
[on-device-signing-feasibility.md](../architecture/on-device-signing-feasibility.md),
Sections 15–16. There is no identity UI, profile trust/authorization, or
installation. ZS-017's separate decoded-payload parser is described in the
architecture document; it does not change the identity or private-key boundary.

## Model and capability

A certificate supplies public metadata, not possession of a signing key.
`SigningIdentity` reuses that metadata and a minted UUID, and separately reports
key availability, certificate/key association, and capability readiness.
Readiness is a snapshot, not a successful signature, validity, trust, or Apple
policy approval. Missing certificates fail resolution rather than fabricating
metadata. Selection metadata has no key handle.

`SigningCapability.sign(data:algorithm:)` accepts an explicit message/digest
algorithm and returns only a signature. RSA PKCS#1 v1.5 SHA-256 and ECDSA
X9.62 SHA-256 have distinct message and digest cases. Digest input must be
32 bytes. There is no digest-to-message fallback and no algorithm inferred
from a certificate's issuer-signature algorithm. Other algorithms are future
extensions, not silently substituted. Security checks platform support before
signing. Identity failures have stable reason codes on `ZynSignError`, with
fixed safe messages and no retained platform error object.

## Ownership and storage

`IdentityStore` remains the Application read/capability port. Platform's
`SecureIdentityStore` orchestrates a registry and a key resolver; their narrow
internal protocols allow deterministic tests without credentials.
`KeychainIdentityRegistry` owns only versioned registration records, stored as
non-synchronizable generic-password items under its fixed service. Records
contain a UUID, public certificate DER, and an opaque persistent key reference.
There is no schema field for a private key, password, PKCS#12 blob, or
authorization token; registration validates the certificate and locator before
storage. No identity data is added to the application catalog.

Registration is a Platform-only operation accepting a public certificate and
an existing persistent key reference. It is **not import** and does not create,
copy, export, or change keys. The caller that originally provisioned the key
owns it. Registration validates the key and public-key association before
writing anything. The UUID survives store reconstruction. Duplicate certificate
registrations are rejected; certificate fingerprint is an index, not proof of
key possession. Certificate input retains the 256 KiB inspection bound; locators
are limited to 4 KiB and encoded records to 512 KiB (application policy, not
published Keychain limits). Removing a registration revokes subsequent
capability calls
but deliberately does not delete the borrowed key or other certificates.
Re-registering after removal mints a new UUID.

Persistent references stay in Platform and Keychain, never Domain, SwiftUI,
application records, or diagnostics. They are locators, not portable credentials;
deletion/recreation of a key may invalidate them. No automatic repair or fallback
by subject, label, or name is performed. Missing keys produce an unavailable
snapshot; authorization and storage failures are not treated as an empty store.
A malformed registration fails resolution and is not automatically overwritten
or deleted.

## Private-key boundary

The Apple resolver queries a private `SecKey` reference and attributes, never
private-key data. It compares the certificate's public-key representation with
`SecKeyCopyPublicKey`'s representation, including algorithm and size. Only public
keys reach `SecKeyCopyExternalRepresentation`. Matching is not a signing trial.
The resolver also requires the existing
public-key adequacy heuristic (RSA at least 2048 bits, EC at least 256 bits),
without turning it into a trust or platform-policy claim.
A policy evaluation uses none of the capability path. Policy validation
(ZS-019) resolves an identity's *metadata* through `IdentityStore` read-only —
certificate fingerprint, key availability, association, readiness — and a test
asserts that it never requests a signing capability, so no key handle is
resolved and no signature is produced to prove possession. Identity questions
answered by policy are reported as indeterminate when no identity was supplied
or the store could not be read, and an unavailable key is never reported as a
defect in a profile.

The key handle lives only inside Platform. The outward capability retains a
resolver, not a key, and rechecks the registry, protection, association, and
algorithm on every operation. Deletion cannot cancel an operation already in
progress; future calls fail. Status checks cannot guarantee a subsequent sign
will succeed because lock state and authorization can change.

No logging or file I/O is introduced. Store, record, and capability
descriptions/reflection are redacted; the Apple resolver retains no state.
Only allowlisted fields are serialized.
This protects ordinary rendering, not arbitrary debugger access or a compromised
process. Swift/Foundation buffers do not offer a general secure-zeroization
guarantee; this boundary avoids obtaining private-key bytes in the first place.

## Protection policy

Registry items use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and
`kSecAttrSynchronizable = false`. Borrowed keys must resolve as non-synchronizable
private-key items and report the same accessibility and non-extractability. Missing
or incompatible protection evidence fails closed; the adapter never weakens
existing protections to make a test pass. An attribute report is not an
experimentally proven non-exportability guarantee.

This is a foreground/unlocked policy. Device-only items do not migrate to another
device. Same-device restore and uninstall/reinstall retention need E7; removal
of the app must not be advertised as key erasure. No shared access group is added.
Keychain access is restricted by the app's existing entitlements.

A fresh `LAContext` with `interactionNotAllowed` is used for lookup. Background
metadata checks must not prompt, and this increment does not implement a consent
session. Authorization-gated keys may remain unavailable. No biometric ACL or
Secure Enclave support is claimed, and no claim is made that an imported RSA key
can be moved into the Secure Enclave. Call synchronous store operations off the
UI thread and serialize ownership operations in a future workflow.

## Platform evidence

The project specifies iOS/iPadOS 17.0. The following are **Verified from Apple
API documentation**, not from local SDK compilation or device execution:

| API | iOS availability | Source |
| --- | --- | --- |
| `SecItemAdd`, `SecItemCopyMatching`, `SecItemDelete` | 2.0+ | [Add](https://developer.apple.com/documentation/security/secitemadd(_:_:)), [Query](https://developer.apple.com/documentation/security/secitemcopymatching(_:_:)), [Delete](https://developer.apple.com/documentation/security/secitemdelete(_:)) |
| Persistent references | 2.0+ | [Reference](https://developer.apple.com/documentation/security/ksecvaluepersistentref) |
| `WhenUnlockedThisDeviceOnly` | 4.0+ | [Accessibility](https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly) |
| Synchronizable attribute | 7.0+ | [Synchronization](https://developer.apple.com/documentation/security/ksecattrsynchronizable) |
| Extractability attribute | 2.0+ | [Extractability](https://developer.apple.com/documentation/security/ksecattrisextractable) |
| `SecKeyCopyPublicKey`, `SecKeyCopyAttributes`, `SecKeyCopyExternalRepresentation` | 10.0+ | [Public key](https://developer.apple.com/documentation/security/seckeycopypublickey(_:)), [Attributes](https://developer.apple.com/documentation/security/seckeycopyattributes(_:)), [Representation](https://developer.apple.com/documentation/security/seckeycopyexternalrepresentation(_:_:)) |
| `SecKeyCreateSignature`, `SecKeyIsAlgorithmSupported` | 10.0+ | [Signature](https://developer.apple.com/documentation/security/seckeycreatesignature(_:_:_:_:)), [Support](https://developer.apple.com/documentation/security/seckeyisalgorithmsupported(_:_:_:)) |
| `LAContext.interactionNotAllowed`, authentication context | 11.0+, 9.0+ | [Noninteractive](https://developer.apple.com/documentation/localauthentication/lacontext/interactionnotallowed), [Context](https://developer.apple.com/documentation/security/ksecuseauthenticationcontext) |
| `SecCertificateCopyKey` | 12.0+ | [Certificate key](https://developer.apple.com/documentation/security/seccertificatecopykey(_:)) |

`SecCertificateCopyValues`, desktop keychains, `SecItemImport`, and desktop
signing utilities are not used. `kSecUseAuthenticationUIFail` is deprecated on
iOS 14; the adapter uses LocalAuthentication instead. Exact Swift SDK signatures
and all query combinations still need an Xcode build and iOS tests.

**Inferred:** public-key comparison establishes the mathematical association for
the accepted RSA/EC encodings. **Requires experiment:** agreement of Security's
representations and metadata, persistent-reference lifecycle, attribute reporting,
locked-device behavior, and signature verification on target devices.

## Import limitation

No PKCS#12 importer is implemented or composed. The existing IdentityStore port
already excludes import. E1/E7 have not established accepted encodings, import
side effects, protection control, or authorization behavior on the target.
Registration of an already-provisioned key is not evidence of `.p12` support.
A future importer must remain a separate explicit-intent port and satisfy these
gates before creating keys or accepting passphrases. No speculative raw-key import
or export method is added to the Domain boundary.

## Testing and outstanding validation

Deterministic XCTest cases cover the refined model, explicit algorithms, store
lifecycle, duplicate/malformed records, resolution failures, capability revocation,
and redacted rendering/serialization. They use fake capabilities and synthetic
public certificates; no production credentials or private-key fixtures are stored.

Opt-in iOS integration tests use disposable runtime-generated keys only. They
use synthetic public certificates with replacement public-key bytes (invalid
issuer signatures, intentionally not trust tests), and exercise reference
resolution, protection checks, public-key matching/mismatch,
signing/verification, and registry persistence/removal. They are not E1 or a full
E7 substitute. Use a signed test host with its own Keychain sandbox on iOS 17+,
set `ZYNSIGN_RUN_KEYCHAIN_TESTS=1`, and run `ZynSignTests`. Always inspect cleanup
results. Run normal tests without that variable first.

This implementation environment is Linux without Swift, Xcode, an Apple SDK,
a simulator, or a device. XCTest, iOS builds, and Keychain integration tests were
**not run**. Twenty source-boundary assertions, changed-file/credential-pattern checks,
relative documentation links, and diff whitespace checks passed. These static
checks do not prove Swift compilation or runtime security. Before production
composition: build/test with Xcode, run the opt-in
suite on simulator and physical iPhone/iPad, then execute E7's lock/background,
authorization, backup, and reinstall matrix and E1 before adding import.
