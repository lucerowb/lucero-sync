# Contributing to Lucero Sync

Thanks for helping out. This guide covers how to set up the project, what's expected in a pull request, and how releases are signed.

## Ground rules

- **Privacy is the product.** Pull requests that add analytics, telemetry, ads, accounts or any traffic beyond the local network won't be merged.
- **Never lose or duplicate a photo.** Changes to the sync engine, receiver or database need tests or a clear explanation of how you verified them on real devices.
- Keep changes focused: one fix or feature per pull request.

## Development setup

1. Install [Flutter](https://docs.flutter.dev/get-started/install) (3.38+), Xcode + CocoaPods (iOS), and Android Studio (Android).
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

Testing a sync needs two real devices on the same Wi-Fi. Simulators and emulators can't do mDNS or local networking reliably.

## Before you open a pull request

```bash
flutter analyze
```

```bash
flutter test
```

Both must pass, and CI runs them on every pull request. Add unit tests in `test/` for anything that doesn't need a device, such as models, the protocol, filename handling or the dedup logic.

If you changed the wire protocol (`lib/core/protocol.dart`), keep it backward compatible or bump `Protocol.version`, and update [ARCHITECTURE.md](ARCHITECTURE.md).

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
3. The **Release** workflow builds the APK and an unsigned IPA, then publishes a GitHub release.
