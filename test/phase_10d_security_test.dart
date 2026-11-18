import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicc/core/config/app_environment.dart';
import 'package:aicc/core/network/dio_client.dart';
import 'package:aicc/core/storage/local_storage.dart';
import 'package:aicc/core/storage/secure_token_store.dart';
import 'package:aicc/features/support/presentation/support_bridge_message.dart';

class _MemoryTokenBackend implements SecureTokenBackend {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String token) async {
    value = token;
  }

  @override
  Future<void> delete() async {
    value = null;
  }
}

String _jwtWithExpiry(DateTime expiry) {
  final payload = base64Url
      .encode(
        utf8.encode(jsonEncode({'exp': expiry.millisecondsSinceEpoch ~/ 1000})),
      )
      .replaceAll('=', '');
  return 'e30.$payload.signature';
}

void main() {
  group('endpoint configuration', () {
    test('release endpoints must be explicit, HTTPS, and non-local', () {
      expect(
        () => AppEnvironment.resolveEndpoint(
          '',
          developmentDefault: 'http://localhost:3000',
          release: true,
          name: 'API_BASE_URL',
        ),
        throwsStateError,
      );
      expect(
        () => AppEnvironment.resolveEndpoint(
          'http://api.example.test',
          developmentDefault: 'http://localhost:3000',
          release: true,
          name: 'API_BASE_URL',
        ),
        throwsStateError,
      );
      expect(
        () => AppEnvironment.resolveEndpoint(
          'https://localhost:3000',
          developmentDefault: 'http://localhost:3000',
          release: true,
          name: 'API_BASE_URL',
        ),
        throwsStateError,
      );
      expect(
        () => AppEnvironment.resolveEndpoint(
          'https://api.example.test?auth=placeholder',
          developmentDefault: 'http://localhost:3000',
          release: true,
          name: 'API_BASE_URL',
        ),
        throwsStateError,
      );
    });

    test('development permits emulator and LAN HTTP endpoints', () {
      final endpoint = AppEnvironment.resolveEndpoint(
        '',
        developmentDefault: 'http://10.0.2.2:5000',
        release: false,
        name: 'SUPPORT_AGENT_URL',
      );

      expect(endpoint.host, '10.0.2.2');
      final lanEndpoint = AppEnvironment.resolveEndpoint(
        'http://192.168.1.25:5000',
        developmentDefault: 'http://localhost:5000',
        release: false,
        name: 'SUPPORT_AGENT_URL',
      );
      expect(lanEndpoint.host, '192.168.1.25');
    });

    test('bridge page origin must match the configured origin', () {
      final trusted = Uri.parse('https://support.example.test:8443/chat');

      expect(
        AppEnvironment.isTrustedOrigin(
          'https://support.example.test:8443/chat',
          trusted,
        ),
        isTrue,
      );
      expect(
        AppEnvironment.isTrustedOrigin(
          'https://evil.example.test:8443/chat',
          trusted,
        ),
        isFalse,
      );
      expect(
        AppEnvironment.isTrustedOrigin(
          'http://support.example.test:8443/chat',
          trusted,
        ),
        isFalse,
      );
    });
  });

  test('Dio client has no request or response body logger', () {
    final client = DioClient();

    expect(client.dio.interceptors.whereType<LogInterceptor>(), isEmpty);
  });

  group('support bridge validation', () {
    final trustedUri = Uri.parse('https://support.example.test:8443/chat');

    SupportBridgeMessage? parse(
      Object? payload, {
      bool isMainFrame = true,
      String origin = 'https://support.example.test:8443',
      String requestUrl = 'https://support.example.test:8443/chat',
    }) {
      return SupportBridgeMessage.parse(
        payload: payload,
        isMainFrame: isMainFrame,
        origin: origin,
        requestUrl: requestUrl,
        trustedUri: trustedUri,
      );
    }

    test('accepts a trusted main-frame READY message', () {
      final message = parse({'version': '1.0', 'type': 'TREEKO_SUPPORT_READY'});

      expect(message?.type, 'TREEKO_SUPPORT_READY');
    });

    test('rejects untrusted origins, subframes, and malformed events', () {
      const payload = {'version': '1.0', 'type': 'TREEKO_SUPPORT_READY'};

      expect(parse(payload, isMainFrame: false), isNull);
      expect(parse(payload, origin: 'https://evil.example.test'), isNull);
      expect(
        parse(payload, requestUrl: 'https://evil.example.test/frame'),
        isNull,
      );
      expect(parse({...payload, 'token': 'unexpected'}), isNull);
      expect(parse({...payload, 'version': '2.0'}), isNull);
      expect(parse({'version': '1.0', 'type': 'UNKNOWN'}), isNull);
    });

    test('validates audition navigation payloads', () {
      final message = parse({
        'version': '1.0',
        'type': 'APPLY_AUDITION',
        'audition_id': 'audition-123',
      });

      expect(message?.auditionId, 'audition-123');
      expect(
        parse({
          'version': '1.0',
          'type': 'APPLY_AUDITION',
          'audition_id': 'bad\nid',
        }),
        isNull,
      );
    });
  });

  group('secure token storage', () {
    test(
      'migrates the SharedPreferences token and removes the legacy copy',
      () async {
        final token = _jwtWithExpiry(
          DateTime.now().add(const Duration(hours: 1)),
        );
        SharedPreferences.setMockInitialValues({'auth_token': token});
        final backend = _MemoryTokenBackend();

        await LocalStorage.init(tokenStore: SecureTokenStore(backend));

        final preferences = await SharedPreferences.getInstance();
        expect(LocalStorage.instance.getToken(), token);
        expect(backend.value, token);
        expect(preferences.getString('auth_token'), isNull);

        await LocalStorage.instance.clearAll();

        expect(LocalStorage.instance.hasToken(), isFalse);
        expect(backend.value, isNull);
      },
    );

    test('migrates a valid legacy token to secure storage', () async {
      final backend = _MemoryTokenBackend();
      final store = SecureTokenStore(backend);
      final token = _jwtWithExpiry(
        DateTime.now().add(const Duration(hours: 1)),
      );

      await store.initialize(legacyToken: token);

      expect(backend.value, token);
      expect(store.token, token);
      expect(store.hasExpiredToken, isFalse);
    });

    test('does not expose expired tokens and reports expiry', () async {
      final backend = _MemoryTokenBackend();
      final store = SecureTokenStore(backend);
      final expiredToken = _jwtWithExpiry(
        DateTime.now().subtract(const Duration(minutes: 1)),
      );

      await store.initialize(legacyToken: expiredToken);

      expect(store.token, isNull);
      expect(store.hasExpiredToken, isTrue);
      expect(backend.value, isNull);
    });

    test('clears secure storage and the in-memory token', () async {
      final backend = _MemoryTokenBackend();
      final store = SecureTokenStore(backend);
      final token = _jwtWithExpiry(
        DateTime.now().add(const Duration(hours: 1)),
      );
      await store.initialize();
      await store.save(token);

      await store.clear();

      expect(backend.value, isNull);
      expect(store.token, isNull);
    });
  });
}
