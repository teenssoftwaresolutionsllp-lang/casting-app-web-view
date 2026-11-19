import '../../../../core/config/app_environment.dart';

class SupportBridgeMessage {
  final String type;
  final String? auditionId;

  const SupportBridgeMessage._(this.type, {this.auditionId});

  static SupportBridgeMessage? parse({
    required Object? payload,
    required bool isMainFrame,
    required String origin,
    String? requestUrl,
    required Uri trustedUri,
  }) {
    if (!isMainFrame ||
        !AppEnvironment.isTrustedOrigin(origin, trustedUri) ||
        (requestUrl != null &&
            !AppEnvironment.isTrustedOrigin(requestUrl, trustedUri)) ||
        payload is! Map) {
      return null;
    }

    final message = <String, dynamic>{};
    for (final entry in payload.entries) {
      final key = entry.key;
      if (key is! String) return null;
      message[key] = entry.value;
    }

    if (message['version'] != '1.0' || message['type'] is! String) {
      return null;
    }

    switch (message['type']) {
      case 'TREEKO_SUPPORT_READY':
        if (message.length != 2) return null;
        return const SupportBridgeMessage._('TREEKO_SUPPORT_READY');
      case 'TREEKO_AUTH_EXPIRED':
        if (message.keys.any(
          (key) => key != 'version' && key != 'type' && key != 'reason',
        )) {
          return null;
        }
        final reason = message['reason'];
        if (message.length > 3 ||
            (reason != null && (reason is! String || reason.length > 256))) {
          return null;
        }
        return const SupportBridgeMessage._('TREEKO_AUTH_EXPIRED');
      case 'APPLY_AUDITION':
        final auditionId = message['audition_id'];
        if (message.length != 3 ||
            auditionId is! String ||
            auditionId.trim().isEmpty ||
            auditionId.length > 128 ||
            RegExp(r'[\u0000-\u001f\u007f]').hasMatch(auditionId)) {
          return null;
        }
        return SupportBridgeMessage._(
          'APPLY_AUDITION',
          auditionId: auditionId.trim(),
        );
      default:
        return null;
    }
  }
}
