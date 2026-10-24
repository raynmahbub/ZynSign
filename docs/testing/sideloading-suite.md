# Sideloading suite — what the host run establishes

> Code: `Tests/Host/zynsim/` · Runner: `Scripts/sim/run_unified_suite.py` ·
> Design: [../architecture/sideloading.md](../architecture/sideloading.md)

The suite is an independent implementation of the signing engine, the device
wire protocols and a simulated device, plus the tests that drive them. It is
here so a claim about a signature, a frame or a container can be checked
without Xcode and without a device — and so the Swift implementation has
byte-level expectations to be held to.

```sh
python3 Scripts/sim/run_unified_suite.py
```

The runner executes every host test, then produces real artefacts (a signed
package, an OpenSSL-verified CMS, a container, an installation on the simulated
device) and writes `Reports/unified-engine-report.md`, which is a CI artefact
and not versioned.

## Modules

| Module | What it does |
| --- | --- |
| `zynsim/der.py`, `cms.py` | DER reader/writer and the Apple-format detached CMS `SignedData` (raw RSA through the host `openssl` binary) |
| `zynsim/macho.py` | thin Mach-O parsing, load-command injection, file-type patching, signature-region planning |
| `zynsim/codesign.py` | CodeDirectory (44/52/88-byte headers), special slots, SuperBlob, ad-hoc and certificate modes, independent verification |
| `zynsim/profile.py` | provisioning profiles, entitlement derivation, DER entitlements, PKCS#12 split |
| `zynsim/bundle.py` | IPA read/write, overrides, plugin removal, inner-first signing |
| `zynsim/pairing.py`, `device.py`, `simulator.py` | pairing records, usbmux/lockdownd/AFC/installation_proxy, and the simulated device with real mutual TLS |
| `zynsim/container.py` | guest containers: file-type patch, loader link, ad-hoc signing, metadata, launch plan |

## What it does not replace

The Swift build, XCTest, a physical device, and the local-tunnel entitlement.
Those stay open in the architecture record; this page does not upgrade them.

## Latest run

| Fact | Result |
| --- | --- |
| Host tests | 83 run, 0 failures, 0 errors (`python3 -m unittest discover -s Tests/Host`) |
| Signed package | 3 images, all valid, CMS accepted by `openssl cms -verify` for each |
| Tampering | a flipped byte inside the hashed region rejected |
| Injection | `@executable_path/Frameworks/ZynTweak.dylib` present in the main executable, header padding consumed, signature valid afterwards |
| Pairing | HostID = SHA-1(HostCertificate); host certificate chains to the device root |
| Session | mutual TLS, `QueryType` → `StartSession` accepted |
| Installation | AFC upload → `installation_proxy` → `Complete`, device verified the signature |
| Ad-hoc on stock policy | refused at `VerifyingApplication` |
| Container | 4 images ad-hoc signed and verified; guest patched to `MH_DYLIB`; loader linked; 12 container entries |
| Overrides | bundle identifier, display name and version rewritten; extension identifiers follow the new prefix |
| Profile authorisation | a profile that does not cover the identifier is refused before signing |

Re-run the script for the current numbers; this table records the state at the
commit that introduced it.
