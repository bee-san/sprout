import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'model.dart';

class ImportResult {
  const ImportResult(this.imported, this.skipped);
  final int imported;
  final int skipped;
}

class ImportPlan {
  const ImportPlan(this.activities, this.sessions, this.skipped);
  final List<Activity> activities;
  final List<Session> sessions;
  final int skipped;
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
  final knownSessions = sessions.map((s) => s.id).toSet();
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
  DateTime now,
) => const JsonEncoder.withIndent('  ').convert({
  'application': 'sprout', 'schema': 1,
  'exportedAt': now.toUtc().toIso8601String(),
  'activities': activities.map((a) => a.toJson()).toList(),
  // A portable snapshot restores elapsed time, never an unattended timer.
  'sessions': sessions
      .map(
        (s) => s.isRunning
            ? s.copyWith(end: s.effectiveEnd(now)).toJson()
            : s.toJson(),
      )
      .toList(),
});

ImportPlan planRestore(
  String content, {
  required List<Activity> activities,
  required List<Session> sessions,
  required String deviceId,
  required String deviceName,
}) {
  if (utf8.encode(content).length > 32 * 1024 * 1024) {
    throw const FormatException('Choose a backup smaller than 32 MB.');
  }
  final dynamic decoded = jsonDecode(content);
  if (decoded is! Map ||
      decoded['application'] != 'sprout' ||
      decoded['schema'] != 1 ||
      decoded['activities'] is! List ||
      decoded['sessions'] is! List) {
    throw const FormatException('Choose a Sprout JSON backup.');
  }
  try {
    final importedActivities = (decoded['activities'] as List)
        .map((v) => Activity.fromJson(Map<String, dynamic>.from(v as Map)))
        .toList();
    final importedSessions = (decoded['sessions'] as List)
        .map((v) => Session.fromJson(Map<String, dynamic>.from(v as Map)))
        .toList();
    final activityIds = activities.map((a) => a.id).toSet();
    final sessionIds = sessions.map((s) => s.id).toSet();
    final restoredActivities = <Activity>[];
    final restoredSessions = <Session>[];
    var skipped = 0;
    for (final a in importedActivities) {
      if (a.id.isEmpty || a.name.trim().isEmpty) {
        throw const FormatException('Invalid activity.');
      }
      if (activityIds.add(a.id)) restoredActivities.add(a);
    }
    for (final s in importedSessions) {
      if (s.id.isEmpty || s.end == null || s.end!.isBefore(s.start)) {
        throw const FormatException('Invalid session.');
      }
      if (!sessionIds.add(s.id)) {
        skipped++;
        continue;
      }
      restoredSessions.add(
        Session(
          id: s.id,
          activityId: s.activityId,
          deviceId: deviceId,
          deviceName: deviceName,
          start: s.start,
          end: s.end,
          lastSeen: s.end!,
          source: s.source,
          executable: s.executable,
          note: s.note,
          tags: s.tags,
          billable: s.billable,
        ),
      );
    }
    return ImportPlan(restoredActivities, restoredSessions, skipped);
  } on TypeError {
    throw const FormatException('The backup contains invalid records.');
  }
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
