# Architecture

How Lucero Sync works internally: the stack, the permissions it needs, the sync database, the deduplication rules and the wire protocol. For installation and usage see the [README](README.md) or the [user guide](https://lucerosync.lucerowb.com/guide.html).

## Tech stack: Flutter

| Need | Choice | Why |
|---|---|---|
| Framework | **Flutter 3.38+** | `dart:io` ships a real `HttpServer`/`HttpClient` with streaming, backpressure and append-mode file sinks, so the receiver needs no native server module. React Native has no server built in, so it would need a third-party native TCP/HTTP module. |
| Photo library | `photo_manager` | One API over PHAsset (iOS) and MediaStore (Android). Gives stable asset IDs and the **original** file (HEIC/RAW/MOV). |
| Sync state | `sqflite` | SQLite on both platforms. |
| Hashing | `crypto` + `Isolate.run` | Streams SHA-256 on a background isolate so multi-GB videos don't freeze the UI. |
| Discovery | `bonsoir` (mDNS/Bonjour) + QR (`qr_flutter`, `mobile_scanner`) + manual IP | Discovery finds the device automatically. The QR code carries the PIN, so pairing takes one scan. Manual IP is the fallback. |
| QR scanning | `mobile_scanner` 7 | Uses Apple's Vision framework on iOS, entirely on the device. On Android it uses Google ML Kit, which sends Google diagnostic data (see the privacy policy). Replacing it with an offline decoder such as zxing is on the roadmap. |
| Keep-alive | `wakelock_plus` | Keeps the screen on while syncing or receiving (see Limitations). |

## Native permissions

### iOS (`ios/Runner/Info.plist`)
| Key | Purpose |
|---|---|
| `NSPhotoLibraryUsageDescription` | Read the Camera Roll (sender) |
| `NSLocalNetworkUsageDescription` | iOS 14+ local-network prompt. Without it, every LAN connection fails silently. |
| `NSBonjourServices` = `_lucerosync._tcp` | Allows mDNS browse/advertise |
| `NSAppTransportSecurity › NSAllowsLocalNetworking` | Allows plain HTTP to LAN hosts |
| `NSCameraUsageDescription` | QR pairing |
| `UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace` | Shows received files in the Files app (iOS as receiver) |

### Android (`android/app/src/main/AndroidManifest.xml`)
| Permission | Purpose |
|---|---|
| `INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`, `CHANGE_WIFI_MULTICAST_STATE` | HTTP server and mDNS |
| `READ_MEDIA_IMAGES`, `READ_MEDIA_VIDEO`, `READ_MEDIA_VISUAL_USER_SELECTED`, `READ_EXTERNAL_STORAGE` (≤32) | Android as sender |
| `MANAGE_EXTERNAL_STORAGE` | Write to `Pictures/LuceroSync` so files show up in Gallery. Fine for a sideloaded personal app; Google Play would reject it. Without it, files go to the app-private external dir. |
| `CAMERA` | QR pairing |
| `android:usesCleartextTraffic="true"` | Dart's HttpClient follows Android's cleartext policy |

## Sync-state database schema

The same SQLite file is used on every device. A device only uses the tables for the role it is playing.

```sql
-- Sender: paired receivers (token = receiver PIN)
peers(device_id PK, name, host, port, token, last_seen)

-- Sender: the "already synced" ledger, per receiver
synced_assets(
  peer_id, asset_id,             -- PK; asset_id = PHAsset localIdentifier / MediaStore id
  sha256, filename, size, created_at,
  result,                        -- 'stored' | 'skipped' (receiver already had it)
  synced_at)

-- Sender: persistent work queue (survives app kills → resume)
sync_queue(
  peer_id, asset_id,             -- PK
  created_at,
  filename, size, sha256,        -- filled lazily on first attempt
  status,                        -- pending | uploading | failed
  attempts, last_error, enqueued_at, updated_at)

-- Receiver: everything committed to the destination folder
received_files(
  sha256 PK,
  meta_key,                      -- lower(filename)|created_ms|size  (indexed)
  filename, rel_path, size, created_at, sender_id, received_at)
```

## How dedup works

1. **Sender diff (cheap).** The library is paged by metadata only, and any asset whose `asset_id` is in `synced_assets` for that receiver is skipped. Everything else goes into `sync_queue` with `INSERT OR IGNORE`, so rescanning is idempotent.
2. **Lazy hash.** A queued item is SHA-256 hashed only when its turn comes. The hash is cached in the queue row, so a resume doesn't hash it again.
3. **Receiver pre-check** (`POST /v1/check`). The receiver looks the file up by `sha256` **or** `meta_key` (filename + creation date + size) and confirms it is still on disk.
   - `exists`: the sender records it as `skipped`. Nothing is sent.
   - `partial`: returns the byte offset of the `.part` file, and the sender uploads only the remainder.
   - `missing`: full upload.
4. **Second check on PUT.** If two uploads of the same file race, the PUT handler checks again and answers `skipped`.
5. **Integrity.** The receiver re-hashes the completed `.part` and only commits it if it matches. It never overwrites; if names collide it writes `IMG_0001 (1).HEIC`.

If you delete a backed-up file on the receiver, the next sync sends it again. This is deliberate for a backup, and the logic is in `ReceiverServer._statusFor`.

## What gets backed up
- **Photos:** the original file (HEIC/JPEG/RAW/ProRAW), unedited, with full EXIF.
- **Videos:** the original `.MOV`/`.MP4`, including slo-mo and cinematic originals.
- **Live Photos (iOS):** sent as two files, the still and its paired video, named as a pair (`IMG_0001.HEIC` + `IMG_0001.MOV`). The asset is marked synced only after **both** reach the receiver. If the video fails, the next attempt finds the still already there and retries just the video.
- **Android Motion Photos** (Pixel/Samsung): the video is embedded inside the JPEG, so the single file already contains it.

## Reliability and resume
- Each queue item moves `pending → uploading → (ledger row + queue row deleted)` inside one transaction. Anything still marked `uploading` after a crash goes back to `pending`.
- Network errors (socket, timeout, Wi-Fi drop, or a stall over 30 s detected by the upload watchdog) **don't use up an item's retry**. The engine backs off from 2 s up to 60 s, re-resolves the receiver over mDNS in case its IP changed, then resumes from the byte offset the receiver reports.
- File-specific errors (iCloud original unavailable, hash mismatch) use up a retry. After 5 attempts the item is parked, and the UI offers "Retry failed".

## Protocol
See `lib/core/protocol.dart`. It is plain HTTP on port 8765, authenticated with the receiver's 6-digit PIN in the `x-lucero-token` header.

## Project layout
```
lib/
  core/        protocol, models, SQLite schema/DAO, hashing, device identity
  discovery/   mDNS advertise/browse
  sender/      library scanner, HTTP transfer client, sync engine
  receiver/    dart:io HTTP server, storage (folders, .part files, media scan)
  ui/          Send / Receive / QR scan screens
```

## Known limitations / next steps
- **iOS background:** iOS won't let an app run a long upload in the background. A sync needs the app open; the screen is kept awake. Next step: a `BGProcessingTask` for overnight charging syncs.
- **Android receiver while backgrounded:** Doze can suspend the server. Next step: a foreground service (`flutter_foreground_task`) with a persistent notification.
- **Edits:** the original unedited asset is backed up. Edits made later aren't re-sent.
- **Transport is unencrypted HTTP** on your LAN, protected only by the PIN. Next step if you use untrusted Wi-Fi: TLS with a self-signed certificate pinned through the QR code.
