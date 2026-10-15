import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:photo_manager/photo_manager.dart';

import '../storage/storage.dart';
import 'platform.dart';

enum PermState {
  granted,
  limited,
  denied,
  notDetermined,

  /// The OS gives apps no way to check (e.g. Local Network on Apple platforms).
  unknown,
}

/// One OS permission the app relies on, with its current state and how to fix it.
class PermissionItem {
  PermissionItem({
    required this.id,
    required this.title,
    required this.reason,
    required this.icon,
    required this.state,
    this.required = false,
  });

  final String id;
  final String title;
  final String reason;
  final IconData icon;
  final PermState state;

  /// Core features break without it (as opposed to one optional feature).
  final bool required;

  bool get ok => state == PermState.granted || state == PermState.limited || state == PermState.unknown;
}

/// Checks and requests the permissions each platform needs.
///
/// | Platform | Checked                                              |
/// |----------|------------------------------------------------------|
/// | iOS      | Photos, Camera, Local Network (info only)            |
/// | Android  | Photos & videos, All files access, Camera            |
/// | macOS    | Photos, Camera, Local Network (info only)            |
/// | Windows / Linux | nothing: no runtime permissions, firewall only |
class Permissions {
  static const _channel = MethodChannel('lucero_sync/permissions');

  static bool get _apple => Platform.isIOS || Platform.isMacOS;

  static Future<List<PermissionItem>> check() async {
    if (!Caps.isMobile && !Platform.isMacOS) return const [];
    return [
      if (Caps.hasPhotoLibrary)
        PermissionItem(
          id: 'photos',
          title: Platform.isAndroid ? 'Photos & videos' : 'Photos',
          reason: Platform.isAndroid
              ? 'Back up your gallery and pick photos to send.'
              : 'Back up your photo library. "Limited" only backs up the photos you select.',
          icon: Icons.photo_library_outlined,
          state: await _photos(),
          required: Caps.isMobile,
        ),
      if (Platform.isAndroid)
        PermissionItem(
          id: 'files',
          title: 'All files access',
          reason: 'Save received photos to Pictures and files to Downloads, so they show up in your gallery.',
          icon: Icons.folder_special_outlined,
          state: await Storage.hasAllFilesAccess() ? PermState.granted : PermState.denied,
        ),
      if (Caps.canScanQr)
        PermissionItem(
          id: 'camera',
          title: 'Camera',
          reason: 'Scan another device\'s QR code to pair. Optional; you can pair by code instead.',
          icon: Icons.qr_code_scanner_rounded,
          state: await _camera(),
        ),
      if (_apple)
        PermissionItem(
          id: 'network',
          title: 'Local network',
          reason:
              'Find and connect to your other devices. If nearby devices never appear, check that '
              'Lucero Sync is turned on under ${Platform.isIOS ? 'Settings › Privacy & Security' : 'System Settings › Privacy & Security'} › Local Network.',
          icon: Icons.wifi_rounded,
          state: PermState.unknown,
          required: true,
        ),
    ];
  }

  static Future<PermState> _photos() async {
    try {
      final s = await PhotoManager.getPermissionState(requestOption: const PermissionRequestOption());
      return switch (s) {
        PermissionState.authorized => PermState.granted,
        PermissionState.limited => PermState.limited,
        PermissionState.notDetermined => PermState.notDetermined,
        _ => PermState.denied,
      };
    } catch (_) {
      return PermState.unknown;
    }
  }

  static Future<PermState> _camera() async {
    try {
      if (Platform.isAndroid) {
        final s = await ph.Permission.camera.status;
        if (s.isGranted) return PermState.granted;
        // Android doesn't distinguish "never asked" from "denied once".
        return s.isPermanentlyDenied ? PermState.denied : PermState.notDetermined;
      }
      return _parse(await _channel.invokeMethod<String>('cameraStatus'));
    } catch (_) {
      return PermState.unknown;
    }
  }

  static PermState _parse(String? s) => switch (s) {
    'granted' => PermState.granted,
    'notDetermined' => PermState.notDetermined,
    'denied' || 'restricted' => PermState.denied,
    _ => PermState.unknown,
  };

  /// Shows the system prompt if the OS still allows it, otherwise opens Settings.
  /// Returns once the prompt closes; call [check] again afterwards.
  static Future<void> request(PermissionItem item) async {
    try {
      switch (item.id) {
        case 'photos':
          if (item.state == PermState.notDetermined || (Platform.isAndroid && item.state == PermState.denied)) {
            final s = await PhotoManager.requestPermissionExtend();
            if (s.hasAccess || !Platform.isAndroid) return;
          }
          if (item.state == PermState.limited && Platform.isIOS) return await PhotoManager.presentLimited();
          return await openSettings(item);
        case 'files':
          await ph.Permission.manageExternalStorage.request();
          return;
        case 'camera':
          if (item.state == PermState.notDetermined) {
            if (Platform.isAndroid) {
              final s = await ph.Permission.camera.request();
              if (!s.isPermanentlyDenied) return;
            } else {
              await _channel.invokeMethod<String>('requestCamera');
              return;
            }
          }
          return await openSettings(item);
        default:
          return await openSettings(item);
      }
    } catch (_) {
      await openSettings(item);
    }
  }

  static Future<void> openSettings(PermissionItem item) async {
    if (Platform.isMacOS) {
      final pane = switch (item.id) {
        'camera' => 'Camera',
        'network' => 'LocalNetwork',
        _ => 'Photos',
      };
      await _channel.invokeMethod('openSettings', pane);
    } else if (Platform.isIOS) {
      await _channel.invokeMethod('openSettings');
    } else {
      await ph.openAppSettings();
    }
  }
}
