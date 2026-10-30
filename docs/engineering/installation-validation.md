# Installation validation report

Status: **Blocked / Partially implemented**. There is no verified direct installation in this working tree.

Direct installation requires authenticated transport, proper lockdownd service negotiation and TLS, AFC staging, installation-proxy requests and trustworthy progress. The experimental bridge now refuses TLS requirements it cannot satisfy, bounds response frames and progress count, and closes scoped transports; it remains gated. It does not provide verified upload resumption, bounded network deadlines, installed-application discovery or independent post-install verification. A proxy `Complete` message is a device-reported result, not proof of successful launch or verified installed identity.

The OTA path produces an operator-assisted manifest and `itms-services` link and writes unique local manifest files. It does not upload or host the IPA/manifest, ensure HTTPS trust/reachability, install an app, observe confirmation or validate the resulting installation. Hosting and device trust are external prerequisites.

Before claiming support, test owned signed fixtures on supported physical devices and OS versions: trust/profile expiry, pairing, service TLS, fragmented transfer, disconnect, cancellation, timeout, failure and recovery, proxy progress and terminal status, discovery/identity verification, launch and removal. Test OTA with a reachable trusted HTTPS host separately. Record actual OS/device/channel and each distinct outcome; no device testing occurred here. Do not stage private credentials or test IPAs in public artifacts.
