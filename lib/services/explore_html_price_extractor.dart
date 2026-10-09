import 'dart:convert';

import 'explore_regex_cache.dart';

import 'package:flutter/foundation.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import 'explore_clinic_identity.dart';
import 'explore_marketplace_discovery.dart';
import 'explore_price_evidence.dart';
import 'explore_price_ownership.dart';
import 'explore_price_sanity.dart';
import 'explore_procedure_family.dart';

/// Arabic menus print dirhams as "درهم" / "د.إ" instead of "AED".
const _kCurrencyAlt =
    r'€|eur|euro|£|gbp|\$|usd|ron|lei|mdl|try|tl|pln|zł|aed|درهم|د\.إ';

final _kPriceLike = cachedRegExp(
  '(?:$_kCurrencyAlt)'
  r'\s*\d|'
  r'\d[\d.,\s]*\s*'
  '(?:$_kCurrencyAlt)'
  r'|'
  r'(?:from|starts?\s+from|desde|de\s+la|a\s+partir\s+de|porneste|pornește|începe|incepe|'
  r'يبدأ من|تبدأ من)\s*(?:aed|usd|eur|gbp|د\.إ|درهم|[€£$])?\s*\d',
  caseSensitive: false,
);

final _kBarePrice = cachedRegExp(
  r'(?:from|desde|de\s+la|a\s+partir\s+de)?\s*[€£$]?\s*\d{2,6}(?:[.,]\d{2,3})?'
  r'\s*(?:€|eur|£|gbp|ron|lei|aed|درهم|د\.إ)?',
  caseSensitive: false,
);

String _listedRawPriceText(String raw, ParsedPrice parsed) {
  var t = raw.replaceAll(cachedRegExp(r'\s+'), ' ').trim();
  t = t.replaceAll(
    cachedRegExp(r'\s*\(\s*was\b[^)]*\)', caseSensitive: false),
    '',
  );
  t = t.replaceAll(cachedRegExp(r'\s+'), ' ').trim();
  if (t.isEmpty) return t;
  final amountSpan = cachedRegExp(
    r'(?:între|intre|de la|from|desde)?\s*\d[\d.,]*'
    r'(?:\s*(?:–|—|-|to|pana la|până la)\s*\+?\s*\d[\d.,]*)?'
    r'\s*(?:€|eur|euro|lei|ron|£|gbp|\$|aed|درهم|د\.إ)?',
    caseSensitive: false,
  ).firstMatch(t);
  if (amountSpan != null) {
    final span = amountSpan.group(0)!.trim();
    if (span.length >= 3 && t.length > span.length + 8) {
      t = span;
    }
  }
  final hasCurrency = cachedRegExp(
    r'(ron|lei|eur|euro|usd|gbp|aed|try|€|£|\$|درهم|د\.إ)',
    caseSensitive: false,
  ).hasMatch(t);
  if (!hasCurrency && parsed.currency.isNotEmpty) {
    return '$t ${parsed.currency}';
  }
  return t;
}

/// HTTP `Response.body` defaults to Latin-1 when charset is missing.
/// Romanian clinic pages are UTF-8 (`ă` → `Ä`, `î` → `Ã®`, `–` → `â`).
bool looksLikeUtf8Mojibake(String raw) {
  if (raw.isEmpty) return false;
  return raw.contains('Ã') ||
      raw.contains('\u0080') ||
      raw.contains('\u0082') ||
      raw.contains('\u0083') ||
      raw.contains('\u0093') ||
      cachedRegExp(r'Ä[\u0080-\u009f]').hasMatch(raw);
}

String repairUtf8Mojibake(String raw) {
  if (!looksLikeUtf8Mojibake(raw)) return raw;
  try {
    return utf8.decode(latin1.encode(raw), allowMalformed: true);
  } catch (_) {
    return raw;
  }
}

String decodeHtmlHttpBody({
  required List<int> bodyBytes,
  String contentType = '',
}) {
  if (bodyBytes.isEmpty) return '';
  final declared = contentType.toLowerCase();
  final declaredLatin =
      declared.contains('iso-8859-1') ||
      declared.contains('windows-1252') ||
      declared.contains('latin-1') ||
      declared.contains('latin1');
  final headLen = bodyBytes.length < 4096 ? bodyBytes.length : 4096;
  final head = latin1.decode(bodyBytes.sublist(0, headLen), allowInvalid: true);
  final metaUtf8 = cachedRegExp(
    r'charset\s*=\s*["'
    "'"
    r']?\s*utf-?8',
    caseSensitive: false,
  ).hasMatch(head);
  if (!declaredLatin || metaUtf8) {
    return utf8.decode(bodyBytes, allowMalformed: true);
  }
  final latin = latin1.decode(bodyBytes, allowInvalid: true);
  if (looksLikeUtf8Mojibake(latin)) {
    return utf8.decode(bodyBytes, allowMalformed: true);
  }
  return latin;
}

/// Deterministic HTML → procedure/price evidence. AI never sees the number.
///
/// Caps HTML size so mega pages (Zyte/rendered shells) cannot freeze the UI
/// isolate while [html_parser] walks the DOM.
const kExploreMaxHtmlParseChars = 180000;
const kExploreMaxEvidenceRowsPerPage = 80;

/// Hospital menus list hundreds of surgical rows before injectables. Scan
/// past the visible cap so Botox/filler still make the kept 80.
const kExploreMaxEvidenceScanRowsPerPage = 400;

/// Spa/peel menus nest thousands of wrapper divs. Walking each with
/// [_visibleText] is O(n²) on the UI isolate and freezes Compare.
const _kMaxGenericBlockWalks = 220;

/// Drop CSS/JS shells so a size cap cannot cut off the price table in `<body>`.
String explorePrepareHtmlForPriceParse(String html) {
  if (html.trim().isEmpty) return '';
  final jsonLd = <String>[];
  final ldRe = cachedRegExp(
    r'<script[^>]*type="application/ld\+json"[^>]*>[\s\S]*?</script>',
    caseSensitive: false,
  );
  for (final m in ldRe.allMatches(html)) {
    jsonLd.add(m.group(0)!);
    if (jsonLd.length >= 8) break;
  }
  var cleaned = html.replaceAll(
    cachedRegExp(r'<script[\s\S]*?</script>', caseSensitive: false),
    ' ',
  );
  cleaned = cleaned.replaceAll(
    cachedRegExp(r'<style[\s\S]*?</style>', caseSensitive: false),
    ' ',
  );
  cleaned = cleaned.replaceAll(
    cachedRegExp(r'<noscript[\s\S]*?</noscript>', caseSensitive: false),
    ' ',
  );
  cleaned = cleaned.replaceAll(
    cachedRegExp(r'<svg[\s\S]*?</svg>', caseSensitive: false),
    ' ',
  );
  cleaned = cleaned.replaceAll(
    cachedRegExp(r'<link[^>]*>', caseSensitive: false),
    ' ',
  );
  final body = cachedRegExp(
    r'<body[^>]*>([\s\S]*)</body>',
    caseSensitive: false,
  ).firstMatch(cleaned);
  var core = body != null ? body.group(1)! : cleaned;
  // Booking menus can sit after a large photo/layout shell. Compact only
  // presentation attributes before the cap; preserve service boundaries,
  // links and structured price attributes for the deterministic extractor.
  if (core.contains('data-testid="services-list-item-root"')) {
    core = core.replaceAll(
      cachedRegExp(
        r'''\s+(?:class|style|id|srcset|sizes|src|data-v-[\w-]+)=(?:"[^"]*"|'[^']*')''',
        caseSensitive: false,
      ),
      '',
    );
  }
  if (jsonLd.isNotEmpty) {
    core = '${jsonLd.join('\n')}\n<div>$core</div>';
  }
  if (core.length > kExploreMaxHtmlParseChars) {
    core = core.substring(0, kExploreMaxHtmlParseChars);
  }
  return core;
}

/// Site chrome names every treatment. Never bind a nav label to a body price.
void _stripSiteChrome(Document doc) {
  for (final sel in const [
    'nav',
    'header',
    'footer',
    '[role="navigation"]',
    '.mega-menu',
    '.mega-menu-wrap',
    '#mega-menu-wrap',
  ]) {
    for (final el in doc.querySelectorAll(sel).toList()) {
      el.remove();
    }
  }
}

List<ExtractedPriceEvidence> extractPriceEvidence({
  required String html,
  required String sourceUrl,
}) {
  if (html.trim().isEmpty) return const [];
  final jsonLdScripts = [
    for (final m in cachedRegExp(
      r'<script[^>]*type="application/ld\+json"[^>]*>([\s\S]*?)</script>',
      caseSensitive: false,
    ).allMatches(html))
      if ((m.group(1) ?? '').trim().isNotEmpty) m.group(1)!.trim(),
  ];
  html = explorePrepareHtmlForPriceParse(html);
  if (html.isEmpty && jsonLdScripts.isEmpty) return const [];
  html = repairUtf8Mojibake(html);
  final doc = html_parser.parse(html);
  _stripSiteChrome(doc);
  // Classify the surrounding page once, before validating its fragments. A
  // table row in a market guide must not become a clinic quote on its own.
  final pageContextWire = explorePricePageContextWire(
    classifyExplorePricePageContext(
      sourceUrl: sourceUrl,
      pageText: doc.body?.text ?? doc.documentElement?.text ?? '',
      title: doc.querySelector('h1')?.text ?? '',
    ),
  );
  // Remove disallowed DOM amounts before every extraction strategy. Otherwise
  // a correct table row can be followed by a generic card/proximity pass that
  // revives its old price or loses the conditions of a child price span.
  _stripSupersededTableAmounts(doc);
  _stripConditionalOfferCards(doc);
  final out = <ExtractedPriceEvidence>[];
  final seen = <String>{};
  final headingContext = _PriceHeadingContext();

  void add(ExtractedPriceEvidence? row) {
    if (out.length >= kExploreMaxEvidenceScanRowsPerPage) return;
    if (row == null || !row.hasUsablePrice) return;
    if (row.rawProcedureText.trim().length < 3) return;
    // Truncated Zyte/HTML shells sometimes yield CSS/JS as "labels".
    final label = row.rawProcedureText;
    if (label.contains('<') ||
        label.contains('stylesheet') ||
        label.contains('wp-includes') ||
        label.length > 180) {
      return;
    }
    final verdict = evaluateExtractedPriceCandidate(
      rawPriceText: row.rawPriceText,
      priceMin: row.priceMin,
      currency: row.currency,
      extractionMethod: row.extractionMethod.wire,
      rawEvidence: row.rawEvidence,
      rawProcedureText: row.rawProcedureText,
      procedure: row.rawProcedureText,
      sourceUrl: row.sourceUrl,
      priceMax: row.priceMax,
      pageContextWire: pageContextWire,
      structuredOffer:
          row.extractionMethod == PriceExtractionMethod.jsonLd ||
          row.extractionMethod == PriceExtractionMethod.schemaOffer,
    );
    if (!verdict.accepted) return;
    if (exploreEvidenceLooksLikeStitchedCatalogBlob(
      rawPriceText: row.rawPriceText,
      rawEvidence: row.rawEvidence,
      priceMin: row.priceMin,
      extractionMethod: row.extractionMethod.wire,
    )) {
      return;
    }
    if (row.extractionMethod != PriceExtractionMethod.jsonLd &&
        row.extractionMethod != PriceExtractionMethod.schemaOffer &&
        row.priceMin > 0 &&
        row.priceMax >= row.priceMin * 4) {
      final own = clinicOwnPublishedPriceWindow(
        '${row.rawPriceText}\n${row.rawEvidence}',
      );
      if (own == null || !publishedAmountMatchesWindow(own, row.priceMin)) {
        return;
      }
    }
    final key =
        '${row.rawProcedureText.toLowerCase()}|${row.priceMin}|${row.extractionMethod.wire}';
    if (!seen.add(key)) return;
    var hashed = row.copyWith(
      evidenceHash: row.evidenceHash.isNotEmpty
          ? row.evidenceHash
          : buildEvidenceHash(
              sourceUrl: row.sourceUrl,
              rawProcedureText: row.rawProcedureText,
              rawPriceText: row.rawPriceText,
            ),
      sourceType: classifyPriceSourceType(row.sourceUrl),
    );
    final graftQty = hairGraftSessionQuantity(
      '${row.rawProcedureText} ${row.rawPriceText} ${row.rawEvidence}',
    );
    if (graftQty != null && (row.quantity == null || row.quantity! < 50)) {
      hashed = hashed.copyWith(quantity: graftQty);
    }
    out.add(hashed);
  }

  // The provider's service menu is authoritative within Booksy. Never mix
  // neighbouring services, review labels, or duration text into its amounts.
  final sourceHost = Uri.tryParse(sourceUrl)?.host.toLowerCase() ?? '';
  final booksyRows =
      (sourceHost == 'booksy.com' || sourceHost.endsWith('.booksy.com'))
      ? doc.querySelectorAll('[data-testid="services-list-item-root"]')
      : <Element>[];
  if (booksyRows.isNotEmpty) {
    final provider = extractMarketplaceProviderName(html, sourceUrl: sourceUrl);
    for (final service in booksyRows) {
      final name = service.querySelector('[data-testid="service-name"]');
      if (name == null) continue;
      final label = _visibleText(name);
      for (final price in service.querySelectorAll(
        '[data-testid="service-variant-price"]',
      )) {
        final raw = _visibleText(price);
        final parsed = parsePriceText(raw);
        if (parsed == null || parsed.priceMin <= 0) continue;
        add(
          ExtractedPriceEvidence(
            rawProcedureText: label,
            rawPriceText: raw,
            priceMin: parsed.priceMin,
            priceMax: parsed.priceMax,
            currency: parsed.currency,
            sourceUrl: sourceUrl,
            extractionMethod: PriceExtractionMethod.productCard,
            rawEvidence: '$label | $raw',
            confidence: .95,
            priceType: raw.trim().endsWith('+')
                ? PriceType.from
                : parsed.priceType,
            unit: parsed.unit,
            quantity: parsed.quantity,
            providerClinic: provider,
            sourcePlatform: marketplacePlatformLabel(sourceUrl),
          ),
        );
      }
    }
    return _preferFlagshipEvidenceRows(out);
  }

  final jsonLdRows = <ExtractedPriceEvidence>[];
  for (final raw in jsonLdScripts) {
    try {
      _walkJsonLd(jsonDecode(raw), sourceUrl, jsonLdRows);
    } catch (_) {
      for (final chunk in raw.split(cachedRegExp(r'\}\s*\{'))) {
        var piece = chunk.trim();
        if (!piece.startsWith('{')) piece = '{$piece';
        if (!piece.endsWith('}')) piece = '$piece}';
        try {
          _walkJsonLd(jsonDecode(piece), sourceUrl, jsonLdRows);
        } catch (_) {}
      }
    }
  }
  for (final row in jsonLdRows) {
    add(row);
  }
  for (final row in _extractJsonLd(doc, sourceUrl)) {
    add(row);
  }
  for (final row in _extractTables(doc, sourceUrl, headingContext)) {
    add(row);
  }
  for (final row in _extractLabeledCostFacts(doc, sourceUrl, headingContext)) {
    add(row);
  }
  for (final row in _extractProcedurePretSiblingPairs(
    doc,
    sourceUrl,
    headingContext,
  )) {
    add(row);
  }
  for (final row in _extractWooCommerce(doc, sourceUrl)) {
    add(row);
  }
  for (final row in _extractShopify(html, sourceUrl)) {
    add(row);
  }
  for (final row in _extractCardsAndLists(doc, sourceUrl, headingContext)) {
    add(row);
    if (out.length >= kExploreMaxEvidenceScanRowsPerPage) break;
  }
  for (final row in _extractHeadingsWithPrices(doc, sourceUrl)) {
    add(row);
  }
  // Elementor / WCF / many spa builders put the treatment name in one
  // heading and the fee in the next ("Peeling Biorepell Cl3" → "70€").
  for (final row in _extractAdjacentHeadingPricePairs(doc, sourceUrl)) {
    add(row);
  }
  if (out.isEmpty) {
    for (final row in _extractTextProximity(doc, sourceUrl)) {
      add(row);
    }
  }
  if (out.isEmpty) return out;
  final ranked = _preferFlagshipEvidenceRows(out);
  if (!isMarketplaceOrDirectoryHost(sourceUrl)) return ranked;
  final provider = extractMarketplaceProviderName(html, sourceUrl: sourceUrl);
  final platform = marketplacePlatformLabel(sourceUrl);
  return [
    for (final row in ranked)
      row.copyWith(
        sourceType: classifyPriceSourceType(sourceUrl),
        providerClinic: provider,
        sourcePlatform: platform,
      ),
  ];
}

bool _looksLikeBotoxEvidenceLabel(String label) {
  return cachedRegExp(
    r'botox|botulin|ботокс|ботулин|dysport|xeomin|toxina|'
    r'anti[- ]?wrinkle|estompare riduri',
    caseSensitive: false,
  ).hasMatch(label);
}

bool _looksLikeFillerEvidenceLabel(String label) {
  return cachedRegExp(
    r'filler|hialuron|hyaluron|juvederm|teosyal|stylage|'
    r'acid hialuronic|marire buze',
    caseSensitive: false,
  ).hasMatch(label);
}

bool _looksLikeFlagshipEvidenceLabel(String label) {
  return _looksLikeBotoxEvidenceLabel(label) ||
      _looksLikeFillerEvidenceLabel(label) ||
      cachedRegExp(
        r'laser|peel|rinoplast|rhinoplast|hair transplant|\bfue\b|'
        r'breast|mamar',
        caseSensitive: false,
      ).hasMatch(label);
}

/// Hospital menus list surgery first. Keep Botox/filler in the stored 80
/// even when 80+ breast/rhino rows appear earlier on the same page.
List<ExtractedPriceEvidence> _preferFlagshipEvidenceRows(
  List<ExtractedPriceEvidence> rows,
) {
  if (rows.length <= kExploreMaxEvidenceRowsPerPage) return rows;
  final botox = <ExtractedPriceEvidence>[];
  final filler = <ExtractedPriceEvidence>[];
  final flagship = <ExtractedPriceEvidence>[];
  final rest = <ExtractedPriceEvidence>[];
  for (final r in rows) {
    final blob = '${r.rawProcedureText} ${r.rawEvidence}';
    if (_looksLikeBotoxEvidenceLabel(blob)) {
      botox.add(r);
    } else if (_looksLikeFillerEvidenceLabel(blob)) {
      filler.add(r);
    } else if (_looksLikeFlagshipEvidenceLabel(blob)) {
      flagship.add(r);
    } else {
      rest.add(r);
    }
  }
  return [
    ...botox,
    ...filler,
    ...flagship,
    ...rest,
  ].take(kExploreMaxEvidenceRowsPerPage).toList();
}

List<ExtractedPriceEvidence> _extractJsonLd(Document doc, String sourceUrl) {
  final out = <ExtractedPriceEvidence>[];
  final scripts = doc.querySelectorAll('script[type="application/ld+json"]');
  for (final script in scripts) {
    final raw = script.text.trim();
    if (raw.isEmpty) continue;
    try {
      final decoded = jsonDecode(raw);
      _walkJsonLd(decoded, sourceUrl, out);
    } catch (_) {
      // Some sites concatenate two JSON objects.
      for (final chunk in raw.split(cachedRegExp(r'\}\s*\{'))) {
        var piece = chunk.trim();
        if (!piece.startsWith('{')) piece = '{$piece';
        if (!piece.endsWith('}')) piece = '$piece}';
        try {
          _walkJsonLd(jsonDecode(piece), sourceUrl, out);
        } catch (_) {}
      }
    }
  }
  return out;
}

void _walkJsonLd(
  dynamic node,
  String sourceUrl,
  List<ExtractedPriceEvidence> out,
) {
  if (node is List) {
    for (final item in node) {
      _walkJsonLd(item, sourceUrl, out);
    }
    return;
  }
  if (node is! Map) return;
  final map = node.map((k, v) => MapEntry('$k', v));
  if (map['@graph'] != null) _walkJsonLd(map['@graph'], sourceUrl, out);

  final type = '${map['@type'] ?? ''}'.toLowerCase();
  final name = '${map['name'] ?? map['title'] ?? ''}'.trim();
  final description = '${map['description'] ?? ''}'.trim();
  final label = name.isNotEmpty ? name : description;

  String offerProcedureLabel(Map<String, dynamic> offer, String fallback) {
    if (fallback.trim().isNotEmpty) return fallback.trim();
    final offered = offer['itemOffered'];
    if (offered is Map) {
      final o = offered.map((k, v) => MapEntry('$k', v));
      final n = '${o['name'] ?? o['title'] ?? ''}'.trim();
      if (n.isNotEmpty) return n;
      final d = '${o['description'] ?? ''}'.trim();
      if (d.isNotEmpty) return d;
    }
    return '${offer['name'] ?? offer['category'] ?? ''}'.trim();
  }

  (String unit, double? quantity) quantityFromLabel(String proc) {
    final q = exploreInjectableVolumeMl(proc);
    if (q != null) return ('ml', q);
    return ('', null);
  }

  void fromOffer(dynamic offer, {String procedure = ''}) {
    if (offer is List) {
      for (final o in offer) {
        fromOffer(o, procedure: procedure);
      }
      return;
    }
    if (offer is! Map) return;
    final o = offer.map((k, v) => MapEntry('$k', v));
    final currency = '${o['priceCurrency'] ?? o['pricecurrency'] ?? ''}'
        .trim()
        .toUpperCase();
    final low = '${o['lowPrice'] ?? o['price'] ?? o['highPrice'] ?? ''}'.trim();
    final high = '${o['highPrice'] ?? ''}'.trim();
    if (low.isEmpty && '${o['price'] ?? ''}'.isEmpty) return;
    final rawPrice = high.isNotEmpty && high != low
        ? '$low–$high $currency'
        : '$low $currency';
    final parsed = parsePriceText(rawPrice);
    if (parsed == null || parsed.priceMin <= 0) return;
    final proc = offerProcedureLabel(
      o,
      procedure.isNotEmpty ? procedure : label,
    );
    if (proc.isEmpty) return;
    final qty = quantityFromLabel(proc);
    final isMarketplace = isMarketplaceOrDirectoryHost(sourceUrl);
    out.add(
      ExtractedPriceEvidence(
        rawProcedureText: proc,
        rawPriceText: rawPrice.trim(),
        priceMin: parsed.priceMin,
        priceMax: high.isNotEmpty
            ? (parseLocaleNumber(high) ?? parsed.priceMax)
            : parsed.priceMin,
        currency: parsed.currency.isNotEmpty ? parsed.currency : currency,
        sourceUrl: sourceUrl,
        extractionMethod: isMarketplace
            ? PriceExtractionMethod.schemaOffer
            : (type.contains('offer') && !type.contains('product')
                  ? PriceExtractionMethod.schemaOffer
                  : PriceExtractionMethod.jsonLd),
        rawEvidence: [
          proc, rawPrice.trim(),
          '${o['category'] ?? map['category'] ?? ''}',
          '${o['description'] ?? description}',
          if (o['itemOffered'] is Map)
            '${(o['itemOffered'] as Map)['category'] ?? ''} | '
                '${(o['itemOffered'] as Map)['description'] ?? ''}',
        ].where((part) => part.trim().isNotEmpty).join(' | '),
        confidence: 0.98,
        priceType: parsed.priceType,
        unit: (parsed.unit.isNotEmpty ? parsed.unit : qty.$1),
        quantity: parsed.quantity ?? qty.$2,
        sourceType: isMarketplace
            ? PriceSourceType.marketplace
            : PriceSourceType.officialClinic,
        sourcePlatform: isMarketplace
            ? marketplacePlatformLabel(sourceUrl)
            : '',
      ),
    );
  }

  if (type.contains('product') ||
      type.contains('service') ||
      type.contains('offer') ||
      type.contains('aggregateoffer')) {
    if (map['offers'] != null) {
      fromOffer(map['offers'], procedure: label);
    } else if (type.contains('offer') || type.contains('aggregateoffer')) {
      fromOffer(map, procedure: label);
    }
  }

  for (final key in ['hasOfferCatalog', 'itemListElement', 'makesOffer']) {
    if (map[key] != null) _walkJsonLd(map[key], sourceUrl, out);
  }
}

/// Was/now tables list the old price first. Min→max ranges list the low
/// first. Pick the current starting amount either way.
String _preferredTablePriceCell(List<String> priceCells) {
  String firstCurrency() {
    for (final t in priceCells) {
      if (looksLikeGraftOrFollicleQuantity(t)) continue;
      if (hasCurrencySignal(t)) return t;
    }
    for (final t in priceCells) {
      if (looksLikeGraftOrFollicleQuantity(t)) continue;
      if (looksLikePerGraftQuotedPrice(t)) return t;
    }
    for (final t in priceCells) {
      if (!looksLikeGraftOrFollicleQuantity(t)) return t;
    }
    return '';
  }

  if (priceCells.length < 2) return firstCurrency();
  ParsedPrice? first;
  ParsedPrice? last;
  for (final t in priceCells) {
    final parsed = parsePriceText(t);
    if (parsed == null || parsed.priceMin <= 0) continue;
    first ??= parsed;
    last = parsed;
  }
  if (first == null || last == null) return firstCurrency();
  if (identical(first, last) || first.priceMin == last.priceMin) {
    return firstCurrency();
  }
  if (last.priceMin < first.priceMin) {
    for (var i = priceCells.length - 1; i >= 0; i--) {
      final parsed = parsePriceText(priceCells[i]);
      if (parsed != null && parsed.priceMin == last.priceMin) {
        return priceCells[i];
      }
    }
  }
  return firstCurrency();
}

List<String> _tableColumnHeaders(Element tr) {
  Element? table = tr;
  for (var i = 0; i < 8; i++) {
    if (table == null) return const [];
    if ((table.localName ?? '').toLowerCase() == 'table') break;
    table = table.parent;
  }
  if (table == null) return const [];
  final headerRow =
      table.querySelector('thead tr') ?? table.querySelector('tr');
  if (headerRow == null) return const [];
  return [
    for (final cell in headerRow.querySelectorAll('th, td')) _visibleText(cell),
  ];
}

void _stripSupersededTableAmounts(Document doc) {
  for (final table in doc.querySelectorAll('table')) {
    final rows = table.querySelectorAll('tr');
    if (rows.isEmpty) continue;
    final headerRow = table.querySelector('thead tr') ?? rows.first;
    final headers = headerRow.querySelectorAll('th, td');
    final oldColumns = <int>[
      for (var i = 0; i < headers.length; i++)
        if (looksLikeSupersededPriceColumnHeader(_visibleText(headers[i]))) i,
    ];
    if (oldColumns.isEmpty) continue;
    for (final row in rows) {
      if (identical(row, headerRow)) continue;
      final cells = row.querySelectorAll('th, td');
      for (final column in oldColumns) {
        if (column >= cells.length) continue;
        cells[column].text = '';
        cells[column].attributes.clear();
      }
    }
  }
}

void _stripConditionalOfferCards(Document doc) {
  final conditions = cachedRegExp(
    r'\b(?:pack\s+amigas?|friends?\s+pack|bring\s+(?:a\s+)?friend|'
    r'ven\s+con\s+una\s+amiga|couples?\s+offer|couples?\s+price|per\s+couple)\b',
    caseSensitive: false,
  );
  for (final card in doc.querySelectorAll(
    'article, .promo-card, .pricing-card, .offer-card, .service-card',
  ).toList()) {
    if (conditions.hasMatch(_visibleText(card))) card.remove();
  }
}

List<ExtractedPriceEvidence> _extractTables(
  Document doc,
  String sourceUrl,
  _PriceHeadingContext headingContext,
) {
  final out = <ExtractedPriceEvidence>[];
  for (final tr in doc.querySelectorAll('tr')) {
    final cells = tr.querySelectorAll('th, td');
    if (cells.length < 2) continue;
    final headers = _tableColumnHeaders(tr);
    String procedure = '';
    final priceCells = <String>[];
    final priceHeaders = <String, String>{};
    for (var i = 0; i < cells.length; i++) {
      final t = _visibleText(cells[i]);
      if (t.isEmpty) continue;
      if (looksLikeGraftOrFollicleQuantity(t)) {
        if (procedure.isEmpty) procedure = t;
        continue;
      }
      final header = i < headers.length ? headers[i] : '';
      if (looksLikeCompetitorPriceColumnHeader(header) ||
          looksLikeThirdPartyProviderPriceLabel(header) ||
          looksLikeSupersededPriceColumnHeader(header)) {
        continue;
      }
      if (_kPriceLike.hasMatch(t) || _kBarePrice.hasMatch(t)) {
        // Gulf menus often put "Cost (AED)" only in the column header.
        final value = !hasCurrencySignal(t) && hasCurrencySignal(header)
            ? '$t $header' : t;
        priceCells.add(value);
        priceHeaders[value] = header;
      } else if (_looksLikeProcedureLabel(t)) {
        if (procedure.isEmpty) {
          procedure = t;
        } else if ((looksLikeCatalogSectionHeading(procedure) ||
                looksLikeGenericInjectableCategoryHeading(procedure)) &&
            !looksLikeCatalogSectionHeading(t) &&
            !looksLikeGenericInjectableCategoryHeading(t)) {
          // 3-col menus: "Filler dermatological injections | Stylage M 1 ml | 140 €"
          procedure = t;
        }
      }
    }
    var priceRaw = _preferredTablePriceCell(priceCells);
    if (procedure.isEmpty || priceRaw.isEmpty) continue;
    if (looksLikeThirdPartyProviderPriceLabel(procedure) ||
        looksLikeCompetitorPriceColumnHeader(procedure)) {
      continue;
    }
    procedure = _withSectionContext(tr, procedure, headingContext);
    final basis = priceHeaders[priceRaw] ?? '';
    if (cachedRegExp(
      r'\b\d+\s*(?:viales?|vials?|ml|sessions?|sesiones?|units?|unidades|zones?|zonas?|areas?)\b',
      caseSensitive: false,
    ).hasMatch(basis)) {
      procedure = '$procedure · ${basis.replaceAll(cachedRegExp(
        r'\s*\(\s*(?:ahora|now|current)\s*\)', caseSensitive: false,
      ), '').trim()}';
    }
    final hint = _nearestCurrencyHint(tr);
    final parsed = parsePriceText(
      hint.isNotEmpty && !hasCurrencySignal(priceRaw)
          ? '$priceRaw $hint'
          : priceRaw,
    );
    if (parsed == null || parsed.priceMin <= 0) continue;
    out.add(
      ExtractedPriceEvidence(
        rawProcedureText: procedure,
        rawPriceText: _listedRawPriceText(priceRaw, parsed),
        priceMin: parsed.priceMin,
        priceMax: parsed.priceMax,
        currency: parsed.currency,
        sourceUrl: sourceUrl,
        extractionMethod: PriceExtractionMethod.htmlTable,
        rawEvidence: shrinkEvidenceToProcedureAndPrice(
          block: _visibleText(tr),
          procedure: procedure,
          priceRaw: priceRaw,
        ),
        confidence: 0.97,
        priceType: parsed.priceType,
        unit: parsed.unit,
        quantity: parsed.quantity,
      ),
    );
  }
  return out;
}

List<ExtractedPriceEvidence> _extractWooCommerce(
  Document doc,
  String sourceUrl,
) {
  final out = <ExtractedPriceEvidence>[];
  final productTitle = _wooProductTitle(doc);
  final isProductPage = cachedRegExp(
    r'/product/|/products/|/shop/',
    caseSensitive: false,
  ).hasMatch(sourceUrl);

  // On product pages, only the main summary price is trusted — related /
  // upsell cards reuse chrome and would steal a cheaper unrelated amount.
  final priceNodes = <Element>[
    if (isProductPage) ...[
      ...doc.querySelectorAll(
        '.summary.entry-summary > p.price, .entry-summary > p.price, '
        '.summary > p.price, .product .summary p.price',
      ),
    ],
    if (!isProductPage ||
        doc
            .querySelectorAll(
              '.summary.entry-summary > p.price, .entry-summary > p.price, '
              '.summary > p.price, .product .summary p.price',
            )
            .isEmpty) ...[
      ...doc.querySelectorAll('p.price'),
      ...doc.querySelectorAll('.summary .price, .entry-summary .price'),
      ...doc.querySelectorAll('.woocommerce-Price-amount'),
      ...doc.querySelectorAll('span.price'),
      ...doc.querySelectorAll('.price'),
    ],
  ];
  final seen = <Element>{};
  for (final node in priceNodes) {
    if (_isInsideRelatedOrUpsell(node)) continue;
    // Never emit the struck-through "was" amount as its own row. Climb to the
    // del+ins wrapper so only the current (ins) price is used.
    if (_isInsideStruckThroughSalePrice(node)) continue;
    final block = _priceContainer(node);
    if (!seen.add(block)) continue;
    final del = block.querySelector('del');
    final ins = block.querySelector('ins');
    String rawPrice;
    ParsedPrice? parsed;
    if (ins != null) {
      final insText = _visibleText(ins);
      final delText = del == null ? '' : _visibleText(del);
      rawPrice = insText;
      final active = parsePriceText(insText);
      final original = delText.isEmpty ? null : parsePriceText(delText);
      if (active == null || active.priceMin <= 0) continue;
      // FROM price is the live amount only — never the struck-through "was".
      parsed = ParsedPrice(
        priceMin: active.priceMin,
        priceMax: active.priceMin,
        currency: active.currency.isNotEmpty
            ? active.currency
            : (original?.currency ?? ''),
        priceType: original != null && original.priceMin > active.priceMin
            ? PriceType.sale
            : active.priceType,
      );
    } else {
      rawPrice = _visibleText(block);
      // Screen-reader "Original price was: … Current price is: …" — keep current.
      final currentCue = cachedRegExp(
        r'Current price is:\s*([\d.,]+\s*[A-Za-z€£$]*)',
        caseSensitive: false,
      ).firstMatch(rawPrice);
      if (currentCue != null) {
        rawPrice = currentCue.group(1)!.trim();
      }
      parsed = parsePriceText(rawPrice);
      if (parsed == null || parsed.priceMin <= 0) continue;
    }
    var procedure = _nearestProcedureLabel(block);
    final inMainSummary = _isInsideMainProductSummary(block);
    if (looksLikeCommerceChromeLabel(procedure) || procedure.isEmpty) {
      // Only inherit the page product title for the main summary price.
      if (inMainSummary || isProductPage) {
        procedure = productTitle;
      }
    }
    if (procedure.isEmpty || looksLikeCommerceChromeLabel(procedure)) continue;
    // Clean breadcrumb noise: "Breast Augmentation Home Breast Augmentation".
    procedure = _cleanWooProcedureLabel(procedure, productTitle);
    out.add(
      ExtractedPriceEvidence(
        rawProcedureText: procedure,
        rawPriceText: rawPrice,
        priceMin: parsed.priceMin,
        priceMax: parsed.priceMax,
        currency: parsed.currency,
        sourceUrl: sourceUrl,
        extractionMethod: PriceExtractionMethod.wooCommerce,
        rawEvidence: '$procedure · $rawPrice',
        confidence: inMainSummary ? 0.97 : 0.96,
        priceType: parsed.priceType,
        unit: parsed.unit,
        quantity: parsed.quantity,
      ),
    );
    // One trusted main price is enough on a product URL.
    if (isProductPage && inMainSummary) break;
  }
  return out;
}

bool _isInsideRelatedOrUpsell(Element node) {
  Element? cur = node;
  for (var i = 0; i < 10; i++) {
    if (cur == null) return false;
    final id = cur.id.toLowerCase();
    final cls = cur.className.toLowerCase();
    if (cls.contains('related') ||
        cls.contains('upsell') ||
        cls.contains('cross-sell') ||
        cls.contains('products') && cls.contains('columns') ||
        id.contains('related')) {
      return true;
    }
    cur = cur.parent;
  }
  return false;
}

bool _isInsideMainProductSummary(Element node) {
  Element? cur = node;
  for (var i = 0; i < 8; i++) {
    if (cur == null) return false;
    final cls = cur.className.toLowerCase();
    if (cls.contains('entry-summary') ||
        (cls.contains('summary') && !cls.contains('after-summary'))) {
      return true;
    }
    cur = cur.parent;
  }
  return false;
}

String _cleanWooProcedureLabel(String raw, String productTitle) {
  var t = raw.replaceAll(cachedRegExp(r'\s+'), ' ').trim();
  if (productTitle.isNotEmpty &&
      t.toLowerCase().contains(productTitle.toLowerCase())) {
    return productTitle;
  }
  t = t.replaceFirst(
    cachedRegExp(r'^(home|shop)\s+', caseSensitive: false),
    '',
  );
  // "Breast Augmentation Home Breast Augmentation" → first title segment.
  final dup = cachedRegExp(
    r'^(.+?)\s+(?:home|shop)\s+\1$',
    caseSensitive: false,
  ).firstMatch(t);
  if (dup != null) return dup.group(1)!.trim();
  return t;
}

/// True when [node] sits under `<del>` while a sibling `<ins>` holds the live price.
bool _isInsideStruckThroughSalePrice(Element node) {
  Element? cur = node;
  for (var i = 0; i < 6; i++) {
    if (cur == null) return false;
    if ((cur.localName ?? '').toLowerCase() == 'del') {
      final parent = cur.parent;
      if (parent != null && parent.querySelector('ins') != null) return true;
      return false;
    }
    if ((cur.localName ?? '').toLowerCase() == 'ins') return false;
    cur = cur.parent;
  }
  return false;
}

Element _priceContainer(Element node) {
  var cur = node;
  for (var i = 0; i < 6; i++) {
    final parent = cur.parent;
    if (parent == null) break;
    // A sale <del>/<ins> on a sibling card must not swallow the whole grid.
    if (parent.querySelectorAll('.product-item, li.product').length > 1) {
      break;
    }
    final name = (cur.localName ?? '').toLowerCase();
    // Climb out of del/ins so we see the full was/now pair.
    if (name == 'del' || name == 'ins') {
      cur = parent;
      continue;
    }
    if (parent.querySelector('del') != null ||
        parent.querySelector('ins') != null ||
        parent.localName == 'p' ||
        parent.classes.contains('price') ||
        parent.classes.contains('summary') ||
        parent.classes.contains('entry-summary')) {
      cur = parent;
      continue;
    }
    break;
  }
  return cur;
}

String _wooProductTitle(Document doc) {
  for (final sel in const [
    'h1.product_title',
    '.product_title',
    '.summary .product_title',
    '.entry-summary .product_title',
    '.title h1',
    '.title h2',
    '.title h2 span',
    'nav.woocommerce-breadcrumb li:last-child',
    '.woocommerce-breadcrumb li:last-child',
  ]) {
    final el = doc.querySelector(sel);
    if (el == null) continue;
    final t = _visibleText(el);
    if (t.isEmpty || looksLikeCommerceChromeLabel(t)) continue;
    if (_looksLikeProcedureLabel(t)) return t;
  }
  return '';
}

List<ExtractedPriceEvidence> _extractShopify(String html, String sourceUrl) {
  final out = <ExtractedPriceEvidence>[];
  final jsonBlocks = cachedRegExp(
    r'<script[^>]*type="application/json"[^>]*>([\s\S]*?)</script>',
    caseSensitive: false,
  );
  for (final m in jsonBlocks.allMatches(html)) {
    final raw = (m.group(1) ?? '').trim();
    if (raw.isEmpty || raw.length > 400000) continue;
    try {
      final decoded = jsonDecode(raw);
      _walkShopifyJson(decoded, sourceUrl, out);
    } catch (_) {}
  }
  final productJson = cachedRegExp(
    r'"product"\s*:\s*\{[\s\S]{0,8000}?"title"\s*:\s*"([^"]+)"[\s\S]{0,4000}?"price"\s*:\s*"?(\d+(?:\.\d+)?)"?',
    caseSensitive: false,
  );
  for (final m in productJson.allMatches(html)) {
    final name = (m.group(1) ?? '').trim();
    final price = (m.group(2) ?? '').trim();
    if (name.isEmpty || price.isEmpty) continue;
    final cents = double.tryParse(price);
    if (cents == null) continue;
    final amount =
        cents > 1000 && cents == cents.roundToDouble() && cents % 100 == 0
        ? cents / 100
        : cents;
    if (amount <= 0) continue;
    out.add(
      ExtractedPriceEvidence(
        rawProcedureText: name,
        rawPriceText: price,
        priceMin: amount,
        priceMax: amount,
        currency: '',
        sourceUrl: sourceUrl,
        extractionMethod: PriceExtractionMethod.shopify,
        rawEvidence: m.group(0) ?? '',
        confidence: 0.93,
        priceType: PriceType.fixed,
      ),
    );
  }
  return out;
}

void _walkShopifyJson(
  dynamic node,
  String sourceUrl,
  List<ExtractedPriceEvidence> out,
) {
  if (node is List) {
    for (final item in node) {
      _walkShopifyJson(item, sourceUrl, out);
    }
    return;
  }
  if (node is! Map) return;
  final map = node.map((k, v) => MapEntry('$k', v));
  final title = '${map['title'] ?? map['name'] ?? ''}'.trim();
  final variants = map['variants'];
  if (title.isNotEmpty && variants is List && variants.isNotEmpty) {
    for (final v in variants) {
      if (v is! Map) continue;
      final vm = v.map((k, val) => MapEntry('$k', val));
      final priceRaw = '${vm['price'] ?? ''}';
      final compare = '${vm['compare_at_price'] ?? ''}';
      final parsed = parsePriceText('$priceRaw EUR');
      if (parsed == null) continue;
      var min = parsed.priceMin;
      if (min >= 100 && min == min.roundToDouble() && priceRaw.length >= 4) {
        // Shopify often stores cents.
        if (!priceRaw.contains('.') && min > 5000) min = min / 100;
      }
      final orig = parseLocaleNumber(compare);
      out.add(
        ExtractedPriceEvidence(
          rawProcedureText: title,
          rawPriceText: priceRaw,
          priceMin: min,
          priceMax: (orig != null && orig > min) ? orig : min,
          currency: parsed.currency,
          sourceUrl: sourceUrl,
          extractionMethod: PriceExtractionMethod.shopify,
          rawEvidence: jsonEncode(vm),
          confidence: 0.94,
          priceType: orig != null && orig > min
              ? PriceType.sale
              : PriceType.fixed,
        ),
      );
      break;
    }
  }
  for (final v in map.values) {
    if (v is Map || v is List) _walkShopifyJson(v, sourceUrl, out);
  }
}

List<ExtractedPriceEvidence> _extractCardsAndLists(
  Document doc,
  String sourceUrl,
  _PriceHeadingContext headingContext,
) {
  final out = <ExtractedPriceEvidence>[];
  final blocks = <Element>[
    ...doc.querySelectorAll('li'),
    ...doc.querySelectorAll('p'),
    ...doc.querySelectorAll(
      '.service, .servicio, .product, .product-item, .card, .tratamiento, '
      '.treatment, .item, article, .wp-block-column, .service-list--block',
    ),
    ...doc.querySelectorAll('div'),
  ];
  final seen = <Element>{};
  var genericWalks = 0;
  for (final el in blocks) {
    if (!seen.add(el)) continue;
    // Nested spa/peel menus: walking each wrapper with [_visibleText] is
    // O(n²) on the UI isolate and freezes Compare. Leaf cards still run.
    if (_isDeepLayoutWrapper(el)) continue;
    if (el.localName == 'div' || el.localName == 'span') {
      genericWalks++;
      if (genericWalks > _kMaxGenericBlockWalks) continue;
    }
    final text = _visibleText(el);
    if (text.length < 8) continue;
    if (!_kPriceLike.hasMatch(text)) continue;
    if (text.length > 400) {
      out.addAll(_namedMenuRowsFromText(text, sourceUrl));
      continue;
    }
    if (el
            .querySelectorAll(
              '.price, .woocommerce-Price-amount, ins, del, .service-list--price',
            )
            .isEmpty &&
        el.querySelectorAll('h1, h2, h3, h4, strong, span, p').length > 12) {
      continue;
    }
    var priceRaw = '';
    ParsedPrice? parsed;
    final priceEl = _firstPriceChild(el);
    if (priceEl != null) {
      priceRaw = _visibleText(priceEl);
      parsed = parsePriceText(priceRaw);
    } else if (el.localName == 'li' ||
        el.localName == 'p' ||
        _looksLikeSingleNamedMenuLine(text)) {
      parsed = parsePriceText(text);
      if (parsed != null && parsed.priceMin > 0) {
        priceRaw = text;
      }
    } else {
      continue;
    }
    if (parsed == null || parsed.priceMin <= 0 || priceRaw.isEmpty) continue;
    final heading = el.querySelector(
      'h1, h2, h3, h4, .product_title, .entry-title, '
      '.service-list--block-title-text, .service-list--block-title',
    );
    var procedure = heading == null ? '' : _visibleText(heading);
    if (looksLikePriceMenuHeadingOnly(procedure)) procedure = '';
    if (procedure.isEmpty) {
      procedure = _procedureFromBlock(el, priceRaw);
    }
    if (procedure.isEmpty || procedure == priceRaw) {
      procedure = _procedureBeforePublishedPrice(text);
    }
    procedure = stripSurroundingPageCopyFromProcedureTitle(procedure);
    procedure = _withSectionContext(el, procedure, headingContext);
    if (procedure.isEmpty || procedure == priceRaw) continue;
    final method = el.localName == 'li'
        ? PriceExtractionMethod.listItem
        : (el.classes.contains('product') ||
                  el.classes.contains('product-item') ||
                  el.classes.contains('service') ||
                  el.classes.contains('servicio')
              ? PriceExtractionMethod.productCard
              : PriceExtractionMethod.domBlock);
    out.add(
      ExtractedPriceEvidence(
        rawProcedureText: procedure,
        rawPriceText: priceRaw,
        priceMin: parsed.priceMin,
        priceMax: parsed.priceMax,
        currency: parsed.currency,
        sourceUrl: sourceUrl,
        extractionMethod: method,
        rawEvidence: shrinkEvidenceToProcedureAndPrice(
          block: text,
          procedure: procedure,
          priceRaw: priceRaw,
        ),
        confidence: method == PriceExtractionMethod.productCard ? 0.93 : 0.88,
        priceType: parsed.priceType,
        unit: parsed.unit,
        quantity: parsed.quantity,
      ),
    );
  }
  return out;
}

List<ExtractedPriceEvidence> _extractTextProximity(
  Document doc,
  String sourceUrl,
) {
  final out = <ExtractedPriceEvidence>[];
  for (final el in doc.querySelectorAll('p, li, td')) {
    final text = _visibleText(el);
    if (text.length < 8 || text.length > 520) continue;
    if (!_kPriceLike.hasMatch(text)) continue;
    final own = clinicOwnPublishedPriceWindow(text);
    ParsedPrice? parsed;
    var priceRaw = text;
    if (own != null) {
      parsed = parsePriceText(own);
      if (parsed != null) priceRaw = own;
    }
    parsed ??= parsePriceText(text);
    if (parsed == null) continue;
    // Keep age claims bound to the same element before shortening its evidence.
    // A following sentence can mark this otherwise-owned quote as expired.
    if (looksLikeHairStaleLandingQuote(
      sourceUrl: sourceUrl,
      blob: text,
      priceMin: parsed.priceMin,
      priceMax: parsed.priceMax,
    )) {
      continue;
    }
    if (looksLikeMarketAveragePriceBlurb(text) &&
        (own == null || !publishedAmountMatchesWindow(own, parsed.priceMin))) {
      continue;
    }
    if (looksLikeRoundedMarketPriceSpread(
      priceMin: parsed.priceMin,
      priceMax: parsed.priceMax,
      currency: parsed.currency,
      procedure: text,
    )) {
      continue;
    }
    if ((looksLikeSearchQuickFactsBlob(text) ||
            looksLikeSeoQuotedPriceHeadline(text)) &&
        !looksLikeClinicLabeledCostFact(text)) {
      continue;
    }
    if (looksLikeMixedServiceBundle(text)) {
      continue;
    }
    var procedure = _procedureFromBlock(el, priceRaw);
    if (procedure.isEmpty || looksLikeBarePriceLabel(procedure)) {
      final fromBlob = procedureLabelFromPricedBlob(
        rawProcedureText: procedure,
        rawEvidence: text,
      );
      if (fromBlob.isNotEmpty) procedure = fromBlob;
    }
    if (procedure.isEmpty) continue;
    out.add(
      ExtractedPriceEvidence(
        rawProcedureText: procedure,
        rawPriceText: priceRaw,
        priceMin: parsed.priceMin,
        priceMax: parsed.priceMax,
        currency: parsed.currency,
        sourceUrl: sourceUrl,
        extractionMethod: PriceExtractionMethod.textProximity,
        rawEvidence: shrinkEvidenceToProcedureAndPrice(
          block: text,
          procedure: procedure,
          priceRaw: priceRaw,
        ),
        confidence: own != null ? 0.72 : 0.55,
        priceType: parsed.priceType,
        unit: parsed.unit,
        quantity: parsed.quantity,
      ),
    );
  }
  return out;
}

Element? _firstPriceChild(Element el) {
  for (final sel in [
    'ins',
    '.woocommerce-Price-amount',
    '.service-list--price',
    '.price',
    'strong',
    'span',
    'div.price',
    'p',
  ]) {
    for (final child in el.querySelectorAll(sel)) {
      final t = _visibleText(child);
      if (t.isEmpty || looksLikeGraftOrFollicleQuantity(t)) continue;
      if (_kPriceLike.hasMatch(t) || _kBarePrice.hasMatch(t)) return child;
    }
  }
  return null;
}

String _nearestProcedureLabel(Element priceEl) {
  Element? cur = priceEl;
  for (var i = 0; i < 8; i++) {
    if (cur == null) break;
    final heading = cur.querySelector(
      'h1, h2, h3, h4, .product_title, .entry-title, .woocommerce-loop-product__title, .title span',
    );
    if (heading != null) {
      final t = _visibleText(heading);
      if (_looksLikeProcedureLabel(t) && !looksLikeCommerceChromeLabel(t)) {
        return t;
      }
    }
    var sib = cur.previousElementSibling;
    while (sib != null) {
      // Skip WooCommerce "Sale!" badges and other chrome.
      if (sib.classes.contains('onsale') ||
          looksLikeCommerceChromeLabel(_visibleText(sib))) {
        sib = sib.previousElementSibling;
        continue;
      }
      final t = _visibleText(sib);
      if (_looksLikeProcedureLabel(t) &&
          !looksLikeCommerceChromeLabel(t) &&
          t.length <= 120) {
        return t;
      }
      final inner = sib.querySelector('h1, h2, h3, h4, .product_title');
      if (inner != null) {
        final ht = _visibleText(inner);
        if (_looksLikeProcedureLabel(ht) && !looksLikeCommerceChromeLabel(ht)) {
          return ht;
        }
      }
      sib = sib.previousElementSibling;
    }
    if (cur.classes.contains('product-item') ||
        (cur.classes.contains('product') &&
            !cur.classes.contains('product-grid') &&
            !cur.classes.contains('products'))) {
      break;
    }
    cur = cur.parent;
  }
  return '';
}

String _procedureFromBlock(Element el, String priceRaw) {
  final heading = el.querySelector(
    'h1, h2, h3, h4, .service-list--block-title-text, p, span, strong',
  );
  if (heading != null) {
    final t = stripSurroundingPageCopyFromProcedureTitle(_visibleText(heading));
    if (_looksLikeProcedureLabel(t) && t != priceRaw) return t;
  }
  var text = _visibleText(el);
  text = text
      .replaceAll(priceRaw, ' ')
      .replaceAll(cachedRegExp(r'\s+'), ' ')
      .trim();
  if (_looksLikeProcedureLabel(text)) return text;
  return _procedureBeforePublishedPrice(_visibleText(el));
}

/// "Cost of 500 FUE grafts – from £3500" → "Cost of 500 FUE grafts".
/// Short menu lines like "Chemical Peel $300" also split. Prose such as
/// "some clinics offering Botox for £99" must not.
String _procedureBeforePublishedPrice(String text) {
  final t = text.replaceAll('\u00a0', ' ').trim();
  String cleaned(String procedure) {
    final label = stripSurroundingPageCopyFromProcedureTitle(procedure);
    if (!_looksLikeProcedureLabel(label)) return '';
    return label;
  }

  final fromCut = cachedRegExp(
    r'(?:from|starts?\s+from|starts?\s+at|starting(?:\s+from)?)\s*'
    r'(?:aed|usd|eur|gbp|€|£|\$|درهم|د\.إ)?\s*\d',
    caseSensitive: false,
  ).firstMatch(t);
  if (fromCut != null && fromCut.start >= 3) {
    final procedure = t
        .substring(0, fromCut.start)
        .replaceAll(cachedRegExp(r'[–—\-:\s]+$'), '')
        .trim();
    final label = cleaned(procedure);
    if (label.isNotEmpty) return label;
  }
  if (t.length > 160 ||
      cachedRegExp(
        r'\b(?:offering|clinics? that|ridiculously|typically last|'
        r'consultation|financing|carecredit)\b',
        caseSensitive: false,
      ).hasMatch(t)) {
    return '';
  }
  final cashCut = cachedRegExp(
    r'(?:\$|€|£)\s*\d|'
    r'(?:usd|eur|gbp|aed|ron|lei|درهم|د\.إ)\s*\d|'
    r'\d[\d.,]*\s*(?:usd|eur|gbp|aed|ron|lei|€|£)',
    caseSensitive: false,
  ).firstMatch(t);
  if (cashCut == null || cashCut.start < 3) return '';
  final procedure = t
      .substring(0, cashCut.start)
      .replaceAll(cachedRegExp(r'[–—\-:\s]+$'), '')
      .trim();
  final label = cleaned(procedure);
  if (label.isEmpty) return '';
  if (label.split(cachedRegExp(r'\s+')).length > 8) return '';
  return label;
}

bool _looksLikeTypicalMarketSnippet(String raw) {
  return cachedRegExp(
    r'\btypical(?:ly)?\s+sessions?\s+rang|'
    r'\bprices?\s+vary\s+depending\b|'
    r'\btypical(?:ly)?\s+(?:range|ranges)\s+from\b',
    caseSensitive: false,
  ).hasMatch(raw);
}

bool _looksLikeSingleNamedMenuLine(String text) {
  final t = text.replaceAll('\u00a0', ' ').trim();
  if (t.length < 8 || t.length > 160) return false;
  if (_looksLikeTypicalMarketSnippet(t)) return false;
  if (!_kPriceLike.hasMatch(t)) return false;
  if (countPriceLikeAmounts(t) != 1) return false;
  return _procedureBeforePublishedPrice(t).isNotEmpty;
}

final _kNamedMenuPrice = cachedRegExp(
  r'([A-Za-zÀ-ÿ®™][A-Za-zÀ-ÿ0-9®™\s/\-+&.]{1,70}?)\s+'
  r'((?:from\s+|starting\s+at\s+)?'
  r'(?:\$|€|£)\s*\d[\d,]*(?:\.\d{2})?'
  r'(?:\s*(?:per\s+(?:syringe|unit|session|ml|vial|area|treatment)|'
  r'/\s*(?:syringe|unit|ml|session)))?)',
  caseSensitive: false,
);

List<ExtractedPriceEvidence> _namedMenuRowsFromText(
  String text,
  String sourceUrl,
) {
  final t = text.replaceAll('\u00a0', ' ').trim();
  if (t.length < 8) return const [];
  if (_looksLikeTypicalMarketSnippet(t) && countPriceLikeAmounts(t) <= 2) {
    return const [];
  }
  if (cachedRegExp(
    r'\b(?:offering|clinics? that|ridiculously|procedure starts|'
    r'typically last|consultation)\b',
    caseSensitive: false,
  ).hasMatch(t)) {
    return const [];
  }
  final out = <ExtractedPriceEvidence>[];
  for (final m in _kNamedMenuPrice.allMatches(t)) {
    var label = (m.group(1) ?? '').trim();
    label = label
        .replaceAll(cachedRegExp(r'^[·•\-–—*]+|[·•\-–—*]+$'), '')
        .trim();
    final priceRaw = (m.group(2) ?? '').trim();
    if (label.length < 3 || priceRaw.isEmpty) continue;
    if (label.split(cachedRegExp(r'\s+')).length > 8) continue;
    if (_looksLikeTypicalMarketSnippet('$label $priceRaw')) continue;
    if (looksLikeCommerceChromeLabel(label)) continue;
    if (cachedRegExp(
      r'^(?:from|starting|starts?|and|with|or)$',
      caseSensitive: false,
    ).hasMatch(label)) {
      continue;
    }
    if (!_looksLikeProcedureLabel(label)) continue;
    final parsed = parsePriceText(priceRaw);
    if (parsed == null || parsed.priceMin <= 0) continue;
    out.add(
      ExtractedPriceEvidence(
        rawProcedureText: label,
        rawPriceText: priceRaw,
        priceMin: parsed.priceMin,
        priceMax: parsed.priceMax,
        currency: parsed.currency,
        sourceUrl: sourceUrl,
        extractionMethod: PriceExtractionMethod.listItem,
        rawEvidence: shrinkEvidenceToProcedureAndPrice(
          block: t,
          procedure: label,
          priceRaw: priceRaw,
        ),
        confidence: 0.86,
        priceType: parsed.priceType,
        unit: parsed.unit,
        quantity: parsed.quantity,
      ),
    );
  }
  return out;
}

bool _isGenericSectionHeading(String raw) {
  return looksLikeCatalogSectionHeading(raw);
}

/// Index each parent's preceding headings once per parse. Walking backwards
/// through every sibling for every menu row grows quadratically (and sibling
/// lookup itself scans the child list). Large menus must stay linear here.
class _PriceHeadingContext {
  final _preceding = <Element, Map<Element, String>>{};

  String nearest(Element el, {required int maxDepth}) {
    Element? cur = el;
    for (var depth = 0; depth < maxDepth && cur != null; depth++) {
      final parent = cur.parent;
      if (parent == null) break;
      final index = _preceding.putIfAbsent(parent, () {
        final result = <Element, String>{};
        var heading = '';
        for (final child in parent.children) {
          result[child] = heading;
          final name = child.localName ?? '';
          if (name.length == 2 &&
              name[0] == 'h' &&
              '123456'.contains(name[1])) {
            final text = _visibleText(child);
            if (_looksLikeProcedureLabel(text) &&
                !_isGenericSectionHeading(text)) {
              heading = text;
            }
          }
        }
        return result;
      });
      final heading = index[cur] ?? '';
      if (heading.isNotEmpty) return heading;
      cur = parent;
    }
    return '';
  }
}

String _nearestCurrencyHint(Element el) {
  Element? cur = el;
  for (var i = 0; i < 8; i++) {
    if (cur == null) break;
    if (cur.localName == 'table') {
      final headerBits = <String>[
        for (final node in [
          cur.querySelector('caption'),
          cur.querySelector('thead'),
          ...cur.querySelectorAll('th'),
        ])
          if (node != null) _visibleText(node),
      ];
      // "Cost (AED)" is often a bold <td> in the first body row, not <th>.
      final firstRow = cur.querySelector('tr');
      if (firstRow != null) headerBits.add(_visibleText(firstRow));
      final blob = headerBits.join(' ').toLowerCase();
      if (cachedRegExp(r'\b(?:aed|dirham|درهم|د\.إ)\b').hasMatch(blob)) {
        return 'AED';
      }
      if (cachedRegExp(r'€|\beuros?\b|\beur\b').hasMatch(blob) &&
          !cachedRegExp(r'\b(?:lei|ron)\b').hasMatch(blob)) {
        return 'EUR';
      }
      if (cachedRegExp(r'\b(?:lei|ron)\b').hasMatch(blob) &&
          !cachedRegExp(r'€|\beuros?\b|\beur\b').hasMatch(blob)) {
        return 'RON';
      }
    }
    cur = cur.parent;
  }
  return '';
}

List<ExtractedPriceEvidence> _extractHeadingsWithPrices(
  Document doc,
  String sourceUrl,
) {
  final out = <ExtractedPriceEvidence>[];
  for (final el in doc.querySelectorAll('title, h1, h2, h3, h4, h5, h6, p')) {
    final text = _visibleText(el);
    if (text.length < 10 || text.length > 280) continue;
    if (!_kPriceLike.hasMatch(text)) continue;
    final parsed = parsePriceText(text);
    if (parsed == null || parsed.priceMin <= 0) continue;
    if (parsed.currency.isEmpty) continue;
    var procedure = text;
    final cut = cachedRegExp(
      r'\s*(?:[:–—-]\s*)?(?:între|intre|de la|from|desde|'
      r'porneste(?:\s+de\s+la)?|pornește(?:\s+de\s+la)?|'
      r'începe(?:\s+de\s+la)?|incepe(?:\s+de\s+la)?)\s*[€£$]?\s*\d',
      caseSensitive: false,
    ).firstMatch(text);
    if (cut != null && cut.start >= 3) {
      procedure = text.substring(0, cut.start).trim();
    }
    if (!_looksLikeProcedureLabel(procedure)) continue;
    out.add(
      ExtractedPriceEvidence(
        rawProcedureText: procedure,
        rawPriceText: _listedRawPriceText(text, parsed),
        priceMin: parsed.priceMin,
        priceMax: parsed.priceMax,
        currency: parsed.currency,
        sourceUrl: sourceUrl,
        extractionMethod: PriceExtractionMethod.domBlock,
        rawEvidence: text,
        confidence: 0.95,
        priceType: parsed.priceType,
        unit: parsed.unit,
        quantity: parsed.quantity,
      ),
    );
  }
  return out;
}

/// Adjacent heading pairs: procedure title in one `h*` / title widget, fee in
/// the next. Common on Elementor / WCF / spa builders worldwide where the
/// amount is never on the same node as the treatment name.
List<ExtractedPriceEvidence> _extractAdjacentHeadingPricePairs(
  Document doc,
  String sourceUrl,
) {
  final out = <ExtractedPriceEvidence>[];
  final headings = doc.querySelectorAll(
    'h1, h2, h3, h4, h5, h6, .wcf--title, [class*="price-title"], '
    '[class*="service-title"], [class*="treatment-title"]',
  );
  if (headings.length < 2) return out;
  final barePrice = cachedRegExp(
    r'^(?:from|de\s+la|desde|a\s+partir\s+de)?\s*'
    r'[€£$]?\s*\d{1,6}(?:[.,]\d{2,3})?\s*'
    r'(?:€|eur|euro|£|gbp|\$|usd|ron|lei|lekë|leke|lek|all|aed|try|tl)?\s*$',
    caseSensitive: false,
  );
  final ordinalOnly = cachedRegExp(r'^\d{1,2}[.)]?$');
  final ctaNoise = cachedRegExp(
    r'^(?:book|book\s+now|lini\s+nj[eë]\s+takim|appointment|'
    r'regjistrimin|online|contact|more|learn\s+more|read\s+more|'
    r'cmimi\s+sipas|çmimi\s+sipas|on\s+request)$',
    caseSensitive: false,
  );

  for (var i = 0; i < headings.length - 1; i++) {
    final labelRaw = _visibleText(headings[i]).replaceAll('\u00a0', ' ').trim();
    if (labelRaw.length < 3 || labelRaw.length > 120) continue;
    if (ordinalOnly.hasMatch(labelRaw)) continue;
    if (ctaNoise.hasMatch(labelRaw)) continue;
    if (barePrice.hasMatch(labelRaw)) continue;
    if (looksLikeBarePriceLabel(labelRaw)) continue;
    if (!_looksLikeProcedureLabel(labelRaw)) continue;
    if (_isGenericSectionHeading(labelRaw)) continue;

    // Skip ordinal / CTA noise between label and fee.
    String? priceRaw;
    for (var j = i + 1; j < headings.length && j <= i + 3; j++) {
      final cand = _visibleText(headings[j]).replaceAll('\u00a0', ' ').trim();
      if (cand.isEmpty) continue;
      if (ordinalOnly.hasMatch(cand) || ctaNoise.hasMatch(cand)) continue;
      if (!barePrice.hasMatch(cand)) break;
      priceRaw = cand;
      break;
    }
    if (priceRaw == null) continue;
    final parsed = parsePriceText(priceRaw);
    if (parsed == null || parsed.priceMin <= 0) continue;
    if (parsed.currency.isEmpty &&
        !cachedRegExp(
          r'[€£$]|eur|lei|ron|lek',
          caseSensitive: false,
        ).hasMatch(priceRaw)) {
      continue;
    }
    out.add(
      ExtractedPriceEvidence(
        rawProcedureText: labelRaw,
        rawPriceText: _listedRawPriceText(priceRaw, parsed),
        priceMin: parsed.priceMin,
        priceMax: parsed.priceMax >= parsed.priceMin
            ? parsed.priceMax
            : parsed.priceMin,
        currency: parsed.currency.isNotEmpty ? parsed.currency : 'EUR',
        sourceUrl: sourceUrl,
        extractionMethod: PriceExtractionMethod.domBlock,
        rawEvidence: '$labelRaw $priceRaw',
        confidence: 0.93,
        priceType: parsed.priceType,
        unit: parsed.unit,
        quantity: parsed.quantity,
      ),
    );
  }
  return out;
}

/// Procedure label in one block + "Pret 1500 Lei" in a tight sibling/child.
List<ExtractedPriceEvidence> _extractProcedurePretSiblingPairs(
  Document doc,
  String sourceUrl,
  _PriceHeadingContext headingContext,
) {
  final out = <ExtractedPriceEvidence>[];
  final pretRe = cachedRegExp(
    r'\b(?:pret|preț|tarif|price|cost)\b\s*[:\-]?\s*'
    r'((?:from|de\s+la|desde)?\s*'
    r'(?:ron|lei|eur|€|£|\$)?\s*\d[\d.,\s]*\s*(?:ron|lei|eur|€|£|\$)?)',
    caseSensitive: false,
  );
  final containers = <Element>[
    ...doc.querySelectorAll('li'),
    ...doc.querySelectorAll('tr'),
    ...doc.querySelectorAll('article'),
    ...doc.querySelectorAll('div'),
  ];
  final seen = <Element>{};
  var walks = 0;
  for (final el in containers) {
    if (!seen.add(el)) continue;
    walks++;
    if (walks > 400) break;
    final text = _visibleText(el);
    if (text.length < 12 || text.length > 400) continue;
    final pret = pretRe.firstMatch(text);
    if (pret == null) continue;
    final priceRaw = (pret.group(1) ?? '').trim();
    final parsed = parsePriceText(priceRaw);
    if (parsed == null || parsed.priceMin <= 0) continue;
    if (parsed.currency.trim().isEmpty &&
        !cachedRegExp(
          r'\b(?:ron|lei|eur|€|£|\$)\b',
          caseSensitive: false,
        ).hasMatch(priceRaw) &&
        !cachedRegExp(
          r'\b(?:ron|lei|eur|€|£|\$)\b',
          caseSensitive: false,
        ).hasMatch(text)) {
      continue;
    }
    var procedure = text.substring(0, pret.start).trim();
    procedure = procedure
        .replaceAll(cachedRegExp(r'[\s\-–—:|]+$'), '')
        .replaceAll(cachedRegExp(r'\s+'), ' ')
        .trim();
    if (procedure.length < 4) {
      procedure = headingContext.nearest(el, maxDepth: 12);
    }
    if (procedure.length < 4) continue;
    if (looksLikeBarePriceLabel(procedure)) continue;
    out.add(
      ExtractedPriceEvidence(
        rawProcedureText: procedure,
        rawPriceText: priceRaw,
        priceMin: parsed.priceMin,
        priceMax: parsed.priceMax >= parsed.priceMin
            ? parsed.priceMax
            : parsed.priceMin,
        currency: parsed.currency.isNotEmpty
            ? parsed.currency
            : (cachedRegExp(
                    r'\b(?:ron|lei)\b',
                    caseSensitive: false,
                  ).hasMatch(text)
                  ? 'RON'
                  : parsed.currency),
        sourceUrl: sourceUrl,
        extractionMethod: PriceExtractionMethod.domBlock,
        rawEvidence: text,
        confidence: 0.96,
        priceType: parsed.priceType,
        unit: parsed.unit,
        quantity: parsed.quantity,
      ),
    );
  }
  return out;
}

List<ExtractedPriceEvidence> _extractLabeledCostFacts(
  Document doc,
  String sourceUrl,
  _PriceHeadingContext headingContext,
) {
  final out = <ExtractedPriceEvidence>[];
  final pageHeading = _pageProcedureHeading(doc, sourceUrl);
  final blocks = <Element>[
    ...doc.querySelectorAll('li'),
    ...doc.querySelectorAll('p'),
    ...doc.querySelectorAll('td'),
    ...doc.querySelectorAll('dd'),
    ...doc.querySelectorAll('span'),
    ...doc.querySelectorAll('div'),
  ];
  final seenEl = <Element>{};
  var genericWalks = 0;
  for (final el in blocks) {
    if (!seenEl.add(el)) continue;
    if (_hasBlockChild(el)) continue;
    if (el.localName == 'div' || el.localName == 'span') {
      genericWalks++;
      if (genericWalks > _kMaxGenericBlockWalks) continue;
    }
    final text = _visibleText(el);
    if (text.length < 8 || text.length > 240) continue;
    final labeled = _labeledCostQuote(text);
    if (labeled == null) continue;
    final parsed = parsePriceText(labeled);
    if (parsed == null || parsed.priceMin <= 0) continue;
    var procedure = headingContext.nearest(el, maxDepth: 12);
    if (procedure.isEmpty || looksLikeBarePriceLabel(procedure)) {
      procedure = pageHeading;
    }
    if (procedure.isEmpty) {
      procedure = _procedureHintFromUrl(sourceUrl);
    }
    if (procedure.length < 3) continue;
    out.add(
      ExtractedPriceEvidence(
        rawProcedureText: procedure,
        rawPriceText: labeled,
        priceMin: parsed.priceMin,
        priceMax: parsed.priceMax >= parsed.priceMin
            ? parsed.priceMax
            : parsed.priceMin,
        currency: parsed.currency,
        sourceUrl: sourceUrl,
        extractionMethod: PriceExtractionMethod.listItem,
        rawEvidence: text,
        confidence: 0.97,
        priceType: parsed.priceType,
        unit: parsed.unit,
        quantity: parsed.quantity,
      ),
    );
  }
  return out;
}

String? _labeledCostQuote(String text) {
  final t = text.replaceAll('\u00a0', ' ').trim();
  if (!looksLikeClinicLabeledCostFact(t) &&
      !cachedRegExp(
        r'\b(?:pret|preț|tarif|price|cost)\b',
        caseSensitive: false,
      ).hasMatch(t)) {
    return null;
  }
  final labeled = cachedRegExp(
    r'^(?:[\-–—*•]\s*)?(?:cost|price|fee|pret|preț|tarif|starting(?:\s+price)?)\s*[:\-]?\s*(.+)$',
    caseSensitive: false,
  ).firstMatch(t);
  if (labeled != null) {
    final rest = (labeled.group(1) ?? '').trim();
    if (parsePriceText(rest) != null) return rest;
  }
  // "Pret 1500 Lei" / "Preț: 1500 RON" mid-string.
  final inline = cachedRegExp(
    r'\b(?:pret|preț|tarif|price|cost)\b\s*[:\-]?\s*'
    r'((?:from|de\s+la|desde)?\s*'
    r'(?:ron|lei|eur|€|£|\$)?\s*\d[\d.,\s]*\s*(?:ron|lei|eur|€|£|\$)?)',
    caseSensitive: false,
  ).firstMatch(t);
  if (inline != null) {
    final rest = (inline.group(1) ?? '').trim();
    if (parsePriceText(rest) != null) return rest;
  }
  final starts = cachedRegExp(
    r'(?:starts?\s+from|starting(?:\s+from)?)\s+'
    r'(?:aed|usd|eur|gbp|€|£|\$|درهم|د\.إ)\s*\d[\d.,]*'
    r'(?:\s*(?:to|–|—|-)\s*'
    r'(?:aed|usd|eur|gbp|€|£|\$|درهم|د\.إ)?\s*\d[\d.,]*'
    r'(?:\s*(?:aed|usd|eur|gbp|€|£|\$|درهم|د\.إ))?)?'
    r'(?:\s*(?:per\s+ml|\/\s*ml))?',
    caseSensitive: false,
  ).firstMatch(t);
  return starts?.group(0)?.trim();
}

String _pageProcedureHeading(Document doc, String sourceUrl) {
  for (final sel in ['h1', 'title', 'h2']) {
    for (final el in doc.querySelectorAll(sel)) {
      final t = _visibleText(el);
      if (_looksLikeProcedureLabel(t) && !_isGenericSectionHeading(t)) {
        return t;
      }
    }
  }
  return _procedureHintFromUrl(sourceUrl);
}

String _procedureHintFromUrl(String sourceUrl) {
  try {
    final path = Uri.parse(
      sourceUrl.contains('://') ? sourceUrl : 'https://$sourceUrl',
    ).path;
    return path.replaceAll(cachedRegExp(r'[/_\-]+'), ' ').trim();
  } catch (_) {
    return '';
  }
}

String _withSectionContext(
  Element el,
  String procedure,
  _PriceHeadingContext headingContext,
) {
  if (procedure.trim().isEmpty) return procedure;
  if (looksLikeCatalogSectionHeading(procedure) &&
      !looksLikeRealTreatmentLabel(procedure)) {
    return procedure;
  }
  final heading = headingContext.nearest(el, maxDepth: 10);
  if (heading.isEmpty) return procedure;
  if (looksLikeCatalogSectionHeading(heading)) return procedure;
  if (procedure.toLowerCase().contains(heading.toLowerCase())) return procedure;
  return '$heading · $procedure';
}

bool _looksLikeProcedureLabel(String raw) {
  final t = raw.trim();
  if (t.length < 3 || t.length > 140) return false;
  if (!_hasLetter(t)) return false;
  if (looksLikeBarePriceLabel(t)) return false;
  if (looksLikePublishedPriceUnitLabel(t)) return false;
  if (looksLikeCommerceChromeLabel(t)) return false;
  if (looksLikePriceMenuHeadingOnly(t)) return false;
  if (cachedRegExp(r'^\d[\d.,\s]*\s*[€£$]?\s*$').hasMatch(t)) return false;
  if (looksLikeRawScrapedProcedureTitle(t)) return false;
  return true;
}

/// WooCommerce / shop chrome that must never become a procedure name or brand.
bool looksLikeCommerceChromeLabel(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').trim().toLowerCase();
  if (t.isEmpty) return false;
  if (cachedRegExp(
    r'^(sale!?|on\s*sale|hot!?|new!?|promo!?|offer!?|oferta!?|'
    r'description|descripcion|descripci[oó]n|uncategorized|uncategorised|'
    r'related products|you may also like|add to cart|book now|book now\s*>|'
    r'know more|know more\s*>|quantity|category|categories|sku|'
    r'in stock|out of stock|original price was|current price is)$',
    caseSensitive: false,
  ).hasMatch(t)) {
    return true;
  }
  if (t == 'sale' || t.startsWith('sale!') || t == 'onsale') return true;
  if (t.contains('book now') && t.contains('know more')) return true;
  if (looksLikeFinancingOrPaymentHeading(t)) return true;
  if (looksLikeProcedureLabelChromeFragment(t)) return true;
  return false;
}

/// CTA / promo tails glued onto a real menu name ("Your saving", "Book Now").
bool looksLikeProcedureLabelChromeFragment(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').trim().toLowerCase();
  if (t.isEmpty) return false;
  return cachedRegExp(
    r'^(book\s*now|know\s*more|add\s+to\s+cart|shop\s*now|buy\s*now|'
    r'your\s+saving|you\s+save|save\s+now|saving|sale!?|offer!?)$',
    caseSensitive: false,
  ).hasMatch(t);
}

/// Drop "Book Now" / "Your saving" so cards show the treatment, not the button.
String stripExploreProcedureLabelChrome(String raw) {
  var t = raw.replaceAll('\u00a0', ' ').trim();
  if (t.isEmpty) return '';
  t = t.replaceAll(
    cachedRegExp(
      r'[\s·|,;:]+(?:book\s*now|know\s*more|add\s+to\s+cart|shop\s*now|'
      r'buy\s*now|your\s+saving|you\s+save|save\s+now)\s*$',
      caseSensitive: false,
    ),
    '',
  );
  t = t.replaceAll(
    cachedRegExp(
      r'^(?:book\s*now|know\s*more|your\s+saving|you\s+save)\s*[:·|-]\s*',
      caseSensitive: false,
    ),
    '',
  );
  return t.trim();
}

/// Frequency / section copy glued onto a menu row
/// ("depending on provider discretion PRICING FACE VI PEEL").
String stripSurroundingPageCopyFromProcedureTitle(String raw) {
  var t = raw
      .replaceAll('\u00a0', ' ')
      .replaceAll(cachedRegExp(r'\s+'), ' ')
      .trim();
  if (t.isEmpty) return '';
  t = t.replaceAll(
    cachedRegExp(
      r'(?:every\s+\d+\s*(?:to|-|–|—)\s*\d+\s+weeks?,?\s*)?'
      r'depending on (?:provider|physician|doctor|practitioner) discretion',
      caseSensitive: false,
    ),
    ' ',
  );
  t = t.replaceAll(
    cachedRegExp(
      r'\bevery\s+\d+\s*(?:to|-|–|—)\s*\d+\s+weeks?\b',
      caseSensitive: false,
    ),
    ' ',
  );
  t = t.replaceAll(
    cachedRegExp(r'\bfrequency\s*:?', caseSensitive: false),
    ' ',
  );
  t = t.replaceAll(cachedRegExp(r'\s+'), ' ').trim();
  t = t.replaceFirst(
    cachedRegExp(
      r'^(?:pricing|prices|price|our pricing|our prices)\s+',
      caseSensitive: false,
    ),
    '',
  );
  t = t.replaceAll(
    cachedRegExp(
      r'\b(?:pricing|prices|price)\s+(?=face\b|vi\s*peel\b|chemical\b)',
      caseSensitive: false,
    ),
    '',
  );
  return t.replaceAll(cachedRegExp(r'\s+'), ' ').trim();
}

/// Arabic/Greek/Cyrillic menus have no Latin letters — still real labels.
bool _hasLetter(String raw) =>
    cachedRegExp(r'[A-Za-zÀ-ÿ\u0370-\u04ff\u0600-\u06ff]').hasMatch(raw);

/// True when this node wraps other wrappers (typical spa/peel menus).
/// Checks only two child levels — never walks the whole subtree.
bool _isDeepLayoutWrapper(Element el) {
  for (final child in el.children) {
    final n = child.localName;
    if (n == 'ul' || n == 'ol' || n == 'table') return true;
    if (n != 'div' && n != 'section' && n != 'article') continue;
    for (final g in child.children) {
      final gn = g.localName;
      if (gn == 'div' ||
          gn == 'ul' ||
          gn == 'ol' ||
          gn == 'section' ||
          gn == 'article' ||
          gn == 'li') {
        return true;
      }
    }
  }
  return false;
}

/// Leaf-only walk for labeled cost facts. Nested cards are handled elsewhere.
bool _hasBlockChild(Element el) {
  for (final child in el.children) {
    switch (child.localName) {
      case 'div':
      case 'ul':
      case 'ol':
      case 'table':
      case 'section':
      case 'article':
      case 'li':
      case 'p':
        return true;
    }
  }
  return false;
}

String _visibleText(Node node) {
  if (node is Text)
    return node.text.replaceAll(cachedRegExp(r'\s+'), ' ').trim();
  if (node is! Element) return '';
  if (node.localName == 'script' ||
      node.localName == 'style' ||
      node.localName == 'noscript') {
    return '';
  }
  final buf = StringBuffer();
  for (final child in node.nodes) {
    final t = _visibleText(child);
    if (t.isEmpty) continue;
    if (buf.isNotEmpty) buf.write(' ');
    buf.write(t);
  }
  return buf.toString().replaceAll(cachedRegExp(r'\s+'), ' ').trim();
}

List<ExtractedPriceEvidence> _extractPriceEvidenceInBackground(
  ({String html, String sourceUrl}) input,
) => extractPriceEvidence(html: input.html, sourceUrl: input.sourceUrl);

/// Session/request cache: one parse per source URL.
class ExploreHtmlPriceParseCache {
  ExploreHtmlPriceParseCache._();
  static final ExploreHtmlPriceParseCache instance =
      ExploreHtmlPriceParseCache._();

  /// Pages kept per session. A city sweep touches 40+ URLs and each entry
  /// holds up to [kExploreMaxHtmlParseChars]; without a bound, switching pills
  /// grew this to tens of megabytes and every later search paid for the GC.
  static const int maxCachedPages = 80;

  final Map<String, String> htmlByUrl = {};
  final Map<String, List<ExtractedPriceEvidence>> evidenceByUrl = {};
  final Map<String, Future<List<ExtractedPriceEvidence>>> _warmInFlight = {};
  final List<String> _lru = [];

  /// All remembered evidence a clinic can read, with explicit discovery URLs
  /// first. Other clinics' pages must not delay this clinic's verification.
  List<String> urlsForHost({
    required String host,
    Iterable<String> sourceUrls = const [],
  }) {
    String normalizedHost(String raw) {
      final value = raw.trim().toLowerCase();
      if (value.isEmpty) return '';
      return (Uri.tryParse(value.contains('://') ? value : 'https://$value')
              ?.host ?? '')
          .replaceFirst(RegExp(r'^www\.'), '');
    }
    final wanted = normalizedHost(host);
    final urls = <String>{
      for (final raw in sourceUrls)
        if (raw.trim().isNotEmpty) raw.trim(),
    };
    if (wanted.isNotEmpty) {
      for (final url in htmlByUrl.keys) {
        final candidate = normalizedHost(url);
        if (candidate == wanted ||
            candidate.endsWith('.$wanted') ||
            wanted.endsWith('.$candidate') && candidate.isNotEmpty) {
          urls.add(url);
        }
      }
    }
    return urls.toList(growable: false);
  }

  void _touch(String url) {
    _lru.remove(url);
    _lru.add(url);
    while (_lru.length > maxCachedPages) {
      final drop = _lru.removeAt(0);
      htmlByUrl.remove(drop);
      evidenceByUrl.remove(drop);
    }
  }

  void rememberHtml(String url, String html) {
    if (url.isEmpty || html.isEmpty) return;
    // Cap stored HTML so later evidenceFor() parses stay bounded.
    final capped = explorePrepareHtmlForPriceParse(html);
    if (capped.isEmpty) return;
    final existing = htmlByUrl[url];
    if (existing != null) {
      if (existing == capped) {
        _touch(url);
        return;
      }
      // One URL arrives from several fetchers (plain HTTP capped at 12k, the
      // renderer, Firecrawl, Zyte). Replacing a full page with a shorter
      // re-fetch threw away the parse, so every duplicate verify re-walked
      // the DOM and re-logged the same rejects. Keep the richest copy.
      if (capped.length <= existing.length) {
        _touch(url);
        return;
      }
    }
    htmlByUrl[url] = capped;
    evidenceByUrl.remove(url);
    _touch(url);
  }

  List<ExtractedPriceEvidence> evidenceFor(String url) {
    final hit = evidenceByUrl[url];
    if (hit != null) {
      _touch(url);
      return hit;
    }
    final html = htmlByUrl[url];
    if (html == null || html.isEmpty) return const [];
    final rows = extractPriceEvidence(html: html, sourceUrl: url);
    evidenceByUrl[url] = rows;
    _touch(url);
    debugPrint('[GP EXTRACT] cached ${rows.length} evidence rows from $url');
    return rows;
  }

  List<ExtractedPriceEvidence> evidenceForHtml({
    required String html,
    required String sourceUrl,
  }) {
    rememberHtml(sourceUrl, html);
    return evidenceFor(sourceUrl);
  }

  /// Parse pending pages without blocking the UI isolate.
  ///
  /// Call this from an async step before the sync [evidenceFor] readers run;
  /// they then hit the cache instead of parsing on the frame thread.
  Future<void> warmEvidence(Iterable<String> urls) async {
    for (final url in urls) {
      if (url.isEmpty || evidenceByUrl.containsKey(url)) continue;
      final html = htmlByUrl[url];
      if (html == null || html.isEmpty) continue;
      final pending = _warmInFlight[url];
      if (pending != null) {
        await pending;
        continue;
      }
      // Parsing one page synchronously still blocks several frames even
      // when we yield between pages. Keep DOM and regex work off the frame
      // isolate; only immutable evidence comes back into this cache.
      final fut = compute(_extractPriceEvidenceInBackground, (
        html: html,
        sourceUrl: url,
      ), debugLabel: 'explore_price_parse');
      _warmInFlight[url] = fut;
      try {
        final rows = await fut;
        // A richer fetch may have replaced the page while we parsed the old
        // copy; that parse is stale, so drop it rather than cache it.
        if (htmlByUrl[url] == html) {
          evidenceByUrl[url] = rows;
          _touch(url);
          debugPrint('[GP EXTRACT] warmed ${rows.length} rows from $url');
        }
      } catch (e) {
        debugPrint('[GP EXTRACT] warm failed $url: $e');
      } finally {
        _warmInFlight.remove(url);
      }
    }
  }

  /// Every page held for this session that has not been parsed yet.
  ///
  /// The sync readers scan all cached pages for the clinic's host, so warming
  /// only the preferred URL still left the frame thread parsing the rest.
  Future<void> warmAllPending({int max = 12}) async {
    final pending = <String>[
      for (final url in htmlByUrl.keys)
        if (!evidenceByUrl.containsKey(url)) url,
    ];
    if (pending.isEmpty) return;
    await warmEvidence(pending.take(max));
  }

  void clear() {
    htmlByUrl.clear();
    evidenceByUrl.clear();
    _warmInFlight.clear();
    _lru.clear();
  }
}
