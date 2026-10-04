import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sprout/drive_sync.dart';
import 'package:sprout/model.dart';
import 'package:sprout/store.dart';
import 'support/fake_drive.dart';

void main() {
  late Store a;
  late Store b;
  late FakeDrive remote;
  late FakeAuth auth;
  late DriveSync syncA;
  late DriveSync syncB;
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
    remote = FakeDrive();
    auth = FakeAuth();
    syncA = DriveSync(
      a,
      auth,
      client: remote.client,
      retryDelay: Duration.zero,
    );
    syncB = DriveSync(
      b,
      FakeAuth(),
      client: remote.client,
      retryDelay: Duration.zero,
    );
  });
  tearDown(() async {
    remote.client.close();
    await a.close();
    await b.close();
  });

  test(
    'offline edits recover, unchanged downloads are skipped, and pagination retains both devices',
    () async {
      await a.write('activity', 'a', {
        'id': 'a',
        'name': 'Reading',
        'color': 1,
      });
      await syncA.sync();
      await syncB.sync();
      final downloads = remote.downloads;
      await syncB.sync();
      // B sees its own newly uploaded file once; the next pass is a no-op.
      await syncB.sync();
      expect(remote.downloads, downloads + 1);
      remote.offline = true;
      await a.write('activity', 'a', {'id': 'a', 'name': 'Books', 'color': 1});
      await b.write('activity', 'b', {'id': 'b', 'name': 'Study', 'color': 2});
      await syncA.sync();
      expect(syncA.error, contains('offline'));
      expect(await a.setting('dirty'), isNot(await a.setting('synced')));
      remote.offline = false;
      remote.pageSize = 1;
      await syncA.sync();
      await syncB.sync();
      await syncA.sync();
      expect(syncA.error, isNull);
      expect(syncB.error, isNull);
      expect((await a.activities()).map((x) => x.name).toSet(), {
        'Books',
        'Study',
      });
      expect((await b.activities()).map((x) => x.name).toSet(), {
        'Books',
        'Study',
      });
    },
  );

  test(
    'expired access tokens refresh and transient server failures retry',
    () async {
      remote.expiredOnce = true;
      await syncA.sync();
      expect(syncA.error, isNull);
      expect(auth.refreshes, greaterThan(0));
      remote.transientFailures = 2;
      await syncA.sync();
      expect(syncA.error, isNull);
    },
  );

  test(
    'a local edit made during an upload is still dirty and uploads on the next pass',
    () async {
      await a.write('activity', 'a', {'id': 'a', 'name': 'Before', 'color': 1});
      remote.duringUpload = () async {
        await a.write('activity', 'a', {
          'id': 'a',
          'name': 'During upload',
          'color': 2,
          'client': 'Demo',
        });
      };
      await syncA.sync();
      expect(await a.setting('dirty'), isNot(await a.setting('synced')));
      await syncA.sync();
      await syncB.sync();
      expect((await b.activities()).single.name, 'During upload');
      expect((await b.activities()).single.client, 'Demo');
      expect(remote.files.length, 2);
    },
  );

  test(
    'malformed remote journals cannot partially import and a repaired journal can recover',
    () async {
      final valid = const Mutation(
        kind: 'activity',
        id: 'a',
        clock: 1,
        device: 'remote',
        data: {'id': 'a', 'name': 'Valid', 'color': 1},
      ).toJson();
      final id = remote.addJournal('timebud-v1-remote.json', {
        'schema': 1,
        'device': 'remote',
        'records': [
          valid,
          {
            'kind': 'session',
            'id': 'bad',
            'clock': 2,
            'device': 'remote',
            'deleted': false,
            'data': {},
          },
        ],
      });
      await syncA.sync();
      expect(syncA.error, isNotNull);
      expect(await a.activities(), isEmpty);
      expect(await a.setting('remote:$id'), isNull);
      remote.setPayload(
        id,
        jsonEncode({
          'schema': 1,
          'device': 'remote',
          'records': [valid],
        }),
      );
      await syncA.sync();
      expect(syncA.error, isNull);
      expect((await a.activities()).single.name, 'Valid');
    },
  );

  test(
    'session metadata converges through conflict, stop, and deletion without resurrection',
    () async {
      final start = DateTime.utc(2026, 1, 2, 9);
      final session = Session(
        id: 's',
        activityId: 'a',
        deviceId: a.deviceId,
        deviceName: 'Demo',
        start: start,
        lastSeen: start,
        note: 'Draft',
        tags: const ['focus'],
        billable: true,
      );
      await a.write('session', 's', session.toJson());
      await syncA.sync();
      await syncB.sync();
      await a.write(
        'session',
        's',
        session
            .copyWith(note: 'Edit A', end: start.add(const Duration(hours: 1)))
            .toJson(),
      );
      await b.write(
        'session',
        's',
        session
            .copyWith(
              note: 'Edit B',
              tags: ['edited'],
              end: start.add(const Duration(hours: 2)),
            )
            .toJson(),
      );
      await syncA.sync();
      await syncB.sync();
      await syncA.sync();
      expect(
        (await a.sessions()).single.toJson(),
        (await b.sessions()).single.toJson(),
      );
      final winner = (await a.sessions()).single;
      expect(winner.billable, isTrue);
      expect(winner.end, isNotNull);
      final stale = await a.owned();
      await b.write('session', 's', winner.toJson(), deleted: true);
      await syncB.sync();
      await syncA.sync();
      await a.merge(stale);
      expect(await a.sessions(), isEmpty);
      expect(await b.sessions(), isEmpty);
    },
  );
}
