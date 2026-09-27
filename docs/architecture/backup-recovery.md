# Backup & Workspace Recovery (Beta 2)

## Trust boundary

The Recovery Center exports an explicit allowlist from Application Support:
`catalog.json`, `Artifacts/<UUID>.ipa`, `Organization.json`, `Preferences.json`,
`ImportHistory.json`, `SigningHistory.json`, and `Exports.json`. The latter
contains **references**, not signed output bytes. Library packages are the
user's imported ZIP/IPA files, and are included only when Library is selected.
Search and download history currently have no portable store and are **not**
claimed as backed up. Signing identities, private keys, provisioning profiles,
queue setup/profile copies, diagnostic logs, cached artifacts, and temporary
workspaces are never exported. On a different device, re-import signing
credentials and provisioning profiles separately. The backup passphrase is
never persisted. Files are kept in the private app container until the user
exports them using the system share sheet.

## Format 1

`ZYNSBK01` (8 ASCII bytes) + 16-byte random salt + framed AES-256-GCM
ciphertexts. Each frame has a four-byte big-endian length followed by the
combined 12-byte nonce, ciphertext and 16-byte authentication tag. The first
frame is an encrypted JSON manifest (format version, date, allowlisted paths,
category, byte count, SHA-256 and preview counts); subsequent frames are up
to 1 MiB of each file in manifest order. An empty file has no content frames
and the SHA-256 digest of empty data. PBKDF2-HMAC-SHA256 uses 250,000 rounds
and derives 32 bytes from the user's passphrase and the random salt. GCM
nonces are generated independently for each frame by CryptoKit. Future
versions must reject unknown formats and add explicit conversions, not guess
at a changed payload shape. IPA is already ZIP-compressed, so the builder
does not recompress it and avoids an extra decompression pass on restore.

The builder first streams source checksums, then encrypts in bounded chunks
and checks that the source has not changed; it verifies the entire finished
archive before publishing a uniquely named file. Verification authenticates
all frames, checks lengths and digests, rejects unexpected paths, versions,
trailing bytes and duplicate entries, validates catalog and collection
schemas, checks every referenced package's byte count and fingerprint, and
compares preview counts. A failure removes only the unpublished temporary
file; existing backups remain intact. An exported copy has no dependency on
local history metadata.

## Restore / rollback

The wizard copies a Files-provider URL into the private container while it
holds its security scope. Verification and preview precede choosing a scope.
A second full extraction goes into a uniquely named, file-protected staging
directory. The pending plan records the selected categories and checksums;
no running store is modified. At the **next cold launch**, before constructing
any cached preferences, library or queue store, the plan is rechecked.
Affected original files are moved to a retained rollback directory before
installing verified copies. An interrupted install restores its originals
from that directory before retrying; failures attempt rollback and leave the
pending plan plus an error notice. A successful install checks every copied
file again, then removes the pending marker and reports completion. The user
may explicitly delete previous restore snapshots only after success.

Selective restore **replaces** selected categories; it is not a merge.
Collections may reference records absent from a library-only restore, so
users should normally select both together. The existing signing queue is
not imported or marked complete: it uses its own restart recovery policy,
which marks interrupted runs failed and retries only when the source and
configuration survive. The import hub retains its own interrupted-import
journal. Recovery Center links to the live job inspection and safe retry
controls. Temporary storage cleanup remains explicit and honors the
storage manager's retention policy.

## Constraints and follow-up

This build does not support automatic backups, cloud destinations, key export,
search/download history portability, merging with an existing library, or
resuming a signing operation mid-run. A passphrase cannot be reset. The
verification scratch directory is removed after checking; a device/process
failure during checking may leave a hidden scratch directory in private app
storage. The on-device history index is lightweight and not portable. Backups
are built serially on an actor with one MiB frame buffers; enumerating a large
library or verifying a backup may take time but is not performed on the UI
actor. Large libraries require enough free space for a backup plus staging
and optional pre-restore snapshots.
