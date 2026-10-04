import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'model.dart';

const driveScope = 'https://www.googleapis.com/auth/drive.appdata';

class GoogleAuth {
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  GoogleSignInAccount? _androidAccount;
  bool _initialized = false;
  bool connected = false;
  Json? _tokens;

  Future<void> load() async {
    connected = await _storage.read(key: 'connected') == 'true';
    final saved = await _storage.read(key: 'tokens');
    if (saved != null) _tokens = jsonDecode(saved) as Json;
  }

  Future<void> configureDesktop(Json json) async {
    final installed = json['installed'];
    if (installed is! Map ||
        installed['client_id'] is! String ||
        installed['client_secret'] is! String) {
      throw const FormatException(
        'Choose an OAuth credentials JSON for a Desktop app.',
      );
    }
    await disconnect();
    await _storage.write(key: 'desktopClient', value: jsonEncode(installed));
  }

  Future<void> configureAndroid(String webClientId) async {
    if (!webClientId.trim().endsWith('.apps.googleusercontent.com')) {
      throw const FormatException('Enter your Google Web client ID.');
    }
    if (_initialized) {
      throw StateError(
        'Restart Sprout before changing an initialized Google client.',
      );
    }
    await _storage.write(key: 'androidClient', value: webClientId.trim());
  }

  Future<bool> configured() async => Platform.isAndroid
      ? (await _storage.read(key: 'androidClient') ??
                const String.fromEnvironment('GOOGLE_ANDROID_SERVER_CLIENT_ID'))
            .isNotEmpty
      : await _storage.read(key: 'desktopClient') != null;
  Future<void> _initializeAndroid() async {
    if (_initialized) return;
    final client =
        await _storage.read(key: 'androidClient') ??
        const String.fromEnvironment('GOOGLE_ANDROID_SERVER_CLIENT_ID');
    if (client.isEmpty) throw StateError('Set up Google credentials first.');
    await GoogleSignIn.instance.initialize(serverClientId: client);
    _initialized = true;
  }

  Future<void> connect() async {
    if (Platform.isAndroid) {
      await _initializeAndroid();
      _androidAccount = await GoogleSignIn.instance.authenticate();
      await _androidAccount!.authorizationClient.authorizeScopes([driveScope]);
    } else {
      await _connectDesktop();
    }
    connected = true;
    await _storage.write(key: 'connected', value: 'true');
  }

  String _random() => base64UrlEncode(
    List.generate(32, (_) => Random.secure().nextInt(256)),
  ).replaceAll('=', '');
  Future<void> _connectDesktop() async {
    final saved = await _storage.read(key: 'desktopClient');
    if (saved == null) {
      throw StateError('Import Google desktop credentials first.');
    }
    final client = jsonDecode(saved) as Json;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final verifier = _random();
    final state = _random();
    final redirect = 'http://127.0.0.1:${server.port}/oauth/callback';
    final code = Completer<String>();
    final listener = server.listen((request) async {
      if (request.uri.path != '/oauth/callback') {
        request.response.statusCode = 404;
        await request.response.close();
        return;
      }
      final query = request.uri.queryParameters;
      if (query['state'] != state) {
        request.response.statusCode = 400;
        request.response.write('Invalid sign-in state.');
        await request.response.close();
        return;
      }
      request.response.headers.contentType = ContentType.html;
      request.response.write(
        '<!doctype html><title>Sprout</title><p>You can return to Sprout.</p>',
      );
      await request.response.close();
      if (!code.isCompleted) {
        if (query['code'] == null) {
          code.completeError(
            StateError('Google sign-in was cancelled or denied.'),
          );
        } else {
          code.complete(query['code']!);
        }
      }
    });
    try {
      final url = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
        'client_id': client['client_id'] as String,
        'redirect_uri': redirect,
        'response_type': 'code',
        'scope': driveScope,
        'access_type': 'offline',
        'prompt': 'consent',
        'state': state,
        'code_challenge': base64UrlEncode(
          sha256.convert(utf8.encode(verifier)).bytes,
        ).replaceAll('=', ''),
        'code_challenge_method': 'S256',
      });
      if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
        throw StateError('Could not open the browser.');
      }
      final authCode = await code.future.timeout(const Duration(minutes: 5));
      await _exchange({
        'client_id': client['client_id'] as String,
        'client_secret': client['client_secret'] as String,
        'code': authCode,
        'code_verifier': verifier,
        'redirect_uri': redirect,
        'grant_type': 'authorization_code',
      });
    } finally {
      await listener.cancel();
      await server.close(force: true);
    }
  }

  Future<void> _exchange(Map<String, String> body) async {
    final response = await http
        .post(Uri.https('oauth2.googleapis.com', '/token'), body: body)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw StateError(
        'Google authorization failed (${response.statusCode}). Check your credentials or reconnect.',
      );
    }
    final result = jsonDecode(response.body) as Json;
    if (result['access_token'] is! String) {
      throw StateError('Google returned an invalid token.');
    }
    _tokens = {
      'access': result['access_token'],
      'refresh': result['refresh_token'] ?? _tokens?['refresh'],
      'expires': DateTime.now()
          .add(Duration(seconds: result['expires_in'] as int? ?? 3600))
          .toUtc()
          .toIso8601String(),
    };
    await _storage.write(key: 'tokens', value: jsonEncode(_tokens));
  }

  Future<String> accessToken({bool forceRefresh = false}) async {
    if (!connected) throw StateError('Connect Google Drive first.');
    if (Platform.isAndroid) {
      await _initializeAndroid();
      _androidAccount ??= await GoogleSignIn.instance
          .attemptLightweightAuthentication();
      final account = _androidAccount;
      if (account == null) {
        throw StateError('Reconnect Google Drive to continue syncing.');
      }
      var authorization = await account.authorizationClient
          .authorizationForScopes([driveScope]);
      if (forceRefresh && authorization != null) {
        await account.authorizationClient.clearAuthorizationToken(
          accessToken: authorization.accessToken,
        );
        authorization = await account.authorizationClient
            .authorizationForScopes([driveScope]);
      }
      if (authorization == null) {
        throw StateError('Reconnect Google Drive to renew access.');
      }
      return authorization.accessToken;
    }
    final tokens = _tokens;
    if (tokens == null) throw StateError('Reconnect Google Drive.');
    if (forceRefresh ||
        DateTime.parse(
          tokens['expires'] as String,
        ).isBefore(DateTime.now().add(const Duration(minutes: 2)))) {
      final saved = await _storage.read(key: 'desktopClient');
      if (saved == null || tokens['refresh'] == null) {
        throw StateError('Reconnect Google Drive.');
      }
      final client = jsonDecode(saved) as Json;
      await _exchange({
        'client_id': client['client_id'] as String,
        'client_secret': client['client_secret'] as String,
        'refresh_token': tokens['refresh'] as String,
        'grant_type': 'refresh_token',
      });
    }
    return _tokens!['access'] as String;
  }

  Future<void> disconnect() async {
    if (Platform.isAndroid && _initialized) {
      await GoogleSignIn.instance.signOut();
    }
    _androidAccount = null;
    _tokens = null;
    connected = false;
    await _storage.delete(key: 'tokens');
    await _storage.delete(key: 'connected');
  }
}
