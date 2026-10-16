# Changelog

## Unreleased

### New
- **Transfer page:** tap any transfer (or send something) to see every file with its own progress, plus overall speed and time left. The receiver opens it automatically after tapping Accept, and it stays open with the result and a **Show files** button.
- **Send folders** (Android, Mac, Windows, Linux): pick or drop a folder and it arrives with the same structure. Sending the same folder again lands next to the first as "Name (1)".
- **Text** button on Share: add a note or link (pre-filled from the clipboard) and send it along with files.

## 0.3.0

### New
- **Live progress on both devices.** Receivers now see incoming backups (item count plus the file arriving) and every incoming share, including auto-accepted ones; stalled transfers show as paused. A new *In progress* section on Share, Activity and Backup, and a badge on Activity.
- **Share sheet:** send photos, videos, files, links and text to Lucero Sync from any app on iPhone and Android.
- **Dynamic Island & Lock Screen** Live Activity on iPhone (iOS 16.2+).
- **Menu bar / system tray** on Mac, Windows and Linux with progress, Send files / Send clipboard to any device, and a receiving toggle. Closing the window keeps the app running.
- **Web access:** let any browser on your Wi-Fi send to and download from a device after entering a 6-digit code shown on it.
- **Browser extension** for Chrome, Edge, Brave and Firefox: send links, images, selections and pages to a paired device through the desktop app.

### Fixed
- **macOS:** the app could hang on launch behind an invisible "access your Documents folder" prompt (the database now lives in Application Support; existing data is moved).
- **iPhone/iPad/Mac:** the app could freeze when returning to the foreground while announcing itself on the network (patched mDNS plugin).
- Picked files are no longer lost when a window is resized between phone and desktop layouts.
- Storage paths say "On My iPad" on iPads.

## 0.2.1

### New
- **Settings › Permissions** shows whether Photos, Camera, All files access (Android) and Local Network (Apple) are allowed, with a button to grant each one or open system Settings. It refreshes when you come back from Settings.

### Fixed
- **macOS:** the Files and Photos & videos buttons, and "Change folder…", did nothing. The file picker needs a user-selected-files entitlement even outside the sandbox.
- Picker errors now show a message instead of failing silently, and the buttons show a spinner while the system picker opens.
- **Website:** the download section could render as one unstyled line when a cached old stylesheet was served. Stylesheets are now versioned.

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
