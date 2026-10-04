import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sprout/controller.dart';
import 'package:sprout/google_auth.dart';
import 'package:sprout/main.dart';
import 'package:sprout/store.dart';

void main() {
  testWidgets(
    'mobile layout can add an activity, start and stop it, and open history',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      sqfliteFfiInit();
      final store = await Store.open(
        factory: databaseFactoryFfiNoIsolate,
        databasePath: inMemoryDatabasePath,
      );
      final tracker = Tracker(store, GoogleAuth());
      await tester.pumpWidget(Sprout(tracker: tracker));
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Japanese');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(tracker.activities.single.name, 'Japanese');
      await tester.scrollUntilVisible(
        find.byTooltip('Start Japanese'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Japanese'), findsOneWidget);
      await tester.tap(find.byTooltip('Start Japanese'));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(tracker.current?.activityId, isNotNull);
      await tester.scrollUntilVisible(
        find.text('Stop'),
        -180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Stop'));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(tracker.current, isNull);
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();
      expect(find.text('Your timeline'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      tracker.dispose();
      await store.close();
    },
  );
}
