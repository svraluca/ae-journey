import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Zyte API browser HTML fallback for Explore clinic pages.
///
/// Returns **only** rendered HTML (`browserHtml: true`). Never requests
/// Zyte AI extraction / product schemas / LLM fields — callers must run
/// deterministic [extractPriceEvidence] on the HTML.
class ExploreZyteClient {
  ExploreZyteClient({
    required this.apiKey,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final String apiKey;
  final http.Client _http;

  static const _endpoint = 'https://api.zyte.com/v1/extract';
  static const _timeout = Duration(seconds: 35);
  /// Keep below the HTML extractor cap so parse stays off the critical path.
  static const maxBrowserHtmlChars = 120000;

  static Future<void>? _gate;

  /// Serialize Zyte calls — parallel mega-fetches freeze the UI isolate.
  static Future<T> _withGate<T>(Future<T> Function() run) async {
    while (_gate != null) {
      try {
        await _gate;
      } catch (_) {}
    }
    final done = Completer<void>();
    _gate = done.future;
    try {
      return await run();
    } finally {
      done.complete();
      if (identical(_gate, done.future)) _gate = null;
    }
  }

  bool get isConfigured => apiKey.trim().isNotEmpty;

  /// URLs that must never be sent to Zyte (sitemaps / feeds choke the UI).
  static bool isUnsupportedUrl(String pageUrl) {
    final u = pageUrl.trim().toLowerCase();
    if (u.isEmpty) return true;
    if (u.endsWith('.xml') ||
        u.endsWith('.xml.gz') ||
        u.contains('sitemap') ||
        u.contains('/feed') ||
        u.contains('robots.txt') ||
        u.contains('/category/') ||
        u.contains('/tag/') ||
        u.contains('/wp-json/') ||
        u.contains('health-knowledge') ||
        u.contains('/post/') ||
        u.contains('what-is-') ||
        u.contains('before-and-after') ||
        u.endsWith('.json') ||
        u.endsWith('.css') ||
        u.endsWith('.js')) {
      return true;
    }
    return false;
  }

  /// Browser-rendered HTML for [pageUrl], or empty on failure.
  Future<String> fetchBrowserHtml(String pageUrl) {
    return _withGate(() => _fetchBrowserHtmlUnlocked(pageUrl));
  }

  Future<String> _fetchBrowserHtmlUnlocked(String pageUrl) async {
    if (!isConfigured || pageUrl.trim().isEmpty) return '';
    if (isUnsupportedUrl(pageUrl)) {
      debugPrint('[ZYTE FALLBACK] skip unsupported · $pageUrl');
      return '';
    }
    final url =
        pageUrl.contains('://') ? pageUrl.trim() : 'https://${pageUrl.trim()}';
    try {
      debugPrint('[ZYTE FALLBACK] browserHtml · $url');
      final basic = base64Encode(utf8.encode('${apiKey.trim()}:'));
      final res = await _http
          .post(
            Uri.parse(_endpoint),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              'Authorization': 'Basic $basic',
            },
            body: jsonEncode({
              'url': url,
              // Rendered DOM only — never AI extract / product / customAttributes.
              'browserHtml': true,
            }),
          )
          .timeout(_timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        debugPrint('[ZYTE FALLBACK] HTTP ${res.statusCode}');
        return '';
      }
      // Avoid decoding multi‑MB JSON on the UI isolate when possible.
      if (res.bodyBytes.length > maxBrowserHtmlChars * 3) {
        debugPrint(
          '[ZYTE FALLBACK] response too large (${res.bodyBytes.length} B) · skip',
        );
        return '';
      }
      final decoded = jsonDecode(res.body);
      if (decoded is! Map) {
        debugPrint('[ZYTE FALLBACK] non-object response');
        return '';
      }
      // Explicitly ignore any AI / extract / product fields if present.
      for (final banned in const [
        'product',
        'productList',
        'article',
        'jobPosting',
        'customAttributes',
        'extract',
        'llm',
      ]) {
        if (decoded.containsKey(banned)) {
          debugPrint('[ZYTE FALLBACK] ignoring banned field "$banned"');
        }
      }
      var html = '${decoded['browserHtml'] ?? ''}'.trim();
      if (html.isEmpty) {
        debugPrint('[ZYTE FALLBACK] empty browserHtml');
        return '';
      }
      if (html.length > maxBrowserHtmlChars) {
        debugPrint(
          '[ZYTE FALLBACK] truncate ${html.length} → $maxBrowserHtmlChars · $url',
        );
        html = html.substring(0, maxBrowserHtmlChars);
      }
      debugPrint('[ZYTE FALLBACK] ok · ${html.length} chars · $url');
      return html;
    } catch (e) {
      debugPrint('[ZYTE FALLBACK] failed: $e');
      return '';
    }
  }
}