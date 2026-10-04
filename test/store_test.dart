import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sprout/controller.dart';
import 'package:sprout/google_auth.dart';
import 'package:sprout/model.dart';
import 'package:sprout/store.dart';

void main() {
  late Store a;
  late Store b;
  setUp(() async {
    sqfliteFfiInit();
    a = await Store.open(
      factory: databaseFactoryFfiNoIsolate,
      databasePath: inMemoryDatabasePath,
    );
    b = await Store.open(
      factory: databaseFactoryFfiNoIsolate,
      databasePath: inMemoryDatabasePath,
    );
    expect(a.deviceId, isNot(b.deviceId));
  });
  tearDown(() async {
    await a.close();
    await b.close();
  });
  test(
    'two devices retain independent offline sessions and tombstones on repeated sync',
    () async {
      const activity = Activity(id: 'Japanese', name: 'Japanese', color: 1);
      await a.write('activity', activity.id, activity.toJson());
      await b.merge(await a.owned());
      final time = DateTime.utc(2026, 10, 4);
      Session session(Store store, String id) => Session(
        id: id,
        activityId: activity.id,
        deviceId: store.deviceId,
        deviceName: store.deviceName,
        start: time,
        end: time.add(const Duration(minutes: 30)),
        lastSeen: time,
      );
      final sa = session(a, 'PC-session');
      final sb = session(b, 'phone-session');
      await a.write('session', sa.id, sa.toJson());
      await b.write('session', sb.id, sb.toJson());
      await a.merge(await b.owned());
      await b.merge(await a.owned());
      expect((await a.sessions()).map((s) => s.id).toSet(), {
        'PC-session',
        'phone-session',
      });
      expect((await b.sessions()).map((s) => s.id).toSet(), {
        'PC-session',
        'phone-session',
      });
      final stale = await a.owned();
      await b.write('session', sa.id, sa.toJson(), deleted: true);
      await a.merge(await b.owned());
      await b.merge(stale);
      expect((await a.sessions()).map((s) => s.id).toList(), ['phone-session']);
      expect((await b.sessions()).map((s) => s.id).toList(), ['phone-session']);
    },
  );
  test(
    'failed timer switches roll back completely, leaving the original timer active',
    () async {
      final tracker = Tracker(a, GoogleAuth());
      await tracker.addActivity('Reading', 1, id: 'reading');
      await tracker.addActivity('Work', 2, id: 'work');
      await tracker.start(tracker.activity('reading')!);
      final currentId = tracker.current!.id;
      await a.db.execute(
        "CREATE TRIGGER reject_new_session BEFORE INSERT ON entities WHEN NEW.kind = 'session' AND NEW.key != 'session:$currentId' BEGIN SELECT RAISE(ABORT, 'simulated disk failure'); END",
      );
      await expectLater(
        tracker.start(tracker.activity('work')!),
        throwsA(isA<DatabaseException>()),
      );
      final sessions = await a.sessions();
      expect(sessions.length, 1);
      expect(sessions.single.id, currentId);
      expect(sessions.single.isRunning, isTrue);
      tracker.dispose();
    },
  );

  test(
    'editing and continuing a timer preserve notes, tags and billable flags',
    () async {
      final tracker = Tracker(a, GoogleAuth());
      await tracker.addActivity('Work', 1, id: 'work');
      await tracker.start(tracker.activities.single);
      final before = tracker.current!;
      await tracker.saveSession(
        before.copyWith(note: 'Draft', tags: ['focus'], billable: true),
      );
      expect(tracker.current!.id, before.id);
      expect(tracker.current!.isRunning, isTrue);
      await tracker.stop();
      await tracker.continueSession(tracker.sessions.single);
      expect(tracker.current!.id, isNot(before.id));
      expect(tracker.current!.note, 'Draft');
      expect(tracker.current!.tags, ['focus']);
      expect(tracker.current!.billable, isTrue);
      tracker.dispose();
    },
  );
  test(
    'Windows upgrade reuses the legacy database and identity without copying',
    () async {
      final root = await Directory.systemTemp.createTemp('sprout-upgrade-');
      Store? legacy;
      Store? reopened;
      try {
        final oldDirectory = await Directory(
          path.join(root.path, 'Timebud'),
        ).create();
        final newDirectory = await Directory(
          path.join(root.path, 'Sprout'),
        ).create();
        final oldPath = path.join(oldDirectory.path, 'timebud.sqlite');
        legacy = await Store.open(
          factory: databaseFactoryFfiNoIsolate,
          databasePath: oldPath,
        );
        final device = legacy.deviceId;
        await legacy.write('activity', 'saved', {
          'id': 'saved',
          'name': 'Saved work',
          'color': 1,
        });
        await legacy.close();
        legacy = null;
        final selected = resolveDatabasePath(
          newDirectory.path,
          legacyWindows: true,
        );
        expect(selected, oldPath);
        reopened = await Store.open(
          factory: databaseFactoryFfiNoIsolate,
          databasePath: selected,
        );
        expect(reopened.deviceId, device);
        expect((await reopened.activities()).single.name, 'Saved work');
        final newPath = path.join(newDirectory.path, 'timebud.sqlite');
        await File(newPath).writeAsString('Existing Sprout database');
        expect(
          resolveDatabasePath(newDirectory.path, legacyWindows: true),
          newPath,
        );
        expect(resolveDatabasePath(newDirectory.path), newPath);
      } finally {
        await legacy?.close();
        await reopened?.close();
        await root.delete(recursive: true);
      }
    },
  );

  test('new local edits advance past imported clocks', () async {
    await a.merge([
      const Mutation(
        kind: 'activity',
        id: 'x',
        clock: 900,
        device: 'other',
        data: {'id': 'x', 'name': 'Old', 'color': 1},
      ),
    ]);
    final local = await a.write('activity', 'x', {
      'id': 'x',
      'name': 'New',
      'color': 2,
    });
    expect(local.clock, 901);
    expect((await a.activities()).single.name, 'New');
  });
  test(
    'switching manual activities closes the previous session atomically in sequence',
    () async {
      final tracker = Tracker(a, GoogleAuth());
      await tracker.addActivity('Japanese', 1, id: 'j');
      await tracker.addActivity('Gaming', 2, id: 'g');
      await tracker.start(tracker.activity('j')!);
      await tracker.start(tracker.activity('g')!);
      expect(tracker.sessions.where((s) => s.isRunning).length, 1);
      expect(tracker.current?.activityId, 'g');
      expect(
        tracker.sessions.firstWhere((s) => s.activityId == 'j').end,
        isNotNull,
      );
      await tracker.stop();
      expect(tracker.current, isNull);
      tracker.dispose();
    },
  );
}
