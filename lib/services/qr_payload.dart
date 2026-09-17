import 'dart:convert';

/// QR payload codec for the "add friend offline" flow.
///
/// The Settings screen encodes the user's public key (plus short id and
/// nickname for a nicer pending-friend entry) as a self-describing string;
/// the Discover screen parses it again. Two shapes are accepted on input so
/// older/other clients can share a bare 64-char hex key too:
///
/// - `wave:pk:<64hex>`                          (bare, backwards friendly)
/// - `wave:pk:<base64-url or json>` — we emit compact JSON:
///   `wave:pk:{"p":"<64hex>","s":"<shortId>","n":"<name>"}`
class QrPayload {
  QrPayload._();

  static const String _prefix = 'wave:pk:';
  static final RegExp _hexRe = RegExp(r'^[0-9a-fA-F]{64}$');

  /// Hard cap for scanned/copied payloads. QR codes can only hold a few KB, so
  /// anything larger is never a real Wave key and is rejected before parsing.
  static const int maxPayloadLength = 2048;
  static const int _maxShortIdLength = 64;
  static const int _maxNameLength = 200;

  /// Builds the QR payload string for the local identity.
  static String build({
    required String publicKeyHex,
    String? shortId,
    String? name,
  }) {
    final hex = publicKeyHex.trim().toLowerCase();
    final map = <String, String>{'p': hex};
    if (shortId != null && shortId.trim().isNotEmpty) {
      map['s'] = shortId.trim();
    }
    if (name != null && name.trim().isNotEmpty) {
      map['n'] = name.trim();
    }
    return '$_prefix${jsonEncode(map)}';
  }

  /// Decodes a scanned/copied payload into a public key hex + optional
  /// shortId/name, or returns null when it is not a valid Wave key payload.
  static Map<String, String>? parse(String raw) {
    var s = raw.trim();
    if (s.isEmpty || s.length > maxPayloadLength) return null;
    if (s.startsWith(_prefix)) {
      s = s.substring(_prefix.length).trim();
    }

    if (s.startsWith('{')) {
      try {
        final map = jsonDecode(s) as Map<String, dynamic>;
        final hex = map['p'];
        if (hex is String && _hexRe.hasMatch(hex.trim())) {
          return {
            'p': hex.trim().toLowerCase(),
            if (map['s'] is String &&
                (map['s'] as String).length <= _maxShortIdLength)
              's': map['s'] as String,
            if (map['n'] is String && (map['n'] as String).length <= _maxNameLength)
              'n': map['n'] as String,
          };
        }
        return null;
      } catch (_) {
        return null;
      }
    }

    if (_hexRe.hasMatch(s)) {
      return {'p': s.trim().toLowerCase()};
    }
    return null;
  }

  /// True when [payload] decodes to a valid Wave key.
  static bool isValid(String payload) => parse(payload) != null;
}