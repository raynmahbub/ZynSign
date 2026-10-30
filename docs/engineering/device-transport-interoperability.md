# Device transport interoperability report

Status: **Blocked**. Review of the current working tree, not a device test or a full security audit. Production `NetworkDeviceBridgeTransport.supportsAuthenticatedSessions` remains false.

## Current implementation and gaps

- Pairing import requires nonempty certificate/key data, a recognized HostID form and now a nonempty, control-character-free SystemBUID. It does **not** parse and match the pairing certificate/private key, validate the device certificate or prove an actual pairing. A UUID HostID is not a certificate fingerprint.
- Production transport does not implement the pairing-identity TLS handshake or verify device identity. It discovers the first mux device, not necessarily the device named by the record. It cannot safely reconnect or authenticate lockdownd or service sessions. A TCP connection is not authentication.
- The bridge starts a lockdownd session and now refuses both a requested in-place session TLS upgrade and service-specific TLS instead of ignoring those requirements. It closes connection scopes on success and failure. Session shutdown, connection setup failure behavior, task cancellation during network callbacks, bounded I/O timeouts and reconnection remain incomplete. Unsupported services remain blocked, not successful.
- USBMux header and network-order port, AFC length/transaction framing and property-list framing have local implementations. The AFC upload is chunked and validates replies; installation-proxy progress is now bounded. These Swift paths and their relationship to actual device traffic are **unverified**. The Python host simulator uses a different AFC subset and does not prove interoperability.
- Network.framework's send completion reports acceptance of the submitted content, but end-to-end delivery and interrupted writes remain unverified. Deadlines, cancellation races and partial connection termination need dedicated tests and design before enabling the gate.

## Evidence and next steps

New Swift tests cover BUID rejection, fragmented and truncated reads, malformed lengths, TLS-required refusal and cleanup; **not run**. Host simulator tests passed but are not Swift/device tests. On macOS, compile and run all XCTest; then use owned pairing material on a supported device in a controlled environment to test TLS certificate/key association, session and service sequencing, fragmented I/O, mismatched tags, disconnects, timeouts and cleanup. Never upload pairing records, keys or certificates in CI logs/artifacts. Until this evidence exists, do not enable production connections.
