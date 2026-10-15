# Security policy

## Reporting a vulnerability

Please **don't** open a public issue for security problems. Report them privately through GitHub's [private vulnerability reporting](https://github.com/lucerowb/lucero-sync/security/advisories/new). You'll get a reply within a week.

Include what you found, how to reproduce it, and the affected versions and platforms.

## Security design (v0.2+)

The full design is in [ARCHITECTURE.md › Security model](ARCHITECTURE.md#security-model). In short:

- **Every device has its own key and certificate** (ECDSA P-256, self-signed). Its SHA-256 fingerprint is the device's identity.
- **All transfers use TLS 1.3**, pinned to the paired device's fingerprint. No certificate authorities are trusted.
- **Pairing uses a commitment-based comparison code** that both people confirm, or a QR code that carries the fingerprint and a one-time secret.
- **Paired devices authenticate with 256-bit bearer tokens**, stored only as hashes and sent only over the pinned channel.
- **Every received file is verified** by SHA-256 before it's saved. File names are sanitised.
- **Discovery data is treated as untrusted.** A paired device advertising a different identity is flagged and not trusted.
- **Web access is off by default.** When on, browsers can't pin the certificate, so it relies on a 6-digit code shown on the device (rate limited per address, rotated after repeated failures) that starts a short-lived session. Turning it off, or closing the app, ends every session. Browsers can only download files you explicitly offer.
- **The browser-extension API listens on 127.0.0.1 only**, needs a token issued for a one-time code from Settings, and refuses requests from web pages (`Origin`) and DNS-rebinding attempts (`Host`).

## Threat model

| Protected | Not protected |
|---|---|
| Someone on your Wi-Fi reading or altering transfers | Someone who controls one of your paired devices |
| Impersonating a paired device (spoofed name or address) | Someone who can see your screen and approves a pairing, including confirming the code |
| A man in the middle during pairing (codes won't match; ~10⁻⁶ per attempt, each needing a person) | Denial of service on your network |
| Replaying a stolen app database (tokens are stored hashed) | Metadata visible on the LAN: device names, and that two devices talk |
| Corrupted or truncated files | Malware inside files you choose to accept |
| Writing outside the destination folder | Physical access to an unlocked device |

## Known gaps

- Web access can't pin certificates the way the apps do. Someone on your network who intercepts the browser's first connection could present their own certificate; compare the fingerprint shown in **Settings › Web access** with the one the browser shows before entering the code.

- The private key is stored in the app's private data folder, not in the Secure Enclave or Android Keystore.
- On Android, QR scanning uses Google ML Kit, which sends diagnostic data to Google. It doesn't send the camera image or your files.
- Releases aren't code-signed by a paid Apple or Microsoft developer certificate yet, so verify you downloaded them from the [official repository](https://github.com/lucerowb/lucero-sync/releases).

## Supported versions

Only the latest release gets security fixes. **v0.1.x used plain HTTP with a 6-digit PIN; please upgrade.**
