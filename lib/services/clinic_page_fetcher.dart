/// HTTP now; later Cloud Run / Playwright / Browserless can implement this
/// without putting a browser engine inside Flutter.
abstract class ClinicPageFetcher {
  Future<ClinicPageFetchResult> fetch(String url);
}

class ClinicPageFetchResult {
  const ClinicPageFetchResult({
    required this.url,
    required this.html,
    this.statusCode = 0,
    this.blocked = false,
    this.renderingRequired = false,
  });

  final String url;
  final String html;
  final int statusCode;
  final bool blocked;
  final bool renderingRequired;

  bool get hasHtml => html.trim().isNotEmpty && !blocked;
}

/// Default HTTP fetch. JS-rendered shells are flagged, not invented.
class HttpClinicPageFetcher implements ClinicPageFetcher {
  HttpClinicPageFetcher(this._get);

  final Future<ClinicPageFetchResult> Function(String url) _get;

  @override
  Future<ClinicPageFetchResult> fetch(String url) => _get(url);
}
