import 'dart:math' as math;

typedef Json = Map<String, dynamic>;

class Activity {
  const Activity({
    required this.id,
    required this.name,
    required this.color,
    this.client = '',
  });
  final String id;
  final String name;
  final int color;
  final String client;
  Json toJson() => {'id': id, 'name': name, 'color': color, 'client': client};
  factory Activity.fromJson(Json json) => Activity(
    id: json['id'] as String,
    name: json['name'] as String,
    color: json['color'] as int,
    client: json['client'] as String? ?? '',
  );
}

class Session {
  const Session({
    required this.id,
    required this.activityId,
    required this.deviceId,
    required this.deviceName,
    required this.start,
    required this.lastSeen,
    this.end,
    this.source = 'manual',
    this.executable = '',
    this.note = '',
    this.tags = const [],
    this.billable = false,
  });
  final String id;
  final String activityId;
  final String deviceId;
  final String deviceName;
  final DateTime start;
  final DateTime lastSeen;
  final DateTime? end;
  final String source;
  final String executable;
  final String note;
  final List<String> tags;
  final bool billable;
  bool get isRunning => end == null;
  DateTime effectiveEnd(DateTime now) =>
      end ?? (source == 'auto' ? lastSeen : now);
  Duration duration(DateTime now) => Duration(
    milliseconds: math.max(
      0,
      effectiveEnd(now).difference(start).inMilliseconds,
    ),
  );
  Duration within(DateTime from, DateTime to, DateTime now) {
    final a = start.isBefore(from) ? from : start;
    final b = effectiveEnd(now).isAfter(to) ? to : effectiveEnd(now);
    return Duration(milliseconds: math.max(0, b.difference(a).inMilliseconds));
  }

  Session copyWith({
    DateTime? end,
    DateTime? lastSeen,
    String? note,
    List<String>? tags,
    bool? billable,
  }) => Session(
    id: id,
    activityId: activityId,
    deviceId: deviceId,
    deviceName: deviceName,
    start: start,
    lastSeen: lastSeen ?? this.lastSeen,
    end: end ?? this.end,
    source: source,
    executable: executable,
    note: note ?? this.note,
    tags: tags ?? this.tags,
    billable: billable ?? this.billable,
  );
  Json toJson() => {
    'id': id,
    'activityId': activityId,
    'deviceId': deviceId,
    'deviceName': deviceName,
    'start': start.toUtc().toIso8601String(),
    'end': end?.toUtc().toIso8601String(),
    'lastSeen': lastSeen.toUtc().toIso8601String(),
    'source': source,
    'executable': executable,
    'note': note,
    'tags': tags,
    'billable': billable,
  };
  factory Session.fromJson(Json json) => Session(
    id: json['id'] as String,
    activityId: json['activityId'] as String,
    deviceId: json['deviceId'] as String,
    deviceName: json['deviceName'] as String,
    start: DateTime.parse(json['start'] as String),
    end: json['end'] == null ? null : DateTime.parse(json['end'] as String),
    lastSeen: DateTime.parse(json['lastSeen'] as String),
    source: json['source'] as String,
    executable: json['executable'] as String? ?? '',
    note: json['note'] as String? ?? '',
    tags: (json['tags'] as List? ?? []).cast<String>(),
    billable: json['billable'] as bool? ?? false,
  );
}

class AppRule {
  const AppRule({
    required this.id,
    required this.activityId,
    required this.executable,
    this.mode = 'focused',
    this.pauseWhenIdle = false,
    this.idleMinutes = 5,
    this.enabled = true,
  });
  final String id;
  final String activityId;
  final String executable;
  final String mode;
  final bool pauseWhenIdle;
  final int idleMinutes;
  final bool enabled;
  Json toJson() => {
    'id': id,
    'activityId': activityId,
    'executable': executable,
    'mode': mode,
    'pauseWhenIdle': pauseWhenIdle,
    'idleMinutes': idleMinutes,
    'enabled': enabled,
  };
  factory AppRule.fromJson(Json json) => AppRule(
    id: json['id'] as String,
    activityId: json['activityId'] as String,
    executable: json['executable'] as String,
    mode: json['mode'] as String,
    pauseWhenIdle: json['pauseWhenIdle'] as bool,
    idleMinutes: json['idleMinutes'] as int,
    enabled: json['enabled'] as bool,
  );
}

class Mutation {
  const Mutation({
    required this.kind,
    required this.id,
    required this.clock,
    required this.device,
    required this.data,
    this.deleted = false,
  });
  final String kind;
  final String id;
  final int clock;
  final String device;
  final Json data;
  final bool deleted;
  String get key => '$kind:$id';
  bool newerThan(Mutation other) =>
      clock > other.clock ||
      (clock == other.clock && device.compareTo(other.device) > 0);
  Json toJson() => {
    'kind': kind,
    'id': id,
    'clock': clock,
    'device': device,
    'data': data,
    'deleted': deleted,
  };
  factory Mutation.fromJson(Json json) {
    final result = Mutation(
      kind: json['kind'] as String,
      id: json['id'] as String,
      clock: json['clock'] as int,
      device: json['device'] as String,
      data: Map<String, dynamic>.from(json['data'] as Map),
      deleted: json['deleted'] as bool,
    );
    if (!{'activity', 'session'}.contains(result.kind) ||
        result.id.isEmpty ||
        result.device.isEmpty ||
        result.clock < 1) {
      throw const FormatException('Invalid sync record');
    }
    if (!result.deleted) {
      if (result.data['id'] != result.id) {
        throw const FormatException('Mismatched sync identity');
      }
      if (result.kind == 'activity') {
        Activity.fromJson(result.data);
      } else {
        final session = Session.fromJson(result.data);
        if (session.end != null && session.end!.isBefore(session.start)) {
          throw const FormatException('Invalid session duration');
        }
      }
    }
    return result;
  }
}

Map<String, Mutation> mergeMutations(Iterable<Mutation> records) {
  final result = <String, Mutation>{};
  for (final record in records) {
    final existing = result[record.key];
    if (existing == null || record.newerThan(existing)) {
      result[record.key] = record;
    }
  }
  return result;
}

String normalizedExecutable(String executable) =>
    executable.replaceAll('/', r'\').toLowerCase();
bool matchesExecutable(String rule, String actual) {
  final expected = normalizedExecutable(rule);
  final found = normalizedExecutable(actual);
  return expected.contains(r'\')
      ? expected == found
      : expected == found.split(r'\').last;
}

AppRule? chooseRule({
  required Iterable<AppRule> rules,
  required String focused,
  required Iterable<String> running,
  required int idleMs,
  required bool locked,
}) {
  if (locked) return null;
  final eligible = rules.where(
    (r) => r.enabled && (!r.pauseWhenIdle || idleMs < r.idleMinutes * 60000),
  );
  for (final rule in eligible) {
    if (matchesExecutable(rule.executable, focused)) return rule;
  }
  for (final rule in eligible) {
    if (rule.mode == 'running' &&
        running.any((p) => matchesExecutable(rule.executable, p))) {
      return rule;
    }
  }
  return null;
}

Set<String> overlappingSessions(Iterable<Session> sessions, DateTime now) {
  final sorted = sessions.toList()..sort((a, b) => a.start.compareTo(b.start));
  final result = <String>{};
  final active = <Session>[];
  for (final session in sorted) {
    active.removeWhere((s) => !s.effectiveEnd(now).isAfter(session.start));
    if (!session.effectiveEnd(now).isAfter(session.start)) continue;
    for (final other in active) {
      result.add(other.id);
      result.add(session.id);
    }
    active.add(session);
  }
  return result;
}

String formatDuration(Duration duration, {bool seconds = false}) {
  final total = math.max(0, duration.inSeconds);
  final h = total ~/ 3600;
  final m = (total ~/ 60) % 60;
  final s = total % 60;
  return seconds
      ? '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
      : '${h}h ${m.toString().padLeft(2, '0')}m';
}

// Quoting alone does not stop spreadsheet formula execution.
String csvCell(String value) {
  final safe = RegExp(r'^\s*[=+@-]').hasMatch(value) ? "'$value" : value;
  return '"${safe.replaceAll('"', '""')}"';
}
