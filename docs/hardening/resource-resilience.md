# Low storage & memory

ZynSign must fail safely rather than corrupt its workspace — which is a
stronger claim than "it does not crash". A refusal has to arrive **before** a
byte is written, has to say what it needed, and has to leave the library
exactly as it was.

## What the Lab executes

| Check | What it establishes |
|---|---|
| Insufficient storage is refused | A working copy larger than the free space is refused by `ImportStorageGuard` as a storage failure the user can act on — before the copy, with the requirement named |
| Concurrent copies respect headroom | The second of two 400 MB copies is refused in 1 GB: outstanding claims and the 100 MB of headroom are counted before another copy is permitted |
| Memory spike and release | A bounded 32 MB spike is taken and released, and the resident set settles back near its baseline |
| Large import | A package at ordinary large-application size is read, structured and planned inside the large-import benchmark |
| Workspace accounting | Every storage category is measured, and imported applications are never counted as reclaimable |

## The rules a refusal follows

1. **Before the write.** The storage guard is the only place a copy is
   permitted, and it decides with the platform's own free-space figure.
2. **With numbers.** The failure names what the copy needed and what was
   available. "Not enough space" without figures is not a recovery.
3. **Retryable.** Freeing space and trying the same file again can succeed, so
   the failure says so.
4. **Nothing partial.** The refusal arrives before a byte is copied, so there
   is nothing to clean up.

## Cleanup

The Lab measures cleanup's *scope* and never runs one. A validation tool that
deletes what the user made is a liability.

What is true of cleanup, and checked:

- Cleanup may only ever reach ZynSign's own scratch: the temporary directory,
  or the workspace under Application Support. The Lab refuses a build in which
  a temporary location sits inside Documents.
- Imported applications are never counted as reclaimable.
- Caches and the temporary workspace live where the platform already excludes
  them from backup.

What is not checked here, because it belongs to a person: that a cleanup on a
device full of half-finished work leaves the library intact. The protocol is
in the [QA checklist](release-blockers.md): fill the device, interrupt an
import at each stage, and confirm the library is untouched and the workspace
is reclaimable.

## Memory

The Lab measures the process's own resident set as the kernel reports it, and
the device's thermal state. It allocates 32 MB, releases it, and checks the
footprint settles. It does not:

- raise a memory warning — an app cannot honestly simulate the system asking
  it to free memory;
- claim a peak-footprint figure — that needs Instruments during a real signing
  run;
- compare a simulator's accounting with a device's.

If the retained spike exceeds the benchmark, the next step names the two
places that grow: `AppIconExtraction`'s cache and the library index.

## The one thing that must never happen

Workspace corruption. No check in this pack is more important than that: a
shortage, a cancellation, a background suspension or a memory warning may stop
the work, but it may never leave the library, the export catalog or the
signing journal half-written. Every refusal path in ZynSign is written to
decide before it mutates, and the regressions freeze that behaviour.
