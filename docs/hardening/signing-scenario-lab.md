# Signing Scenario Lab

Eight package shapes, built from nothing and read back through the production
pipeline — twice each, because a result that cannot be reproduced is not a
result.

This is the executable half of the signing matrix. It does not sign: an actual
signature needs an identity and a profile only the user has, and the Lab
reports that instead of staging a fake one. What it verifies is everything
that happens *before* the signature: that the package is understood, that the
code inside it is found, and that a signing order was justified.

## How a scenario runs

1. `LabPackageFactory` assembles the entries — an information file, one
   executable per bundle, resources, and the nested code the scenario is
   about. Identifiers all sit under `com.zynsign.lab`, so a Lab artifact is
   unmistakable in a log.
2. `ZipArchiveWriter` serializes them — the same writer that produces a signed
   package, so the container is the real thing.
3. The bytes are written to the Lab's scratch directory, opened with
   `ZipArchiveReader`, and taken through `IPAStructureValidator`,
   `ApplicationMetadataReader`, `NestedCodeDiscovery` and
   `NestedSigningPlanValidator`.
4. Steps 1–3 run a second time, and the two outcomes are compared.

Every byte in every package is generated in the Lab. Nothing real is committed,
downloaded, or referenced.

## The images

`LabMachOImage` builds a thin `arm64` Mach-O: a 64-bit little-endian header
and, where the scenario calls for one, a code-signature load command over a
SuperBlob the Lab writes itself. The image is structural — it exists so the
production parser, the discovery rules and the plan validator see the *shape*
of a real executable. It is not a signed binary, and the Lab never claims it
is: the check reports the state the production inspector establishes.

The parser is the judge. If it refused the Lab's image, every nested-code
scenario would be measuring the wrong thing, so two unit tests assert the
image parses as thin `arm64` Mach-O, with and without a signature region.

## The eight scenarios

| Scenario | Shape | Expectation |
|---|---|---|
| Simple app | One bundle, one executable, resources, an embedded profile and a resource seal | Valid; a plan with no nested items |
| App with frameworks | Plus `Frameworks/Core.framework` and `Frameworks/libhelper.dylib` | Valid; two nested items; the plan validates |
| App with extensions | Plus `PlugIns/WidgetExtension.appex` | Valid; one nested item; the plan validates |
| Multiple bundles | Two `.app` bundles directly in `Payload` | **Ambiguous**, and discovery refuses rather than choosing |
| Unsigned app | One bundle, no signature artifacts at all | Valid; no existing signature established |
| Already signed app | A signature region, a resource seal, an embedded profile | Valid; the existing signature's state is reported, whatever it is |
| Large IPA | One bundle and 384 resources, about 12 MB | Valid, within the large-import benchmark |
| Edge-case bundle layout | Deep nesting, non-ASCII names, a `.app` nested inside the bundle, an archive artifact | Valid; the nested bundle is reported, not planned |

## How a result is judged

A scenario fails when:

- two runs disagree — the same package must produce the same outcome twice;
- the fixture wrote fewer entries than it declares — a fixture and its
  expectation have drifted apart;
- the structure was classified differently than the scenario declares;
- discovery produced a plan where it must refuse, or refused where it must
  produce one;
- the plan validator refused a plan for a shape that should plan cleanly.

A scenario warns when:

- discovery located an item it could not establish as signable code — an
  ordinary package shape is not being recognised;
- the number of nested items disagrees with what the fixture declares.

The second warning is deliberately a warning and not a failure. It means the
fixture's declaration and the production parser have reached different answers,
which is worth a maintainer's attention before it is worth a red row: the
resolution is a decision about which is right, recorded here, not a verdict a
device can make on its own in the moment.

## What a pass does not mean

A passing scenario means the package was read deterministically through the
production boundary, and — where the shape calls for it — a signing order was
justified. It does **not** mean:

- that a signature was produced, or would be accepted by iOS;
- that the profile or identity the user will choose is valid;
- that the package would install.

Every scenario's check says as much in its "what was verified" line.
