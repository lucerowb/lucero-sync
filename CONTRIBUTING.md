# Contributing to Lucero Sync

Thanks for helping out. This guide covers how to set up the project, what's expected in a pull request, and how releases are signed.

## Ground rules

- **Privacy is the product.** Pull requests that add analytics, telemetry, ads, accounts or any traffic beyond the local network won't be merged.
- **Never lose or duplicate a photo.** Changes to the sync engine, receiver or database need tests or a clear explanation of how you verified them on real devices.
- Keep changes focused: one fix or feature per pull request.

## Development setup

1. Install [Flutter](https://docs.flutter.dev/get-started/install) (3.38+) and the toolchain for each platform you work on:
   - **iOS / macOS:** Xcode + CocoaPods
   - **Android:** Android Studio
   - **Windows:** Visual Studio 2022 with "Desktop development with C++"
   - **Linux:** `sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev zenity`
2. Fetch dependencies:
   ```bash
   flutter pub get
   ```
3. For iOS, create your personal signing file (it's git-ignored):
   ```bash
   cp ios/Flutter/Signing.example.xcconfig ios/Flutter/Signing.local.xcconfig
   ```
   Set `DEVELOPMENT_TEAM` and a unique `APP_BUNDLE_ID` in it. **Don't** change the team or bundle ID in Xcode's Signing & Capabilities tab: Xcode writes those into `project.pbxproj`, which is committed.
4. Run on a device:
   ```bash
   flutter run
   ```

The quickest two-device setup is the desktop app plus a phone, or two instances: a desktop app and an iOS simulator on the same Mac share the network, and the second instance automatically picks the next free port. `tool/demo_peer_test.dart` is a scripted peer that pairs with a running app and offers it files (run it with `LUCERO_TARGET_PORT=8765 flutter test tool/demo_peer_test.dart`).

## Before you open a pull request

```bash
flutter analyze
```

```bash
flutter test
```

Both must pass. CI also builds Android, iOS, macOS, Windows and Linux on every pull request. `test/protocol_test.dart` runs two complete devices against each other over real TLS on localhost; add a case there for any protocol or security change.

**Security-sensitive code** (`lib/security/`, `lib/net/`, `lib/storage/storage.dart`) needs a test showing the attack it prevents, like the existing impostor and interception tests.

If you changed the wire protocol (`lib/core/protocol.dart`), keep it backward compatible or bump `Protocol.version`, and update [ARCHITECTURE.md](ARCHITECTURE.md). Keep `appVersion` in `lib/core/version.dart` in sync with `pubspec.yaml`.

## Project layout

See [ARCHITECTURE.md › Project layout](ARCHITECTURE.md#project-layout).

## Android release signing

Release builds look for `android/key.properties` (git-ignored):

```properties
storeFile=/absolute/path/to/lucero-release.jks
storePassword=…
keyAlias=lucero
keyPassword=…
```

Create a keystore with:

```bash
keytool -genkey -v -keystore ~/lucero-release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias lucero
```

In CI, the release workflow reads the same values from repository secrets:

| Secret | Contents |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | `base64 -i lucero-release.jks` |
| `ANDROID_KEYSTORE_PASSWORD` | keystore password |
| `ANDROID_KEY_ALIAS` | key alias |
| `ANDROID_KEY_PASSWORD` | key password |

Without these, releases are signed with a throwaway debug key. Users then can't upgrade between releases without uninstalling first, which wipes the receiver's sync history.

## Releasing

1. Bump `version:` in `pubspec.yaml`.
2. Tag and push:
   ```bash
   git tag v0.2.0 && git push origin v0.2.0
   ```
3. The **Release** workflow builds the Android APK, an unsigned iOS IPA with its AltStore/SideStore source, a macOS app (ad-hoc signed), and Windows and Linux bundles, then publishes a GitHub release. Add a section to [CHANGELOG.md](CHANGELOG.md) first.
