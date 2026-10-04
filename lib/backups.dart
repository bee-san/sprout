import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

import 'portability.dart';

Future<String> readPortableFile(File file) async {
  if (await file.length() > maxPortableBytes) {
    throw const FormatException('Choose a file smaller than 32 MB.');
  }
  return file.readAsString();
}

/// Stage, flush and read back before publishing a document. Preserve an
/// existing destination until the replacement is verified; roll back on error.
Future<void> writeVerifiedDocument(
  File destination,
  String content, {
  bool backup = false,
}) async {
  if (backup) decodeBackup(content);
  final bytes = utf8.encode(content);
  final expected = sha256.convert(bytes);
  final suffix = const Uuid().v4();
  final temporary = File('${destination.path}.$suffix.tmp');
  final previous = File('${destination.path}.$suffix.previous');
  var preserved = false;
  var published = false;
  try {
    await temporary.writeAsBytes(bytes, flush: true);
    if (sha256.convert(await temporary.readAsBytes()) != expected) {
      throw const FileSystemException('Document verification failed.');
    }
    if (await destination.exists()) {
      await destination.rename(previous.path);
      preserved = true;
    }
    await temporary.rename(destination.path);
    published = true;
    if (sha256.convert(await destination.readAsBytes()) != expected) {
      throw const FileSystemException('Saved document verification failed.');
    }
    if (preserved) await previous.delete();
  } catch (_) {
    if (published && await destination.exists()) await destination.delete();
    if (preserved && await previous.exists()) {
      await previous.rename(destination.path);
    }
    rethrow;
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
}

class LocalBackup {
  const LocalBackup(this.file, this.reason, this.data, this.error);
  final File file;
  final String reason;
  final BackupData? data;
  final String? error;
  String get label => switch (reason) {
    'daily' => 'Automatic copy',
    'import' => 'Before Toggl import',
    'restore' => 'Before restore',
    'delete' => 'Before deletion',
    _ => 'Recovery copy',
  };
}

class BackupVault {
  BackupVault(this.directory);
  final Directory directory;
  Future<void> _queue = Future.value();
  static const dailyDays = 7;
  static const safetyCopies = 8;

  Future<T> _serial<T>(Future<T> Function() action) {
    final next = _queue.then((_) => action());
    _queue = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<LocalBackup> save(String content, String reason) => _serial(() async {
    if (!{'daily', 'import', 'restore', 'delete'}.contains(reason)) {
      throw ArgumentError.value(reason, 'reason');
    }
    final data = decodeBackup(content);
    await directory.create(recursive: true);
    final stamp = data.exportedAt.toUtc().toIso8601String().replaceAll(
      RegExp(r'[^0-9]'),
      '',
    );
    final file = File(
      path.join(
        directory.path,
        'sprout-$reason-$stamp-${const Uuid().v4()}.json',
      ),
    );
    await writeVerifiedDocument(file, content, backup: true);
    // Prune only after the new copy is safely published. Damaged copies are
    // retained for inspection and never displace verified recovery copies.
    await _prune(file.path);
    return LocalBackup(file, reason, data, null);
  });

  Future<List<LocalBackup>> list() => _serial(_list);

  Future<List<LocalBackup>> _list() async {
    if (!await directory.exists()) return [];
    final files = await directory
        .list(followLinks: false)
        .where(
          (entry) =>
              entry is File &&
              RegExp(
                r'^sprout-(daily|import|restore|delete)-[0-9]+-[a-f0-9-]+\.json$',
              ).hasMatch(path.basename(entry.path)),
        )
        .cast<File>()
        .toList();
    files.sort(
      (a, b) => path
          .basename(b.path)
          .split('-')[2]
          .compareTo(path.basename(a.path).split('-')[2]),
    );
    final result = <LocalBackup>[];
    for (final file in files) {
      final reason = path.basename(file.path).split('-')[1];
      try {
        result.add(
          LocalBackup(
            file,
            reason,
            decodeBackup(await readPortableFile(file)),
            null,
          ),
        );
      } catch (_) {
        result.add(
          LocalBackup(
            file,
            reason,
            null,
            'This copy could not be verified. Choose another backup.',
          ),
        );
      }
    }
    return result;
  }

  Future<void> _prune(String protectedPath) async {
    final backups = await _list();
    final current = backups.firstWhere((b) => b.file.path == protectedPath);
    backups.remove(current);
    backups.insert(0, current);
    final days = <String>{};
    var safety = 0;
    for (final backup in backups) {
      if (backup.data == null) continue;
      var keep = false;
      if (backup.reason == 'daily') {
        final day = backup.data!.exportedAt
            .toUtc()
            .toIso8601String()
            .split('T')
            .first;
        if (!days.contains(day) && days.length < dailyDays) {
          days.add(day);
          keep = true;
        }
      } else {
        keep = safety++ < safetyCopies;
      }
      if (!keep) await backup.file.delete();
    }
  }
}
