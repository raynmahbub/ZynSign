# Single-image DER signing review

Status: **Experimental / Blocked on Apple-platform validation**. This is not an installation or launch claim.

The single-image metadata option defaults off. When enabled, it requires entitlements and this project's v20400 policy, derives XML and DER from the same model, refuses a lossy DER round trip, hashes the entire framed DER blob into slot 7, and includes it in the SuperBlob. Verification checks the decoded and re-encoded bytes, prepared bytes and slot digest before accepting the signature. The application pipeline and coordinator refusal gates remain in place. XML-only requests retain v20200 behavior.

The serializer now sorts complete DER-encoded dictionary members, including nested dictionaries. Existing standalone real-to-string behavior is retained for compatibility, but the new signing path rejects it. General-purpose decoding remains permissive about SET ordering; the signing verifier enforces it by re-encoding. If parsing fails before the DER entry can be inspected, verification can still return the general post-sign error.

## Evidence and limitations

- Apple's [XNU cs_blobs.h](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/kern/cs_blobs.h) defines slot 7 and magic `0xfade7172`; it names version `0x20400` for exec-segment fields, not a DER-specific minimum. The version restriction is repository policy.
- [ldid](https://github.com/ProcursusTeam/ldid/blob/af86971ae72ec3ed3d0a699107c4e882324c941b/ldid.cpp) independently sorts full encoded dictionary members and rejects reals. Its encoder emits boolean true as `01`, while this implementation uses DER-canonical `ff` and its decoder accepts only canonical booleans. This difference needs actual Apple and independent interoperability testing; it is not evidence of Apple acceptance.
- OpenSSL `asn1parse` parsed a manually supplied synthetic two-pair DER fixture. It did **not** inspect bytes emitted by Swift or a signed Mach-O, and does not validate Apple's entitlement schema, set ordering, CodeDirectory binding, CMS or platform trust.
- Swift, Xcode, `codesign`, and `ldid` are unavailable in this environment. Added XCTest cases have not been compiled or executed. No current independent signed-artifact inspection, Apple verification, GitHub Actions run, provisioning validation, install or device test was performed. A macOS Xcode run followed by independent slot/hash inspection and authorized physical-device validation is required before broader use.
