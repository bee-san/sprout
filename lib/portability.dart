import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'model.dart';

class ImportResult {
  const ImportResult(this.imported, this.skipped, {this.activities = 0});
  final int imported;
  final int skipped;
  final int activities;
}

class ImportPlan {
  const ImportPlan(this.activities, this.sessions, this.skipped);
  final List<Activity> activities;
  final List<Session> sessions;
  final int skipped;
}

const maxPortableBytes = 32 * 1024 * 1024;

class RestoreOptions {
  const RestoreOptions({
    this.includeDeleted = false,
    this.deviceSettings = false,
  });
  final bool includeDeleted;
  final bool deviceSettings;
}

class BackupData {
  const BackupData({
    required this.activities,
    required this.sessions,
    required this.exportedAt,
    required this.verified,
    this.rules = const [],
    this.preferences = const {},
    this.frozenTimers = 0,
    this.recoveredActivityNames = 0,
  });
  final List<Activity> activities;
  final List<Session> sessions;
  final List<AppRule> rules;
  final Map<String, bool> preferences;
  final DateTime exportedAt;
  final bool verified;
  final int frozenTimers;
  final int recoveredActivityNames;
  Duration get total =>
      sessions.fold(Duration.zero, (sum, s) => sum + s.duration(exportedAt));
}

class RestorePlan extends ImportPlan {
  const RestorePlan(
    super.activities,
    super.sessions,
    super.skipped, {
    required this.backup,
    required this.keptActivities,
    required this.conflicts,
    required this.deletedSkipped,
    this.rules = const [],
    this.preferences = const {},
  });
  final BackupData backup;
  final int keptActivities;
  final int conflicts;
  final int deletedSkipped;
  final List<AppRule> rules;
  final Map<String, bool> preferences;
  bool get hasChanges =>
      activities.isNotEmpty ||
      sessions.isNotEmpty ||
      rules.isNotEmpty ||
      preferences.isNotEmpty;
}

List<String> parseTags(String value) => value
    .split(RegExp('[,;]'))
    .map((s) => s.trim())
    .where((s) => s.isNotEmpty)
    .toSet()
    .toList();

/// RFC 4180 cells, including embedded newlines and doubled quotes.
List<List<String>> parseCsv(String text) {
  if (utf8.encode(text).length > 32 * 1024 * 1024) {
    throw const FormatException('Choose a CSV smaller than 32 MB.');
  }
  final rows = <List<String>>[];
  var row = <String>[];
  var cell = StringBuffer();
  var quoted = false;
  var closed = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          quoted = false;
          closed = true;
        }
      } else {
        cell.write(c);
      }
    } else if (c == ',' || c == '\n' || c == '\r') {
      row.add(cell.toString());
      cell = StringBuffer();
      closed = false;
      if (c != ',') {
        if (row.any((s) => s.trim().isNotEmpty)) rows.add(row);
        row = [];
        if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      }
    } else if (c == '"') {
      if (cell.isNotEmpty || closed) {
        throw const FormatException('Unexpected quote in CSV.');
      }
      quoted = true;
    } else {
      if (closed) throw const FormatException('Text after a quoted CSV cell.');
      cell.write(c);
    }
  }
  if (quoted) throw const FormatException('Unclosed quoted CSV cell.');
  row.add(cell.toString());
  if (row.any((s) => s.trim().isNotEmpty)) rows.add(row);
  return rows;
}

String _id(String prefix, Object value) =>
    '$prefix-${sha256.convert(utf8.encode(jsonEncode(value)))}';
String _activityKey(String name, String client) =>
    jsonEncode([name.trim().toLowerCase(), client.trim().toLowerCase()]);

DateTime _timestamp(String date, String time) {
  final d = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(date);
  final t = RegExp(
    r'^(\d{1,2}):(\d{2})(?::(\d{2}))?(Z|[+-]\d{2}:\d{2})?$',
  ).firstMatch(time);
  if (d == null || t == null) {
    throw const FormatException(
      'Use YYYY-MM-DD dates and HH:mm:ss times in your Toggl export.',
    );
  }
  final year = int.parse(d[1]!);
  final month = int.parse(d[2]!);
  final day = int.parse(d[3]!);
  final check = DateTime(year, month, day);
  if (check.year != year ||
      check.month != month ||
      check.day != day ||
      int.parse(t[1]!) > 23 ||
      int.parse(t[2]!) > 59 ||
      int.parse(t[3] ?? '0') > 59) {
    throw const FormatException('Invalid date or time.');
  }
  return DateTime.parse(
    '$date ${t[1]!.padLeft(2, '0')}:${t[2]}:${t[3] ?? '00'}${t[4] ?? ''}',
  );
}

Duration _duration(String value) {
  final match = RegExp(r'^(\d+):(\d{2}):(\d{2})$').firstMatch(value);
  if (match == null || int.parse(match[2]!) > 59 || int.parse(match[3]!) > 59) {
    throw const FormatException(
      'Export durations as HH:mm:ss (Toggl Improved format).',
    );
  }
  return Duration(
    hours: int.parse(match[1]!),
    minutes: int.parse(match[2]!),
    seconds: int.parse(match[3]!),
  );
}

ImportPlan planTogglImport(
  String csv, {
  required List<Activity> activities,
  required List<Session> sessions,
  required String deviceId,
  required String deviceName,
  Set<String> deletedSessionIds = const {},
}) {
  final rows = parseCsv(csv.replaceFirst(RegExp('^\uFEFF'), ''));
  if (rows.length < 2) {
    throw const FormatException('The CSV contains no time entries.');
  }
  final headers = rows.first.map((s) => s.trim().toLowerCase()).toList();
  if (headers.toSet().length != headers.length) {
    throw const FormatException('CSV column names must be unique.');
  }
  if (!headers.contains('start date') ||
      !headers.contains('start time') ||
      !(headers.contains('duration') ||
          (headers.contains('end date') && headers.contains('end time')))) {
    throw const FormatException(
      'Choose a Toggl Detailed report CSV with Start date, Start time, and Duration or End date / End time.',
    );
  }
  final knownActivities = {
    for (final a in activities) _activityKey(a.name, a.client): a,
  };
  final activitiesById = {for (final a in activities) a.id: a};
  final knownSessions = {...sessions.map((s) => s.id), ...deletedSessionIds};
  final addedActivities = <Activity>[];
  final addedSessions = <Session>[];
  final occurrences = <String, int>{};
  var skipped = 0;
  for (var n = 1; n < rows.length; n++) {
    try {
      final row = rows[n];
      if (row.length != headers.length) {
        throw const FormatException('Incorrect number of columns.');
      }
      String field(String name) {
        final index = headers.indexOf(name);
        return index < 0 ? '' : row[index].trim();
      }

      final start = _timestamp(field('start date'), field('start time'));
      // Toggl's Duration is authoritative; exported endpoints may round or cross DST.
      final end = field('duration').isNotEmpty
          ? start.add(_duration(field('duration')))
          : _timestamp(field('end date'), field('end time'));
      if (end.isBefore(start)) {
        throw const FormatException('End time is before start time.');
      }
      final project = field('project').isEmpty
          ? 'Unassigned'
          : field('project');
      final client = field('client');
      final task = field('task');
      final description = field('description');
      final note = [
        if (task.isNotEmpty) 'Task: $task',
        if (description.isNotEmpty) description,
      ].join('\n');
      final tags = parseTags(field('tags'));
      final billableText = field('billable').toLowerCase();
      if (!{
        '',
        'yes',
        'y',
        'true',
        '1',
        'no',
        'n',
        'false',
        '0',
      }.contains(billableText)) {
        throw const FormatException('Unrecognized Billable value.');
      }
      final billable = {'yes', 'y', 'true', '1'}.contains(billableText);
      final fingerprint = _id('toggl', [
        field('email').toLowerCase(),
        field('user'),
        project,
        client,
        task,
        description,
        start.toUtc().toIso8601String(),
        end.toUtc().toIso8601String(),
        [...tags]..sort(),
        billable,
      ]);
      final occurrence = (occurrences[fingerprint] ?? 0) + 1;
      occurrences[fingerprint] = occurrence;
      // Toggl CSV has no entry ID. Preserve identical source rows as separate
      // entries while assigning stable IDs for repeat imports of that export.
      final id = occurrence == 1 ? fingerprint : '$fingerprint-$occurrence';
      if (!knownSessions.add(id)) {
        skipped++;
        continue;
      }
      final key = _activityKey(project, client);
      final activity = knownActivities.putIfAbsent(key, () {
        final projectId = _id('project', key);
        // Later exports retain local names, clients and colours after a rename.
        final existing = activitiesById[projectId];
        if (existing != null) return existing;
        final a = Activity(
          id: projectId,
          name: project,
          client: client,
          color: [
            0xFF567561,
            0xFFAF657D,
            0xFF7165A1,
            0xFFAD763D,
            0xFF477C95,
          ][(activities.length + addedActivities.length) % 5],
        );
        addedActivities.add(a);
        return a;
      });
      addedSessions.add(
        Session(
          id: id,
          activityId: activity.id,
          deviceId: deviceId,
          deviceName: deviceName,
          start: start,
          end: end,
          lastSeen: end,
          source: 'import',
          note: note,
          tags: tags,
          billable: billable,
        ),
      );
    } on FormatException catch (e) {
      throw FormatException(
        'Row ${n + 1}: ${e.message} No entries were imported.',
      );
    }
  }
  return ImportPlan(addedActivities, addedSessions, skipped);
}

String encodeBackup(
  List<Activity> activities,
  List<Session> sessions,
  DateTime now, {
  List<AppRule> rules = const [],
  Map<String, bool> preferences = const {},
}) {
  final json = <String, dynamic>{
    'application': 'sprout',
    'schema': 2,
    'exportedAt': now.toUtc().toIso8601String(),
    'frozenTimers': sessions.where((s) => s.isRunning).length,
    'activities': activities.map((a) => a.toJson()).toList(),
    // Freeze elapsed time without stopping or changing the actual timer.
    'sessions': sessions.map((s) {
      if (!s.isRunning) return s.toJson();
      var end = s.effectiveEnd(now);
      if (end.isAfter(now)) end = now;
      if (end.isBefore(s.start)) end = s.start;
      return s.copyWith(end: end, lastSeen: end).toJson();
    }).toList(),
    'rules': rules.map((r) => r.toJson()).toList(),
    'preferences': preferences,
  };
  json['checksum'] = _checksum(json);
  final content = const JsonEncoder.withIndent('  ').convert(json);
  // Never export a snapshot that our own restore cannot read.
  decodeBackup(content);
  return content;
}

Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}

String _checksum(Json json) => sha256
    .convert(utf8.encode(jsonEncode(_canonical({...json}..remove('checksum')))))
    .toString();

String _text(Json json, String key, {int limit = 4096, bool optional = false}) {
  final value = json[key];
  if (optional && value == null) return '';
  if (value is! String || value.length > limit || value.contains('\u0000')) {
    throw FormatException('Invalid $key in backup.');
  }
  return value;
}

String _identity(Json json, String key) {
  final value = _text(json, key, limit: 256);
  if (value.trim().isEmpty || RegExp(r'[\x00-\x1f]').hasMatch(value)) {
    throw FormatException('Invalid $key in backup.');
  }
  return value;
}

// DateTime.parse accepts impossible dates by normalizing them. Backups must
// reject those values, and require offsets so moving devices cannot shift time.
DateTime _backupTime(Object? value) {
  if (value is! String) {
    throw const FormatException('Invalid backup timestamp.');
  }
  final m = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$',
  ).firstMatch(value);
  if (m == null) throw const FormatException('Invalid backup timestamp.');
  final parts = List.generate(6, (i) => int.parse(m[i + 1]!));
  final calendar = DateTime.utc(parts[0], parts[1], parts[2]);
  if (parts[0] < 1 ||
      calendar.year != parts[0] ||
      calendar.month != parts[1] ||
      calendar.day != parts[2] ||
      parts[3] > 23 ||
      parts[4] > 59 ||
      parts[5] > 59 ||
      (m[7] != 'Z' &&
          (int.parse(m[7]!.substring(1, 3)) > 23 ||
              int.parse(m[7]!.substring(4)) > 59))) {
    throw const FormatException('Invalid date or time in backup.');
  }
  return DateTime.parse(value).toLocal();
}

List<Json> _records(Json json, String key, {bool optional = false}) {
  final list = json[key];
  if (list == null && optional) return [];
  if (list is! List || list.length > 100000) {
    throw FormatException('Invalid or oversized $key in backup.');
  }
  final ids = <String>{};
  return list.map((value) {
    if (value is! Map<String, dynamic>) {
      throw FormatException('Invalid $key record in backup.');
    }
    if (!ids.add(_identity(value, 'id'))) {
      throw FormatException('Duplicate $key ID in backup.');
    }
    return value;
  }).toList();
}

BackupData decodeBackup(String content) {
  if (utf8.encode(content).length > maxPortableBytes) {
    throw const FormatException('Choose a backup smaller than 32 MB.');
  }
  try {
    final decoded = jsonDecode(content);
    if (decoded is! Json || decoded['application'] != 'sprout') {
      throw const FormatException('Choose a Sprout JSON backup.');
    }
    final schema = decoded['schema'];
    if (schema is! int || (schema != 1 && schema != 2)) {
      throw const FormatException(
        'This backup needs a newer version of Sprout.',
      );
    }
    if (schema == 2 &&
        (decoded['checksum'] is! String ||
            decoded['checksum'] != _checksum(decoded))) {
      throw const FormatException(
        'Backup verification failed. The file is damaged or has changed.',
      );
    }
    final exportedAt = _backupTime(decoded['exportedAt']);
    final importedActivities = _records(decoded, 'activities').map((v) {
      if (_text(v, 'name').trim().isEmpty ||
          v['color'] is! int ||
          v['color'] < 0 ||
          v['color'] > 0xffffffff) {
        throw const FormatException('Invalid activity in backup.');
      }
      _text(v, 'client', optional: true);
      return Activity.fromJson(v);
    }).toList();
    final importedSessions = _records(decoded, 'sessions').map((v) {
      _identity(v, 'activityId');
      _identity(v, 'deviceId');
      _text(v, 'deviceName');
      _text(v, 'source');
      _text(v, 'executable', limit: 32768, optional: true);
      _text(v, 'note', limit: 1024 * 1024, optional: true);
      final start = _backupTime(v['start']);
      final end = _backupTime(v['end']);
      final seen = _backupTime(v['lastSeen']);
      if (end.isBefore(start) || seen.isBefore(start)) {
        throw const FormatException('Invalid session duration in backup.');
      }
      final tags = v['tags'];
      if (tags != null &&
          (tags is! List ||
              tags.length > 256 ||
              tags.any((tag) => tag is! String || tag.length > 4096))) {
        throw const FormatException('Invalid session tags in backup.');
      }
      if (v['billable'] != null && v['billable'] is! bool) {
        throw const FormatException('Invalid billable value in backup.');
      }
      return Session.fromJson(v);
    }).toList();
    final ids = importedActivities.map((a) => a.id).toSet();
    var recovered = 0;
    for (final s in importedSessions) {
      if (ids.contains(s.activityId)) continue;
      if (schema == 2) {
        throw const FormatException('A session refers to a missing activity.');
      }
      // 0.2.0 omitted deleted activities. Keep those old backups recoverable.
      ids.add(s.activityId);
      importedActivities.add(
        Activity(
          id: s.activityId,
          name: 'Recovered activity',
          color: 0xFF567561,
        ),
      );
      recovered++;
    }
    final rules = _records(decoded, 'rules', optional: schema == 1).map((v) {
      _identity(v, 'activityId');
      if (!ids.contains(v['activityId']) ||
          _text(v, 'executable', limit: 32768).trim().isEmpty ||
          !{'focused', 'running'}.contains(v['mode']) ||
          v['enabled'] is! bool ||
          v['pauseWhenIdle'] is! bool ||
          v['idleMinutes'] is! int ||
          v['idleMinutes'] < 1 ||
          v['idleMinutes'] > 1440) {
        throw const FormatException('Invalid app rule in backup.');
      }
      return AppRule.fromJson(v);
    }).toList();
    final preferences = decoded['preferences'] ?? <String, dynamic>{};
    if (preferences is! Map ||
        preferences.keys.any(
          (k) => !{'automatic', 'notifications'}.contains(k),
        ) ||
        preferences.values.any((v) => v is! bool)) {
      throw const FormatException('Invalid preferences in backup.');
    }
    final frozen = decoded['frozenTimers'] ?? 0;
    if (frozen is! int || frozen < 0 || frozen > importedSessions.length) {
      throw const FormatException('Invalid timer count in backup.');
    }
    return BackupData(
      activities: importedActivities,
      sessions: importedSessions,
      rules: rules,
      preferences: Map<String, bool>.from(preferences),
      exportedAt: exportedAt,
      verified: schema == 2,
      frozenTimers: frozen,
      recoveredActivityNames: recovered,
    );
  } on TypeError {
    throw const FormatException('The backup contains invalid records.');
  } on FormatException catch (e) {
    if (e.source != null) {
      throw const FormatException('The backup is not valid JSON.');
    }
    rethrow;
  }
}

RestorePlan planRestore(
  String content, {
  required List<Activity> activities,
  required List<Session> sessions,
  required String deviceId,
  required String deviceName,
  Set<String> deletedActivities = const {},
  Set<String> deletedSessions = const {},
  List<AppRule> rules = const [],
  RestoreOptions options = const RestoreOptions(),
}) => planBackupRestore(
  decodeBackup(content),
  activities: activities,
  sessions: sessions,
  deletedActivities: deletedActivities,
  deletedSessions: deletedSessions,
  rules: rules,
  options: options,
);

RestorePlan planBackupRestore(
  BackupData backup, {
  required List<Activity> activities,
  required List<Session> sessions,
  Set<String> deletedActivities = const {},
  Set<String> deletedSessions = const {},
  List<AppRule> rules = const [],
  RestoreOptions options = const RestoreOptions(),
}) {
  final activityById = {for (final a in activities) a.id: a};
  final sessionById = {for (final s in sessions) s.id: s};
  final restoredActivities = <Activity>[];
  final restoredSessions = <Session>[];
  var skipped = 0;
  var keptActivities = 0;
  var conflicts = 0;
  var deletedSkipped = 0;
  for (final a in backup.activities) {
    final existing = activityById[a.id];
    if (existing != null) {
      keptActivities++;
      if (jsonEncode(existing.toJson()) != jsonEncode(a.toJson())) conflicts++;
    } else if (!options.includeDeleted && deletedActivities.contains(a.id)) {
      deletedSkipped++;
    } else {
      restoredActivities.add(a);
    }
  }
  for (final s in backup.sessions) {
    final existing = sessionById[s.id];
    if (existing != null) {
      skipped++;
      if (jsonEncode(existing.toJson()) != jsonEncode(s.toJson())) conflicts++;
    } else if (!options.includeDeleted && deletedSessions.contains(s.id)) {
      skipped++;
      deletedSkipped++;
    } else {
      // Finished sessions retain their original device attribution and IDs.
      restoredSessions.add(s);
    }
  }
  final knownRules = rules.map((r) => r.id).toSet();
  return RestorePlan(
    restoredActivities,
    restoredSessions,
    skipped,
    backup: backup,
    keptActivities: keptActivities,
    conflicts: conflicts,
    deletedSkipped: deletedSkipped,
    rules: options.deviceSettings
        ? backup.rules
              .where(
                (r) =>
                    !knownRules.contains(r.id) &&
                    (options.includeDeleted ||
                        !deletedActivities.contains(r.activityId)),
              )
              .map(
                (r) => AppRule(
                  id: r.id,
                  activityId: r.activityId,
                  executable: r.executable,
                  mode: r.mode,
                  pauseWhenIdle: r.pauseWhenIdle,
                  idleMinutes: r.idleMinutes,
                  enabled: false,
                ),
              )
              .toList()
        : const [],
    preferences: options.deviceSettings ? backup.preferences : const {},
  );
}

String exportSessionsCsv(
  Iterable<Session> sessions,
  String Function(String) activityName,
  DateTime now,
) {
  final rows = <String>[
    'id,activity,start_utc,end_utc,duration_seconds,source,executable,device,note,tags,billable',
  ];
  for (final s in sessions) {
    rows.add(
      [
        s.id,
        activityName(s.activityId),
        s.start.toUtc().toIso8601String(),
        s.end?.toUtc().toIso8601String() ?? '',
        '${s.duration(now).inSeconds}',
        s.source,
        s.executable,
        s.deviceName,
        s.note,
        s.tags.join('; '),
        s.billable ? 'yes' : 'no',
      ].map(csvCell).join(','),
    );
  }
  return '${rows.join('\r\n')}\r\n';
}
