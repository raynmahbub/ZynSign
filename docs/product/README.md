<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../../Assets/Brand/Logo/logo-lockup-dark.svg">
    <img src="../../Assets/Brand/Logo/logo-lockup.svg" alt="ZynSign" width="260">
  </picture>
</p>

# Product Documentation

What ZynSign is for, who it is for, and — just as important — what it
deliberately does not do.

## Start here

| Document | Question it answers |
|---|---|
| [UNIQUE_VALUE_PROPOSITION.md](UNIQUE_VALUE_PROPOSITION.md) | Why does this exist, and for whom? |
| [WHAT_DOES_NOT_EXIST.md](WHAT_DOES_NOT_EXIST.md) | Which capabilities are wired, and which are claimed *never*? |
| [ROADMAP-v3.0-nova.md](ROADMAP-v3.0-nova.md) | Where is it going? — v3.0 “Nova”, the complete iOS signing platform, mapped onto the architecture |

## The one-paragraph version

ZynSign is an on-device iOS signing platform: import an application package,
inspect it, sign it with your own certificate and profile, and deliver the
result — entirely inside the app sandbox, with no desktop helper, no remote
service, and no analytics. Its differentiator is not that signing happens,
but that the user is never lied to: every state says what was verified, every
failure says what to do next, and the [anti-roadmap](WHAT_DOES_NOT_EXIST.md)
is a shipped document, not a promise.

## The three nevers

These are recorded decisions, reviewed in ADRs — not missing features:

1. **In-app installation** — no delivery mechanism is composed; signed output
   is handed off (`Documents/Signed`, OTA manifest, MDM, host tooling). See
   [../architecture/installation-compatibility.md](../architecture/installation-compatibility.md).
2. **Pairing / JIT / Mux** — would require private entitlements
   (`lockdown`, `MobileDevice`, `get-task-allow`). Feasibility record:
   [../architecture/pairing-jit-mux-feasibility.md](../architecture/pairing-jit-mux-feasibility.md).
3. **Off-device analytics** — no Kit, no SDK, no endpoint, no identifier. The
   activity journal is on-device and never transmitted.

If any screen claims one of these as working, the screen is wrong — file an
issue with the exact `ZynSignError` code.
