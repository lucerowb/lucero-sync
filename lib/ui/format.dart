import 'package:flutter/material.dart';

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = bytes / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v < 10 ? 1 : 0)} ${units[i]}';
}

String timeAgo(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 45) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  if (d.inDays < 7) return '${d.inDays} d ago';
  return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
}

IconData platformIcon(String platform, {String? name}) => switch (platform) {
      'ios' when name != null && name.toLowerCase().contains('ipad') => Icons.tablet_mac_rounded,
      'ios' => Icons.phone_iphone_rounded,
      'android' => Icons.phone_android_rounded,
      'macos' => Icons.laptop_mac_rounded,
      'windows' => Icons.desktop_windows_rounded,
      'linux' => Icons.computer_rounded,
      'web' => Icons.public_rounded,
      _ => Icons.devices_other_rounded,
    };

IconData fileIcon(String name) {
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  return switch (ext) {
    'jpg' || 'jpeg' || 'png' || 'heic' || 'heif' || 'gif' || 'webp' || 'dng' || 'raw' => Icons.image_outlined,
    'mov' || 'mp4' || 'm4v' || 'mkv' || 'avi' || 'webm' => Icons.movie_outlined,
    'mp3' || 'm4a' || 'wav' || 'flac' || 'aac' => Icons.audiotrack_outlined,
    'pdf' => Icons.picture_as_pdf_outlined,
    'zip' || 'rar' || '7z' || 'tar' || 'gz' => Icons.folder_zip_outlined,
    'doc' || 'docx' || 'txt' || 'md' || 'rtf' || 'pages' => Icons.description_outlined,
    'xls' || 'xlsx' || 'csv' || 'numbers' => Icons.table_chart_outlined,
    'apk' || 'ipa' || 'exe' || 'dmg' || 'deb' || 'msi' => Icons.install_desktop_outlined,
    _ => Icons.insert_drive_file_outlined,
  };
}
