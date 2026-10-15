# Security policy

## Reporting a vulnerability

Please **don't** open a public issue for security problems. Report them privately through GitHub's [private vulnerability reporting](https://github.com/lucerowb/lucero-sync/security/advisories/new). You'll get a reply within a week.

Include what you found, how to reproduce it, and which versions and platforms are affected.

## Threat model

Lucero Sync is designed for **trusted home networks**. It's useful to know what it does and doesn't protect against:

| Protected | Not protected |
|---|---|
| Other devices on the network can't upload files without the receiver's 6-digit PIN. | Traffic is **plain HTTP**. Someone who can sniff your Wi-Fi can see the PIN and the photos in transit. |
| Filenames are sanitised, so a sender can't write outside the receiver's folder. | The PIN is short and there's no rate limiting, so it can be brute-forced by someone on the same network. |
| Every received file is verified by SHA-256 before it's saved. | Anyone with access to an unlocked phone can open the app and read the PIN. |
| Nothing is sent to the internet. | |

The planned fix for the gaps on the right is TLS with a self-signed certificate pinned through the pairing QR code, plus a longer pairing secret. Contributions are welcome.

## Supported versions

Only the latest release gets security fixes.
