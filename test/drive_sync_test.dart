import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sprout/drive_sync.dart';
import 'package:sprout/google_auth.dart';
import 'package:sprout/model.dart';
import 'package:sprout/store.dart';

class TestAuth extends GoogleAuth {
  TestAuth() {
    connected = true;
  }
  @override
  Future<String> accessToken({bool forceRefresh = false}) async => 'test-token';
}

void main() {
  test(
    'Drive protocol merges two device journals, uploads edits, and retains deletions',
    () async {
      sqfliteFfiInit();
      final a = await Store.open(
        factory: databaseFactoryFfiNoIsolate,
        databasePath: inMemoryDatabasePath,
      );
      final b = await Store.open(
        factory: databaseFactoryFfiNoIsolate,
        databasePath: inMemoryDatabasePath,
      );
      addTearDown(() async {
        await a.close();
        await b.close();
      });
      final files = <String, Json>{};
      final contents = <String, String>{};
      var nextId = 0;
      final client = MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer test-token');
        final uri = request.url;
        if (request.method == 'GET' && uri.path == '/drive/v3/files') {
          expect(uri.queryParameters['spaces'], 'appDataFolder');
          return http.Response(
            jsonEncode({'files': files.values.toList()}),
            200,
          );
        }
        if (request.method == 'GET') {
          return http.Response(contents[uri.pathSegments.last]!, 200);
        }
        String id;
        String payload;
        if (request.method == 'POST') {
          final boundary = request.headers['content-type']!
              .split('boundary=')
              .last;
          final parts = request.body.split('--$boundary');
          final metadata =
              jsonDecode(parts[1].split('\r\n\r\n').last.trim()) as Json;
          payload = parts[2].split('\r\n\r\n').last.trim();
          id = '${++nextId}';
          files[id] = {'id': id, 'name': metadata['name']};
        } else {
          expect(request.method, 'PATCH');
          id = uri.pathSegments.last;
          payload = request.body;
        }
        contents[id] = payload;
        files[id]!['size'] = '${utf8.encode(payload).length}';
        files[id]!['md5Checksum'] = md5
            .convert(utf8.encode(payload))
            .toString();
        files[id]!['modifiedTime'] = '2026-10-04T09:00:00Z';
        return http.Response(jsonEncode({'id': id}), 200);
      });
      addTearDown(client.close);
      final driveA = DriveSync(a, TestAuth(), client: client);
      final driveB = DriveSync(b, TestAuth(), client: client);
      await a.write('activity', 'gaming', {
        'id': 'gaming',
        'name': 'Gaming',
        'color': 1,
      });
      await b.write('activity', 'reading', {
        'id': 'reading',
        'name': 'Reading',
        'color': 2,
      });
      await driveA.sync();
      await driveB.sync();
      await driveA.sync();
      expect(driveA.error, isNull);
      expect(driveB.error, isNull);
      expect((await a.activities()).map((a) => a.id).toSet(), {
        'gaming',
        'reading',
      });
      expect((await b.activities()).map((a) => a.id).toSet(), {
        'gaming',
        'reading',
      });
      expect(files.length, 2);
      await a.write('activity', 'reading', {
        'id': 'reading',
        'name': 'Japanese',
        'color': 3,
      });
      await b.write('activity', 'gaming', {}, deleted: true);
      await driveA.sync();
      await driveB.sync();
      await driveA.sync();
      await driveB.sync();
      expect((await a.activities()).single.name, 'Japanese');
      expect((await b.activities()).single.name, 'Japanese');
      expect(files.length, 2);
    },
  );
}
