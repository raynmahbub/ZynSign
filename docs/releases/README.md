# Release Documentation

The release process for ZynSign will be documented here.

## Current State

**There have been no releases.** ZynSign is in a pre-development state: the
repository contains documentation only, with no source code, no build system, and
no shippable artifact. There is nothing to version, build, or distribute.

No tags and no releases exist.

## Recording Changes

Notable changes are recorded in [CHANGELOG.md](../../CHANGELOG.md) at the
repository root, under `[Unreleased]`, as they are made. That file is the source
of truth for what has changed; this directory documents the process around
turning those changes into a release.

## What Will Live Here

Once there is something to release:

- The release process, step by step.
- Versioning scheme and how versions are chosen.
- Build and packaging steps, including signing of distributed artifacts.
- Release notes conventions.
- Support and deprecation policy.

## Conventions

- Document a release process that has actually been performed and verified. Do
  not write it ahead of the first real release.
- Release artifacts must never contain secrets, credentials, private keys,
  provisioning profiles, or user data. See [SECURITY.md](../../SECURITY.md).

## Index

- [version-strategy.md](version-strategy.md) — the development → alpha →
  beta → release-candidate → stable progression, exit criteria, and the
  current position.
