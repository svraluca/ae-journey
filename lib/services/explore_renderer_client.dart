import 'dart:convert';

/// Cloud Run Playwright renderer for clinic sites that block our HTTP client
/// or ship a JS-only shell.
///
/// The renderer returns the page's real DOM and nothing else: the rendered HTML
/// goes through the same deterministic extractor as a normal fetch, so a
/// headless browser never decides what a price is.
final _kPrivateHost = RegExp(
  r'^(localhost|127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[0-1])\.|0\.|'
  r'169\.254\.|\[::1\]|metadata\.google\.internal)',
  caseSensitive: false,
);

Uri? exploreRendererEndpoint(String base) {
  final trimmed = base.trim().replaceAll(RegExp(r'/+$'), '');
  if (trimmed.isEmpty) return null;
  final withScheme = trimmed.contains('://') ? trimmed : 'https://$trimmed';
  try {
    return Uri.parse('$withScheme/render');
  } catch (_) {
    return null;
  }
}

Map<String, String> exploreRendererHeaders(String token) => {
      'Content-Type': 'application/json',
      if (token.trim().isNotEmpty) 'Authorization': 'Bearer ${token.trim()}',
    };

String exploreRendererRequestBody(String url) => jsonEncode({'url': url});

/// Loopback and RFC1918 targets are never worth a render round-trip.
bool exploreRendererAllowsUrl(String url) {
  final raw = url.trim();
  if (raw.isEmpty) return false;
  Uri parsed;
  try {
    parsed = Uri.parse(raw.contains('://') ? raw : 'https://$raw');
  } catch (_) {
    return false;
  }
  final host = parsed.host;
  if (host.isEmpty) return false;
  return !_kPrivateHost.hasMatch(host);
}

class ExploreRenderResult {
  const ExploreRenderResult({required this.html, required this.statusCode});

  final String html;
  final int statusCode;

  /// A rendered Cloudflare / "access denied" page is long and HTML-shaped but
  /// carries no menu, so it must not be parsed as the clinic's own page.
  bool get usable => html.isNotEmpty && statusCode < 400;
}

/// The rendered page, or an empty result when the renderer had nothing to give.
ExploreRenderResult exploreParseRenderedHtml(String responseBody) {
  const empty = ExploreRenderResult(html: '', statusCode: 0);
  if (responseBody.trim().isEmpty) return empty;
  Object? decoded;
  try {
    decoded = jsonDecode(responseBody);
  } catch (_) {
    return empty;
  }
  if (decoded is! Map) return empty;
  final status = decoded['statusCode'];
  return ExploreRenderResult(
    html: '${decoded['html'] ?? ''}',
    statusCode: status is int ? status : (status is num ? status.toInt() : 200),
  );
}
