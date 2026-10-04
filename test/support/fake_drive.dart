import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sprout/google_auth.dart';
import 'package:sprout/model.dart';

class FakeAuth extends GoogleAuth {
  FakeAuth() {
    connected = true;
  }
  int refreshes = 0;
  @override
  Future<String> accessToken({bool forceRefresh = false}) async {
    if (forceRefresh) refreshes++;
    return 'test-token';
  }
}

class FakeDrive {
  FakeDrive() {
    client = MockClient(handle);
  }
  late final http.Client client;
  final files = <String, Json>{};
  final contents = <String, String>{};
  bool offline = false;
  bool expiredOnce = false;
  int transientFailures = 0;
  int downloads = 0;
  int uploads = 0;
  int pageSize = 1000;
  Future<void> Function()? duringUpload;
  int _next = 0;

  void setPayload(String id, String payload) {
    contents[id] = payload;
    files[id]!['size'] = '${utf8.encode(payload).length}';
    files[id]!['md5Checksum'] = md5.convert(utf8.encode(payload)).toString();
    files[id]!['modifiedTime'] = '2026-01-01T00:00:00Z';
  }

  String addJournal(String name, Json journal) {
    final id = '${++_next}';
    files[id] = {'id': id, 'name': name};
    setPayload(id, jsonEncode(journal));
    return id;
  }

  Future<http.Response> handle(http.Request request) async {
    if (offline) throw http.ClientException('offline');
    if (expiredOnce) {
      expiredOnce = false;
      return http.Response('', 401);
    }
    if (transientFailures > 0) {
      transientFailures--;
      return http.Response('', 503);
    }
    final uri = request.url;
    if (request.method == 'GET' && uri.path == '/drive/v3/files') {
      final offset = int.parse(uri.queryParameters['pageToken'] ?? '0');
      final page = files.values.skip(offset).take(pageSize).toList();
      return http.Response(
        jsonEncode({
          'files': page,
          if (offset + page.length < files.length)
            'nextPageToken': '${offset + page.length}',
        }),
        200,
      );
    }
    if (request.method == 'GET') {
      downloads++;
      return http.Response(contents[uri.pathSegments.last]!, 200);
    }
    uploads++;
    String id;
    String payload;
    if (request.method == 'POST') {
      final boundary = request.headers['content-type']!.split('boundary=').last;
      final parts = request.body.split('--$boundary');
      final metadata =
          jsonDecode(parts[1].split('\r\n\r\n').last.trim()) as Json;
      payload = parts[2].split('\r\n\r\n').last.trim();
      id = '${++_next}';
      files[id] = {'id': id, 'name': metadata['name']};
    } else {
      id = uri.pathSegments.last;
      payload = request.body;
    }
    setPayload(id, payload);
    final callback = duringUpload;
    duringUpload = null;
    if (callback != null) await callback();
    return http.Response(jsonEncode({'id': id}), 200);
  }
}
