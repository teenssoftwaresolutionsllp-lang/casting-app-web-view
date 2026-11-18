import 'package:flutter/foundation.dart';

class AppEnvironment {
  AppEnvironment._();

  static const String apiBaseUrl = String.fromEnvironment('API_BASE_URL');
  static const String supportAgentUrl = String.fromEnvironment(
    'SUPPORT_AGENT_URL',
  );

  static Uri resolveApiBaseUri({bool release = kReleaseMode}) {
    final defaultUrl = switch (defaultTargetPlatform) {
      TargetPlatform.android => 'http://10.0.2.2:3000/',
      _ => 'http://localhost:3000/',
    };
    return resolveEndpoint(
      apiBaseUrl,
      developmentDefault: defaultUrl,
      release: release,
      name: 'API_BASE_URL',
    );
  }

  static Uri resolveSupportAgentUri({
    String? override,
    bool release = kReleaseMode,
  }) {
    final defaultUrl = switch (defaultTargetPlatform) {
      TargetPlatform.android => 'http://10.0.2.2:5000/',
      _ => 'http://localhost:5000/',
    };
    return resolveEndpoint(
      override ?? supportAgentUrl,
      developmentDefault: defaultUrl,
      release: release,
      name: 'SUPPORT_AGENT_URL',
    );
  }

  static Uri resolveEndpoint(
    String configuredUrl, {
    required String developmentDefault,
    required bool release,
    required String name,
  }) {
    final rawUrl = configuredUrl.trim().isEmpty
        ? (release ? '' : developmentDefault)
        : configuredUrl.trim();
    if (rawUrl.isEmpty) {
      throw StateError('$name must be configured for release builds.');
    }

    final uri = Uri.tryParse(rawUrl);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !const ['http', 'https'].contains(uri.scheme.toLowerCase())) {
      throw StateError('$name must be a valid HTTP(S) URL.');
    }

    final isHttps = uri.scheme.toLowerCase() == 'https';
    final isLocalHost = _isLocalHost(uri.host);
    if (release && (!isHttps || isLocalHost)) {
      throw StateError('$name must use HTTPS and a non-local host in release.');
    }
    return uri;
  }

  static bool _isLocalHost(String host) {
    final normalizedHost = host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
    return normalizedHost == 'localhost' ||
        normalizedHost.endsWith('.localhost') ||
        normalizedHost.startsWith('127.') ||
        normalizedHost == '::1' ||
        normalizedHost == '0.0.0.0' ||
        normalizedHost == '10.0.2.2';
  }

  static bool isTrustedOrigin(String currentUrl, Uri trustedUri) {
    final currentUri = Uri.tryParse(currentUrl);
    return currentUri != null &&
        currentUri.scheme.toLowerCase() == trustedUri.scheme.toLowerCase() &&
        currentUri.host.toLowerCase() == trustedUri.host.toLowerCase() &&
        currentUri.port == trustedUri.port &&
        currentUri.userInfo.isEmpty;
  }
}
