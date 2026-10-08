import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'explore_url_discovery.dart';
import 'explore_zyte_client.dart';

/// Firecrawl `/v2/map` + `/v2/scrape` for Explore discovery fallback.
///
/// Returns URLs and raw HTML/markdown only. Callers must run
/// [extractPriceEvidence] / procedure match / price sanity — never treat a
/// Firecrawl JSON field as a trusted clinic price.
class ExploreFirecrawlClient {
  ExploreFirecrawlClient({
    required this.apiKey,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final String apiKey;
  final http.Client _http;

  static const _mapUrl = 'https://api.firecrawl.dev/v2/map';
  static const _scrapeUrl = 'https://api.firecrawl.dev/v2/scrape';
  static const _timeout = Duration(seconds: 25);

  bool get isConfigured => apiKey.trim().isNotEmpty;

  /// Site map filtered by [search]; ordered most → least relevant by Firecrawl.
  Future<List<String>> mapSite({
    required String siteUrl,
    String search = '',
    int limit = 50,
  }) async {
    if (!isConfigured) return const [];
    final url = siteUrl.trim();
    if (url.isEmpty) return const [];
    try {
      debugPrint('[GP FIRECRAWL] map $url search="$search"');
      final res = await _http
          .post(
            Uri.parse(_mapUrl),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${apiKey.trim()}',
            },
            body: jsonEncode({
              'url': url.contains('://') ? url : 'https://$url',
              if (search.trim().isNotEmpty) 'search': search.trim(),
              'limit': limit.clamp(5, 100),
              'includeSubdomains': false,
              'sitemap': 'include',
            }),
          )
          .timeout(_timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        debugPrint('[GP FIRECRAWL] map HTTP ${res.statusCode}');
        return const [];
      }
      final decoded = jsonDecode(res.body);
      if (decoded is! Map) return const [];
      final raw = decoded['links'] ??
          (decoded['data'] is Map ? decoded['data']['links'] : null);
      final out = <String>[];
      if (raw is List) {
        for (final item in raw) {
          if (item is String && item.trim().isNotEmpty) {
            out.add(item.trim());
          } else if (item is Map) {
            final u = '${item['url'] ?? item['href'] ?? ''}'.trim();
            if (u.isNotEmpty) out.add(u);
          }
        }
      }
      debugPrint('[GP FIRECRAWL] map → ${out.length} urls');
      return out;
    } catch (e) {
      debugPrint('[GP FIRECRAWL] map failed: $e');
      return const [];
    }
  }

  /// HTML page or PDF→markdown body for the deterministic extractor.
  Future<ExploreFirecrawlPage> scrapePage(String pageUrl) async {
    final empty = ExploreFirecrawlPage(url: pageUrl, html: '');
    if (!isConfigured || pageUrl.trim().isEmpty) return empty;
    if (ExploreZyteClient.isUnsupportedUrl(pageUrl) &&
        !RegExp(r'\.pdf(\?|#|$)', caseSensitive: false).hasMatch(pageUrl)) {
      debugPrint('[GP FIRECRAWL] skip unsupported $pageUrl');
      return empty;
    }
    final isPdf = RegExp(r'\.pdf(\?|#|$)', caseSensitive: false)
        .hasMatch(pageUrl);
    try {
      debugPrint(
        '[GP FIRECRAWL] scrape $pageUrl${isPdf ? ' (pdf)' : ''}',
      );
      final body = <String, Object?>{
        'url': pageUrl.contains('://') ? pageUrl : 'https://$pageUrl',
        'formats': ['html', 'markdown'],
        'onlyMainContent': false,
        if (isPdf) 'parsers': ['pdf'],
      };
      final res = await _http
          .post(
            Uri.parse(_scrapeUrl),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${apiKey.trim()}',
            },
            body: jsonEncode(body),
          )
          .timeout(_timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        debugPrint('[GP FIRECRAWL] scrape HTTP ${res.statusCode}');
        return empty;
      }
      return exploreParseFirecrawlScrape(res.body, fallbackUrl: pageUrl);
    } catch (e) {
      debugPrint('[GP FIRECRAWL] scrape failed: $e');
      return empty;
    }
  }
}

class ExploreFirecrawlPage {
  const ExploreFirecrawlPage({
    required this.url,
    required this.html,
    this.fromPdf = false,
  });

  final String url;
  final String html;
  final bool fromPdf;

  bool get usable => html.trim().isNotEmpty;
}

/// Prefer HTML; else wrap markdown so [extractPriceEvidence] can run.
ExploreFirecrawlPage exploreParseFirecrawlScrape(
  String responseBody, {
  required String fallbackUrl,
}) {
  if (responseBody.trim().isEmpty) {
    return ExploreFirecrawlPage(url: fallbackUrl, html: '');
  }
  Object? decoded;
  try {
    decoded = jsonDecode(responseBody);
  } catch (_) {
    return ExploreFirecrawlPage(url: fallbackUrl, html: '');
  }
  if (decoded is! Map) {
    return ExploreFirecrawlPage(url: fallbackUrl, html: '');
  }
  final data = decoded['data'] is Map
      ? decoded['data'] as Map
      : decoded;
  final meta = data['metadata'] is Map
      ? data['metadata'] as Map
      : const <String, Object?>{};
  final url = '${data['url'] ?? meta['sourceURL'] ?? meta['url'] ?? fallbackUrl}'
      .trim();
  final html = '${data['html'] ?? data['rawHtml'] ?? ''}'.trim();
  final markdown = '${data['markdown'] ?? ''}'.trim();
  final fromPdf = RegExp(r'\.pdf(\?|#|$)', caseSensitive: false).hasMatch(url) ||
      '${meta['contentType'] ?? ''}'.toLowerCase().contains('pdf');
  if (html.isNotEmpty) {
    return ExploreFirecrawlPage(url: url, html: html, fromPdf: fromPdf);
  }
  if (markdown.isNotEmpty) {
    return ExploreFirecrawlPage(
      url: url,
      html: exploreMarkdownToExtractableHtml(markdown),
      fromPdf: fromPdf,
    );
  }
  return ExploreFirecrawlPage(url: url, html: '', fromPdf: fromPdf);
}

String exploreMarkdownToExtractableHtml(String markdown) {
  final md = markdown.replaceAll('\r\n', '\n').trim();
  if (md.isEmpty) return '';
  final parts = <String>[];
  var inTable = false;
  for (final rawLine in md.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('|') && line.contains('|', 1)) {
      final compact = line.replaceAll(RegExp(r'\s'), '');
      if (RegExp(r'^\|?-{-2,}').hasMatch(compact)) continue;
      final cells = line
          .split('|')
          .map((c) => c.trim())
          .where((c) => c.isNotEmpty)
          .toList();
      if (cells.length < 2) continue;
      if (!inTable) {
        parts.add('<table>');
        inTable = true;
      }
      parts.add(
        '<tr>${cells.map((c) => '<td>${_escapeHtml(c)}</td>').join()}</tr>',
      );
      continue;
    }
    if (inTable) {
      parts.add('</table>');
      inTable = false;
    }
    final bullet = RegExp(r'^[-*•]\s+').firstMatch(line) ??
        RegExp(r'^\d+\.\s+').firstMatch(line);
    if (bullet != null) {
      parts.add('<li>${_escapeHtml(line.substring(bullet.end))}</li>');
    } else {
      parts.add('<p>${_escapeHtml(line)}</p>');
    }
  }
  if (inTable) parts.add('</table>');
  if (parts.isEmpty) return '';
  return '<html><body>${parts.join('\n')}</body></html>';
}

String _escapeHtml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

int exploreFirecrawlUrlScore(String url, {String procedure = '', String city = ''}) =>
    exploreScoreClinicPriceUrl(url, procedure: procedure, city: city);

bool exploreIsPdfUrl(String url) => exploreUrlLooksLikePdf(url);

List<String> exploreRankFirecrawlUrls(
  Iterable<String> urls, {
  String procedure = '',
  String host = '',
  String city = '',
  int max = 5,
}) =>
    exploreRankClinicPriceUrls(
      urls,
      procedure: procedure,
      host: host,
      city: city,
      max: max,
    );

String exploreFirecrawlMapSearch({
  required String procedure,
  required List<String> priceWords,
}) {
  final words = <String>{
    ...priceWords.take(4),
    'price',
    'prices',
    'fees',
    'fee',
    'tarif',
    'pret',
  };
  final parts = <String>[
    procedure.trim(),
    ...words.take(6),
  ].where((s) => s.isNotEmpty);
  return parts.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
}
