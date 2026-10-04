import 'dart:math' as math;
import 'model.dart';

DateTime dateOnly(DateTime value) {
  final local = value.toLocal();
  return DateTime(local.year, local.month, local.day);
}

int calendarDays(DateTime from, DateTime to) => DateTime.utc(
  to.year,
  to.month,
  to.day,
).difference(DateTime.utc(from.year, from.month, from.day)).inDays;

class ReportStats {
  ReportStats(Iterable<Session> sessions, this.from, this.to, DateTime now) {
    for (final s in sessions) {
      final duration = s.within(from, to, now);
      if (duration == Duration.zero) continue;
      count++;
      total += duration;
      if (s.billable) billable += duration;
      byActivity.update(
        s.activityId,
        (v) => v + duration,
        ifAbsent: () => duration,
      );
      for (final tag in s.tags.toSet()) {
        byTag.update(tag, (v) => v + duration, ifAbsent: () => duration);
      }
      if (duration > longest) longest = duration;
      if (!s.start.isBefore(from) && s.start.isBefore(to)) {
        startsByHour[s.start.toLocal().hour]++;
      }
      var day = dateOnly(s.start.isBefore(from) ? from : s.start);
      final end = s.effectiveEnd(now).isAfter(to) ? to : s.effectiveEnd(now);
      while (day.isBefore(end)) {
        final next = DateTime(day.year, day.month, day.day + 1);
        final time = s.within(
          day.isBefore(from) ? from : day,
          next.isAfter(to) ? to : next,
          now,
        );
        if (time > Duration.zero) {
          byDay.update(day, (v) => v + time, ifAbsent: () => time);
        }
        day = next;
      }
    }
    final effectiveTo = to.isAfter(now) ? now : to;
    final days = calendarDays(dateOnly(from), dateOnly(effectiveTo));
    dayCount = math.max(
      1,
      days + (effectiveTo == dateOnly(effectiveTo) ? 0 : 1),
    );
  }
  final DateTime from;
  final DateTime to;
  int count = 0;
  int dayCount = 1;
  Duration total = Duration.zero;
  Duration billable = Duration.zero;
  Duration longest = Duration.zero;
  final byActivity = <String, Duration>{};
  final byTag = <String, Duration>{};
  final byDay = <DateTime, Duration>{};
  final startsByHour = List<int>.filled(24, 0);
  Duration get averageDay =>
      Duration(milliseconds: total.inMilliseconds ~/ dayCount);
  Duration get averageSession =>
      Duration(milliseconds: total.inMilliseconds ~/ math.max(1, count));
  int get activeDays => byDay.length;
  MapEntry<DateTime, Duration>? get bestDay => byDay.entries.isEmpty
      ? null
      : byDay.entries.reduce((a, b) => a.value > b.value ? a : b);
  List<MapEntry<DateTime, Duration>> chartDays(DateTime now, {int limit = 14}) {
    final last = dateOnly(
      to.isAfter(now) ? now : to.subtract(const Duration(microseconds: 1)),
    );
    final length = math.min(
      limit,
      math.max(1, calendarDays(dateOnly(from), last) + 1),
    );
    return List.generate(length, (i) {
      final day = DateTime(last.year, last.month, last.day - length + i + 1);
      return MapEntry(day, byDay[day] ?? Duration.zero);
    });
  }
}
