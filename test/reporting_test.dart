import 'package:flutter_test/flutter_test.dart';
import 'package:sprout/model.dart';
import 'package:sprout/reporting.dart';

void main() {
  Session session(
    String id,
    DateTime start,
    DateTime end, {
    bool billable = false,
    List<String> tags = const [],
  }) => Session(
    id: id,
    activityId: 'study',
    deviceId: 'd',
    deviceName: 'Demo',
    start: start,
    end: end,
    lastSeen: end,
    billable: billable,
    tags: tags,
  );

  test(
    'daily statistics split midnight, include empty days, and retain tag and billable totals',
    () {
      final records = [
        session(
          'a',
          DateTime(2026, 1, 1, 23, 30),
          DateTime(2026, 1, 2, 1, 30),
          billable: true,
          tags: ['focus', 'study'],
        ),
        session('b', DateTime(2026, 1, 3, 10), DateTime(2026, 1, 3, 11)),
      ];
      final stats = ReportStats(
        records,
        DateTime(2026, 1, 1),
        DateTime(2026, 1, 5),
        DateTime(2026, 1, 6),
      );
      expect(stats.total, const Duration(hours: 3));
      expect(stats.byDay[DateTime(2026, 1, 1)], const Duration(minutes: 30));
      expect(stats.byDay[DateTime(2026, 1, 2)], const Duration(minutes: 90));
      expect(stats.activeDays, 3);
      expect(stats.dayCount, 4);
      expect(stats.averageDay, const Duration(minutes: 45));
      expect(stats.averageSession, const Duration(minutes: 90));
      expect(stats.billable, const Duration(hours: 2));
      expect(stats.byTag['focus'], const Duration(hours: 2));
      expect(stats.chartDays(DateTime(2026, 1, 6)).last.value, Duration.zero);
    },
  );

  test('open periods omit future days from daily averages', () {
    final now = DateTime(2026, 1, 3, 12);
    final stats = ReportStats(
      [session('a', DateTime(2026, 1, 2, 9), DateTime(2026, 1, 2, 12))],
      DateTime(2026, 1, 1),
      DateTime(2026, 1, 8),
      now,
    );
    expect(stats.dayCount, 3);
    expect(stats.averageDay, const Duration(hours: 1));
    expect(stats.chartDays(now).length, 3);
  });
}
