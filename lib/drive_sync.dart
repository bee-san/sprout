import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'google_auth.dart';
import 'model.dart';
import 'store.dart';

class DriveSync {
  DriveSync(
    this.store,
    this.auth, {
    http.Client? client,
    this.retryDelay = const Duration(seconds: 1),
  }) : _client = client;
  final Store store;
  final GoogleAuth auth;
  final http.Client? _client;
  final Duration retryDelay;
  bool busy = false;
  String? error;
  DateTime? lastSync;

  Future<http.Response> _request(
    String method,
    Uri uri, {
    String? body,
    String? contentType,
  }) async {
    var refresh = false;
    for (var attempt = 0; attempt < 3; attempt++) {
      final token = await auth.accessToken(forceRefresh: refresh);
      final request = http.Request(method, uri);
      request.headers['Authorization'] = 'Bearer $token';
      if (contentType != null) request.headers['Content-Type'] = contentType;
      if (body != null) request.body = body;
      final client = _client ?? http.Client();
      try {
        final response = await http.Response.fromStream(
          await client.send(request).timeout(const Duration(seconds: 30)),
        ).timeout(const Duration(seconds: 45));
        if (response.statusCode == 401 && !refresh && attempt < 2) {
          refresh = true;
          continue;
        }
        // GET and PATCH are safe to retry. Retrying an uncertain POST could
        // create a second journal, so let the next sync rediscover it instead.
        if (method != 'POST' &&
            attempt < 2 &&
            (response.statusCode == 429 || response.statusCode >= 500)) {
          await Future<void>.delayed(retryDelay * (attempt + 1));
          continue;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw StateError(
            'Drive request failed (${response.statusCode}). ${response.statusCode == 403 ? 'Enable the Drive API and check your Google OAuth setup.' : 'Try syncing again.'}',
          );
        }
        return response;
      } finally {
        if (_client == null) client.close();
      }
    }
    throw StateError('Reconnect Google Drive.');
  }

  Future<List<Json>> _files() async {
    final result = <Json>[];
    String? page;
    do {
      final response = await _request(
        'GET',
        Uri.https('www.googleapis.com', '/drive/v3/files', {
          'spaces': 'appDataFolder',
          'q': "trashed = false and name contains 'timebud-v1-'",
          'fields':
              'nextPageToken,files(id,name,modifiedTime,md5Checksum,size)',
          'pageSize': '1000',
          'pageToken': ?page,
        }),
      );
      final json = jsonDecode(utf8.decode(response.bodyBytes)) as Json;
      result.addAll(
        (json['files'] as List).map((e) => Map<String, dynamic>.from(e as Map)),
      );
      page = json['nextPageToken'] as String?;
    } while (page != null);
    return result;
  }

  Future<void> sync() async {
    if (busy || !auth.connected) return;
    busy = true;
    error = null;
    try {
      final files = await _files();
      final ownName = 'timebud-v1-${store.deviceId}.json';
      final ownFiles = files.where((f) => f['name'] == ownName).toList();
      for (final file in files) {
        final id = file['id'] as String;
        final checksum =
            file['md5Checksum'] as String? ?? file['modifiedTime'] as String;
        if (await store.setting('remote:$id') == checksum) continue;
        if ((int.tryParse(file['size'] as String? ?? '0') ?? 0) >
            32 * 1024 * 1024) {
          throw StateError(
            'A Sprout sync journal is too large to load safely.',
          );
        }
        final response = await _request(
          'GET',
          Uri.https('www.googleapis.com', '/drive/v3/files/$id', {
            'alt': 'media',
          }),
        );
        if (response.bodyBytes.length > 32 * 1024 * 1024) {
          throw const FormatException('Sync journal is too large');
        }
        final journal = jsonDecode(utf8.decode(response.bodyBytes)) as Json;
        if (journal['schema'] != 1 ||
            journal['device'] is! String ||
            journal['records'] is! List ||
            file['name'] != 'timebud-v1-${journal['device']}.json') {
          throw const FormatException('Unrecognized Sprout sync journal');
        }
        final records = (journal['records'] as List)
            .map((e) => Mutation.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
        if (records.any((r) => r.device != journal['device'])) {
          throw const FormatException('Invalid journal owner');
        }
        await store.merge(records);
        await store.setSetting('remote:$id', checksum);
      }
      final dirty = await store.setting('dirty') ?? '0';
      final synced = await store.setting('synced') ?? '-1';
      if (ownFiles.isEmpty || dirty != synced) {
        final records = await store.owned();
        final body = jsonEncode({
          'schema': 1,
          'device': store.deviceId,
          'records': records.map((m) => m.toJson()).toList(),
        });
        if (ownFiles.isEmpty) {
          final boundary = 'timebud_${const Uuid().v4()}';
          final metadata = jsonEncode({
            'name': ownName,
            'parents': ['appDataFolder'],
            'mimeType': 'application/json',
          });
          await _request(
            'POST',
            Uri.https('www.googleapis.com', '/upload/drive/v3/files', {
              'uploadType': 'multipart',
            }),
            body:
                '--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n$metadata\r\n--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n$body\r\n--$boundary--\r\n',
            contentType: 'multipart/related; boundary=$boundary',
          );
        } else {
          await _request(
            'PATCH',
            Uri.https(
              'www.googleapis.com',
              '/upload/drive/v3/files/${ownFiles.first['id']}',
              {'uploadType': 'media'},
            ),
            body: body,
            contentType: 'application/json; charset=UTF-8',
          );
        }
        await store.setSetting('synced', dirty);
      }
      lastSync = DateTime.now();
      await store.setSetting('lastSync', lastSync!.toUtc().toIso8601String());
    } catch (e) {
      error = e.toString().replaceFirst(
        RegExp(r'^(Bad state: |FormatException: )'),
        '',
      );
    } finally {
      busy = false;
    }
  }
}
