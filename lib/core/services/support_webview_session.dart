import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class SupportWebViewSession {
  SupportWebViewSession._();

  static final Set<InAppWebViewController> _controllers = {};
  static bool _wasRegistered = false;

  static void register(InAppWebViewController controller) {
    _controllers.add(controller);
    _wasRegistered = true;
  }

  static void unregister(InAppWebViewController controller) {
    _controllers.remove(controller);
  }

  static Future<void> clear() async {
    if (!_wasRegistered && _controllers.isEmpty) return;
    var failed = false;

    for (final controller in _controllers.toList()) {
      try {
        await controller.evaluateJavascript(
          source: '''
            window.sessionStorage.clear();
            window.localStorage.clear();
            if (typeof window.clearTreekoAuthToken === 'function') {
              window.clearTreekoAuthToken();
            }
          ''',
        );
      } catch (_) {
        failed = true;
      }
    }

    try {
      await InAppWebViewController.clearAllCache(includeDiskFiles: true);
    } catch (_) {
      failed = true;
    }

    try {
      await CookieManager.instance().deleteAllCookies();
    } catch (_) {
      failed = true;
    }

    if (failed) {
      throw StateError('Support WebView session cleanup was incomplete.');
    }
    _wasRegistered = false;
  }
}
