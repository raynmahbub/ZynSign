# Installation and Compatibility

This record separates six statements that are frequently conflated, states
what ZynSign can and cannot establish about each, and records the
installation boundary honestly. It is the authoritative product statement on
installation; where earlier notes disagree with it, this record governs.

## The Six Statements

| # | Statement | Meaning |
| --- | --- | --- |
| 1 | Artifact validity | The package is a well-formed archive with the expected layout and declared metadata. |
| 2 | Signature validity | The code signature on an executable verifies: structure, page hashes, special slots, CMS binding, and the cryptographic check. |
| 3 | Provisioning validity | The provisioning profile is authentic and its policy rules are satisfied for the application, identity, and configuration. |
| 4 | Target-device compatibility | The profile authorizes the device, the platform and OS requirements match, and the device is capable of running the build. |
| 5 | Installation capability | A supported mechanism exists that can deliver the package to the device. |
| 6 | Platform acceptance | The operating system accepts, installs, and launches the application. |

Each statement is independent. A lower-numbered statement never implies a
higher-numbered one: a well-formed package may be unsigned, a verified
signature may sit beside an incompatible profile, a compatible profile may
name a different device, and an installable package on one channel may be
rejected on another. ZynSign reports each statement separately and never
collapses them into "installable" on its own authority.

## What ZynSign Establishes Today

- **Artifact validity (1):** implemented and reachable through the import
  flow — archive validation, bundle discovery, structural classification,
  and declared-metadata extraction.
- **Signature validity (2):** implemented below the interface for single
  Mach-O images and nested code, with independent post-sign verification,
  and composed into the application pipeline, which verifies the bundles
  it produces against its own expectations. No interface consumes it.
  Measured externally (ZS-031): Apple's desktop `codesign` accepts
  ZynSign's single-image signatures and rejects the pipeline's bundles, and
  the signature format fails Apple's documented iOS 15+ requirements. See
  [external-validation.md](external-validation.md).
- **Provisioning validity (3):** implemented below the interface as a
  staged pipeline (container verification, parsing and structural
  validation, policy evaluation). Trust evaluation and authorization stay
  unevaluated; no interface consumes the result.
- **Target-device compatibility (4):** not established. ZynSign does not
  read a trustworthy device identifier on any path, does not assume the
  running device is authorized, and defers device comparison to
  installation-time evidence it does not have.
- **Installation capability (5):** not available. See below.
- **Platform acceptance (6):** never claimed. Only the operating system can
  establish it, and ZynSign does not speak on its behalf.

## Installation Capability

No public application-facing mechanism is known for installing an arbitrary
IPA onto the device running ZynSign. The candidate mechanisms that exist
are external to the application: managed-device installation, over-the-air
distribution with explicit user confirmation, and host-based tooling such
as Xcode or Finder installing to a connected device. None of them is an
in-app install API, and none is implemented or invoked by ZynSign.

Consequences, all deliberate:

- ZynSign never claims an IPA was installed unless a supported
  installation mechanism confirms it. Today that means it never claims an
  installation at all.
- The product implements no private Apple API, no jailbreak functionality,
  no trust bypass, no security circumvention, no fake installation
  success, and no unsupported over-the-air or device-management mechanism.
- Whether installation belongs in a future release is unresolved. A
  negative answer removes installation from scope; it does not affect
  inspection, signing, verification, or packaging.

## Supported Workflow

Until installation scope is decided, the supported workflow ends at a
validated artifact: import, inspect, record in the library, and — once the
signing and packaging stages are complete and reachable — sign, verify
independently, and rebuild the package. Delivery of that package to a
device is the operator's responsibility through whatever channel their
management relationship supports, and ZynSign makes no statement about the
outcome of that step.

## Compatibility Notes

- Supported artifact categories are exactly those the inspection and
  signing stages accept; everything else is refused with a typed,
  structured reason rather than approximated.
- Universal (fat) Mach-O mutation is explicitly unsupported; thin arm64
  images within the admitted synthetic-executable model are the signing
  scope.
- The deployment target is provisionally iOS 17.0 as a build setting; the
  product deployment-target decision remains open, so no claim is made
  about behavior across OS versions.
- Real-world compatibility testing with representative artifacts has not
  been performed. No universal IPA compatibility is claimed, and no
  unauthorized or pirated application is acceptable test material.
