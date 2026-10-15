import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'app_controller.dart';

/// Files and text handed to Lucero Sync from another app's share sheet.
class SharedPayload {
  const SharedPayload(this.files, this.texts);
  final List<String> files;
  final List<String> texts;
  bool get isEmpty => files.isEmpty && texts.isEmpty;
}

/// Phone integrations:
///
/// * **Share sheet**: iOS share extension / Android `SEND` intents. Items
///   arrive in [incoming]; the Share page picks them up and asks which device.
/// * **Live Activity** (iOS 16.2+): Lock Screen and Dynamic Island progress
///   for whatever is in flight, driven from [AppController.live].
class MobileBridge with WidgetsBindingObserver {
  MobileBridge(this.app);

  final AppController app;
  static const _channel = MethodChannel('lucero_sync/platform');

  /// The latest batch shared into the app; cleared by whoever handles it.
  final incoming = ValueNotifier<SharedPayload?>(null);

  bool _activityOn = false;
  DateTime _lastActivityPush = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _endTimer;

  void start() {
    if (!Platform.isIOS && !Platform.isAndroid) return;
    WidgetsBinding.instance.addObserver(this);
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'sharedItemsChanged') await checkShared();
    });
    unawaited(checkShared());
    if (Platform.isIOS) app.live.addListener(_onLive);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(checkShared());
  }

  Future<void> checkShared() async {
    try {
      final batches = await _channel.invokeListMethod<Map<Object?, Object?>>('takeSharedItems') ?? const [];
      final files = <String>[];
      final texts = <String>[];
      for (final b in batches) {
        files.addAll(((b['files'] as List?) ?? const []).cast<String>().where((f) => File(f).existsSync()));
        texts.addAll(((b['texts'] as List?) ?? const []).cast<String>().where((t) => t.trim().isNotEmpty));
      }
      if (files.isEmpty && texts.isEmpty) return;
      final prev = incoming.value;
      incoming.value = SharedPayload([...?prev?.files, ...files], [...?prev?.texts, ...texts]);
    } on MissingPluginException {
      // Older build without the native side.
    } catch (e) {
      app.log('Could not read shared items: $e');
    }
  }

  // ---- Live Activity ----------------------------------------------------------------

  void _onLive() {
    final live = app.live.value;
    if (live.isEmpty) {
      if (!_activityOn || _endTimer != null) return;
      // Short grace period so back-to-back transfers share one activity.
      _endTimer = Timer(const Duration(seconds: 3), () {
        _endTimer = null;
        _activityOn = false;
        unawaited(_push('end', headline: 'All done', detail: 'Transfers finished', fraction: 1, finished: true));
      });
      return;
    }
    _endTimer?.cancel();
    _endTimer = null;
    // ActivityKit throttles frequent updates; once a second is plenty.
    final now = DateTime.now();
    if (_activityOn && now.difference(_lastActivityPush) < const Duration(seconds: 1)) return;
    _lastActivityPush = now;
    _activityOn = true;
    final sending = live.items.where((i) => i.direction == LiveDirection.sending).length;
    unawaited(_push(
      'update',
      headline: live.headline,
      detail: live.detail,
      fraction: live.fraction ?? -1,
      count: live.count,
      sending: sending * 2 >= live.count,
    ));
  }

  Future<void> _push(String action,
      {required String headline,
      required String detail,
      required double fraction,
      int count = 0,
      bool sending = true,
      bool finished = false}) async {
    try {
      await _channel.invokeMethod('liveActivity', {
        'action': action,
        'device': app.identity.name,
        'headline': headline,
        'detail': detail,
        'fraction': fraction,
        'count': count,
        'sending': sending,
        'finished': finished,
      });
    } catch (_) {
      // Live Activities off, or iOS < 16.2: nothing to show.
    }
  }
}
