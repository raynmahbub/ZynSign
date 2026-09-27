# Store & network resilience

A network failure that can only be tested by waiting for one is a network
failure nobody tests. Every case below is reproduced through an injected
`RepositoryHealthTransport`, so it runs on a device, in a test, and in CI
without reaching a host.

## The cases

| Case | Reproduced as | What must be true |
|---|---|---|
| Offline | A transport that throws `NSURLErrorNotConnectedToInternet` | The probe finishes, never throws, and reports `offline` with that reason |
| Slow | A transport that waits past the 800 ms policy threshold | The latency is measured and the source is reported `slow`, not failed |
| Failing source | A transport that answers 500 | Reported `offline` **with its status code** |
| Non-JSON body | A transport that answers 200 with HTML — the captive-portal case | Refused as `not json` rather than parsed |
| Truncated body | A transport that sends fewer bytes than it declares | Refused, never yielding a half-populated source list |
| Partial transfer | The same short body, read as a download | Ends in a reportable state the Downloads screen can offer to retry |
| Download workspace | The downloads directory's location | Inside the user's Documents, so transfers are reachable and shareable |

The contract being tested is not that the fetch succeeds — it cannot — but
that a failure becomes **a state the interface renders**, with a category a
user can act on, and never an exception the screen was not built for.

## The category must not leak

A platform error's own text can carry a host name, a path or a
credential-shaped fragment, and the probe's result is shown in the interface
and written into reports. `RepositoryHealthProbe.transportErrorCategory`
therefore reduces every transport failure to one word from a closed
vocabulary:

`timeout` · `offline` · `connection lost` · `cancelled` · `host not found` ·
`tls` · `bad response` · `transport`

Enough to tell an offline device from a timeout; never enough to leak what the
network said.

## What is not tested here

- **The background session's own resume behaviour.** That needs a real
  transfer. `DownloadsResilienceTests` covers what is checkable without one:
  that transferred packages land inside Documents, that the directory is
  created when asked for, and that pausing or cancelling an identifier the
  service is not tracking is a no-op rather than a trap — which is what a
  stale identifier after an interrupted run looks like.
- **A real repository.** ZynSign ships no repository of its own; sources are
  the user's.

## Manual pass

1. Put the device in aeroplane mode and open App Store → Sources. Every source
   shows a health state; nothing spins, nothing shows a blank list, nothing
   throws.
2. Add a source that answers 404, and one whose body is not JSON. Both are
   reported rather than parsed.
3. Start a download, background ZynSign, return. The transfer either resumed
   or reported itself as interrupted with a retry.
4. Start a download, then pause it from the Downloads screen, then resume.
5. Fill the device until the storage guard refuses a copy, then confirm the
   refusal names what was needed and what was free (see
   [resource-resilience.md](resource-resilience.md)).
