import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'explore_search_locale.dart';

/// World-wide price / menu / booking path tokens (Latin + major scripts).
/// Scoring is data-driven from this list + [exploreCityPriceSearchTerms].
const kExploreWorldUrlPriceTokens = <String>[
  'price',
  'prices',
  'pricing',
  'pricelist',
  'price-list',
  'fees',
  'fee',
  'tarif',
  'tarifs',
  'tarifas',
  'tariffe',
  'tarife',
  'menu',
  'meniu',
  'listino',
  'cennik',
  'pret',
  'preturi',
  'precio',
  'precios',
  'prezzo',
  'prezzi',
  'preis',
  'preise',
  'preisliste',
  'prix',
  'fiyat',
  'fiyatlar',
  'preco',
  'precos',
  'preço',
  'preços',
  'prijs',
  'prijzen',
  'cost',
  'costs',
  'costo',
  'kosten',
  'packages',
  'offers',
  'book',
  'booking',
  'book-online',
  'reserve',
  'reservation',
  'cita',
  'appoint',
  'treatment',
  'treatments',
  'services',
  'servicii',
  'servicio',
  'servicios',
  'tratament',
  'tratamiento',
  'tratamientos',
  'سعر',
  'اسعار',
  'أسعار',
  'تكلفة',
  'اسعارنا',
  'باقات',
  'حجز',
  '가격',
  '비용',
  '요금',
  '料金',
  '価格',
  '費用',
  'цена',
  'цены',
  'стоимость',
  'прайс',
];

const kExploreWorldUrlTreatmentTokens = <String>[
  'botox',
  'filler',
  'fillers',
  'laser',
  'peel',
  'peeling',
  'rhino',
  'rhinoplasty',
  'breast',
  'hair',
  'transplant',
  'hifu',
  'prp',
  'hyaluron',
  'injectable',
  'injectables',
  'بوتوكس',
  'فيلر',
  'ليزر',
  'تقشير',
];

/// True when [url] looks like a PDF price list (extension or query).
bool exploreUrlLooksLikePdf(String url) {
  final u = url.toLowerCase();
  return RegExp(r'\.pdf(\?|#|$)').hasMatch(u) ||
      u.contains('format=pdf') ||
      u.contains('type=pdf');
}

/// True when an HTTP Content-Type header is a PDF.
bool exploreContentTypeIsPdf(String contentType) {
  final t = contentType.toLowerCase();
  return t.contains('application/pdf') || t.contains('application/x-pdf');
}

/// Score how likely [url] is a pricing / treatment / booking page.
///
/// [city] supplies local price words; [procedure] boosts matching path tokens.
/// No city- or clinic-specific host rules.
int exploreScoreClinicPriceUrl(
  String url, {
  String city = '',
  String procedure = '',
  List<String> extraPriceWords = const [],
}) {
  final u = url.toLowerCase();
  if (u.isEmpty) return 0;
  if (city.trim().isNotEmpty && exploreUrlConflictsWithSearchCity(url, city)) {
    return 0;
  }
  if (RegExp(
    r'-template|/templates?/|page-editor|preview_theme',
  ).hasMatch(u)) {
    return 0;
  }
  if (procedure.trim().isNotEmpty &&
      exploreUrlConflictsWithProcedure(url, procedure)) {
    return 0;
  }
  if (RegExp(
    r'wp-admin|wp-login|/tag/|/author/|\.jpe?g(\?|$)|'
    r'\.png(\?|$)|\.gif(\?|$)|mailto:|tel:',
  ).hasMatch(u)) {
    return 0;
  }

  final loc = city.trim().isEmpty
      ? (lang: 'en', priceWords: <String>[], clinicWord: 'clinic')
      : exploreCityPriceSearchTerms(city);
  final tokens = <String>{
    ...kExploreWorldUrlPriceTokens,
    ...loc.priceWords.map((w) => w.toLowerCase()),
    ...extraPriceWords.map((w) => w.toLowerCase()),
  };

  var score = 0;
  for (final t in tokens) {
    if (t.length < 2) continue;
    if (u.contains(t.toLowerCase())) {
      score = score < 3 ? 3 : score;
      break;
    }
  }
  if (score < 2) {
    for (final t in const [
      'servicii',
      'tratament',
      'tratamiento',
      'procedur',
      'procedure',
      'services',
      'treatments',
      '/treatment',
      'booking',
      'reserve',
      'cita',
      'حجز',
    ]) {
      if (u.contains(t)) {
        score = 2;
        break;
      }
    }
  }
  if (score < 1) {
    for (final t in kExploreWorldUrlTreatmentTokens) {
      if (u.contains(t)) {
        score = 1;
        break;
      }
    }
  }
  if (exploreUrlLooksLikePdf(u) && score < 3) score = 3;

  final proc = procedure.toLowerCase();
  for (final t in proc.split(RegExp(r'[^a-z0-9\u0600-\u06ff\u3040-\u30ff\u4e00-\u9fff]+'))) {
    if (t.length >= 4 && u.contains(t)) score += 1;
  }
  for (final name in exploreProcedureNamesForLang(
    _familyKeyFromProcedure(procedure),
    loc.lang,
  )) {
    final n = name.toLowerCase().trim();
    if (n.length >= 4 && u.contains(n.replaceAll(' ', '-'))) score += 1;
    if (n.length >= 4 && u.contains(n.replaceAll(' ', ''))) score += 1;
  }

  if (RegExp(r'/page/\d+(?:/|$|\?)').hasMatch(u) && score < 3) {
    score = score >= 2 ? score - 2 : 0;
  }

  // official price list > booking > treatment page > article / offer / FAQ
  // Match path segments so Shopify `/pages/treatment-pricelist` (a PDF
  // download) does not outrank a real Upper Face / 1-area menu.
  if (RegExp(
        r'(?:^|/)(?:price-list|pricelist|price-guide)(?:/|$|\.)|'
        r'/prices(?:/|$|\.)|/pricing(?:/|$)|'
        r'rhinoplasty-cost|nose-job-cost|boob-job-cost|'
        r'/(?:our-)?fees(?:/|$)|/cost(?:/|$)',
        caseSensitive: false,
      ).hasMatch(u) &&
      !RegExp(
        r'special-?offers?|/(?:offers|deals)(?:/|$)|/booking|/book-|'
        r'cost-in-|cost-london|london-prices|botox-cost',
        caseSensitive: false,
      ).hasMatch(u)) {
    if (score < 5) score = 5;
  } else if (RegExp(
    r'(?:^|[/?#])(?:book-online|booking|book-now)(?:/|$|\.|[#?])',
    caseSensitive: false,
  ).hasMatch(u)) {
    if (score < 4) score = 4;
  } else if (RegExp(
    r'/blog/|/guides?/|/faq|/best-|cost-in-|special-?offers?|'
    r'/(?:offers|deals|promotions?)(?:/|$)|(?:^|/)botox-cost(?:/|$)',
    caseSensitive: false,
  ).hasMatch(u)) {
    if (score > 1) score = 1;
  }
  if (_familyKeyFromProcedure(procedure) == 'botox') {
    if (looksLikeBotoxSpecialtyVariantUrl(u)) {
      if (score > 1) score = 1;
    } else if (looksLikeBotoxStandardStartingUrl(u)) {
      if (score < 4) score = 4;
    }
  }
  return score;
}

/// Lip flip / Barbie / TrapTox landings — not the generic Botox FROM.
bool looksLikeBotoxSpecialtyVariantUrl(String url) {
  final raw = url.trim().toLowerCase();
  if (raw.isEmpty) return false;
  var path = raw;
  try {
    path = Uri.parse(raw.contains('://') ? raw : 'https://$raw').path.toLowerCase();
  } catch (_) {}
  return RegExp(
    r'lip[-_]?flip|barbie[-_]?botox|trap[-_]?tox|'
    r'gummy[-_]?smile|masseter|hyperhidros|baby[-_]?botox|'
    r'jawline[-_]?lift|calf[-_]?(?:slim|reduction)|'
    r'bunny[-_]?line|chin[-_]?dimpl|platysm|migraine[-_]?botox',
    caseSensitive: false,
  ).hasMatch(path);
}

/// Upper-face / anti-wrinkle / 1-area treatment pages.
bool looksLikeBotoxStandardStartingUrl(String url) {
  final raw = url.trim().toLowerCase();
  if (raw.isEmpty) return false;
  if (looksLikeBotoxSpecialtyVariantUrl(raw)) return false;
  var path = raw;
  try {
    path = Uri.parse(raw.contains('://') ? raw : 'https://$raw').path.toLowerCase();
  } catch (_) {}
  return RegExp(
    r'upper[-_]?face|anti[-_]?wrinkle|'
    r'(?:^|/)(?:1|one)[-_]?area(?:/|$)|'
    r'forehead[-_]?botox|frown[-_]?line',
    caseSensitive: false,
  ).hasMatch(path);
}

String _familyKeyFromProcedure(String procedure) {
  final p = procedure.toLowerCase();
  if (p.contains('botox') || p.contains('toxin') || p.contains('بوتوكس')) {
    return 'botox';
  }
  if (p.contains('filler') || p.contains('hialuron') || p.contains('فيلر')) {
    return 'filler';
  }
  if (p.contains('laser') || p.contains('ليزر')) return 'laser';
  if (p.contains('peel') || p.contains('تقشير')) return 'peel';
  if (p.contains('rhino') || p.contains('nose') || p.contains('أنف')) {
    return 'rhinoplasty';
  }
  if (p.contains('breast') || p.contains('boob') || p.contains('ثدي')) {
    return 'breast';
  }
  if (p.contains('hair') || p.contains('fue') || p.contains('شعر')) {
    return 'hair';
  }
  return '';
}

String _urlPathForFamily(String sourceUrl) {
  final raw = sourceUrl.trim().toLowerCase();
  if (raw.isEmpty) return '';
  try {
    return Uri.parse(raw.contains('://') ? raw : 'https://$raw').path.toLowerCase();
  } catch (_) {
    return raw;
  }
}

/// Path family for `*-job-cost` / treatment slugs. Empty = mixed menu / unknown.
String exploreUrlPathFamilyKey(String sourceUrl) {
  final path = _urlPathForFamily(sourceUrl);
  if (path.isEmpty) return '';
  if (RegExp(
    r'rhinoplast|rinoplast|nose-job|nose-reshaping|septorhino|تجميل-الانف|تجميل-الأنف',
    caseSensitive: false,
  ).hasMatch(path)) {
    return 'rhinoplasty';
  }
  if (RegExp(
    r'boob-job|breast-aug|breast-enlarg|breast-implant|breast-uplift|'
    r'mamoplast|aumento-de-pecho|marire-sani',
    caseSensitive: false,
  ).hasMatch(path)) {
    return 'breast';
  }
  if (RegExp(
    r'hair-transplant|injerto-capilar|fue-hair|transplant-de-par',
    caseSensitive: false,
  ).hasMatch(path)) {
    return 'hair';
  }
  if (RegExp(
    r'botox|anti-wrinkle|dysport|xeomin|neuromodul',
    caseSensitive: false,
  ).hasMatch(path)) {
    return 'botox';
  }
  if (RegExp(
    r'dermal-filler|lip-filler|/fillers?(?:/|$)|juvederm|relleno',
    caseSensitive: false,
  ).hasMatch(path)) {
    return 'filler';
  }
  if (RegExp(
    r'chemical-peel|peeling|/peels?(?:/|$)',
    caseSensitive: false,
  ).hasMatch(path)) {
    return 'peel';
  }
  if (RegExp(
    r'laser-hair|depilacion|epilare-laser|hair-removal',
    caseSensitive: false,
  ).hasMatch(path)) {
    return 'laser';
  }
  if (RegExp(
    r'(?:^|/)forma(?:/|$)|morpheus|endolift|skinpen|thermage|ulthera|'
    r'(?:^|/)hifu(?:/|$)|coolsculpt|emsculpt|(?:^|/)exilis(?:/|$)',
    caseSensitive: false,
  ).hasMatch(path)) {
    return 'energy_device';
  }
  return '';
}

/// Forma / Morpheus / Endolift — not Botox or filler, even if copy says "area".
bool looksLikeEnergyOrDeviceTreatment(String raw) {
  return RegExp(
    r'\bforma\b|\bmorpheus\s*8?\b|\bendolift\b|\bskinpen\b|'
    r'\bthermage\b|\bulthera(?:py)?\b|\bhifu\b|\bcoolsculpt|'
    r'\bemsculpt\b|\bexilis\b|\bemface\b|\bsofwave\b',
    caseSensitive: false,
  ).hasMatch(raw);
}

/// `/nose-job-on-finance` — representative APR example, not the clinic tariff.
bool looksLikeTreatmentFinanceUrl(String sourceUrl) {
  final path = _urlPathForFamily(sourceUrl);
  if (path.isEmpty) return false;
  return RegExp(
    r'(?:^|/)(?:[^/]*-)?on-finance(?:/|$)|'
    r'(?:^|/)(?:0-percent-)?financ(?:e|ing|iar)(?:/|$)|'
    r'payment-plan|pay-monthly|monthly-payments?',
    caseSensitive: false,
  ).hasMatch(path);
}

/// `/boob-job-cost` while Compare is on rhinoplasty — other-family cost page.
bool exploreUrlConflictsWithProcedure(String sourceUrl, String procedure) {
  if (looksLikeTreatmentFinanceUrl(sourceUrl)) return true;
  final want = _familyKeyFromProcedure(procedure);
  if (want.isEmpty) return false;
  final got = exploreUrlPathFamilyKey(sourceUrl);
  if (got.isEmpty) return false;
  return got != want;
}

List<String> exploreRankClinicPriceUrls(
  Iterable<String> urls, {
  String city = '',
  String procedure = '',
  String host = '',
  int max = 8,
}) {
  final hostKey =
      host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '').trim();
  final scored = <({String url, int score})>[];
  final seen = <String>{};
  for (final raw in urls) {
    final url = raw.trim();
    if (url.isEmpty || !seen.add(url)) continue;
    if (hostKey.isNotEmpty) {
      try {
        final h = Uri.parse(url.contains('://') ? url : 'https://$url')
            .host
            .toLowerCase()
            .replaceFirst(RegExp(r'^www\.'), '');
        if (h != hostKey &&
            !h.endsWith('.$hostKey') &&
            !hostKey.endsWith('.$h')) {
          continue;
        }
      } catch (_) {
        continue;
      }
    }
    final s = exploreScoreClinicPriceUrl(
      url,
      city: city,
      procedure: procedure,
    );
    if (s < 1 && !exploreUrlLooksLikePdf(url)) continue;
    scored.add((url: url, score: s + (exploreUrlLooksLikePdf(url) ? 1 : 0)));
  }
  scored.sort((a, b) {
    final d = b.score.compareTo(a.score);
    if (d != 0) return d;
    return a.url.length.compareTo(b.url.length);
  });
  return [for (final r in scored.take(max.clamp(1, 12))) r.url];
}

/// Collect sitemap / sitemap-index URLs from robots.txt + common paths.
Future<List<String>> exploreDiscoverSitemapUrls({
  required String hostOrBase,
  http.Client? httpClient,
  Duration timeout = const Duration(seconds: 6),
}) async {
  final client = httpClient ?? http.Client();
  final ownClient = httpClient == null;
  try {
    final host = hostOrBase
        .trim()
        .replaceFirst(RegExp(r'^https?://'), '')
        .replaceFirst(RegExp(r'^www\.'), '')
        .split('/')
        .first
        .toLowerCase();
    if (host.isEmpty) return const [];
    final base = 'https://$host';
    final seeds = <String>{
      '$base/sitemap.xml',
      '$base/sitemap_index.xml',
      '$base/wp-sitemap.xml',
      '$base/sitemap-index.xml',
    };
    try {
      final robots = await client
          .get(Uri.parse('$base/robots.txt'))
          .timeout(timeout);
      if (robots.statusCode == 200) {
        for (final line in robots.body.split(RegExp(r'\r?\n'))) {
          final m = RegExp(
            r'^\s*sitemap\s*:\s*(\S+)',
            caseSensitive: false,
          ).firstMatch(line);
          final u = m?.group(1)?.trim() ?? '';
          if (u.isNotEmpty) seeds.add(u);
        }
      }
    } catch (_) {}

    final out = <String>{};
    for (final sm in seeds) {
      try {
        final res = await client.get(Uri.parse(sm)).timeout(timeout);
        if (res.statusCode != 200) continue;
        final body = res.body;
        if (body.length > 2_000_000) continue;
        out.addAll(_parseSitemapLocs(body, siteHost: host));
      } catch (_) {}
    }
    debugPrint('[GP] Sitemap discovery $host → ${out.length} urls');
    return out.toList(growable: false);
  } finally {
    if (ownClient) client.close();
  }
}

Iterable<String> _parseSitemapLocs(String xml, {required String siteHost}) {
  final locs = <String>[];
  for (final m in RegExp(
    r'<loc>\s*([^<]+)\s*</loc>',
    caseSensitive: false,
  ).allMatches(xml)) {
    final u = (m.group(1) ?? '').trim();
    if (u.isEmpty) continue;
    try {
      final host = Uri.parse(u).host.toLowerCase().replaceFirst(
            RegExp(r'^www\.'),
            '',
          );
      if (host == siteHost ||
          host.endsWith('.$siteHost') ||
          siteHost.endsWith('.$host')) {
        locs.add(u);
      }
    } catch (_) {}
  }
  return locs;
}

/// Unit tokens stored beside a price (not inventing amounts).
const kExplorePriceUnitTokens = <String>[
  'ml',
  'syringe',
  'syringes',
  'area',
  'areas',
  'zone',
  'zones',
  'session',
  'sessions',
  'vial',
  'vials',
  'package',
  'packages',
  'graft',
  'grafts',
  'unit',
  'units',
  'cc',
  'iu',
  'ampoule',
  'ampoule',
  'مل',
  'منطقة',
  'جلسة',
  'وحدات',
];

/// Pull a unit label + optional quantity from a price/evidence blob.
({String unit, double? quantity}) exploreParsePriceUnitQuantity(String raw) {
  final t = raw.replaceAll('\u00a0', ' ');
  if (t.trim().isEmpty) return (unit: '', quantity: null);
  // "From £195 (varies with areas)" is a FROM quote, not £195/area.
  final variesWithAreas = RegExp(
    r'varies\s+with\s+(?:the\s+)?(?:number\s+of\s+)?(?:areas?|zones?)',
    caseSensitive: false,
  ).hasMatch(t);
  final qtyUnit = RegExp(
    r'(\d+(?:[.,]\d+)?)\s*-?\s*'
    r'(ml|cc|iu|syringe|syringes|area|areas|zone|zones|session|sessions|'
    r'vial|vials|package|packages|graft|grafts|unit|units|ampoule|ampoules|'
    r'مل|منطقة|جلسة|وحدات)\b',
    caseSensitive: false,
  ).firstMatch(t);
  if (qtyUnit != null) {
    final unit = (qtyUnit.group(2) ?? '').toLowerCase();
    final q = double.tryParse(
      (qtyUnit.group(1) ?? '').replaceAll(',', '.'),
    );
    final rawQ = qtyUnit.group(1) ?? '';
    final graftThousands = (unit == 'graft' || unit == 'grafts') &&
        RegExp(r'^\d{1,3}[.,]\d{3}$').hasMatch(rawQ);
    final graftSession = (unit == 'graft' || unit == 'grafts') &&
        ((q != null && q >= 50) || graftThousands) &&
        !RegExp(r'(?:per|/)\s*graft', caseSensitive: false).hasMatch(t);
    if (!graftSession) {
      return (unit: unit, quantity: q);
    }
  }
  final per = RegExp(
    r'(?:per|/|على)\s*'
    r'(ml|cc|syringe|area|zone|session|vial|package|graft|unit|'
    r'مل|منطقة|جلسة)\b',
    caseSensitive: false,
  ).firstMatch(t);
  if (per != null) {
    return (unit: (per.group(1) ?? '').toLowerCase(), quantity: null);
  }
  // Bare "package" / "session" in aftercare copy is not a published unit.
  if (variesWithAreas) {
    return (unit: '', quantity: null);
  }
  const bareWordUnits = <String>{
    'ml',
    'cc',
    'iu',
    'unit',
    'units',
    'syringe',
    'syringes',
    'graft',
    'grafts',
    'area',
    'areas',
    'zone',
    'zones',
    'ampoule',
    'ampoules',
    'مل',
    'منطقة',
    'جلسة',
    'وحدات',
  };
  for (final u in bareWordUnits) {
    if ((u == 'graft' || u == 'grafts') &&
        !RegExp(r'(?:per|/)\s*graft', caseSensitive: false).hasMatch(t)) {
      continue;
    }
    if (RegExp('\\b${RegExp.escape(u)}\\b', caseSensitive: false)
        .hasMatch(t)) {
      return (unit: u.toLowerCase(), quantity: null);
    }
  }
  return (unit: '', quantity: null);
}

/// JSON encode helper for sitemap tests without importing dart:convert callers.
String exploreSitemapLocSnippet(String url) =>
    '<url><loc>${const HtmlEscape().convert(url)}</loc></url>';
