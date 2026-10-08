import 'dart:convert';

/// Web search is used for **discovery only**: it tells us which clinic pages
/// exist and where to fetch them. No number that reaches a card ever comes
/// from a search result — prices are parsed from the clinic's own HTML by the
/// deterministic extractor and then verified against its official domain.
class ExploreSerpHit {
  const ExploreSerpHit({
    required this.title,
    required this.link,
    required this.snippet,
    required this.displayedLink,
  });

  final String title;
  final String link;
  final String snippet;
  final String displayedLink;
}

/// Which upstream answers discovery queries, in preference order.
///
/// Serper wins because tail latency decides whether a card reaches the screen:
/// DataForSEO's live endpoint answered in 2s most of the time but left single
/// requests unanswered for 17s and 31s, past every budget the pill has. Serper
/// also bills per result count instead of surcharging `site:` queries five
/// times over. The others stay wired up so one provider having a bad night
/// cannot blank the Explore lists.
enum ExploreSerpProviderKind { serper, dataForSeo, serpApi, none }

ExploreSerpProviderKind exploreSerpProviderKind({
  required String serperApiKey,
  required String dataForSeoLogin,
  required String dataForSeoPassword,
  required String serpApiKey,
}) {
  if (serperApiKey.trim().isNotEmpty) return ExploreSerpProviderKind.serper;
  if (dataForSeoLogin.trim().isNotEmpty &&
      dataForSeoPassword.trim().isNotEmpty) {
    return ExploreSerpProviderKind.dataForSeo;
  }
  if (serpApiKey.trim().isNotEmpty) return ExploreSerpProviderKind.serpApi;
  return ExploreSerpProviderKind.none;
}

Uri exploreSerperEndpoint() => Uri.parse('https://google.serper.dev/search');

Map<String, String> exploreSerperHeaders(String apiKey) => {
      'X-API-KEY': apiKey.trim(),
      'Content-Type': 'application/json',
    };

/// Serper takes plain Google parameters, so `gl`/`hl` pass straight through and
/// unmapped markets simply omit them rather than being forced to google.com.
///
/// No `num`: Serper returns one page whatever is asked for — 10, 30 and 100 all
/// came back with the same nine rows for one credit — and asking for more than a
/// page doubled the response time. Breadth comes from asking a second question
/// (the local-language query returns a different set), not a deeper page.
Map<String, Object?> exploreSerperRequestBody({
  required String query,
  String hl = '',
  String gl = '',
}) {
  final body = <String, Object?>{'q': query.trim()};
  final lang = hl.trim().toLowerCase();
  final country = gl.trim().toLowerCase();
  if (lang.isNotEmpty) body['hl'] = lang;
  if (country.isNotEmpty) body['gl'] = country == 'uk' ? 'gb' : country;
  return body;
}

/// Serper answers with plain HTTP codes: a bad or spent key is 401/403, and
/// there is no point retrying either. 429 and 5xx are worth one more try.
/// Credit exhaustion often arrives as HTTP 400 with `"Not enough credits"`.
bool exploreSerperKeyUnusable(int statusCode) =>
    statusCode == 401 || statusCode == 402 || statusCode == 403;

bool exploreSerperOutOfCredits(int statusCode, String body) {
  if (statusCode != 400 && statusCode != 402) return false;
  final lo = body.toLowerCase();
  return lo.contains('credit') ||
      lo.contains('quota') ||
      lo.contains('balance') ||
      lo.contains('insufficient');
}

List<ExploreSerpHit> exploreParseSerperOrganic(Object? decoded) {
  if (decoded is! Map) return const [];
  final organic = decoded['organic'];
  if (organic is! List) return const [];
  final out = <ExploreSerpHit>[];
  for (final item in organic) {
    if (item is! Map) continue;
    final hit = _hitFrom(
      title: item['title'],
      link: item['link'],
      snippet: item['snippet'],
      displayed: item['displayedLink'] ?? item['domain'],
    );
    if (hit != null) out.add(hit);
  }
  return out;
}

/// Live endpoint (one POST) — the queued endpoints are cheaper but take
/// minutes, which the on-screen pill cannot wait for. `regular` carries the
/// same organic rows as `advanced` for a third of the bytes and about half the
/// latency; discovery only reads url/title/description, so the extra SERP
/// features `advanced` adds are dead weight.
Uri exploreDataForSeoEndpoint() => Uri.parse(
      'https://api.dataforseo.com/v3/serp/google/organic/live/regular',
    );

String exploreDataForSeoAuthHeader(String login, String password) =>
    'Basic ${base64Encode(utf8.encode('${login.trim()}:${password.trim()}'))}';

/// Google geo target IDs for countries are `2000 + ISO 3166-1 numeric`, so one
/// alpha-2 table covers every market the pills can search.
const Map<String, int> _kIsoNumeric = {
  'ae': 784, 'al': 8, 'am': 51, 'ar': 32, 'at': 40, 'au': 36, 'az': 31,
  'ba': 70, 'bd': 50, 'be': 56, 'bg': 100, 'bh': 48, 'br': 76,
  'ca': 124, 'ch': 756, 'cl': 152, 'cn': 156, 'co': 170, 'cy': 196, 'cz': 203,
  'de': 276, 'dk': 208, 'ee': 233, 'eg': 818, 'es': 724,
  'fi': 246, 'fr': 250, 'gb': 826, 'ge': 268, 'gh': 288, 'gr': 300,
  'hk': 344, 'hr': 191, 'hu': 348, 'id': 360, 'ie': 372, 'il': 376, 'in': 356,
  'is': 352, 'it': 380, 'jo': 400, 'jp': 392, 'ke': 404, 'kr': 410, 'kw': 414,
  'kz': 398, 'lb': 422, 'lk': 144, 'lt': 440, 'lu': 442, 'lv': 428,
  'ma': 504, 'md': 498, 'mk': 807, 'mt': 470, 'mx': 484, 'my': 458,
  'ng': 566, 'nl': 528, 'no': 578, 'np': 524, 'nz': 554, 'om': 512,
  'pe': 604, 'ph': 608, 'pk': 586, 'pl': 616, 'pt': 620, 'qa': 634,
  'ro': 642, 'rs': 688, 'ru': 643, 'sa': 682, 'se': 752, 'sg': 702, 'si': 705,
  'sk': 703, 'th': 764, 'tn': 788, 'tr': 792, 'tw': 158, 'ua': 804, 'us': 840,
  'uz': 860, 'vn': 704, 'za': 710,
};

/// `gl` codes we emit are Google-flavoured, so `uk` must resolve to GB.
int? exploreDataForSeoLocationCode(String gl) {
  var code = gl.trim().toLowerCase();
  if (code.isEmpty) return null;
  if (code == 'uk') code = 'gb';
  final numeric = _kIsoNumeric[code];
  return numeric == null ? null : 2000 + numeric;
}

/// How deep a DataForSEO query goes; Serper has no equivalent knob.
///
/// DataForSEO charges per 10 results and five times over for search operators,
/// so a `site:` lookup stays shallow — only the top on-domain hit is ever used.
/// A broad city sweep is the opposite: one deep SERP lists ~29 clinic hosts, and
/// one request always beats three when a slow upstream can cost the pill its
/// whole budget.
int exploreDataForSeoDepth(String query) =>
    query.toLowerCase().contains('site:') ? 10 : 30;

/// A DataForSEO task array for one discovery query.
///
/// `depth: 10` keeps the charge at a single SERP. DataForSEO always needs a
/// location, so markets we cannot map fall back to google.com — the same place
/// SerpApi landed when `gl` was omitted — and lean on the city name in the
/// query as the geo signal.
List<Map<String, Object?>> exploreDataForSeoRequestBody({
  required String query,
  String hl = '',
  String gl = '',
  int depth = 10,
}) {
  final task = <String, Object?>{
    'keyword': query.trim(),
    'depth': depth,
    'device': 'desktop',
    'os': 'windows',
  };
  final lang = hl.trim().toLowerCase();
  if (lang.isNotEmpty) task['language_code'] = lang;
  final location = exploreDataForSeoLocationCode(gl);
  if (location != null) {
    task['location_code'] = location;
  } else {
    task['location_code'] = 2840;
    task['language_code'] = lang.isEmpty ? 'en' : lang;
  }
  return [task];
}

/// DataForSEO answers HTTP 200 and reports problems in `status_code`, and the
/// codes look alike while meaning very different things: 40100 is bad
/// credentials (stop using the provider) while 40101 is the search engine
/// hiccuping (retry the same query).
class ExploreDataForSeoStatus {
  const ExploreDataForSeoStatus(this.code, this.message);

  final int code;
  final String message;

  bool get ok => code == 20000;

  /// Credentials, verification, or billing — retrying cannot help.
  bool get providerUnusable => const {
        40100, // not authorized
        40104, // account not verified
        40200, // payment required
        40201, // account paused
        40210, // insufficient funds
      }.contains(code);

  /// Upstream hiccup — the same query may well succeed on a second try.
  bool get retryable => const {
        40101, // internal SE server error
        40103, // task execution failed, resubmit
        50000, // internal error
        50001, // balance check failed
      }.contains(code);

  bool get rateLimited => code == 40202;

  /// Google genuinely returned nothing; not a failure.
  bool get noResults => code == 40102;

  String get logLine => ok ? '' : '$code $message'.trim();
}

ExploreDataForSeoStatus exploreDataForSeoStatus(Object? decoded) {
  if (decoded is! Map) {
    return const ExploreDataForSeoStatus(-1, 'malformed response');
  }
  final top = decoded['status_code'];
  if (top is int && top != 20000) {
    return ExploreDataForSeoStatus(top, '${decoded['status_message'] ?? ''}');
  }
  final tasks = decoded['tasks'];
  if (tasks is! List || tasks.isEmpty) {
    return const ExploreDataForSeoStatus(-1, 'no tasks');
  }
  final first = tasks.first;
  if (first is! Map) return const ExploreDataForSeoStatus(-1, 'no tasks');
  final code = first['status_code'];
  if (code is int && code != 20000) {
    return ExploreDataForSeoStatus(code, '${first['status_message'] ?? ''}');
  }
  return const ExploreDataForSeoStatus(20000, 'Ok.');
}

/// Non-empty when DataForSEO reported a problem, for one log line.
String exploreDataForSeoStatusError(Object? decoded) =>
    exploreDataForSeoStatus(decoded).logLine;

List<ExploreSerpHit> exploreParseDataForSeoOrganic(Object? decoded) {
  if (decoded is! Map) return const [];
  final tasks = decoded['tasks'];
  if (tasks is! List) return const [];
  final out = <ExploreSerpHit>[];
  for (final task in tasks) {
    if (task is! Map) continue;
    final results = task['result'];
    if (results is! List) continue;
    for (final result in results) {
      if (result is! Map) continue;
      final items = result['items'];
      if (items is! List) continue;
      for (final item in items) {
        if (item is! Map) continue;
        if ('${item['type'] ?? ''}' != 'organic') continue;
        final hit = _hitFrom(
          title: item['title'],
          link: item['url'],
          snippet: item['description'],
          displayed: item['breadcrumb'] ?? item['domain'],
        );
        if (hit != null) out.add(hit);
      }
    }
  }
  return out;
}

List<ExploreSerpHit> exploreParseSerpApiOrganic(Object? decoded) {
  if (decoded is! Map) return const [];
  final organic = decoded['organic_results'];
  if (organic is! List) return const [];
  final out = <ExploreSerpHit>[];
  for (final item in organic) {
    if (item is! Map) continue;
    final hit = _hitFrom(
      title: item['title'],
      link: item['link'],
      snippet: item['snippet'],
      displayed: item['displayed_link'],
    );
    if (hit != null) out.add(hit);
  }
  return out;
}

ExploreSerpHit? _hitFrom({
  Object? title,
  Object? link,
  Object? snippet,
  Object? displayed,
}) {
  final t = '${title ?? ''}'.trim();
  final l = '${link ?? ''}'.trim();
  final s = '${snippet ?? ''}'.trim();
  final d = '${displayed ?? ''}'.trim();
  if (t.isEmpty && l.isEmpty && s.isEmpty) return null;
  return ExploreSerpHit(title: t, link: l, snippet: s, displayedLink: d);
}
