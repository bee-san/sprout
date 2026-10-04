import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sprout/backup_ui.dart';
import 'package:sprout/backups.dart';
import 'package:sprout/controller.dart';
import 'package:sprout/google_auth.dart';
import 'package:sprout/main.dart';
import 'package:sprout/portability.dart';
import 'package:sprout/recovery_screen.dart';
import 'package:sprout/store.dart';

import 'support/backup_fixture.dart';

void main() {
  testWidgets(
    'restore preview stays readable on a small phone and deletion recovery is opt-in',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final snapshot = StoreSnapshot([], [], {});
      final data = decodeBackup(backupFixture(running: true));
      RestoreOptions? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                selected = await showDialog<RestoreOptions>(
                  context: context,
                  builder: (_) => RestorePreviewDialog(
                    backup: data,
                    snapshot: snapshot,
                    fileName:
                        'sprout-backup-a-long-but-perfectly-valid-name.json',
                  ),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('Checksum verified'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Restore').last);
      await tester.pumpAndSettle();
      expect(selected!.includeDeleted, isFalse);
      expect(selected!.deviceSettings, isFalse);
    },
  );

  testWidgets(
    'settings offer portable backups and recovery without layout errors at phone and desktop widths',
    (tester) async {
      sqfliteFfiInit();
      final store = await Store.open(
        factory: databaseFactoryFfiNoIsolate,
        databasePath: inMemoryDatabasePath,
      );
      final tracker = Tracker(store, GoogleAuth());
      addTearDown(() async {
        tracker.dispose();
        await store.close();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      tester.view.devicePixelRatio = 1;
      for (final width in [320.0, 1360.0]) {
        tester.view.physicalSize = Size(width, 844);
        await tester.pumpWidget(Sprout(tracker: tracker));
        await tester.tap(find.text('Settings').last);
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('Save a portable backup'),
          250,
          scrollable: find.byType(Scrollable).first,
        );
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(
          find.text('Restore a backup'),
          180,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('Restore a backup'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('Recovery copies'),
          180,
          scrollable: find.byType(Scrollable).first,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
    },
  );

  testWidgets(
    'a startup failure offers verified local copies for recovery and export',
    (tester) async {
      late Directory root;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('sprout-recovery-ui-');
        await BackupVault(
          Directory('${root.path}/backups'),
        ).save(backupFixture(), 'restore');
      });
      addTearDown(() async {
        await root.delete(recursive: true);
      });
      await tester.pumpWidget(
        RecoveryScreen(
          databasePath: '${root.path}/timebud.sqlite',
          error: 'Synthetic corruption',
          onRecovered: () async {},
        ),
      );
      for (
        var attempt = 0;
        attempt < 30 && find.text('Before restore').evaluate().isEmpty;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.text('Try again'), findsOneWidget);
      expect(find.text('Choose a backup'), findsOneWidget);
      expect(find.text('Before restore'), findsOneWidget);
      expect(find.text('Recover'), findsOneWidget);
      expect(find.text('Export'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Recover'));
      for (
        var attempt = 0;
        attempt < 30 &&
            find.text('Recover from this backup?').evaluate().isEmpty;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      // Recovery remains busy until the confirmation is answered.
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Recover from this backup?'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    },
  );
}
