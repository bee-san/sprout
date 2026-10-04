import 'dart:io';

import 'package:flutter/services.dart';

import 'model.dart';

class PlatformBridge {
  static const channel = MethodChannel('dev.beesan.timebud/platform');
  Future<Json> snapshot() async => Platform.isWindows
      ? Map<String, dynamic>.from(
          await channel.invokeMapMethod<String, dynamic>('snapshot') ?? {},
        )
      : {};
  Future<bool> startupEnabled() async =>
      Platform.isWindows &&
      (await channel.invokeMethod<bool>('startupEnabled') ?? false);
  Future<void> setStartup(bool value) async {
    if (Platform.isWindows) {
      await channel.invokeMethod<void>('setStartup', value);
    }
  }

  Future<void> updateTimer(
    Session? session,
    String name, {
    List<Activity> activities = const [],
    Json stats = const {},
  }) async {
    if (!Platform.isWindows && !Platform.isAndroid) return;
    await channel.invokeMethod<void>('updateTimer', {
      'name': name,
      'start': session?.start.millisecondsSinceEpoch ?? 0,
      'running': session != null,
      'sessionId': session?.id ?? '',
      'activities': activities.map((a) => a.toJson()).toList(),
      'stats': stats,
    });
  }

  Future<void> requestNotifications() async {
    if (Platform.isAndroid) {
      await channel.invokeMethod<void>('requestNotifications');
    }
  }

  Future<Json?> takePendingAction() async => Platform.isAndroid
      ? await channel.invokeMapMethod<String, dynamic>('takePendingAction')
      : null;
  Future<String> signingFingerprint() async => Platform.isAndroid
      ? await channel.invokeMethod<String>('signingFingerprint') ?? ''
      : '';
  Future<void> quit() => channel.invokeMethod<void>('quit');
}
