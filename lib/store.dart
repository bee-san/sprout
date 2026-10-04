import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' show databaseFactorySqflitePlugin;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'model.dart';

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
  static Future<Store> open({
    DatabaseFactory? factory,
    String? databasePath,
  }) async {
    if (factory == null && Platform.isWindows) {
      sqfliteFfiInit();
      factory = databaseFactoryFfi;
    }
    factory ??= databaseFactorySqflitePlugin;
    final dbPath =
        databasePath ??
        resolveDatabasePath(
          (await getApplicationSupportDirectory()).path,
          legacyWindows: Platform.isWindows,
        );
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
  }

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
