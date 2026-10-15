import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

/// Streams the file through SHA-256 on a background isolate so multi-GB
/// videos never block the UI thread.
Future<String> sha256OfFile(String path) => Isolate.run(() async {
      final digest = await sha256.bind(File(path).openRead()).first;
      return digest.toString();
    });

final _sha256Re = RegExp(r'^[0-9a-f]{64}$');

bool isSha256Hex(String s) => _sha256Re.hasMatch(s);
