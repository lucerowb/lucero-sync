# Architecture

How Lucero Sync works inside. For installation and everyday use, see the [README](README.md) or the [user guide](https://lucerosync.lucerowb.com/guide.html).

- [Overview](#overview)
- [Tech stack](#tech-stack)
- [Security model](#security-model)
- [Pairing protocol](#pairing-protocol)
- [Wire protocol (v2)](#wire-protocol-v2)
- [Photo backup](#photo-backup)
- [File and text sharing](#file-and-text-sharing)
- [Storage](#storage)
- [Database schema](#database-schema)
- [Platform notes](#platform-notes)
- [Project layout](#project-layout)
- [Known limitations](#known-limitations)

## Overview

Each device runs the same app, and every device is both a client and a server. While receiving is on, it:

1. **Advertises itself** on the local network over mDNS/Bonjour (`_lucerosync._tcp`).
2. **Runs an HTTPS server** using its own self-signed certificate.
3. **Accepts requests only from paired devices**, each identified by a bearer token. The token is sent only over a connection pinned to that device's certificate.

There is no server, account or relay. If two devices can't reach each other on the LAN, nothing is transferred.

```
 Device A                                         Device B
 ┌─────────────────────┐   mDNS (hint only)    ┌─────────────────────┐
 │ cert A (pinned by B)│ ◀──────────────────▶ │ cert B (pinned by A)│
 │ HTTPS server :8765  │   TLS 1.3, pinned     │ HTTPS server :8765  │
 │ PeerClient          │ ◀══════════════════▶ │ PeerClient          │
 └─────────────────────┘  Bearer token per pair └─────────────────────┘
```

## Tech stack

| Need | Choice | Why |
|---|---|---|
| Framework | **Flutter 3.38+** | One codebase for iOS, Android, macOS, Windows and Linux. `dart:io` provides a real HTTPS server and client with streaming and backpressure. |
| TLS | `dart:io` (BoringSSL) | TLS 1.3 everywhere, with no native code of our own. |
| Certificates | `basic_utils` / `pointycastle` | Generates an ECDSA P-256 key and self-signed X.509 certificate in pure Dart. |
| Photo library | `photo_manager` | Photos (iOS, macOS) and MediaStore (Android). Gives stable IDs and original files. |
| Discovery | `bonsoir` 7 | mDNS/Bonjour on every platform. |
| Database | `sqflite` (+ `sqflite_common_ffi` on Windows/Linux) | SQLite everywhere. |
| QR | `qr_flutter`, `mobile_scanner` 7 | Scanning uses Apple Vision on iOS/macOS and ML Kit on Android. |
| Desktop | `desktop_drop`, `file_picker`, `url_launcher` | Drag and drop, file and folder pickers, opening files. |

## Security model

**Identity.** On first launch each device generates an **ECDSA P-256 key pair** and a **self-signed X.509 certificate**. The SHA-256 of the certificate's DER encoding is the device's **fingerprint**, the same approach as Syncthing device IDs. The key never leaves the device. ([tls_identity.dart](lib/security/tls_identity.dart))

**Transport.** All traffic is HTTPS. Clients use a `SecurityContext` with **no trusted roots** and accept a server only if its certificate fingerprint matches the pinned value, compared in constant time. Every response's certificate is checked again as well. A mismatch aborts the TLS handshake and is shown as "Couldn't verify the other device's identity". ([peer_client.dart](lib/net/peer_client.dart))

**Authorisation.** Pairing exchanges a random **256-bit bearer token** in each direction. Each side stores only the SHA-256 of the token the other side presents, so a leaked database can't be replayed. Tokens are sent only inside the pinned TLS channel.

**Discovery is untrusted.** Anyone on the network can advertise any name. Discovery data (name, address, fingerprint hint) is used only to find devices:
- A paired device's address is updated only if it advertises the pinned fingerprint, and TLS proves the identity anyway.
- A paired device advertising a different fingerprint is flagged **"Identity changed"** and never silently trusted again. This avoids LocalSend's CVE-2025-54792 class of bug.

**What it protects against:** eavesdropping and tampering on the LAN, impersonation of a paired device, man-in-the-middle attacks during pairing (see below), replaying a stolen database, path traversal through file names, and files corrupted in transit (every file is SHA-256-verified before it's saved).

**What it doesn't protect against:** an attacker who controls one of your devices, or who can see the receiver's screen and both approve and confirm a pairing; denial of service on your network; metadata visible on the LAN (device names and the fact that two devices talk).

## Pairing protocol

Pairing is a **numeric comparison with commitment**, like Bluetooth Secure Simple Pairing and ZRTP ([pairing_crypto.dart](lib/security/pairing_crypto.dart), [server.dart](lib/net/server.dart)). It runs over TLS. The client has already seen the server's certificate (`Fs`) and has its own (`Fc`).

```
client                                                     server
  │  GET /v2/info                    (learn Fs from the TLS handshake)
  │  POST /v2/pair/start  {Fc, commit = H(Nc, Fc, Fs)} ──▶
  │                                      ◀── {session, Ns}       (Ns only after the commitment)
  │  show code SAS(Fs, Fc, Nc, Ns)
  │  POST /v2/pair/finish {session, Nc} ──▶ verify commit; show the same code
  │                                         wait for the receiving user: Accept / Don't match
  │                                      ◀── {token_for_client}
  │  user taps "Codes match"
  │  POST /v2/pair/confirm {session, token_for_server} ──▶ store peer (pinned to Fc)
  │  store peer (pinned to Fs)
```

- **Why the commitment matters.** A man in the middle has to present its own certificate, so the two sides compute codes over different `Fs` values. Each side's nonce is fixed before it learns the other's: the client commits to `Nc`, and the server sends `Ns` only after receiving that commitment. The attacker therefore can't search keys or nonces for a colliding code. Each attempt succeeds with probability 10⁻⁶ and needs a person to approve it. Showing a code derived only from fingerprints is not enough; KDE Connect's CVE-2025-32898 was exactly that bug.
- **Both people confirm.** The receiver's Accept and the sender's "Codes match" are both required. Neither side stores the pairing until both have confirmed, and the server only learns the sender's token after the sender confirms.
- **QR pairing** skips the code comparison. The QR code carries the receiver's fingerprint, which the client pins, and a **one-time 128-bit secret** that expires after 10 minutes and proves the scanner saw the screen.
- **Rate limiting:** after 5 failed attempts from an address in 5 minutes, further attempts are refused. At most 8 pairing sessions can be pending at once.

## Wire protocol (v2)

HTTPS. Requests other than `info` and `pair/*` need `Authorization: Bearer <token>` and `x-lucero-device: <id>`. See [protocol.dart](lib/core/protocol.dart).

| Method & path | Purpose |
|---|---|
| `GET /v2/info` | Device ID, name, platform, fingerprint |
| `POST /v2/pair/start`, `/finish`, `/confirm`, `/cancel` | Pairing (see above) |
| `POST /v2/unpair` | Forget the caller |
| `POST /v2/backup/check` | Deduplication pre-check: `exists`, `partial` (with byte offset) or `missing` |
| `PUT /v2/backup/files/<sha256>` | Resumable backup upload (filename, size, created date and offset in headers) |
| `POST /v2/share/offer` | Offer files `{offerId, files:[{id,name,size,sha256}]}` or `{offerId, text}`; waits for Accept |
| `PUT /v2/share/<offer>/<file>` | Resumable shared-file upload |
| `POST /v2/share/<offer>/cancel` | Sender cancelled |

**How uploads resume:**
- The receiver writes to a `.part` file and reports how many bytes it already has.
- The sender sends only the rest.
- Writing past the declared size is rejected.
- The completed file is verified by SHA-256 before it's moved into place. A file that fails is deleted and never saved.

## Photo backup

([backup_engine.dart](lib/backup/backup_engine.dart))

1. **Compare the library with the ledger.** The library is paged by metadata only. Assets not in `synced_assets` for the chosen device are added to a persistent `sync_queue`.
2. **Hash each file lazily.** A file's SHA-256 is computed only when its turn comes, on a background isolate, and cached in the queue row.
3. **Ask the receiver first** (`backup/check`). It looks the file up by SHA-256 **or** by filename + creation date + size, and confirms it's still on disk. If the receiver already has it, it's marked skipped and nothing is sent.
4. **Live Photos are two files**, the still and the paired `.MOV`. The asset only counts as synced once both have arrived.
5. **Reliability:**
   - Network errors pause the queue and retry with backoff from 2 s up to 60 s.
   - While waiting, the app looks the receiver up again over mDNS, but accepts a new address only if it advertises the pinned fingerprint.
   - A file that keeps failing is parked after 5 attempts and can be retried later.

## File and text sharing

([share_sender.dart](lib/share/share_sender.dart))

1. **Hash** each selected file on a background isolate.
2. **Offer** the files. The receiver shows sender, file names, sizes and total, unless that device is set to **auto-accept**. The request waits up to 2 minutes for an answer.
3. **Upload** each accepted file, resuming from the offsets the receiver reports. Transient errors re-offer, which is idempotent per `offerId`, to learn the current offsets.
4. The receiver saves each verified file into the **Received** folder and records the transfer in Activity.

Text is a single offer carrying `text` (up to 100 KB). The receiver shows it with Copy and Open link buttons.

## Storage

| Platform | Photo backups | Received files |
|---|---|---|
| Android | `Pictures/LuceroSync/YYYY/MM` * | `Download/LuceroSync` * |
| iOS | Files › Lucero Sync › Backups | Files › Lucero Sync › Received |
| macOS / Windows / Linux | `~/Pictures/Lucero Sync/YYYY/MM` | `~/Downloads/Lucero Sync` |

\* With "All files access". Without it, files go to the app's external folder. Folders can be changed on every platform except iOS. Existing files are never overwritten; a name clash gets a numbered copy, such as `IMG_0001 (1).HEIC`.

**File-name sanitising.** Path separators, control characters, reserved characters and leading dots are stripped, and names are capped at 200 characters.

## Database schema

SQLite, version 2 ([db.dart](lib/core/db.dart)). Upgrading from v1 drops the old PIN-based pairings, so devices pair again, but **keeps all backup history**, so nothing is sent twice.

```sql
kv(key PK, value)                                    -- device id, name, settings
peers(device_id PK, name, platform, fingerprint, host, port,
      token_out, token_in_hash, auto_accept, last_seen)
synced_assets(peer_id, asset_id PK…, sha256, filename, size, created_at, result, synced_at)
sync_queue(peer_id, asset_id PK…, created_at, filename, size, sha256,
           status, attempts, last_error, enqueued_at, updated_at)
received_files(sha256 PK, meta_key, filename, rel_path, size, created_at, sender_id, received_at)
transfers(id PK, direction, kind, peer_id, peer_name, title, detail, size, status, paths, created_at)
```

## Platform notes

| | Send files | Receive | Back up photo library | QR scan | Notes |
|---|---|---|---|---|---|
| iOS | ✓ | ✓ | ✓ | ✓ Vision | Must stay in the foreground. Needs the Local Network permission. |
| Android | ✓ | ✓ | ✓ | ✓ ML Kit | Set battery use to "Unrestricted"; "All files access" saves to Pictures and Downloads. |
| macOS | ✓ | ✓ | ✓ | ✓ Vision | Not sandboxed (distributed outside the App Store). Ad-hoc signed. |
| Windows | ✓ | ✓ | – | – | Allow it on **Private** networks in Windows Firewall. |
| Linux | ✓ | ✓ | – | – | Needs `zenity` or `kdialog` for file pickers. Allow TCP 8765 and mDNS through the firewall. |

## Project layout

```
lib/
  app/        AppController: wires services together, UI state, prompts
  backup/     photo library scanner and backup engine
  core/       protocol, models, database, identity, platform capabilities
  net/        HTTPS server, pinned client, mDNS discovery
  security/   TLS identity (certificates) and pairing cryptography
  share/      outgoing file and text transfers
  storage/    folders, .part files, sanitising
  ui/         adaptive shell, pages, pairing dialogs, theme
test/         end-to-end protocol tests over real TLS on localhost
tool/         manual demo helpers
```

## Known limitations

- **Keep the app open.** iOS doesn't allow long background transfers, and Android may pause a backgrounded app. Background backup (a `BGProcessingTask` on iOS, a foreground service on Android) is on the roadmap.
- **Android QR scanning uses Google ML Kit**, which sends Google diagnostic data; see the privacy policy. An offline scanner is planned.
- **Desktop photo-library backup** works only on macOS. Windows and Linux are receivers and share files.
- **No relay**, by design: both devices must be on the same network.
- The private key is stored in the app's private data folder, not in a hardware keystore.
