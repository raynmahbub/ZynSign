# Provisioning-profile container security boundary

## Scope and release gate

ZS-018 adds verification of a provisioning-profile CMS container on top of
ZS-017's decoded-payload parser. It reads a SignedData message, checks one
signature, relates the signer certificate to the profile's own certificates and
to locally listed identities, and reports each fact separately. It is not trust
evaluation, not a signing-policy engine, not an authorization decision, and not
an installation path. There is no profile-management interface, no profile
persistence, and no CMS construction.

ZS-019 adds a read-only policy stage above that evidence: it evaluates whether an
authenticated profile may be used with an application, a signing identity, and a
requested signing configuration, under the policy rules ZynSign implements. It
reads no container bytes of its own, re-verifies nothing, signs nothing, and
persists nothing. The container boundary above is unchanged by it, and the two
sections below stay separate: container verification is evidence, policy
validation is a predicate over that evidence, and neither is platform
authorization.

Production use of the verification path is gated by experiments E3 and E4 in
[on-device-signing-feasibility.md](../architecture/on-device-signing-feasibility.md):
the platform primitives the path uses are documented for iOS, but their
on-device behaviour has not been measured, and the iOS-gated test suite that
would measure it has not been executed in an iOS harness.

## Input model and bounds

A profile enters as `ProvisioningProfileInput`: the exact untrusted bytes a
caller presented, capped at 4 MiB. Nothing else about the input is assumed.
Empty input, oversized input, and input that is not a decodable CMS message of a
supported shape are refused before any interpretation.

The container reader applies its own bounds, all ZynSign policy rather than
published limits: constructed nesting depth 16, certificate-bag entries 16,
signers 8, signed attributes per signer 32, declared digest algorithms 8,
serial-number and key-identifier values 64 bytes, signature values 1024 bytes,
and the existing payload cap on encapsulated content. Lengths must be definite
and minimally encoded; high-tag-number forms are refused; a value that extends
past the message, or a message with bytes after its outer value, is refused.

Profile content is never executed. No command-line tool is invoked, no external
process is spawned, no private API is used, and no shell-out to `security cms`
or any macOS tooling exists in a runtime path.

## What verification establishes

A `.verified` CMS status means exactly one thing: the signature over the
authenticated content was produced by the private key matching the signer
certificate's public key, where the authenticated content is the encapsulated
payload, bound through the message-digest signed attribute when the signer
carried signed attributes.

It does not mean any of the following, and the result model has no field that
could be read as claiming them:

- that the signer's certificate is trusted, unrevoked, or chains to an Apple
  anchor — trust evaluation is not performed and is recorded as `notPerformed`;
- that Apple issued the certificate or the profile;
- that ZynSign holds the matching private key;
- that the profile authorizes an application, a bundle identifier, an
  entitlement, a device, a platform, or a profile type — authorization is
  recorded as `notEvaluated`;
- that the profile is structurally valid, currently within its validity period,
  or installable.

Five states stay separate: parseable, structurally valid, cryptographically
authentic, certificate trusted, platform authorized. There is deliberately no
single validity flag, and no result field is named in a way that could be
rendered as one.

## Container boundary rules

Structural refusals throw typed errors carrying a `CMSFailure` reason from the
CMS vocabulary, which is separate from the profile-metadata and identity
vocabularies. A container that decoded and did not verify is returned as
evidence rather than thrown, so a caller can distinguish three different facts:
the container is inauthentic, no conclusion was reached, and the input is not a
CMS message at all.

Unsupported is not invalid. A digest or signature algorithm ZynSign does not map
onto a verification operation is reported as `.unsupportedAlgorithm` with both
object identifiers preserved; a missing verification mechanism is reported as
`.unavailable`; an unexpected platform failure is reported as
`.verificationFailed`. None of those is reported as a signature mismatch, and
none is reported as a defect in the user's profile.

Ambiguity is never resolved silently. A message with no signer is `.noSigner`;
a message with several is `.multipleSigners`, and ZynSign does not pick one; two
embedded certificates matching one serial number is `.ambiguous`.

Detached content is refused rather than approximated: a message whose
encapsulated content is absent has no payload to authenticate, and substituting
bytes from anywhere else would create a signature over content the message did
not carry.

## Signer certificate selection and matching

The signer is related to an embedded certificate by the serial number its
identifier names, parsed through the existing certificate port. Bag order, bag
size, and the position of a certificate in the profile carry no meaning: a bag
that lists the signer second, a bag holding an entry that does not parse, and a
profile listing the same certificate twice each produce an explicit outcome.
Unparsable bag entries are counted and discarded; their parse detail is not
carried into diagnostics, because certificate parse failures may quote bytes.

A subject-key-identifier signer is reported as `.identifierNotMatchable` rather
than matched by approximation. The issuer name inside an
`issuerAndSerialNumber` identifier is not re-parsed at this boundary, so a
serial collision between two different issuers in one bag is reported as
ambiguous; that conservatism is deliberate.

Certificate correspondence is compared by the SHA-256 fingerprint of exact DER
bytes — never by subject name, common name, organizational unit, label, or
email address. The fixtures include a certificate that shares the signer's exact
subject distinguished name and issuer while holding a different key, precisely
so that a name-based match is impossible to pass.

## Payload handling and the parse gate

The authenticated payload is parsed into profile metadata only when the
signature verified. An unverified container contributes evidence about itself
and no parsed profile at all, which is what keeps "parseable" from becoming a
back door to unauthenticated profile metadata.

The same verifier also backs the existing `ProvisioningProfilePayloadDecoder`
seam. Through that seam, an authenticated payload is handed over as
`.authenticated`, a rejected container fails closed rather than passing
unauthenticated bytes to a parser, and a container that could not be evaluated
is handed over as `.notEvaluated` — the state's actual meaning.

Profile bytes are never modified. Where a package contains a DER-encoded
`embedded.mobileprovision`, its presence is a filesystem observation made by the
bundle explorer; the bytes are not rewritten, stripped, or re-encoded, and
archive inspection still does not read embedded profiles.

## Identity relationship without capability

An identity store may be supplied to answer one question: is a locally listed
identity's certificate one the profile names. Answering it uses identity
metadata only. Requesting a signing capability, resolving a key handle, or
producing a signature to prove possession is prohibited on this path, and a test
asserts that no capability request is made.

A match is not authorization and not key possession: key availability is
reported separately, as observed. "No store was consulted" and "the store could
not be read" are different outcomes and are recorded differently; an unreadable
store never fails the verification, because it says nothing about the profile.

## Policy validation boundary

The policy stage consumes `ProvisioningPolicyValidationContext`: a parsed profile
with its staged authenticity, the certificate relationship, application metadata,
the bundle identifier being signed, identity metadata if any, the requested
signing configuration, the device and platform context, and an injected clock. It
cannot receive interface state, key bytes, a key reference, a Keychain record, or
a credential, and it never calls `IdentityStore` itself; the application-layer use
case resolves metadata read-only and hands the validator a domain value. A test
asserts that no signing capability is requested on this path.

A `compatible` result means the configuration satisfies the policy rules
implemented by ZynSign. It is not platform authorization, not installation, not a
signature, and not Apple's approval. Trust stays `notPerformed`, authorization
stays `notEvaluated`, and there is no `isValid`, `isInstallable`, or `isTrusted`
flag on the result.

Three states are kept apart per category — satisfied, violated, indeterminate —
because reporting a question ZynSign could not answer as a pass, or as a conflict,
would be a false statement about the profile. Absence is never treated as a value:
a missing device list is not a grant, a missing `get-task-allow` claim is not
`false`, a missing team identifier is not a mismatch, and an unreadable identity
store is not a defective profile.

Nothing on this path modifies content. No entitlement is stripped, rewritten, or
synthesized; no profile byte, `Info.plist`, or bundle identifier is edited and no
Keychain item is touched. The stage is a predicate over values it was given.

## Diagnostics and redaction

Diagnostic renderings carry states, bounded counts, algorithm identifiers,
certificate fingerprints, and mapped numeric platform error codes. They never
carry container bytes, payload bytes, certificate bodies, private-key material,
user messages from foreign errors, or platform error text. A foreign failure
crossing the boundary is reduced to its CMS reason before it is stored, so a
third-party or platform description cannot reach a log or an interface.

The policy stage follows the same rule with one narrowing: its diagnostic
rendering carries only overall and per-category states plus the codes of the
findings that were not satisfied — no identifiers, no entitlement values, no
fingerprints, and no bytes. A presentation-safe summary may name a claim key and
a category, because keys are not secrets and a reason the user cannot act on is
not worth carrying; a test asserts that neither a bundle identifier, a team
identifier, a certificate fingerprint, nor a requested value appears in it.

User-facing messages come from the fixed `CMSFailure` table and are written
without reference to any input bytes.

## Persistence and lifetime

Nothing on this path is persisted. The verification result holds the payload and
the signer certificate transiently, in memory, for the duration of the call; no
profile bytes, payload bytes, certificate bodies, or fingerprints are written to
application storage, to the library catalog, or to disk. No private key,
password, or Keychain secret is read or stored. There is no automatic profile
storage and no profile cache.

The policy stage persists nothing either, and it writes no profile, no
entitlement, and no `Info.plist`. Its result is derived from the profile, the
application, the identity, the configuration, and the current time, so a caller
that keeps one must define its own invalidation rather than treating it as stored
state.

## Platform evidence

**Verified — Apple Security documentation, per symbol.** `CMSDecoderCreate`
lists macOS 10.5 with no iOS entry; `CMSDecoderCopySignerStatus` lists macOS
10.5 with no iOS entry; `CMSSignerStatus` lists macOS and Mac Catalyst only. No
CMS decoder symbol is available to an iOS 17 application, so none is called and
none is hidden behind a port iOS could not satisfy.

**Verified — API availability.** `SecCertificateCreateWithData` (iOS 2.0+),
`SecCertificateCopyKey` (iOS 12.0+), `SecKeyIsAlgorithmSupported` and
`SecKeyVerifySignature` (iOS 10.0+), including the message-based algorithms
`.rsaSignatureMessagePKCS1v15SHA256` and `.ecdsaSignatureMessageX962SHA256`,
which keep hashing inside the platform primitive.

**Requires experiment (E3, E4).** Whether `SecCertificateCopyKey` yields a key
whose supported algorithms agree with the certificate's own key fields for
unusual certificates; whether `SecKeyVerifySignature` accepts the re-encoded
`SET OF` attribute bytes on device for both RSA and ECDSA signers; and how the
primitives behave under memory pressure and for certificates the platform
rejects. Until measured, the substitute path is implemented and reasoned about,
not demonstrated.

**Unknown.** Signer-chain trust, revocation checking, Apple issuance rules,
profile-type semantics, and every authorization question. Nothing in this
increment answers them.

**Unknown — platform-policy predicates.** The rules of the policy stage are
ZynSign's rules, and their evidence is recorded where they are defined: allowlist
inclusion is verified from Apple's documentation, the identifier wildcard scope
and the mapping from declared device families to platform spellings are inferred,
and the numeric, array, and dictionary comparison choices are this repository's
own conservatism. Whether the platform's behaviour matches a predicate is not
established, so a `compatible` result is stated as satisfying the policy rules
implemented by ZynSign — never as "iOS will accept" the configuration, the
entitlement, the device, or the profile.

## Testing and outstanding validation

Deterministic suites cover the structure reader, the verification boundary with
a recording signature double, the CMS vocabulary, the certificate relationship
rules, and the verification use case. They run without a device, a simulator, a
keychain, or a network.

The ZS-019 policy stage has its own host-side suites over synthetic profile,
identity, application, and configuration values: the identifier rule, the typed
entitlement comparator, the category rules with authenticity gating and
aggregation, and the application-layer use case including the identity-resolution
states and the summary. They assert that `trustEvaluation` stays `notPerformed`,
that `authorization` stays `notEvaluated`, that no signing capability is
requested, that no result carries a value, identifier, or fingerprint, and that
an unauthenticated container yields indeterminate categories rather than
violations. No network, device, keychain, or simulator is involved. Signature mathematics over real fixture bytes lives in a
separate iOS-gated suite, because the primitives it uses do not exist elsewhere;
it needs no signed host, no keychain, and no private key.

Fixtures are synthetic: test-only RSA and EC keys and certificates generated for
this repository with OpenSSL, property-list payloads with placeholder
identifiers, and recorded byte ranges so tampered variants are derived
deterministically. Each container whose name says it is valid was cross-checked
with `openssl cms -verify -noverify`, and the tampered variants were confirmed
to fail it. The private keys existed only while those bytes were produced and
are not committed. No real provisioning profile, production certificate, team
identifier, or device identifier appears anywhere in the suite.

Outstanding: execution of the whole suite in Xcode, execution of the iOS-gated
suite in a simulator and on a physical device, and experiments E3 and E4. The
policy suites (ZS-019) share that status: they were written but not run in the
environment where this increment was written. None of these has been performed,
so no test result is claimed here.
