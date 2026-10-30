# Feature comparison: ZynSign and related iOS apps

**Snapshot: 2026-10-30. Status: Partially implemented comparison, not an exhaustive device audit.**

This compares the **current working tree**, which includes uncommitted redesign changes, with published project READMEs and a limited inspection of Ksign's source tree. Competitor entries are project descriptions or source-presence observations, **not independent tests**. A README claim can differ by build, device, entitlement, account or release. We did not install any of these apps or enumerate every screen, historical release, option or localization. Unknown means not established here, not that a capability is absent. No numeric parity score is defensible from these sources.

### Legend

- **D** — described in the project's README or project description at the snapshot below.
- **S** — a related source path exists, but behavior was not verified.
- **?** — not established from reviewed material; not a negative claim.
- **P** — ZynSign has a relevant implementation or surface, but full behavior, equivalence or Apple-platform verification is incomplete.
- **E** — ZynSign has experimental code only, without established end-to-end capability.
- **B** — ZynSign path is blocked, deliberately disabled or has a known significant limitation.
- **O** — ZynSign feature not established in reviewed code; further audit required.

**A ZynSign P/E/B is never a claim of working parity.** Debug and Release availability can differ: `docs/product/FEATURE_STATUS.md` records the alpha.3 feature gates. No Xcode, iOS simulator or physical-device test was run for this working tree. Some historical Apple validation exists, but is not evidence for the current patch.

## Source snapshots

| Label | Project / inspected reference | Evidence boundary |
|---|---|---|
| F | [Feather `7078b05`](https://github.com/claration/Feather/tree/7078b053c0af262809a48e4d3898d42b0d35fedf) | README describes signer, installer, AltStore repos, signing options and ElleKit tweaks. |
| FP | [FeatherPlus `9af4713`](https://github.com/TomerGamerTV/FeatherPlus/tree/9af4713cf6d5c1db3a1f24ddabca53008a46ac5a) | Fork README describes inherited Feather capabilities; repository description says backup/restore between FeatherPlus apps via Documents. Exact backup scope was not tested. |
| K | [Ksign `c14dedc`](https://github.com/Nyasami/Ksign/tree/c14dedc0c9dadb669021cce83435b14f781b8412) | README identifies a Feather-based signing app; selected paths, not a full functional audit, were inspected. |
| R | [RyukSign `844466c`](https://github.com/faroukbmiled/RyukSign/tree/844466cee6f212291913ba5216f8f19a9c016dea) | README describes inherited signing plus tweak manager, transfer, downloads and install approaches. |
| LC | [LiveContainer `9108ae6`](https://github.com/LiveContainer/LiveContainer/tree/9108ae624ea001f7d7696d48407f890b48fa2653) | README describes an app host, not simply an IPA installer; also lists a combined LiveContainer+SideStore build. |
| SS | [SideStore `cd26085` (`develop`)](https://github.com/SideStore/SideStore/tree/cd260851ae99bf1fc946b123db24e89c8cd21dc6) | README describes Apple-ID signing, VPN/proxy-based installation and periodic refresh. `develop` is not necessarily a released build. |

### 1. Signing, identity and installation

| Capability | F | FP | K | R | LC | SS | ZynSign current working-tree observation |
|---|---|---|---|---|---|---|---|
| IPA import and library | D | D | S | D | D | D | **P** — import hub, library and archive inspection exist; real-device flow not tested. |
| Imported P12 + provisioning profile | D | D | S | D | ? | ? | **P** — certificate/profile import and selection exist; trust, matching and device compatibility need validation. |
| Sign apps on device | D | D | D | D | D | D | **B** — pipeline exists, but historical Apple validation rejected the synthetic application bundle, identified iOS-format gaps and says real binaries were refused by that tested signer. This tree is unverified. |
| Nested frameworks / app extensions correctly signed | ? | ? | ? | ? | ? | ? | **B** — nested signing code exists but historical external validation rejected the tested nested framework; device compatibility is unproven. |
| Customize signing / app metadata | D | D | S | D | ? | ? | **P** — presets, metadata and signing options exist; exact option-for-option parity and Apple acceptance unverified. |
| Entitlements handling | ? | ? | ? | ? | ? | ? | **P/B** — profile-derived XML path and inspection exist; DER emission is explicitly refused in the pipeline. |
| In-app or device-local install | D | D | S | D | ? | D | **B** — ZynSign's direct bridge transport is blocked; OTA handoff only produces artifacts and does not host or install. |
| Local HTTPS / `itms-services` installer | S | D | S | D | ? | ? | **O** — a generated manifest/link exists; no integrated trusted HTTPS installer. LAN HTTP/WebDAV is a different service. |
| Pairing-file based direct delivery | S | D | S | D | ? | D | **B** — pairing import and protocol code exist, but authenticated TLS and correct framing are not complete and production connect is blocked. |
| Apple ID provisioning / account workflow | ? | ? | ? | ? | ? | D | **P** — account service and screens exist, but real authentication, provisioning, authorization and installation are not device-verified. |
| Periodic app refresh | ? | ? | ? | ? | D (combined build) | D | **B** — no verified equivalent; no claim of automatic refresh. |
| Batch signing / installation | ? | ? | S (bulk install paths) | ? | ? | ? | **P/B** — signing queue exists; batch installation is not established. |
| Install outcome detection | ? | ? | S | ? | ? | ? | **B** — installation ledger is user-confirmed, not device observation. |

Historical findings: [`external-validation.md`](../architecture/external-validation.md), including D1–D8, are based on earlier macOS runs, not this working tree. Local verification is not platform acceptance. ZynSign's manifest handoff is documented in [`installation-compatibility.md`](../architecture/installation-compatibility.md).

### 2. Sources, downloads, files and backup

| Capability | F | FP | K | R | LC | SS | ZynSign current working-tree observation |
|---|---|---|---|---|---|---|---|
| AltStore-style sources / browsing | D | D | S | D | ? | D | **P** — AltSource-compatible catalog parser and storefront exist; complete source-format parity and live interoperability unverified. |
| Download queue and progress | ? | ? | S | D | ? | D | **P** — foreground queue, progress, validation and retry/resume code exist; Apple URLSession behavior untested. |
| Background downloads across suspension/relaunch | ? | ? | ? | D (background while using other apps) | ? | ? | **B** — foreground URLSession, no claimed relaunch support; silent-audio workaround removed. R's README does not itself establish relaunch behavior. |
| App/source update checks | ? | ? | ? | D | ? | D | **P** — source comparisons and ignore controls exist; matching is based on local library records, not a general OS installed-app inventory. |
| Browser file upload and WebDAV | ? | ? | S (files views) | D | ? | ? | **P** — foreground LAN HTTP workspace exists, with mandatory Basic authentication, a bounded path policy, protected workspace folders and cross-origin refusal. The link is still plaintext HTTP; overwrite is currently refused; device and real-client testing pending. |
| General file management / archives | ? | ? | S | ? | ? | ? | **P** — Files and ZIP/DEB tools exist; extraction and compatibility remain under review. The new bounded DEB decoder is untested on Apple platforms. |
| Portable app/workspace backup | ? | D (repository description) | ? | ? | D (container management; not equivalent backup) | ? | **P** — encrypted allowlisted recovery backup exists, but excludes keys, profiles and several categories; cross-device and full-restore testing pending. |
| Private-key export / migration | ? | ? | ? | ? | ? | ? | **B / intentional boundary** — recovery backup excludes private keys and profiles; reimport separately. Not a claim that other apps do or do not export secrets. |
| Live Activities / Dynamic Island | ? | ? | ? | D (downloads) | ? | ? | **P** — signing-oriented ActivityKit wrapper exists; widget composition and download-specific parity/device behavior not established. |
| App sources, update metadata, privacy | D | D | S | D | ? | D | **P** — local source metadata and local journal policy exist; full dependency/network/analytics audit is unfinished. |

ZynSign backup scope: [`backup-recovery.md`](../architecture/backup-recovery.md). Download and WebDAV limitations: [`security-cleanup-report.md`](security-cleanup-report.md).

### 3. Tweaks and guest runtime

| Capability | F | FP | K | R | LC | SS | ZynSign current working-tree observation |
|---|---|---|---|---|---|---|---|
| `.dylib` / `.deb` tweak support | D | D | S | D | D (external tweaks) | ? | **P** — tweak library, parser and injection paths exist; bounded DEB decoding and on-device injection remain unverified. |
| Framework / bundle / app-extension tweaks | ? | ? | ? | D | ? | ? | **P** — staging paths exist; complete format/loader/device interoperability unknown. |
| Tweak dependency and Mach-O inspection | ? | ? | ? | D | ? | ? | **P** — inspection code and UI exist; exact parity unverified. |
| Run guest apps without normal separate installation | ? | ? | ? | ? | D | ? | **E** — ZynSign can stage a patched guest and probe a dynamic library; this is not a verified app launch. |
| Guest data profiles / multiple containers | ? | ? | ? | ? | D | ? | **E** — separate directories and profile operations exist; they do not establish sandbox isolation or reliable multi-account behavior. |
| Home-screen guest launch | ? | ? | ? | ? | D | ? | **E** — WebClip/deep-link preparation exists; an actual guest launch is not established. |
| Guest multitasking / native windows / PiP | ? | ? | ? | ? | D (requirements apply) | ? | **O** — equivalent not established. |
| JIT for guest apps | ? | ? | ? | ? | D (external enabler may be needed) | ? | **B** — JIT is not provided; no workaround or device capability claimed. |
| Guest share/open-in, app hiding, picker and notification fixes | ? | ? | ? | ? | D | ? | **O** — equivalent not established; deep-link routing is not proof of these features. |
| SideStore + LiveContainer integrated refresh | ? | ? | ? | ? | D (combined build) | D (refresh) | **B** — guest staging and SideStore-like refresh are not integrated or validated. |

LiveContainer explicitly documents compatibility limitations and JIT/multitasking prerequisites. ZynSign's `dlopen` probe can execute guest initializers in the host process; it must not be presented as normal launch or isolation.

## Product differences and release priorities

1. **Core blocker:** get a real signed IPA that independently verifies and installs/launches on supported devices. The historic `codesign` finding is stronger evidence than source/UI feature counts.
2. **Choose and prove an installation channel:** OTA hosting with appropriate HTTPS trust and lifecycle or an authenticated, fully framed pairing-based path. A generated manifest or a connected socket alone is not installation.
3. **Complete security first:** validation of bounded DEB decompression, safe archive/filesystem writes, URLSession resume and retry behavior, and confidentiality/authentication of local transfer.
4. **Test full workflows:** source compatibility, real certificates/profiles, tweaks, backup/restore, cancellation, failure recovery and UI on the supported iOS/device matrix.
5. **Treat guest hosting and free-account refresh as separate experimental programs:** they have distinct process, entitlement, VPN, pairing, JIT, lifecycle and compatibility requirements. No promise of universal app compatibility, isolation, unlimited slots or seamless refresh.
6. **Audit every competitor release and option before calling this a complete feature inventory.** README descriptions and file names alone cannot support an exhaustive matrix or prove exact feature parity.

## Licensing

ZynSign is MIT-licensed. The reviewed Feather, FeatherPlus, Ksign and RyukSign repositories report GPL-3.0; LiveContainer and SideStore report AGPL-3.0 in GitHub metadata at the snapshot. Submodules and dependencies may carry additional terms or exceptions. Review licenses and notices before adopting code, assets or linking a dependency; comparing public behavior does not itself authorize copying code.
