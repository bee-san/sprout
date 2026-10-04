import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sprout/controller.dart';
import 'package:sprout/google_auth.dart';
import 'package:sprout/model.dart';
import 'package:sprout/portability.dart';
import 'package:sprout/store.dart';
import 'package:sprout/drive_sync.dart';
import 'support/fake_drive.dart';

const header =
    'User,Email,Client,Project,Task,Description,Billable,Start date,Start time,End date,End time,Duration,Tags\r\n';
const entry =
    'Demo,demo@example.invalid,Studio,Design,Review,"A note, with ""quotes""\nand a newline",Yes,2026-01-02,09:00:00,2026-01-02,10:30:00,01:30:00,"focus, work"\r\n';

void main() {
  ImportPlan plan(
    String csv, {
    List<Activity> activities = const [],
    List<Session> sessions = const [],
  }) => planTogglImport(
    csv,
    activities: activities,
    sessions: sessions,
    deviceId: 'test',
    deviceName: 'Test',
  );

  test(
    'Toggl import preserves quoted descriptions, client, tags and billable time',
    () {
      final result = plan('\uFEFF$header$entry');
      expect(
        result.sessions.single.note,
        'Task: Review\nA note, with "quotes"\nand a newline',
      );
      expect(result.sessions.single.tags, ['focus', 'work']);
      expect(result.sessions.single.billable, isTrue);
      expect(result.activities.single.client, 'Studio');
      expect(
        result.sessions.single.duration(DateTime.now()),
        const Duration(minutes: 90),
      );
      final repeated = plan(
        '$header$entry$entry',
        activities: result.activities,
        sessions: result.sessions,
      );
      expect(repeated.sessions.length, 1);
      expect(repeated.skipped, 1);
      final again = plan(
        '$header$entry$entry',
        activities: result.activities,
        sessions: [...result.sessions, ...repeated.sessions],
      );
      expect(again.sessions, isEmpty);
      expect(again.skipped, 2);
    },
  );

  test(
    'duration-only exports import and invalid rows fail before any database write',
    () async {
      final result = plan(
        'Project,Start date,Start time,Duration\nReading,2026-01-02,23:30:00,02:00:00',
      );
      expect(result.sessions.single.end!.day, 3);
      expect(
        () => plan(
          '$header${entry}Demo,demo@example.invalid,Studio,Design,,,No,2026-02-30,09:00:00,2026-03-01,09:00:00,00:00:00,\n',
        ),
        throwsFormatException,
      );
      sqfliteFfiInit();
      final store = await Store.open(
        factory: databaseFactoryFfiNoIsolate,
        databasePath: inMemoryDatabasePath,
      );
      final tracker = Tracker(store, GoogleAuth());
      try {
        await expectLater(
          tracker.importToggl('$header${entry}invalid,row\n'),
          throwsFormatException,
        );
        expect(await store.sessions(), isEmpty);
        expect(await store.activities(), isEmpty);
      } finally {
        tracker.dispose();
        await store.close();
      }
    },
  );

  test(
    'later Toggl exports retain local edits to imported activities',
    () async {
      sqfliteFfiInit();
      final store = await Store.open(
        factory: databaseFactoryFfiNoIsolate,
        databasePath: inMemoryDatabasePath,
      );
      final tracker = Tracker(store, GoogleAuth());
      try {
        await tracker.importToggl('$header$entry');
        final id = tracker.activities.single.id;
        await tracker.addActivity('My design', 42, id: id, client: 'My studio');
        final later = entry.replaceFirst(
          '2026-01-02,09:00:00',
          '2026-01-03,09:00:00',
        );
        final result = await tracker.importToggl('$header$entry$later');
        expect(result.imported, 1);
        expect(result.skipped, 1);
        expect(tracker.activities.length, 1);
        expect(tracker.activities.single.name, 'My design');
        expect(tracker.activities.single.client, 'My studio');
        expect(tracker.activities.single.color, 42);
        expect(tracker.sessions.length, 2);
        expect(tracker.sessions.every((s) => s.activityId == id), isTrue);
      } finally {
        tracker.dispose();
        await store.close();
      }
    },
  );

  test(
    'portable backup freezes active timers and preserves metadata without account secrets',
    () {
      final imported = plan('$header$entry');
      final running = Session(
        id: 'live',
        activityId: imported.activities.single.id,
        deviceId: 'old',
        deviceName: 'Old',
        start: DateTime(2026, 1, 2, 9),
        lastSeen: DateTime(2026, 1, 2, 9),
        note: 'Draft',
        tags: const ['focus'],
        billable: true,
      );
      final backup = encodeBackup(imported.activities, [
        ...imported.sessions,
        running,
      ], DateTime(2026, 1, 2, 11));
      expect((jsonDecode(backup) as Map).keys.toSet(), {
        'application',
        'schema',
        'exportedAt',
        'activities',
        'sessions',
        'rules',
        'preferences',
        'frozenTimers',
        'checksum',
      });
      final restored = planRestore(
        backup,
        activities: [],
        sessions: [],
        deviceId: 'new',
        deviceName: 'New',
      );
      expect(restored.sessions.every((s) => !s.isRunning), isTrue);
      expect(
        restored.sessions.last.duration(DateTime.now()),
        const Duration(hours: 2),
      );
      expect(restored.sessions.last.tags, ['focus']);
      expect(restored.sessions.last.deviceId, 'old');
      final again = planRestore(
        backup,
        activities: restored.activities,
        sessions: restored.sessions,
        deviceId: 'new',
        deviceName: 'New',
      );
      expect(again.sessions, isEmpty);
      expect(again.skipped, 2);
    },
  );

  test('CSV output protects spreadsheet formulas, quotes and newlines', () {
    expect(
      csvCell('=HYPERLINK("https://example.invalid")'),
      startsWith('"\'='),
    );
    final imported = plan('$header$entry');
    final csv = exportSessionsCsv(
      imported.sessions,
      (_) => 'Design',
      DateTime.now(),
    );
    final rows = parseCsv(csv);
    expect(rows.last[8], imported.sessions.single.note);
    expect(rows.last[9], 'focus; work');
    expect(rows.last[10], 'yes');
  });

  test(
    're-importing a CSV respects deliberately deleted entries and activities',
    () async {
      sqfliteFfiInit();
      final store = await Store.open(
        factory: databaseFactoryFfiNoIsolate,
        databasePath: inMemoryDatabasePath,
      );
      final tracker = Tracker(store, GoogleAuth());
      try {
        await tracker.importToggl('$header$entry');
        await tracker.deleteSession(tracker.sessions.single);
        expect((await tracker.importToggl('$header$entry')).imported, 0);
        await tracker.deleteActivity(tracker.activities.single);
        final later = entry.replaceFirst(
          '2026-01-02,09:00:00',
          '2026-01-03,09:00:00',
        );
        expect((await tracker.importToggl('$header$entry$later')).imported, 1);
        expect(tracker.activities, isEmpty);
        expect(tracker.sessions.length, 1);
      } finally {
        tracker.dispose();
        await store.close();
      }
    },
  );

  // Opt in locally; a user's CSV is never a repository fixture.
  final localCsv = Platform.environment['SPROUT_TOGGL_CSV'];
  if (localCsv != null) {
    test(
      'private local Toggl export imports completely and repeated imports add nothing',
      () async {
        final csv = await File(localCsv).readAsString();
        final rows = parseCsv(csv);
        final result = plan(csv);
        expect(result.sessions.length + result.skipped, rows.length - 1);
        expect(result.skipped, 0);
        final durationIndex = rows.first.indexOf('Duration');
        final expectedSeconds = rows.skip(1).fold<int>(0, (total, row) {
          final hms = row[durationIndex].split(':').map(int.parse).toList();
          return total + hms[0] * 3600 + hms[1] * 60 + hms[2];
        });
        expect(
          result.sessions.fold<int>(
            0,
            (v, s) => v + s.duration(DateTime.now()).inSeconds,
          ),
          expectedSeconds,
        );
        final repeated = plan(
          csv,
          activities: result.activities,
          sessions: result.sessions,
        );
        expect(repeated.sessions, isEmpty);
        expect(repeated.skipped, result.sessions.length);
        sqfliteFfiInit();
        final store = await Store.open(
          factory: databaseFactoryFfiNoIsolate,
          databasePath: inMemoryDatabasePath,
        );
        final tracker = Tracker(store, GoogleAuth());
        final replica = await Store.open(
          factory: databaseFactoryFfiNoIsolate,
          databasePath: inMemoryDatabasePath,
        );
        final remote = FakeDrive();
        try {
          final imported = await tracker.importToggl(csv);
          expect(imported.imported, result.sessions.length);
          final duplicate = await tracker.importToggl(csv);
          expect(duplicate.imported, 0);
          expect((await store.sessions()).length, result.sessions.length);
          final backup = await tracker.backup();
          final restoredStore = await Store.open(
            factory: databaseFactoryFfiNoIsolate,
            databasePath: inMemoryDatabasePath,
          );
          final restoredTracker = Tracker(restoredStore, GoogleAuth());
          try {
            final restored = await restoredTracker.restore(backup);
            expect(restored.imported, result.sessions.length);
            expect(
              (await restoredStore.sessions()).fold<int>(
                0,
                (sum, s) => sum + s.duration(DateTime.now()).inSeconds,
              ),
              expectedSeconds,
            );
            expect((await restoredTracker.restore(backup)).imported, 0);
            expect(
              {
                for (final s in await restoredStore.sessions())
                  s.id: s.toJson(),
              },
              {for (final s in await store.sessions()) s.id: s.toJson()},
            );
          } finally {
            restoredTracker.dispose();
            await restoredStore.close();
          }
          final driveA = DriveSync(
            store,
            FakeAuth(),
            client: remote.client,
            retryDelay: Duration.zero,
          );
          final driveB = DriveSync(
            replica,
            FakeAuth(),
            client: remote.client,
            retryDelay: Duration.zero,
          );
          await driveA.sync();
          await driveB.sync();
          await driveA.sync();
          expect(driveA.error, isNull);
          expect(driveB.error, isNull);
          expect((await replica.sessions()).length, result.sessions.length);
          final remoteSessions = (await replica.sessions())
              .map((s) => s.toJson())
              .toList();
          expect(
            remoteSessions,
            (await store.sessions()).map((s) => s.toJson()).toList(),
          );
        } finally {
          tracker.dispose();
          remote.client.close();
          await replica.close();
          await store.close();
        }
      },
    );
  }
}
