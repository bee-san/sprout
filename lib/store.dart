import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' show databaseFactorySqflitePlugin;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'model.dart';
import 'portability.dart';

class StoreSnapshot {
  StoreSnapshot(this.entities, this.rules, this.preferences);
  final List<Mutation> entities;
  final List<AppRule> rules;
  final Map<String, bool> preferences;
  List<Activity> get activities => entities
      .where((m) => m.kind == 'activity' && !m.deleted)
      .map((m) => Activity.fromJson(m.data))
      .toList();
  List<Activity> get historicalActivities => entities
      .where((m) => m.kind == 'activity' && m.data['name'] is String)
      .map((m) => Activity.fromJson(m.data))
      .toList();
  List<Session> get sessions => entities
      .where((m) => m.kind == 'session' && !m.deleted)
      .map((m) => Session.fromJson(m.data))
      .toList();
  Set<String> deleted(String kind) => entities
      .where((m) => m.kind == kind && m.deleted)
      .map((m) => m.id)
      .toSet();
  String get revision => jsonEncode([
    entities.map((m) => m.toJson()).toList(),
    rules.map((r) => r.toJson()).toList(),
    preferences,
  ]);
  String encode(DateTime now) {
    final names = {for (final a in activities) a.id: a};
    final referenced = {
      ...sessions.map((s) => s.activityId),
      ...rules.map((r) => r.activityId),
    };
    for (final id in referenced) {
      if (names.containsKey(id)) continue;
      final old = entities
          .where((m) => m.kind == 'activity' && m.id == id)
          .firstOrNull;
      names[id] = old != null && old.data['name'] is String
          ? Activity.fromJson(old.data)
          : Activity(id: id, name: 'Recovered activity', color: 0xFF567561);
    }
    return encodeBackup(
      names.values.toList(),
      sessions,
      now,
      rules: rules,
      preferences: preferences,
    );
  }

  RestorePlan restorePlan(BackupData backup, RestoreOptions options) =>
      planBackupRestore(
        backup,
        activities: activities,
        sessions: sessions,
        rules: rules,
        deletedActivities: deleted('activity'),
        deletedSessions: deleted('session'),
        options: options,
      );
}

/// Keep the original Windows preview's history and installation identity.
String resolveDatabasePath(String supportPath, {bool legacyWindows = false}) {
  final current = path.join(supportPath, 'timebud.sqlite');
  if (legacyWindows && !File(current).existsSync()) {
    final legacy = path.join(
      path.dirname(supportPath),
      'Timebud',
      'timebud.sqlite',
    );
    if (File(legacy).existsSync()) return legacy;
  }
  return current;
}

class Store {
  Store(this.db, this.deviceId, this.deviceName);
  final Database db;
  final String deviceId;
  final String deviceName;
  static Future<String> defaultDatabasePath() async => resolveDatabasePath(
    (await getApplicationSupportDirectory()).path,
    legacyWindows: Platform.isWindows,
  );
  static Future<Store> open({
    DatabaseFactory? factory,
    String? databasePath,
  }) async {
    if (factory == null && Platform.isWindows) {
      sqfliteFfiInit();
      factory = databaseFactoryFfi;
    }
    factory ??= databaseFactorySqflitePlugin;
    final dbPath = databasePath ?? await defaultDatabasePath();
    if (dbPath != inMemoryDatabasePath && await File(dbPath).exists()) {
      // sqflite_android's read-only path supplies a non-destructive corruption
      // handler. Its normal writable open uses Android's default handler, which
      // can delete a damaged database. Check before entering that path.
      final probe = await factory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      try {
        final check = await probe.rawQuery('PRAGMA quick_check');
        if (check.length != 1 || check.first.values.single != 'ok') {
          throw StateError(
            'Your database needs recovery. The original has been preserved.',
          );
        }
      } finally {
        await probe.close();
      }
    }
    final db = await factory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        singleInstance: dbPath != inMemoryDatabasePath,
        version: 1,
        onConfigure: (db) async {
          // Android rejects result-producing PRAGMAs through execute().
          await db.rawQuery('PRAGMA journal_mode=WAL');
          await db.rawQuery('PRAGMA busy_timeout=5000');
        },
        onCreate: (db, version) async {
          await db.execute(
            'CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE entities (key TEXT PRIMARY KEY, kind TEXT NOT NULL, payload TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE owned (key TEXT PRIMARY KEY, payload TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE rules (id TEXT PRIMARY KEY, payload TEXT NOT NULL)',
          );
        },
      ),
    );
    try {
      final rows = await db.query(
        'metadata',
        where: 'key = ?',
        whereArgs: ['deviceId'],
      );
      final device = rows.isEmpty
          ? const Uuid().v4()
          : rows.first['value'] as String;
      final nameRows = await db.query(
        'metadata',
        where: 'key = ?',
        whereArgs: ['deviceName'],
      );
      final name = nameRows.isEmpty
          ? (Platform.isAndroid ? 'Android' : Platform.localHostname)
          : nameRows.first['value'] as String;
      final store = Store(db, device, name);
      await store.setSetting('deviceId', device);
      await store.setSetting('deviceName', name);
      return store;
    } catch (_) {
      await db.close();
      rethrow;
    }
  }

  Future<StoreSnapshot> snapshot() => db.transaction(_snapshot);
  Future<StoreSnapshot> _snapshot(DatabaseExecutor txn) async {
    final entities = (await txn.query('entities', orderBy: 'key'))
        .map(
          (row) =>
              Mutation.fromJson(jsonDecode(row['payload'] as String) as Json),
        )
        .toList();
    final rules = (await txn.query('rules', orderBy: 'rowid'))
        .map(
          (row) =>
              AppRule.fromJson(jsonDecode(row['payload'] as String) as Json),
        )
        .toList();
    final settings = {
      for (final row in await txn.query('metadata'))
        row['key'] as String: row['value'] as String,
    };
    return StoreSnapshot(entities, rules, {
      'automatic': settings['automatic'] != 'false',
      'notifications': settings['notifications'] != 'false',
    });
  }

  /// Replan against a single, current database snapshot. A concurrent sync or
  /// a stale preview must never let an import overwrite existing edits.
  Future<ImportPlan> applyImport(
    ImportPlan Function(StoreSnapshot) planner, {
    Future<void> Function(StoreSnapshot)? beforeChange,
  }) => db.transaction((txn) async {
    final snapshot = await _snapshot(txn);
    final plan = planner(snapshot);
    final changes = plan is RestorePlan
        ? plan.hasChanges
        : plan.activities.isNotEmpty || plan.sessions.isNotEmpty;
    if (!changes) return plan;
    if (beforeChange != null) await beforeChange(snapshot);
    for (final a in plan.activities) {
      await _write(txn, 'activity', a.id, a.toJson());
    }
    for (final s in plan.sessions) {
      await _write(txn, 'session', s.id, s.toJson());
    }
    if (plan is RestorePlan) {
      for (final r in plan.rules) {
        await txn.insert('rules', {
          'id': r.id,
          'payload': jsonEncode(r.toJson()),
        });
      }
      for (final pref in plan.preferences.entries) {
        await txn.insert('metadata', {
          'key': pref.key,
          'value': '${pref.value}',
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }
    return plan;
  });

  Future<void> deleteSession(
    String id, {
    Future<void> Function(StoreSnapshot)? beforeChange,
  }) => db.transaction((txn) async {
    final snapshot = await _snapshot(txn);
    final session = snapshot.sessions.where((s) => s.id == id).firstOrNull;
    if (session == null) return;
    if (beforeChange != null) await beforeChange(snapshot);
    await _write(txn, 'session', id, session.toJson(), deleted: true);
  });

  Future<void> deleteActivity(
    String id, {
    Future<void> Function(StoreSnapshot)? beforeChange,
  }) => db.transaction((txn) async {
    final snapshot = await _snapshot(txn);
    final activity = snapshot.activities.where((a) => a.id == id).firstOrNull;
    if (activity == null) return;
    if (beforeChange != null) await beforeChange(snapshot);
    final now = DateTime.now();
    for (final s in snapshot.sessions.where(
      (s) => s.activityId == id && s.deviceId == deviceId && s.isRunning,
    )) {
      final end = now.isBefore(s.start) ? s.start : now;
      await _write(
        txn,
        'session',
        s.id,
        s.copyWith(end: end, lastSeen: end).toJson(),
      );
    }
    await _write(txn, 'activity', id, activity.toJson(), deleted: true);
    for (final r in snapshot.rules.where((r) => r.activityId == id)) {
      await txn.delete('rules', where: 'id = ?', whereArgs: [r.id]);
    }
  });

  Future<String?> setting(String key) async {
    final rows = await db.query('metadata', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> setSetting(String key, String value) => db
      .insert('metadata', {
        'key': key,
        'value': value,
      }, conflictAlgorithm: ConflictAlgorithm.replace)
      .then((_) {});

  Future<int> _clock(DatabaseExecutor txn) async {
    final rows = await txn.query(
      'metadata',
      where: 'key = ?',
      whereArgs: ['clock'],
    );
    return rows.isEmpty ? 0 : int.parse(rows.first['value'] as String);
  }

  Future<void> _setClock(DatabaseExecutor txn, int clock) => txn
      .insert('metadata', {
        'key': 'clock',
        'value': '$clock',
      }, conflictAlgorithm: ConflictAlgorithm.replace)
      .then((_) {});

  Future<Mutation> write(
    String kind,
    String id,
    Json data, {
    bool deleted = false,
  }) => db.transaction((txn) => _write(txn, kind, id, data, deleted: deleted));

  Future<Mutation> _write(
    DatabaseExecutor txn,
    String kind,
    String id,
    Json data, {
    bool deleted = false,
  }) async {
    final clock = await _clock(txn) + 1;
    final mutation = Mutation(
      kind: kind,
      id: id,
      clock: clock,
      device: deviceId,
      data: data,
      deleted: deleted,
    );
    await _setClock(txn, clock);
    await _put(txn, mutation);
    await txn.insert('owned', {
      'key': mutation.key,
      'payload': jsonEncode(mutation.toJson()),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await txn.insert('metadata', {
      'key': 'dirty',
      'value': '$clock',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return mutation;
  }

  /// A timer switch or import must either commit completely or not at all.
  Future<void> writeBatch(Map<String, List<Json>> records) =>
      db.transaction((txn) async {
        for (final entry in records.entries) {
          for (final data in entry.value) {
            await _write(txn, entry.key, data['id'] as String, data);
          }
        }
      });

  Future<void> _put(DatabaseExecutor txn, Mutation mutation) => txn
      .insert('entities', {
        'key': mutation.key,
        'kind': mutation.kind,
        'payload': jsonEncode(mutation.toJson()),
      }, conflictAlgorithm: ConflictAlgorithm.replace)
      .then((_) {});

  Future<void> merge(Iterable<Mutation> mutations) async {
    final records = mergeMutations(mutations).values;
    await db.transaction((txn) async {
      var clock = await _clock(txn);
      for (final mutation in records) {
        clock = math.max(clock, mutation.clock);
        final rows = await txn.query(
          'entities',
          where: 'key = ?',
          whereArgs: [mutation.key],
        );
        final current = rows.isEmpty
            ? null
            : Mutation.fromJson(
                jsonDecode(rows.first['payload'] as String) as Json,
              );
        if (current == null || mutation.newerThan(current)) {
          await _put(txn, mutation);
        }
        if (mutation.device == deviceId) {
          final ownRows = await txn.query(
            'owned',
            where: 'key = ?',
            whereArgs: [mutation.key],
          );
          final own = ownRows.isEmpty
              ? null
              : Mutation.fromJson(
                  jsonDecode(ownRows.first['payload'] as String) as Json,
                );
          if (own == null || mutation.newerThan(own)) {
            await txn.insert('owned', {
              'key': mutation.key,
              'payload': jsonEncode(mutation.toJson()),
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }
      }
      await _setClock(txn, clock);
    });
  }

  Future<List<Json>> _data(String kind) async =>
      (await db.query('entities', where: 'kind = ?', whereArgs: [kind]))
          .map(
            (row) =>
                Mutation.fromJson(jsonDecode(row['payload'] as String) as Json),
          )
          .where((m) => !m.deleted)
          .map((m) => m.data)
          .toList();
  Future<List<Activity>> activities() async =>
      (await _data('activity')).map(Activity.fromJson).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  Future<List<Session>> sessions() async =>
      (await _data('session')).map(Session.fromJson).toList()
        ..sort((a, b) => b.start.compareTo(a.start));
  Future<List<Mutation>> owned() async => (await db.query('owned'))
      .map(
        (row) =>
            Mutation.fromJson(jsonDecode(row['payload'] as String) as Json),
      )
      .toList();
  Future<List<AppRule>> rules() async =>
      (await db.query('rules', orderBy: 'rowid'))
          .map(
            (row) =>
                AppRule.fromJson(jsonDecode(row['payload'] as String) as Json),
          )
          .toList();
  Future<void> saveRule(AppRule rule) => db
      .insert('rules', {
        'id': rule.id,
        'payload': jsonEncode(rule.toJson()),
      }, conflictAlgorithm: ConflictAlgorithm.replace)
      .then((_) {});
  Future<void> deleteRule(String id) =>
      db.delete('rules', where: 'id = ?', whereArgs: [id]).then((_) {});
  Future<void> close() => db.close();
}
