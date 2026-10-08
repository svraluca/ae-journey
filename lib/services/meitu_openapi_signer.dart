import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Meitu OpenAPI SDK-HMAC-SHA256 signing (meitu-cli compatible).
class MeituOpenApiSigner {
  static const algorithm = 'SDK-HMAC-SHA256';
  static const headerXDate = 'X-Sdk-Date';
  static const headerHost = 'Host';
  static const headerAuthorization = 'Authorization';
  static const headerContentSha256 = 'X-Sdk-Content-Sha256';

  static String formatBasicDate([DateTime? when]) {
    final d = (when ?? DateTime.now().toUtc()).toIso8601String();
    return '${d.replaceAll(RegExp(r'[:-]|\.\d{3}'), '').substring(0, 15)}Z';
  }

  static String hashSha256Hex(String data) =>
      sha256.convert(utf8.encode(data)).toString();

  static dynamic sortJsonValue(dynamic value) {
    if (value is List) return value.map(sortJsonValue).toList();
    if (value is Map) {
      final keys = value.keys.map((k) => k.toString()).toList()..sort();
      return {for (final k in keys) k: sortJsonValue(value[k])};
    }
    return value;
  }

  static String canonicalBodyString(Object? body) {
    if (body == null) return '';
    return jsonEncode(sortJsonValue(body));
  }

  static List<int> canonicalBodyBytes(Object? body) =>
      utf8.encode(canonicalBodyString(body));

  /// Returns HTTP headers with Meitu-expected casing (Host, X-Sdk-Date, …).
  static Map<String, String> signSdkHeaders({
    required Uri url,
    required String method,
    Map<String, String> headers = const {},
    Object? body,
    required String accessKey,
    required String secretKey,
    bool includeHost = true,
  }) {
    final bodyString = canonicalBodyString(body);
    final normalized = <String, String>{};
    for (final e in headers.entries) {
      final v = e.value.trim();
      if (v.isEmpty) continue;
      normalized[e.key.toLowerCase()] = v;
    }
    if (includeHost) {
      normalized['host'] = normalized['host'] ?? url.host;
    }
    normalized['x-sdk-date'] =
        normalized['x-sdk-date'] ?? formatBasicDate();

    final signedNames = normalized.keys.toList()..sort();
    final payloadHash = hashSha256Hex(bodyString);

    final canonicalHeaders = signedNames
        .map((n) => '$n:${normalized[n] ?? ''}')
        .join('\n');

    var path = url.path;
    if (path.isEmpty || !path.endsWith('/')) path = '$path/';

    final canonicalRequest = [
      method.toUpperCase(),
      path,
      _canonicalQuery(url.query),
      canonicalHeaders,
      signedNames.join(';'),
      payloadHash,
    ].join('\n');

    final date = normalized['x-sdk-date']!;
    final stringToSign =
        '$algorithm\n$date\n${hashSha256Hex(canonicalRequest)}';
    final signature = Hmac(sha256, utf8.encode(secretKey))
        .convert(utf8.encode(stringToSign))
        .toString();
    final inner =
        '$algorithm Access=$accessKey, SignedHeaders=${signedNames.join(';')}, Signature=$signature';

    final out = <String, String>{
      headerAuthorization: 'Bearer ${base64Encode(utf8.encode(inner))}',
      headerXDate: date,
    };
    if (includeHost) out[headerHost] = normalized['host']!;
    final ct = normalized['content-type'];
    if (ct != null && ct.isNotEmpty) {
      out['Content-Type'] = ct;
    }
    return out;
  }

  static String _canonicalQuery(String query) {
    if (query.isEmpty) return '';
    final params = Uri.splitQueryString(query).entries.toList()
      ..sort((a, b) {
        final c = a.key.compareTo(b.key);
        return c != 0 ? c : a.value.compareTo(b.value);
      });
    return params
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&');
  }
}
