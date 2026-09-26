# Intelligent Signing Presets

Alpha 2 stores reusable signing preferences and offers them when they match.
A preset is a template. It is not a signature, and it is not permission to
sign.

## What a preset stores

A preset stores references and preferences:

- name and kind (Personal Development, Testing Device, Enterprise Workflow, Custom)
- certificate fingerprint, when the user has chosen one
- provisioning-profile identifier and name
- team identifier, when one was recorded
- entitlements slot, verification preference, and export behavior
- whether it is the default
- lightweight history: last used, successful uses, failed uses, and the last
  successful app's bundle identifier and display name
- distribution fields reserved for a later version: scope, revision, schedule,
  and an automation label

It does not store a private key, a password, a `.p12`, profile bytes, or an
output path. The fingerprint points at an identity already in the Keychain.
The profile identifier points at a file already in the profile library.
History stops at the app's name and bundle identifier.

`FileSigningPresetStore` writes a versioned catalog. Schema 1 catalogs still
decode: missing keys become the defaults a new preset uses. This build writes
schema 2 and refuses a newer catalog rather than guessing.

## Matching

`SigningPresetMatcher` ranks presets from a snapshot. The snapshot is built
by `SigningPresetWorkflow` from the identity list and the profile library.
Matching does not read the Keychain and does not sign.

A recommendation exists only when an app is in context and the preset passes
preflight: the certificate is present and usable, the profile file is
present, the team identifiers that are present agree, nothing required has
expired, and the profile covers that app's bundle identifier. Opening an app,
importing an IPA, or asking for a recommendation does not record a use and
does not start signing.

The score is the sum of `PresetRankingWeights`:

| Observation | Weight |
|---|---|
| Certificate usable | +25 |
| Certificate present but not usable | −15 |
| Certificate missing | −20 |
| Profile present | +15 |
| Profile missing | −20 |
| Bundle identifier covered | +30 |
| Bundle identifier not covered | −40 |
| Team identifiers agree | +15 |
| Team identifiers disagree | −30 |
| Expiration healthy | +10 |
| Expired | −50 |
| Previous success on this bundle identifier | +20 |
| Each successful use, up to 5 | +2 |
| Each failed use, up to 5 | −1 |
| Default preset | +5 |

A default flag cannot outrank a preset that actually covers the app. Ties
break by previous success on that bundle identifier, then the default, then
last used, then name.

Suggestions are the same checks said out loud: the profile expires within 30
days, another stored profile for the same team covers the same scope and
expires later, another preset scores at least 15 points higher or passes
preflight when this one does not, or verification is not the preset's leading
preference. The pipeline still verifies every run. A suggestion is not an
action.

## One-tap signing

"Sign with Recommended Preset" and "Ready to Sign" open a confirmation
screen. They do not sign. Confirm and Sign is shown only after preflight
passed and the certificate and profile resolved. `PresetSignConfirmationGate`
refuses a confirmation that was not acknowledged or that does not pass
preflight. The normal signing wizard stays on the app detail screen and on
the signing screen.

## Bulk queue

The professional signing queue splits a selection into apps that pass
preflight and apps that need manual attention. Those sets are disjoint.
`ProfessionalSigningQueue.stage` refuses a request whose identifier is in the
attention set and does not call the runner. `confirmAndStart` is the final
confirmation; attention jobs stay in that state. Cancelling marks waiting
jobs cancelled and does not invent successes.

From the library, Select and then Sign with Preset opens that queue for the
selection. Home and the preset library open the same screen.

## Import

After an import is accepted, the queue row asks whether any preset passes
preflight for that record. When one does, the row offers Ready to Sign. That
button opens the same confirmation screen. A partial match is not described
as ready.

## Where it appears

The feature is gated on `ReleaseTrain.isAvailable(.signingPresets)`, which
Alpha 2 introduces. Settings links the preset library. Home links the library
and the queue. An app's detail screen and the signing screen show the
recommendation beside the wizard, not instead of it.

The builder has six steps. Back changes the step and keeps the draft.
Templates fill a name and preferences. They do not fill a certificate or a
profile.

## Accessibility

Cards and the confirmation summary use the system text styles, so Dynamic
Type and Dark Mode follow the system. Compatibility rows have a spoken
summary that names certificate, profile, expiration, and team. Actions use a
44 point target. The builder, queue, and confirmation screens accept the
keyboard shortcuts the rest of the app uses for cancel and the default
action. On a regular width, the library is a split view so a hardware
keyboard can move between the list and the detail.

## What this version does not do

`PresetDistribution` can record a personal-cloud, team, or shared scope, a
schedule, and an automation label. `PresetAutomation.shouldRun` returns
false, including when the schedule is enabled. A later version can read those
fields. It does not need a second preset type, and this version will not
start unattended signing because the fields are present.
