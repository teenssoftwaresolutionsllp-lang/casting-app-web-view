import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class SecureTokenBackend {
  Future<String?> read();
  Future<void> write(String token);
  Future<void> delete();
}

class FlutterSecureTokenBackend implements SecureTokenBackend {
  static const String _key = 'auth_token';
  final FlutterSecureStorage _storage;

  FlutterSecureTokenBackend({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String token) => _storage.write(key: _key, value: token);

  @override
  Future<void> delete() => _storage.delete(key: _key);
}

class SecureTokenStore {
  final SecureTokenBackend _backend;
  String? _token;
  bool _expiredTokenFound = false;

  SecureTokenStore(this._backend);

  String? get token => isUsableToken(_token) ? _token : null;

  bool get hasExpiredToken =>
      _expiredTokenFound || (_token != null && isExpiredToken(_token));

  Future<void> initialize({String? legacyToken}) async {
    var secureToken = await _backend.read();
    if (!isUsableToken(secureToken)) {
      _expiredTokenFound = isExpiredToken(secureToken);
      if (secureToken != null) {
        await _backend.delete();
      }
      secureToken = null;
    }

    if (secureToken == null && legacyToken != null) {
      _expiredTokenFound = _expiredTokenFound || isExpiredToken(legacyToken);
    }
    final tokenToMigrate = secureToken == null && isUsableToken(legacyToken)
        ? legacyToken
        : null;
    if (tokenToMigrate != null) {
      await _backend.write(tokenToMigrate);
      secureToken = tokenToMigrate;
    }

    _token = secureToken;
    if (secureToken != null) {
      _expiredTokenFound = false;
    }
  }

  Future<void> save(String token) async {
    if (!isUsableToken(token)) {
      throw const FormatException(
        'The authentication token is invalid or expired.',
      );
    }
    await _backend.write(token);
    _token = token;
    _expiredTokenFound = false;
  }

  Future<void> clear() async {
    try {
      await _backend.delete();
    } finally {
      _token = null;
      _expiredTokenFound = false;
    }
  }

  static bool isUsableToken(String? token, {DateTime? now}) {
    if (token == null || token.isEmpty) return false;
    final parts = token.split('.');
    if (parts.length != 3) return false;

    try {
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      if (payload is! Map || payload['exp'] is! num) return false;
      final expiry = (payload['exp'] as num).toDouble();
      final nowSeconds = (now ?? DateTime.now()).millisecondsSinceEpoch / 1000;
      return expiry > nowSeconds;
    } catch (_) {
      return false;
    }
  }

  static bool isExpiredToken(String? token, {DateTime? now}) {
    if (token == null) return false;
    final parts = token.split('.');
    if (parts.length != 3) return false;
    try {
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      if (payload is! Map || payload['exp'] is! num) return false;
      final expiry = (payload['exp'] as num).toDouble();
      final nowSeconds = (now ?? DateTime.now()).millisecondsSinceEpoch / 1000;
      return expiry <= nowSeconds;
    } catch (_) {
      return false;
    }
  }

  static String? subjectFromToken(String token) {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    try {
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      final subject = payload is Map ? payload['sub'] : null;
      final value = subject?.toString().trim();
      return value == null || value.isEmpty ? null : value;
    } catch (_) {
      return null;
    }
  }
}
