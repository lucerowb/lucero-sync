import 'dart:io';

/// What the current platform can do. Keeps platform checks out of the UI.
class Caps {
  static bool get isDesktop => Platform.isMacOS || Platform.isWindows || Platform.isLinux;
  static bool get isMobile => Platform.isIOS || Platform.isAndroid;

  /// Has a system photo library we can back up (Photos / MediaStore / PhotoKit).
  static bool get hasPhotoLibrary => Platform.isIOS || Platform.isAndroid || Platform.isMacOS;

  /// Has a camera QR scanner available through mobile_scanner.
  static bool get canScanQr => Platform.isIOS || Platform.isAndroid || Platform.isMacOS;

  /// `ios`, `android`, `macos`, `windows` or `linux`.
  static String get platformId => Platform.operatingSystem;

  static String get defaultNamePrefix => switch (Platform.operatingSystem) {
        'ios' => 'iPhone',
        'android' => 'Android',
        'macos' => 'Mac',
        'windows' => 'Windows PC',
        'linux' => 'Linux PC',
        _ => 'Device',
      };
}

String platformLabel(String id) => switch (id) {
      'ios' => 'iOS',
      'android' => 'Android',
      'macos' => 'macOS',
      'windows' => 'Windows',
      'linux' => 'Linux',
      _ => id,
    };
