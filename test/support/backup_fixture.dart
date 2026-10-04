import 'package:sprout/model.dart';
import 'package:sprout/portability.dart';

const backupActivity = Activity(
  id: 'reading',
  name: 'Reading 日本語',
  client: 'My studio',
  color: 0xFF567561,
);
final backupTime = DateTime.utc(2026, 10, 4, 12);
Session backupSession(String id, {bool running = false}) => Session(
  id: id,
  activityId: backupActivity.id,
  deviceId: 'original-phone',
  deviceName: 'My phone',
  start: backupTime.subtract(const Duration(hours: 2)),
  end: running ? null : backupTime.subtract(const Duration(hours: 1)),
  lastSeen: backupTime.subtract(const Duration(hours: 1)),
  note: 'A note, with "quotes"\nand another line 日本語',
  tags: const ['focus', 'books'],
  billable: true,
);
const backupRule = AppRule(
  id: 'reader-rule',
  activityId: 'reading',
  executable: r'C:\Apps\Reader.exe',
  pauseWhenIdle: true,
);

String backupFixture({bool running = false}) => encodeBackup(
  [backupActivity],
  [backupSession('saved'), if (running) backupSession('live', running: true)],
  backupTime,
  rules: [backupRule],
  preferences: {'automatic': false, 'notifications': false},
);
