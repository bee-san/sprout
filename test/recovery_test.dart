import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sprout/portability.dart';
import 'package:sprout/recovery.dart';
import 'package:sprout/store.dart';

import 'support/backup_fixture.dart';

void main() {
  late Directory root;
  late String databasePath;
  setUp(() async {
    sqfliteFfiInit();
    root = await Directory.systemTemp.createTemp('sprout-recovery-');
    databasePath = '${root.path}/timebud.sqlite';
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test(
    'startup checks corruption read-only and preserves the original bytes',
    () async {
      await File(
        databasePath,
      ).writeAsString('Damaged database; keep every byte');
      final original = await File(databasePath).readAsBytes();
      await expectLater(
        Store.open(
          factory: databaseFactoryFfiNoIsolate,
          databasePath: databasePath,
        ),
        throwsA(isA<DatabaseException>()),
      );
      expect(await File(databasePath).readAsBytes(), original);
    },
  );

  test(
    'a corrupt database recovers only after a verified replacement is ready, preserving originals and WAL',
    () async {
      await File(databasePath).writeAsString('Damaged original database');
      await File('$databasePath-wal').writeAsString('Original WAL');
      await File('$databasePath-shm').writeAsString('Original SHM');
      final originals = await recoverDatabase(
        databasePath: databasePath,
        content: backupFixture(running: true),
        factory: databaseFactoryFfiNoIsolate,
        options: const RestoreOptions(deviceSettings: true),
      );
      expect(
        await File('${originals.path}/timebud.sqlite').readAsString(),
        'Damaged original database',
      );
      expect(
        await File('${originals.path}/timebud.sqlite-wal').readAsString(),
        'Original WAL',
      );
      expect(
        await File('${originals.path}/timebud.sqlite-shm').readAsString(),
        'Original SHM',
      );
      final recovered = await Store.open(
        factory: databaseFactoryFfiNoIsolate,
        databasePath: databasePath,
      );
      try {
        expect((await recovered.sessions()).length, 2);
        expect((await recovered.sessions()).every((s) => !s.isRunning), isTrue);
        expect(
          (await recovered.activities()).single.toJson(),
          backupActivity.toJson(),
        );
        expect((await recovered.rules()).single.enabled, isFalse);
        expect(await recovered.setting('notifications'), 'false');
        expect(
          (await recovered.db.rawQuery(
            'PRAGMA integrity_check',
          )).single.values.single,
          'ok',
        );
        expect(recovered.deviceId, isNot('original-phone'));
      } finally {
        await recovered.close();
      }
    },
  );

  test(
    'an invalid recovery backup leaves the original byte-for-byte untouched',
    () async {
      await File(databasePath).writeAsString('Keep this exact database');
      final original = await File(databasePath).readAsBytes();
      await expectLater(
        recoverDatabase(
          databasePath: databasePath,
          content: backupFixture().replaceFirst('My studio', 'Damaged'),
          factory: databaseFactoryFfiNoIsolate,
        ),
        throwsFormatException,
      );
      expect(await File(databasePath).readAsBytes(), original);
      expect((await root.list().toList()).length, 1);
    },
  );

  test(
    'recovery keeps a previously usable database available in its original archive',
    () async {
      final old = await Store.open(
        factory: databaseFactoryFfiNoIsolate,
        databasePath: databasePath,
      );
      final oldIdentity = old.deviceId;
      await old.write('activity', 'original', {
        'id': 'original',
        'name': 'Original data',
        'color': 1,
      });
      await old.close();
      final originals = await recoverDatabase(
        databasePath: databasePath,
        content: backupFixture(),
        factory: databaseFactoryFfiNoIsolate,
      );
      final archived = await Store.open(
        factory: databaseFactoryFfiNoIsolate,
        databasePath: '${originals.path}/timebud.sqlite',
      );
      try {
        expect(archived.deviceId, oldIdentity);
        expect((await archived.activities()).single.name, 'Original data');
      } finally {
        await archived.close();
      }
    },
  );
}
