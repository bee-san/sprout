import 'package:flutter_test/flutter_test.dart';
import 'package:sprout/model.dart';

void main() {
  test('offline edits converge independent of order, including deletion', () {
    const initial = Mutation(
      kind: 'activity',
      id: 'a',
      clock: 1,
      device: 'A',
      data: {'id': 'a', 'name': 'Gaming', 'color': 1},
    );
    const editA = Mutation(
      kind: 'activity',
      id: 'a',
      clock: 2,
      device: 'A',
      data: {'id': 'a', 'name': 'Games', 'color': 1},
    );
    const editB = Mutation(
      kind: 'activity',
      id: 'a',
      clock: 2,
      device: 'B',
      data: {'id': 'a', 'name': 'Reading', 'color': 1},
    );
    const deletion = Mutation(
      kind: 'activity',
      id: 'a',
      clock: 3,
      device: 'A',
      data: {},
      deleted: true,
    );
    final orders = [
      [initial, editA, editB, deletion],
      [deletion, editB, initial, editA],
      [editB, editA, deletion, initial],
    ];
    for (final records in orders) {
      expect(mergeMutations(records)['activity:a']!.deleted, isTrue);
      expect(mergeMutations(records)['activity:a']!.clock, 3);
    }
    expect(mergeMutations([editA, editB])['activity:a']!.device, 'B');
    expect(mergeMutations([editB, editA])['activity:a']!.device, 'B');
  });
  test(
    'reports clip sessions at midnight instead of crediting whole sessions',
    () {
      final start = DateTime.utc(2026, 10, 3, 23, 30);
      final end = DateTime.utc(2026, 10, 4, 1, 30);
      final s = Session(
        id: 's',
        activityId: 'a',
        deviceId: 'd',
        deviceName: 'PC',
        start: start,
        end: end,
        lastSeen: end,
      );
      expect(
        s.within(DateTime.utc(2026, 10, 4), DateTime.utc(2026, 10, 5), end),
        const Duration(minutes: 90),
      );
      expect(
        s.within(DateTime.utc(2026, 10, 3), DateTime.utc(2026, 10, 4), end),
        const Duration(minutes: 30),
      );
    },
  );
  test('automatic sessions are capped at the last heartbeat after a crash', () {
    final start = DateTime.utc(2026, 10, 4, 9);
    final s = Session(
      id: 's',
      activityId: 'a',
      deviceId: 'd',
      deviceName: 'PC',
      start: start,
      lastSeen: start.add(const Duration(minutes: 10)),
      source: 'auto',
    );
    expect(
      s.duration(start.add(const Duration(hours: 2))),
      const Duration(minutes: 10),
    );
  });
  test('app rules prefer foreground apps and respect paths, idle and lock', () {
    const bg3 = AppRule(
      id: 'game',
      activityId: 'gaming',
      executable: r'C:\Games\BG3.exe',
      mode: 'running',
    );
    const editor = AppRule(
      id: 'editor',
      activityId: 'coding',
      executable: 'code.exe',
      pauseWhenIdle: true,
    );
    final rules = [bg3, editor];
    expect(
      chooseRule(
        rules: rules,
        focused: r'C:\Tools\CODE.EXE',
        running: [r'C:\Games\bg3.exe'],
        idleMs: 0,
        locked: false,
      )?.id,
      'editor',
    );
    expect(
      chooseRule(
        rules: rules,
        focused: 'other.exe',
        running: [r'C:\Games\bg3.exe'],
        idleMs: 600000,
        locked: false,
      )?.id,
      'game',
    );
    expect(
      chooseRule(
        rules: rules,
        focused: 'code.exe',
        running: [],
        idleMs: 600000,
        locked: false,
      ),
      isNull,
    );
    expect(
      chooseRule(
        rules: rules,
        focused: r'C:\Games\BG3.exe',
        running: [r'C:\Games\BG3.exe'],
        idleMs: 0,
        locked: true,
      ),
      isNull,
    );
    expect(
      matchesExecutable(r'C:\Games\BG3.exe', r'D:\Other\bg3.exe'),
      isFalse,
    );
  });
  test(
    'overlap detection preserves both devices without flagging adjacent sessions',
    () {
      final start = DateTime.utc(2026, 10, 4, 9);
      Session session(String id, int minute, int duration) => Session(
        id: id,
        activityId: 'a',
        deviceId: id,
        deviceName: id,
        start: start.add(Duration(minutes: minute)),
        end: start.add(Duration(minutes: minute + duration)),
        lastSeen: start,
      );
      final sessions = [
        session('PC', 0, 60),
        session('phone', 30, 15),
        session('later', 60, 20),
      ];
      expect(
        overlappingSessions(sessions, start.add(const Duration(hours: 2))),
        {'PC', 'phone'},
      );
    },
  );
}
