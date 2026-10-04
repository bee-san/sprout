import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sprout/backups.dart';
import 'package:sprout/controller.dart';
import 'package:sprout/drive_sync.dart';
import 'package:sprout/google_auth.dart';
import 'package:sprout/model.dart';
import 'package:sprout/portability.dart';
import 'package:sprout/platform_bridge.dart';
import 'package:sprout/store.dart';

import 'support/backup_fixture.dart';
import 'support/fake_drive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(PlatformBridge.channel, (_) async => null);
  late Store store;
  late Tracker tracker;
  setUp(() async {
    sqfliteFfiInit();
    store = await Store.open(
      factory: databaseFactoryFfiNoIsolate,
      databasePath: inMemoryDatabasePath,
    );
    tracker = Tracker(store, GoogleAuth());
  });
  tearDown(() async {
    tracker.dispose();
    await store.close();
  });

  String legacy(void Function(Json) change) {
    final json = jsonDecode(backupFixture()) as Json;
    json['schema'] = 1;
    json.remove('checksum');
    json.remove('rules');
    json.remove('preferences');
    json.remove('frozenTimers');
    change(json);
    return jsonEncode(json);
  }

  test('verified snapshots round trip every field, preferences and rules', () {
    final data = decodeBackup(backupFixture(running: true));
    expect(data.verified, isTrue);
    expect(data.frozenTimers, 1);
    expect(data.sessions.every((s) => !s.isRunning), isTrue);
    expect(data.total, const Duration(hours: 3));
    expect(data.sessions.first.toJson(), backupSession('saved').toJson());
    expect(data.activities.single.toJson(), backupActivity.toJson());
    expect(data.rules.single.toJson(), backupRule.toJson());
    expect(data.preferences, {'automatic': false, 'notifications': false});
    // Formatting or object-key order alone does not invalidate the checksum.
    final json = jsonDecode(backupFixture()) as Json;
    final reversed = {
      for (final key in json.keys.toList().reversed) key: json[key],
    };
    expect(decodeBackup(jsonEncode(reversed)).verified, isTrue);
  });

  test('changed, truncated and future-format backups are rejected', () async {
    final original = backupFixture();
    for (final content in [
      original.replaceFirst('My studio', 'Tampered'),
      original.substring(0, original.length - 8),
      original.replaceFirst('"schema": 2', '"schema": 999'),
    ]) {
      await expectLater(tracker.restore(content), throwsFormatException);
    }
    expect(await store.activities(), isEmpty);
    expect(await store.sessions(), isEmpty);
    expect(await store.owned(), isEmpty);
  });

  test(
    'duplicate identities and malformed fields cannot partly restore',
    () async {
      final changes = <void Function(Json)>[
        (j) => (j['sessions'] as List).add((j['sessions'] as List).first),
        (j) => (j['activities'] as List).add((j['activities'] as List).first),
        (j) => j['sessions'][0]['start'] = '2026-02-30T09:00:00Z',
        (j) => j['sessions'][0]['start'] = '2026-01-02T25:00:00Z',
        (j) => j['sessions'][0]['start'] = '2026-01-02T09:00:00',
        (j) => j['sessions'][0]['end'] = '2026-01-01T00:00:00Z',
        (j) => j['sessions'][0]['end'] = null,
        (j) => j['sessions'][0]['tags'] = ['valid', 12],
        (j) => j['sessions'][0]['billable'] = 'yes',
        (j) => j['activities'][0]['color'] = -1,
        (j) => j['activities'][0]['name'] = ' ',
        (j) => j['sessions'][0]['id'] = 'bad\u0000id',
        (j) => j['sessions'] = {},
      ];
      for (final change in changes) {
        await expectLater(
          tracker.restore(legacy(change)),
          throwsFormatException,
        );
      }
      expect(await store.sessions(), isEmpty);
      expect(await store.setting('dirty'), isNull);
    },
  );

  test(
    'old backups recover omitted deleted activity names without losing time',
    () async {
      final old = legacy((j) => j['activities'] = []);
      final data = decodeBackup(old);
      expect(data.verified, isFalse);
      expect(data.recoveredActivityNames, 1);
      expect(data.activities.single.name, 'Recovered activity');
      await tracker.restore(old);
      expect(
        tracker.sessions.single.duration(backupTime),
        const Duration(hours: 1),
      );
      expect(
        () => encodeBackup([], [backupSession('orphan')], backupTime),
        throwsFormatException,
      );
    },
  );

  test(
    'backup reads a current database snapshot and never stops the actual timer',
    () async {
      await store.write('activity', backupActivity.id, backupActivity.toJson());
      final time = DateTime.now().subtract(const Duration(minutes: 3));
      final live = Session(
        id: 'live',
        activityId: backupActivity.id,
        deviceId: store.deviceId,
        deviceName: store.deviceName,
        start: time,
        lastSeen: time,
      );
      await store.write('session', live.id, live.toJson());
      await store.saveRule(backupRule);
      await store.setSetting('notifications', 'false');
      await store.setSetting('clientSecret', 'must-not-export');
      // Tracker was deliberately not reloaded after the database writes.
      expect(tracker.sessions, isEmpty);
      final content = await tracker.backup();
      final data = decodeBackup(content);
      expect(data.sessions.single.isRunning, isFalse);
      expect(
        data.sessions.single.duration(backupTime).inSeconds,
        greaterThanOrEqualTo(180),
      );
      expect((await store.sessions()).single.isRunning, isTrue);
      expect(data.rules.single.id, backupRule.id);
      expect(data.preferences['notifications'], isFalse);
      expect(content, isNot(contains('must-not-export')));
    },
  );

  test(
    'restoring keeps newer local edits, original attribution and a current timer',
    () async {
      await tracker.restore(backupFixture());
      final local = tracker.sessions.single.copyWith(note: 'Newer local edit');
      await tracker.saveSession(local);
      await tracker.start(tracker.activities.single);
      final liveId = tracker.current!.id;
      final plan = (await store.snapshot()).restorePlan(
        decodeBackup(backupFixture()),
        const RestoreOptions(),
      );
      expect(plan.conflicts, 1);
      final result = await tracker.restore(backupFixture());
      expect(result.imported, 0);
      expect(result.skipped, 1);
      expect(
        tracker.sessions.firstWhere((s) => s.id == 'saved').note,
        'Newer local edit',
      );
      expect(tracker.current!.id, liveId);
      expect(
        tracker.sessions.firstWhere((s) => s.id == 'saved').deviceId,
        'original-phone',
      );
    },
  );

  test(
    'a stale preview and later sync writes cannot overwrite database edits',
    () async {
      await tracker.restore(backupFixture());
      final changed = tracker.sessions.single.copyWith(note: 'Edited by sync');
      await store.write('session', changed.id, changed.toJson());
      // The UI/controller still has the old session.
      expect(tracker.sessions.single.note, isNot(changed.note));
      final result = await tracker.restore(backupFixture());
      expect(result.imported, 0);
      expect((await store.sessions()).single.note, changed.note);
    },
  );

  test(
    'restore is atomic when a later record fails, including settings and clocks',
    () async {
      await store.write('activity', 'current', {
        'id': 'current',
        'name': 'Current',
        'color': 1,
      });
      await store.setSetting('notifications', 'true');
      final before = (await store.snapshot()).revision;
      final dirty = await store.setting('dirty');
      final clock = await store.setting('clock');
      await store.db.execute(
        "CREATE TRIGGER reject_restore BEFORE INSERT ON entities WHEN NEW.key = 'session:live' BEGIN SELECT RAISE(ABORT, 'simulated full disk'); END",
      );
      await expectLater(
        tracker.restore(
          backupFixture(running: true),
          options: const RestoreOptions(deviceSettings: true),
        ),
        throwsA(isA<DatabaseException>()),
      );
      expect((await store.snapshot()).revision, before);
      expect(await store.setting('dirty'), dirty);
      expect(await store.setting('clock'), clock);
      expect(await store.rules(), isEmpty);
      expect(await store.setting('notifications'), 'true');
    },
  );

  test(
    'deleted records stay deleted by default; explicit recovery survives stale sync',
    () async {
      await tracker.restore(backupFixture());
      final stale = await store.owned();
      await tracker.deleteSession(tracker.sessions.single);
      final result = await tracker.restore(backupFixture());
      expect(result.imported, 0);
      expect(result.skipped, 1);
      expect(await store.sessions(), isEmpty);
      final recovered = await tracker.restore(
        backupFixture(),
        options: const RestoreOptions(includeDeleted: true),
      );
      expect(recovered.imported, 1);
      await store.merge(stale);
      expect((await store.sessions()).single.id, 'saved');
    },
  );

  test(
    'restore preserves deletion across replicas and deliberate recovery converges',
    () async {
      final b = await Store.open(
        factory: databaseFactoryFfiNoIsolate,
        databasePath: inMemoryDatabasePath,
      );
      final remote = FakeDrive();
      final syncA = DriveSync(store, FakeAuth(), client: remote.client);
      final syncB = DriveSync(b, FakeAuth(), client: remote.client);
      try {
        await tracker.restore(backupFixture());
        await syncA.sync();
        await syncB.sync();
        await tracker.deleteSession(tracker.sessions.single);
        await syncA.sync();
        await syncB.sync();
        await tracker.restore(backupFixture());
        await syncA.sync();
        await syncB.sync();
        expect(await b.sessions(), isEmpty);
        await tracker.restore(
          backupFixture(),
          options: const RestoreOptions(includeDeleted: true),
        );
        await syncA.sync();
        await syncB.sync();
        await syncA.sync();
        expect(syncA.error, isNull);
        expect(syncB.error, isNull);
        expect(
          (await b.sessions()).single.toJson(),
          (await store.sessions()).single.toJson(),
        );
      } finally {
        remote.client.close();
        await b.close();
      }
    },
  );

  test(
    'backup retains names, colours and clients for deleted activities with history',
    () async {
      await tracker.restore(backupFixture());
      await tracker.deleteActivity(tracker.activities.single);
      final data = decodeBackup(await tracker.backup());
      expect(data.activities.single.toJson(), backupActivity.toJson());
      expect(data.sessions.length, 1);
      expect((await tracker.restore(await tracker.backup())).activities, 0);
      expect(tracker.activities, isEmpty);
    },
  );

  test(
    'preferences are opt-in, rules keep local edits and new rules start disabled',
    () async {
      await tracker.restore(backupFixture());
      expect(await store.rules(), isEmpty);
      expect(tracker.notifications, isTrue);
      await tracker.restore(
        backupFixture(),
        options: const RestoreOptions(deviceSettings: true),
      );
      expect(tracker.notifications, isFalse);
      expect(tracker.automatic, isFalse);
      expect((await store.rules()).single.enabled, isFalse);
      const edited = AppRule(
        id: 'reader-rule',
        activityId: 'reading',
        executable: 'MyReader.exe',
      );
      await store.saveRule(edited);
      await tracker.restore(
        backupFixture(),
        options: const RestoreOptions(deviceSettings: true),
      );
      expect((await store.rules()).single.toJson(), edited.toJson());
    },
  );

  test(
    'a failed safety copy aborts restore, import and deletion without touching data',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'sprout-backup-failure-',
      );
      try {
        final blocked = File('${root.path}/blocked');
        await blocked.writeAsString('This is a file, not a backup folder.');
        tracker.dispose();
        tracker = Tracker(
          store,
          GoogleAuth(),
          backups: BackupVault(Directory(blocked.path)),
        );
        await tracker.addActivity('Current', 1, id: 'current');
        final before = (await store.snapshot()).revision;
        await expectLater(tracker.restore(backupFixture()), throwsStateError);
        await expectLater(
          tracker.importToggl(
            'Project,Start date,Start time,Duration\nWork,2026-10-01,09:00:00,01:00:00',
          ),
          throwsStateError,
        );
        await expectLater(
          tracker.deleteActivity(tracker.activities.single),
          throwsStateError,
        );
        expect((await store.snapshot()).revision, before);
        // Automatic failure remains visible without preventing normal tracking.
        await tracker.createRecoveryCopy();
        expect(tracker.backupError, isNotNull);
        await tracker.start(tracker.activities.single);
        expect(tracker.current, isNotNull);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'a verified recovery copy captures the exact state before a restore',
    () async {
      final root = await Directory.systemTemp.createTemp('sprout-safety-');
      try {
        tracker.dispose();
        final vault = BackupVault(root);
        tracker = Tracker(store, GoogleAuth(), backups: vault);
        await tracker.addActivity('My existing garden', 1, id: 'existing');
        await tracker.restore(backupFixture());
        final copy = (await vault.list()).single;
        expect(copy.reason, 'restore');
        expect(copy.data!.activities.single.id, 'existing');
        expect(copy.data!.sessions, isEmpty);
        final count = (await vault.list()).length;
        await tracker.restore(backupFixture());
        expect((await vault.list()).length, count);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'freezing timers clamps a backwards wall clock and stale auto heartbeats',
    () {
      final manual = backupSession('manual', running: true);
      final backward = decodeBackup(
        encodeBackup(
          [backupActivity],
          [manual],
          manual.start.subtract(const Duration(hours: 1)),
        ),
      );
      expect(backward.sessions.single.duration(backupTime), Duration.zero);
      final automatic = Session(
        id: 'auto',
        activityId: backupActivity.id,
        deviceId: 'old',
        deviceName: 'Old',
        start: manual.start,
        lastSeen: manual.start.add(const Duration(minutes: 10)),
        source: 'auto',
      );
      expect(
        decodeBackup(
          encodeBackup([backupActivity], [automatic], backupTime),
        ).total,
        const Duration(minutes: 10),
      );
    },
  );
}
