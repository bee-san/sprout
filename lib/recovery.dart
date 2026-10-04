import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'portability.dart';
import 'store.dart';

/// Build and integrity-check a replacement before touching the original. Keep
/// the original database and its WAL/SHM companions together for recovery.
Future<Directory> recoverDatabase({
  required String databasePath,
  required String content,
  DatabaseFactory? factory,
  RestoreOptions options = const RestoreOptions(),
}) async {
  final backup = decodeBackup(content);
  final parent = Directory(path.dirname(databasePath));
  await parent.create(recursive: true);
  final id = const Uuid().v4();
  final preparedPath = path.join(parent.path, 'sprout-recovery-$id.sqlite');
  final originals = Directory(path.join(parent.path, 'recovery-original-$id'));
  final moved = <(String, String)>[];
  Store? prepared;
  var installed = false;
  try {
    prepared = await Store.open(factory: factory, databasePath: preparedPath);
    await prepared.applyImport(
      (snapshot) => snapshot.restorePlan(backup, options),
    );
    final check = await prepared.db.rawQuery('PRAGMA integrity_check');
    if (check.length != 1 || check.first.values.single != 'ok') {
      throw StateError('The recovered database failed its integrity check.');
    }
    final checkpoint = await prepared.db.rawQuery(
      'PRAGMA wal_checkpoint(TRUNCATE)',
    );
    if (checkpoint.first.values.first != 0) {
      throw StateError('The recovered database could not be finalized.');
    }
    await prepared.close();
    prepared = null;
    await originals.create();
    for (final suffix in ['', '-wal', '-shm']) {
      final original = File('$databasePath$suffix');
      if (!await original.exists()) continue;
      final savedPath = path.join(originals.path, path.basename(original.path));
      await original.rename(savedPath);
      moved.add((original.path, savedPath));
    }
    await File(preparedPath).rename(databasePath);
    installed = true;
    return originals;
  } catch (_) {
    if (!installed) {
      for (final pair in moved.reversed) {
        if (!await File(pair.$1).exists()) await File(pair.$2).rename(pair.$1);
      }
    }
    rethrow;
  } finally {
    await prepared?.close();
    for (final suffix in ['', '-wal', '-shm']) {
      final file = File('$preparedPath$suffix');
      if (await file.exists()) await file.delete();
    }
  }
}
