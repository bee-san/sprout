import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'drive_sync.dart';
import 'google_auth.dart';
import 'model.dart';
import 'platform_bridge.dart';
import 'store.dart';
import 'portability.dart';
import 'reporting.dart';

class Tracker extends ChangeNotifier {
  Tracker(this.store, this.auth) : sync = DriveSync(store, auth);
  final Store store;
  final GoogleAuth auth;
  final DriveSync sync;
  final PlatformBridge bridge = PlatformBridge();
  List<Activity> activities = [];
  List<Session> sessions = [];
  List<AppRule> rules = [];
  List<Json> processes = [];
  String? error;
  bool automatic = true;
  bool startup = false;
  bool notifications = true;
  DateTime now = DateTime.now();
  DateTime? _lastPoll;
  Timer? _clockTimer;
  Timer? _syncTimer;
  Future<void> _queue = Future.value();
  bool _syncQueued = false;
  bool _closing = false;

  Session? get current {
    for (final s in sessions) {
      if (s.deviceId == store.deviceId && s.isRunning) return s;
    }
    return null;
  }

  Activity? activity(String id) {
    for (final a in activities) {
      if (a.id == id) return a;
    }
    return null;
  }

  String activityName(String id) => activity(id)?.name ?? 'Deleted activity';
  Future<void> _serial(Future<void> Function() action) {
    final next = _queue.then((_) => action());
    _queue = next.catchError((Object e) {
      error = e.toString();
      notifyListeners();
    });
    return next;
  }

  Future<void> initialize() async {
    try {
      await auth.load();
    } catch (_) {
      error =
          'Google credentials could not be loaded. Tracking still works offline; reconnect in Settings.';
    }
    automatic = await store.setting('automatic') != 'false';
    notifications = await store.setting('notifications') != 'false';
    final last = await store.setting('lastSync');
    if (last != null) sync.lastSync = DateTime.tryParse(last)?.toLocal();
    await reload();
    for (final s in sessions.where(
      (s) => s.deviceId == store.deviceId && s.source == 'auto' && s.isRunning,
    )) {
      await store.write('session', s.id, s.copyWith(end: s.lastSeen).toJson());
    }
    await reload();
    if (Platform.isWindows) startup = await bridge.startupEnabled();
    PlatformBridge.channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'pendingAction':
          await resume();
        case 'stop':
          await stop();
        case 'toggleAutomatic':
          await setAutomatic(!automatic);
        case 'quit':
          await exitApp();
      }
    });
    await _updatePlatform();
    await resume();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      now = DateTime.now();
      notifyListeners();
      if (Platform.isAndroid && now.second == 0 && !_closing) {
        unawaited(_updatePlatform().catchError((Object _) {}));
      }
      if (Platform.isWindows && now.second.isEven && !_closing) {
        unawaited(_serial(_poll).catchError((Object _) {}));
      }
    });
    _syncTimer = Timer.periodic(
      const Duration(minutes: 2),
      (_) => unawaited(synchronize()),
    );
    unawaited(synchronize());
  }

  Future<void> reload() async {
    activities = await store.activities();
    sessions = await store.sessions();
    rules = await store.rules();
    notifyListeners();
  }

  Future<void> _updatePlatform() async {
    final session = current;
    final day = dateOnly(DateTime.now());
    final week = DateTime(day.year, day.month, day.day - day.weekday + 1);
    final today = ReportStats(
      sessions,
      day,
      DateTime(day.year, day.month, day.day + 1),
      now,
    );
    final weekly = ReportStats(sessions, week, now, now);
    await bridge.updateTimer(
      session,
      session == null ? 'Ready to track' : activityName(session.activityId),
      activities: activities,
      stats: {
        'notifications': notifications,
        'today': formatDuration(today.total),
        'week': formatDuration(weekly.total),
        'sessions': weekly.count,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      },
    );
  }

  Future<void> resume() async {
    final action = await bridge.takePendingAction();
    if (action?['action'] == 'stop' &&
        (action?['sessionId'] == null || action?['sessionId'] == current?.id)) {
      final timestamp = action?['at'] as int?;
      await stop(
        at: timestamp == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(timestamp),
      );
    } else if (action?['action'] == 'start') {
      final target = activity(action?['activityId'] as String? ?? '');
      if (target != null) await start(target);
    }
    unawaited(synchronize());
  }

  Future<void> addActivity(
    String name,
    int color, {
    String? id,
    String client = '',
  }) => _serial(() async {
    if (name.trim().isEmpty) return;
    final a = Activity(
      id: id ?? const Uuid().v4(),
      name: name.trim(),
      color: color,
      client: client.trim(),
    );
    await store.write('activity', a.id, a.toJson());
    await reload();
    await _updatePlatform();
  });
  Future<void> deleteActivity(Activity a) => _serial(() async {
    if (current?.activityId == a.id) await _stopCurrent(DateTime.now());
    await store.write('activity', a.id, a.toJson(), deleted: true);
    for (final rule in rules.where((r) => r.activityId == a.id)) {
      await store.deleteRule(rule.id);
    }
    await reload();
    await _updatePlatform();
  });
  Future<void> start(
    Activity a, {
    String note = '',
    List<String> tags = const [],
    bool billable = false,
    bool newSession = false,
  }) => _serial(() async {
    if (!newSession &&
        current?.activityId == a.id &&
        current?.source == 'manual') {
      return;
    }
    final time = DateTime.now();
    final s = Session(
      id: const Uuid().v4(),
      activityId: a.id,
      deviceId: store.deviceId,
      deviceName: store.deviceName,
      start: time,
      lastSeen: time,
      note: note.trim(),
      tags: tags,
      billable: billable,
    );
    await store.writeBatch({
      'session': [
        ...sessions
            .where((s) => s.deviceId == store.deviceId && s.isRunning)
            .map(
              (s) => s
                  .copyWith(
                    end: time.isBefore(s.start) ? s.start : time,
                    lastSeen: time,
                  )
                  .toJson(),
            ),
        s.toJson(),
      ],
    });
    now = time;
    await reload();
    if (notifications) await bridge.requestNotifications();
    await _updatePlatform();
  });
  Future<void> _stopCurrent(DateTime time) async {
    final s = current;
    if (s == null) return;
    final end = time.isBefore(s.start) ? s.start : time;
    await store.write(
      'session',
      s.id,
      s.copyWith(end: end, lastSeen: end).toJson(),
    );
    now = DateTime.now();
    await reload();
  }

  Future<void> stop({DateTime? at}) => _serial(() async {
    if (current?.source == 'auto') {
      automatic = false;
      await store.setSetting('automatic', 'false');
    }
    final time = DateTime.now();
    await _stopCurrent(at == null || at.isAfter(time) ? time : at);
    await _updatePlatform();
  });
  Future<void> saveSession(Session s) => _serial(() async {
    if (s.end != null && s.end!.isBefore(s.start)) {
      throw StateError('End time must follow start time.');
    }
    if (s.start.isAfter(DateTime.now()) ||
        (s.isRunning &&
            current != null &&
            current!.id != s.id &&
            s.deviceId == store.deviceId)) {
      throw StateError(
        'A session cannot start in the future or create a second timer.',
      );
    }
    await store.write('session', s.id, s.toJson());
    await reload();
    await _updatePlatform();
  });
  Future<void> continueSession(Session s) {
    final a = activity(s.activityId);
    if (a == null) {
      throw StateError('Restore this activity before continuing it.');
    }
    return start(
      a,
      note: s.note,
      tags: s.tags,
      billable: s.billable,
      newSession: true,
    );
  }

  Future<ImportResult> importToggl(String csv) async {
    late ImportResult result;
    await _serial(() async {
      final plan = planTogglImport(
        csv,
        activities: activities,
        sessions: sessions,
        deviceId: store.deviceId,
        deviceName: store.deviceName,
      );
      await store.writeBatch({
        'activity': plan.activities.map((a) => a.toJson()).toList(),
        'session': plan.sessions.map((s) => s.toJson()).toList(),
      });
      result = ImportResult(plan.sessions.length, plan.skipped);
      await reload();
      await _updatePlatform();
    });
    return result;
  }

  String backup() => encodeBackup(activities, sessions, now);

  Future<ImportResult> restore(String content) async {
    late ImportResult result;
    await _serial(() async {
      final plan = planRestore(
        content,
        activities: activities,
        sessions: sessions,
        deviceId: store.deviceId,
        deviceName: store.deviceName,
      );
      await store.writeBatch({
        'activity': plan.activities.map((a) => a.toJson()).toList(),
        'session': plan.sessions.map((s) => s.toJson()).toList(),
      });
      result = ImportResult(plan.sessions.length, plan.skipped);
      await reload();
      await _updatePlatform();
    });
    return result;
  }

  Future<void> deleteSession(Session s) => _serial(() async {
    await store.write('session', s.id, s.toJson(), deleted: true);
    await reload();
    await _updatePlatform();
  });
  Future<void> saveRule(AppRule rule) => _serial(() async {
    await store.saveRule(rule);
    await reload();
  });
  Future<void> removeRule(AppRule rule) => _serial(() async {
    await store.deleteRule(rule.id);
    await reload();
  });
  Future<void> setAutomatic(bool value) => _serial(() async {
    automatic = value;
    await store.setSetting('automatic', '$value');
    if (!value && current?.source == 'auto') await _stopCurrent(DateTime.now());
    await _updatePlatform();
    notifyListeners();
  });
  Future<void> setStartup(bool value) async {
    await bridge.setStartup(value);
    startup = value;
    notifyListeners();
  }

  Future<void> setNotifications(bool value) async {
    notifications = value;
    await store.setSetting('notifications', '$value');
    if (value) await bridge.requestNotifications();
    await _updatePlatform();
    notifyListeners();
  }

  Future<void> refreshProcesses() async {
    final state = await bridge.snapshot();
    processes = (state['processes'] as List? ?? [])
        .map((p) => Map<String, dynamic>.from(p as Map))
        .toList();
    notifyListeners();
  }

  Future<void> _poll() async {
    if (_closing) return;
    final time = DateTime.now();
    if (_lastPoll != null &&
        time.difference(_lastPoll!) > const Duration(seconds: 10) &&
        current?.source == 'auto') {
      await _stopCurrent(_lastPoll!);
    }
    _lastPoll = time;
    final state = await bridge.snapshot();
    final liveProcesses = (state['processes'] as List? ?? [])
        .map((p) => Map<String, dynamic>.from(p as Map))
        .toList();
    processes = liveProcesses;
    if (current?.source == 'manual') return;
    final available = rules.where((r) => activity(r.activityId) != null);
    final rule = automatic
        ? chooseRule(
            rules: available,
            focused: state['focused'] as String? ?? '',
            running: liveProcesses.map((p) => p['path'] as String),
            idleMs: state['idleMs'] as int? ?? 0,
            locked: state['locked'] as bool? ?? false,
          )
        : null;
    final s = current;
    if (s != null &&
        (rule == null ||
            s.activityId != rule.activityId ||
            s.executable != rule.executable)) {
      var end = time;
      final previous = rules
          .where(
            (r) => r.activityId == s.activityId && r.executable == s.executable,
          )
          .firstOrNull;
      final idle = state['idleMs'] as int? ?? 0;
      if (previous != null &&
          previous.pauseWhenIdle &&
          idle >= previous.idleMinutes * 60000) {
        end = time.subtract(Duration(milliseconds: idle));
      }
      await _stopCurrent(end);
    }
    if (rule != null && current == null) {
      final next = Session(
        id: const Uuid().v4(),
        activityId: rule.activityId,
        deviceId: store.deviceId,
        deviceName: store.deviceName,
        start: time,
        lastSeen: time,
        source: 'auto',
        executable: rule.executable,
      );
      await store.write('session', next.id, next.toJson());
      await reload();
      await _updatePlatform();
    } else if (current != null &&
        time.difference(current!.lastSeen) >= const Duration(seconds: 15)) {
      final heartbeat = current!.copyWith(lastSeen: time);
      await store.write('session', heartbeat.id, heartbeat.toJson());
      await reload();
    }
    if (current == null) await _updatePlatform();
  }

  Future<void> synchronize() async {
    if (!auth.connected || _syncQueued || _closing) return;
    _syncQueued = true;
    notifyListeners();
    try {
      await sync.sync();
      await _serial(() async {
        await reload();
        await _updatePlatform();
      });
    } finally {
      _syncQueued = false;
      notifyListeners();
    }
  }

  bool get syncing => _syncQueued;
  Future<void> exitApp() async {
    _closing = true;
    _clockTimer?.cancel();
    _syncTimer?.cancel();
    await _serial(() => _stopCurrent(DateTime.now()));
    await _updatePlatform();
    await bridge.quit();
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _syncTimer?.cancel();
    super.dispose();
  }
}
