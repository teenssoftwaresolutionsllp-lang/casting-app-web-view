import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart'
    hide LocalStorage;
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../../core/config/app_environment.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/routes/app_routes.dart';
import '../../../../core/services/support_webview_session.dart';
import '../../../../core/storage/local_storage.dart';
import '../../../auth/presentation/providers/auth_provider.dart';
import '../support_bridge_message.dart';

class SupportAgentScreen extends StatefulWidget {
  final String? initialUrl;

  const SupportAgentScreen({super.key, this.initialUrl});

  static Future<void> clearSessionCache() => SupportWebViewSession.clear();

  @override
  State<SupportAgentScreen> createState() => _SupportAgentScreenState();
}

class _SupportAgentScreenState extends State<SupportAgentScreen> {
  InAppWebViewController? _controller;
  Uri? _trustedUri;

  bool _isLoading = true;
  bool _hasError = false;
  String _errorMessage = '';
  bool _hasHandshaked = false;
  bool _isConfigurationError = false;
  bool _secureBridgeInstalled = false;

  @override
  void initState() {
    super.initState();

    try {
      final configuredUri = AppEnvironment.resolveSupportAgentUri(
        release: kReleaseMode,
      );
      final override = widget.initialUrl;
      if (override == null) {
        _trustedUri = configuredUri;
      } else {
        final overrideUri = AppEnvironment.resolveEndpoint(
          override,
          developmentDefault: configuredUri.toString(),
          release: kReleaseMode,
          name: 'SUPPORT_AGENT_URL_OVERRIDE',
        );
        if (!AppEnvironment.isTrustedOrigin(
          overrideUri.toString(),
          configuredUri,
        )) {
          throw StateError(
            'The support URL override must use the trusted origin.',
          );
        }
        _trustedUri = overrideUri;
      }
    } on StateError {
      _hasError = true;
      _isLoading = false;
      _isConfigurationError = true;
      _errorMessage = 'Support is not configured securely for this build.';
      return;
    }
  }

  @override
  void dispose() {
    final controller = _controller;
    if (controller != null) {
      SupportWebViewSession.unregister(controller);
    }
    super.dispose();
  }

  Future<void> _onWebViewCreated(InAppWebViewController controller) async {
    _controller = controller;
    SupportWebViewSession.register(controller);
    await _installSecureBridgeAndLoad();
  }

  Future<void> _installSecureBridgeAndLoad() async {
    final controller = _controller;
    final trustedUri = _trustedUri;
    if (controller == null || trustedUri == null) return;

    if (defaultTargetPlatform == TargetPlatform.android &&
        !await WebViewFeature.isFeatureSupported(
          WebViewFeature.WEB_MESSAGE_LISTENER,
        )) {
      _showSecureBridgeError();
      return;
    }

    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      _showSecureBridgeError();
      return;
    }

    try {
      if (!_secureBridgeInstalled) {
        await controller.addWebMessageListener(
          WebMessageListener(
            jsObjectName: 'TreekoApp',
            allowedOriginRules: {trustedUri.origin},
            onPostMessage: (message, sourceOrigin, isMainFrame, _) {
              final data = message?.data;
              if (data is! String) return;
              unawaited(
                _handleBridgeMessage(
                  data,
                  sourceOrigin?.toString(),
                  isMainFrame,
                ),
              );
            },
          ),
        );
        _secureBridgeInstalled = true;
      }

      _hasHandshaked = false;
      await controller.loadUrl(
        urlRequest: URLRequest(url: WebUri(trustedUri.toString())),
      );
    } on PlatformException {
      _showSecureBridgeError();
    }
  }

  void _showSecureBridgeError() {
    if (!mounted) return;
    setState(() {
      _isLoading = false;
      _hasError = true;
      _errorMessage = 'Secure support messaging is unavailable on this device.';
    });
  }

  Future<void> _loadSupportAgent() async {
    final controller = _controller;
    if (controller == null) return;
    await _installSecureBridgeAndLoad();
  }

  bool _isTrustedCurrentPage(String? url) {
    final trustedUri = _trustedUri;
    return trustedUri != null &&
        url != null &&
        AppEnvironment.isTrustedOrigin(url, trustedUri);
  }

  Future<void> _handleBridgeMessage(
    String? rawMessage,
    String? sourceOrigin,
    bool isMainFrame,
  ) async {
    final controller = _controller;
    final trustedUri = _trustedUri;
    if (controller == null ||
        trustedUri == null ||
        sourceOrigin == null ||
        rawMessage == null ||
        rawMessage.length > 4096) {
      return;
    }

    Object? payload;
    try {
      payload = jsonDecode(rawMessage);
    } on FormatException {
      return;
    }

    final message = SupportBridgeMessage.parse(
      payload: payload,
      isMainFrame: isMainFrame,
      origin: sourceOrigin,
      trustedUri: trustedUri,
    );
    if (message == null) return;

    final currentUrl = await controller.getUrl();
    if (!_isTrustedCurrentPage(currentUrl?.toString())) return;

    switch (message.type) {
      case 'TREEKO_SUPPORT_READY':
        await _performJwtHandoff();
        break;

      case 'TREEKO_AUTH_EXPIRED':
        await _handleAuthExpired();
        break;

      case 'APPLY_AUDITION':
        _handleAuditionApply(message.auditionId);
        break;

      default:
        break;
    }
  }

  /// Reads the existing TreeKo JWT from secure storage and hands it to the trusted page.
  Future<void> _performJwtHandoff() async {
    final controller = _controller;
    final trustedUri = _trustedUri;
    if (controller == null || trustedUri == null) return;

    final currentUrl = await controller.getUrl();
    if (!_isTrustedCurrentPage(currentUrl?.toString())) return;

    final token = LocalStorage.instance.getToken();

    if (token == null || token.isEmpty) {
      if (LocalStorage.instance.hasExpiredToken()) {
        await _handleAuthExpired();
      } else {
        await controller.evaluateJavascript(
          source:
              "if (typeof handleAuthError === 'function') { handleAuthError('missing'); }",
        );
      }
      return;
    }

    if (_hasHandshaked) {
      return;
    }
    final safeTokenJson = jsonEncode(token);

    final jsDispatch =
        '''
      (function() {
        var token = $safeTokenJson;
        if (typeof window.receiveAuthToken === 'function') {
          window.receiveAuthToken(token);
        }
        window.postMessage({
          version: '1.0',
          type: 'SET_AUTH_TOKEN',
          token: token
        }, ${jsonEncode(trustedUri.origin)});
      })();
    ''';

    _hasHandshaked = true;
    try {
      await controller.evaluateJavascript(source: jsDispatch);
    } on PlatformException {
      _hasHandshaked = false;
      if (mounted) {
        setState(() {
          _hasError = true;
          _isLoading = false;
          _errorMessage = 'Unable to securely connect to TreeKo Support.';
        });
      }
    }
  }

  /// Handles token expiration notified by the Support Agent.
  Future<void> _handleAuthExpired() async {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text(
          'Your TreeKo session has expired. Please log in again.',
        ),
        backgroundColor: AppColors.danger,
      ),
    );

    try {
      await context.read<AuthProvider>().logout();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Support session cleanup was incomplete.'),
            backgroundColor: AppColors.danger,
          ),
        );
      }
    }
    if (!mounted) return;
    context.go(AppRoutes.login);
  }

  /// Handles in-chat Audition Application button click, routing to native audition details.
  void _handleAuditionApply(String? auditionId) {
    final cleanId = auditionId?.trim();
    if (cleanId == null || cleanId.isEmpty || !mounted) return;

    context.push(AppRoutes.auditionDetails, extra: cleanId);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF121212) : Colors.white;
    final textColor = isDark ? Colors.white : Colors.black87;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, dynamic result) async {
        if (didPop) return;
        final controller = _controller;
        if (controller == null) return;
        final canGoBack = await controller.canGoBack();
        if (canGoBack) {
          await controller.goBack();
        } else {
          if (context.mounted) {
            Navigator.of(context).pop();
          }
        }
      },
      child: Scaffold(
        backgroundColor: bgColor,
        appBar: AppBar(
          backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
          elevation: 0.5,
          leading: IconButton(
            icon: Icon(
              Icons.arrow_back_ios_new_rounded,
              color: textColor,
              size: 20,
            ),
            onPressed: () async {
              final controller = _controller;
              if (controller == null) return;
              final canGoBack = await controller.canGoBack();
              if (canGoBack) {
                await controller.goBack();
              } else {
                if (context.mounted) {
                  Navigator.of(context).pop();
                }
              }
            },
          ),
          title: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.support_agent_rounded,
                  color: AppColors.primary,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Treeko Support',
                    style: TextStyle(
                      color: textColor,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Text(
                    'AI Assistant',
                    style: TextStyle(
                      color: AppColors.primary,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            IconButton(
              icon: Icon(Icons.refresh_rounded, color: textColor, size: 22),
              tooltip: 'Reload Support Agent',
              onPressed: _loadSupportAgent,
            ),
          ],
        ),
        body: Stack(
          children: [
            if (!_hasError && _trustedUri != null)
              InAppWebView(
                initialSettings: InAppWebViewSettings(
                  javaScriptEnabled: true,
                  incognito: true,
                  useShouldOverrideUrlLoading: true,
                  supportMultipleWindows: false,
                  javaScriptCanOpenWindowsAutomatically: false,
                ),
                onWebViewCreated: _onWebViewCreated,
                onLoadStart: (controller, url) {
                  if (url != null && !_isTrustedCurrentPage(url.toString())) {
                    return;
                  }
                  _hasHandshaked = false;
                  if (mounted) {
                    setState(() {
                      _isLoading = true;
                      _hasError = false;
                    });
                  }
                },
                onLoadStop: (controller, url) async {
                  if (url != null && !_isTrustedCurrentPage(url.toString())) {
                    await controller.stopLoading();
                    return;
                  }
                  if (mounted) {
                    setState(() {
                      _isLoading = false;
                    });
                  }
                },
                onReceivedError: (controller, request, error) {
                  if (request.isForMainFrame == true && mounted) {
                    setState(() {
                      _isLoading = false;
                      _hasError = true;
                      _errorMessage =
                          'Please check your internet connection and try again.';
                    });
                  }
                },
                shouldOverrideUrlLoading: (controller, action) async {
                  final url = action.request.url;
                  if (action.isForMainFrame == true &&
                      url != null &&
                      _isTrustedCurrentPage(url.toString())) {
                    return NavigationActionPolicy.ALLOW;
                  }
                  return NavigationActionPolicy.CANCEL;
                },
              ),
            if (_isLoading)
              const LinearProgressIndicator(
                backgroundColor: Colors.transparent,
                valueColor: AlwaysStoppedAnimation<Color>(AppColors.primary),
              ),
            if (_hasError)
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.cloud_off_rounded,
                        size: 56,
                        color: AppColors.danger,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Unable to connect to Treeko Support',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: textColor,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _errorMessage.isNotEmpty
                            ? _errorMessage
                            : 'Please check your internet connection and try again.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: isDark ? Colors.white60 : Colors.black54,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 24),
                      if (!_isConfigurationError)
                        ElevatedButton.icon(
                          onPressed: _loadSupportAgent,
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('Try Again'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 12,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
