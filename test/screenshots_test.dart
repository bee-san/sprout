import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sprout/controller.dart';
import 'package:sprout/google_auth.dart';
import 'package:sprout/main.dart';
import 'package:sprout/model.dart';
import 'package:sprout/store.dart';

void main() {
  testWidgets(
    'reports and tracking work at phone and desktop sizes with real fonts',
    (tester) async {
      final font = FontLoader('Nunito')
        ..addFont(rootBundle.load('assets/fonts/Nunito.ttf'));
      await font.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
      sqfliteFfiInit();
      final store = await Store.open(
        factory: databaseFactoryFfiNoIsolate,
        databasePath: inMemoryDatabasePath,
      );
      final tracker = Tracker(store, GoogleAuth());
      tracker.now = DateTime(2026, 10, 4, 12);
      final activities = [
        const Activity(id: 'reading', name: 'Reading', color: 0xFF567561),
        const Activity(id: 'study', name: 'Japanese', color: 0xFFAF657D),
        const Activity(
          id: 'work',
          name: 'Deep work',
          color: 0xFF7165A1,
          client: 'Studio',
        ),
        const Activity(id: 'walk', name: 'A little walk', color: 0xFFAD763D),
      ];
      await store.writeBatch({
        'activity': activities.map((a) => a.toJson()).toList(),
        'session': List.generate(14, (i) {
          final start = DateTime(2026, 9, 28 + i ~/ 2, 8 + i % 2);
          final end = start.add(Duration(minutes: 25 + (i * 17) % 60));
          return Session(
            id: 'demo-$i',
            activityId: activities[i % 4].id,
            deviceId: store.deviceId,
            deviceName: 'Demo',
            start: start,
            end: end,
            lastSeen: end,
            note: [
              'One more chapter',
              'A little listening practice',
              'Make something lovely',
              'Fresh air',
            ][i % 4],
            tags: [i % 2 == 0 ? 'focus' : 'everyday'],
            billable: i % 4 == 2,
          ).toJson();
        }),
      });
      await tracker.reload();
      addTearDown(() async {
        tracker.dispose();
        await store.close();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      tester.view.devicePixelRatio = 1;
      final key = GlobalKey();
      Future<void> capture(String name) async {
        if (Platform.environment['SPROUT_SCREENSHOTS'] != '1') return;
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final directory = Directory('docs/screenshots')
            ..createSync(recursive: true);
          await File(
            '${directory.path}/$name.png',
          ).writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }

      for (final size in [
        const Size(320, 844),
        const Size(390, 844),
        const Size(1360, 960),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: Sprout(tracker: tracker),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (size.width == 390) await capture('phone-track');
        if (size.width == 1360) await capture('desktop-track');
        await tester.tap(find.text('Reports'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Today').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('This week').last);
        await tester.pumpAndSettle();
        expect(find.text('A little perspective'), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (size.width == 390) await capture('phone-reports');
        if (size.width == 1360) await capture('desktop-reports');
        await tester.scrollUntilVisible(
          find.text('Activity breakdown'),
          220,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
    },
  );
}
