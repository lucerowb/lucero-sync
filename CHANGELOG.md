# Changelog

## 0.2.0

A redesign: Lucero Sync now shares files and text as well as backing up photos, runs on desktop, and encrypts everything.

### New
- **Desktop apps** for macOS, Windows and Linux, with drag and drop and configurable folders.
- **File and text sharing** between paired devices, with per-device "accept automatically".
- **Encrypted transport:** TLS 1.3 pinned to each device's own certificate (ECDSA P-256).
- **New pairing:**
  - Compare a six-digit code on both screens, built on a commitment protocol so codes can't be forged.
  - Or scan a one-time QR code.
  - Pairing is mutual: either device can send to the other.
- **Redesigned app** with four sections (Share, Backup, Activity, Settings) and an adaptive layout: bottom bar on phones, sidebar on tablets and desktops.
- **Activity history** of sent and received files and text.
- **Connection help** page showing addresses, nearby devices, platform-specific fixes and a log.
- **Default device names** taken from the device (e.g. "Pixel 9", your Mac's name).
- **macOS photo library backup.** The backup engine now runs on Macs.

### Changed
- Wire protocol v2 (HTTPS). **Devices running 0.1.x must be updated and paired again.** Backup history is kept, so nothing is re-sent.
- Received files now go to a separate **Received** folder; backups stay date-organised.
- QR scanning on iOS and macOS now uses Apple's Vision framework, so no Google code is included on Apple platforms.

### Security
- Tokens are stored hashed; comparisons are constant-time.
- Pairing attempts are rate-limited.
- Devices whose identity changes are flagged instead of trusted.
- File names are sanitised more strictly (leading dots, reserved characters, length).

## 0.1.1
- AltStore / SideStore source, release signing for the APK, app icon, screenshots.

## 0.1.0
- First release: iPhone → Android photo backup over the local network.
