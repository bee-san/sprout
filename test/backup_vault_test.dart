import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sprout/backups.dart';
import 'package:sprout/portability.dart';

import 'support/backup_fixture.dart';

void main() {
  late Directory root;
  late BackupVault vault;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('sprout-vault-');
    vault = BackupVault(Directory('${root.path}/backups'));
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test(
    'exports stage, verify and safely replace a previous destination',
    () async {
      final file = File('${root.path}/portable.json');
      await file.writeAsString('Previous file');
      await writeVerifiedDocument(file, backupFixture(), backup: true);
      expect(await file.readAsString(), backupFixture());
      expect(decodeBackup(await file.readAsString()).verified, isTrue);
      expect((await root.list().toList()).whereType<File>().length, 1);
      await expectLater(
        writeVerifiedDocument(file, '{broken', backup: true),
        throwsFormatException,
      );
      expect(await file.readAsString(), backupFixture());
    },
  );

  test(
    'a failed publish leaves other files intact and removes staging files',
    () async {
      final original = File('${root.path}/existing.json');
      await original.writeAsString(backupFixture());
      final destination = Directory('${root.path}/folder');
      await destination.create();
      await expectLater(
        writeVerifiedDocument(
          File(destination.path),
          backupFixture(),
          backup: true,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await original.readAsString(), backupFixture());
      expect(await destination.exists(), isTrue);
      expect(
        (await root.list().toList()).where((f) => f.path.endsWith('.tmp')),
        isEmpty,
      );
    },
  );

  test(
    'retention keeps one newest automatic copy per day for seven days and eight safety copies',
    () async {
      String content(int day, int minute) => encodeBackup(
        [backupActivity],
        [backupSession('saved')],
        DateTime.utc(2026, 10, day, 12, minute),
      );
      for (var day = 4; day <= 13; day++) {
        await vault.save(content(day, 0), 'daily');
        await vault.save(content(day, 1), 'daily');
      }
      for (var n = 0; n < 11; n++) {
        await vault.save(content(14, n), n.isEven ? 'restore' : 'delete');
      }
      final copies = await vault.list();
      final daily = copies.where((c) => c.reason == 'daily').toList();
      final safety = copies.where((c) => c.reason != 'daily').toList();
      expect(daily.length, BackupVault.dailyDays);
      expect(daily.map((c) => c.data!.exportedAt.day).toSet(), {
        7,
        8,
        9,
        10,
        11,
        12,
        13,
      });
      expect(daily.every((c) => c.data!.exportedAt.minute == 1), isTrue);
      expect(safety.length, BackupVault.safetyCopies);
      expect(safety.map((c) => c.data!.exportedAt.minute).toSet(), {
        3,
        4,
        5,
        6,
        7,
        8,
        9,
        10,
      });
    },
  );

  test(
    'damaged recovery copies are visible and never displace good copies',
    () async {
      final damaged = await vault.save(backupFixture(), 'restore');
      await damaged.file.writeAsString('{truncated');
      for (var n = 0; n < 9; n++) {
        await vault.save(
          encodeBackup(
            [backupActivity],
            [backupSession('saved')],
            backupTime.add(Duration(minutes: n + 1)),
          ),
          'restore',
        );
      }
      final list = await vault.list();
      expect(
        list.where((c) => c.data != null).length,
        BackupVault.safetyCopies,
      );
      expect(
        list.where((c) => c.data == null).single.error,
        contains('could not be verified'),
      );
      expect(await damaged.file.exists(), isTrue);
    },
  );

  test('a failed new snapshot cannot prune previous recovery copies', () async {
    final previous = await vault.save(backupFixture(), 'restore');
    await expectLater(
      vault.save(
        backupFixture().replaceFirst('My studio', 'Changed'),
        'restore',
      ),
      throwsFormatException,
    );
    expect(await previous.file.exists(), isTrue);
    expect((await vault.list()).length, 1);
  });

  test(
    'parallel saves serialize and retain the newest verified safety copies',
    () async {
      await Future.wait(
        List.generate(
          12,
          (n) => vault.save(
            encodeBackup(
              [backupActivity],
              [backupSession('saved')],
              backupTime.add(Duration(minutes: n)),
            ),
            'import',
          ),
        ),
      );
      final list = await vault.list();
      expect(list.length, BackupVault.safetyCopies);
      expect(list.first.data!.exportedAt.minute, 11);
      expect(list.every((c) => c.data!.verified), isTrue);
    },
  );

  test('a backwards clock never prunes the copy that was just saved', () async {
    for (var day = 4; day < 14; day++) {
      await vault.save(
        encodeBackup(
          [backupActivity],
          [backupSession('saved')],
          DateTime.utc(2026, 10, day, 12),
        ),
        'daily',
      );
    }
    final newest = await vault.save(backupFixture(), 'daily');
    expect(await newest.file.exists(), isTrue);
    expect((await vault.list()).length, BackupVault.dailyDays);
  });

  test('oversized files fail before JSON parsing', () async {
    final huge = File('${root.path}/huge.json');
    final handle = await huge.open(mode: FileMode.write);
    await handle.truncate(maxPortableBytes + 1);
    await handle.close();
    await expectLater(readPortableFile(huge), throwsFormatException);
  });
}
