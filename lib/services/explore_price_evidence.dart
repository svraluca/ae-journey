import 'dart:convert';

import 'explore_regex_cache.dart';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'explore_price_sanity.dart';
import 'explore_clinic_identity.dart';
import 'explore_url_discovery.dart';
import 'explore_currency_tokens.dart';

/// How a clinic procedure price was read from HTML / structured data.
enum PriceExtractionMethod {
  jsonLd,
  schemaOffer,
  htmlTable,
  productCard,
  listItem,
  domBlock,
  wooCommerce,
  shopify,
  textProximity;

  String get wire => switch (this) {
    PriceExtractionMethod.jsonLd => 'jsonLd',
    PriceExtractionMethod.schemaOffer => 'schemaOffer',
    PriceExtractionMethod.htmlTable => 'html_table',
    PriceExtractionMethod.productCard => 'product_card',
    PriceExtractionMethod.listItem => 'list_item',
    PriceExtractionMethod.domBlock => 'dom_block',
    PriceExtractionMethod.wooCommerce => 'woocommerce',
    PriceExtractionMethod.shopify => 'shopify',
    PriceExtractionMethod.textProximity => 'text_proximity',
  };

  static PriceExtractionMethod? fromWire(String? raw) {
    switch ('$raw'.trim()) {
      case 'jsonLd':
      case 'json_ld':
        return PriceExtractionMethod.jsonLd;
      case 'schemaOffer':
      case 'schema_offer':
        return PriceExtractionMethod.schemaOffer;
      case 'html_table':
      case 'htmlTable':
        return PriceExtractionMethod.htmlTable;
      case 'product_card':
      case 'productCard':
        return PriceExtractionMethod.productCard;
      case 'list_item':
      case 'listItem':
        return PriceExtractionMethod.listItem;
      case 'dom_block':
      case 'domBlock':
        return PriceExtractionMethod.domBlock;
      case 'woocommerce':
      case 'wooCommerce':
        return PriceExtractionMethod.wooCommerce;
      case 'shopify':
        return PriceExtractionMethod.shopify;
      case 'text_proximity':
      case 'textProximity':
        return PriceExtractionMethod.textProximity;
      default:
        return null;
    }
  }
}

enum PriceType {
  fixed,
  from,
  range,
  approximate,
  sale,
  perArea,
  perUnit,
  unknown;

  String get wire => name;

  static PriceType fromWire(String? raw) {
    switch ('$raw'.trim().toLowerCase()) {
      case 'fixed':
        return PriceType.fixed;
      case 'from':
        return PriceType.from;
      case 'range':
        return PriceType.range;
      case 'approximate':
        return PriceType.approximate;
      case 'sale':
        return PriceType.sale;
      case 'perarea':
      case 'per_area':
        return PriceType.perArea;
      case 'perunit':
      case 'per_unit':
        return PriceType.perUnit;
      default:
        return PriceType.unknown;
    }
  }
}

enum PriceSourceType {
  officialClinic,
  marketplace,
  aggregator,
  searchSnippet;

  String get wire => switch (this) {
    PriceSourceType.officialClinic => 'official_clinic',
    PriceSourceType.marketplace => 'marketplace',
    PriceSourceType.aggregator => 'aggregator',
    PriceSourceType.searchSnippet => 'search_snippet',
  };

  bool get isTrustedByDefault => this == PriceSourceType.officialClinic;

  static PriceSourceType fromWire(String? raw) {
    switch ('$raw'.trim().toLowerCase()) {
      case 'official_clinic':
      case 'officialclinic':
        return PriceSourceType.officialClinic;
      case 'marketplace':
        return PriceSourceType.marketplace;
      case 'aggregator':
        return PriceSourceType.aggregator;
      case 'search_snippet':
      case 'searchsnippet':
        return PriceSourceType.searchSnippet;
      default:
        return PriceSourceType.officialClinic;
    }
  }
}

class ParsedPrice {
  const ParsedPrice({
    required this.priceMin,
    required this.priceMax,
    required this.currency,
    required this.priceType,
    this.unit = '',
    this.quantity,
  });

  final double priceMin;
  final double priceMax;
  final String currency;
  final PriceType priceType;

  /// `ml`, `syringe`, `area`, `zone`, `session`, `vial`, `package`, `graft`, …
  final String unit;

  /// Quantity beside the unit when present (e.g. `1` in `1 ml`).
  final double? quantity;
}

/// Literal procedure↔price pair taken from HTML / JSON-LD.
///
/// [priceMin] is always parsed from [rawPriceText] by deterministic code.
class ExtractedPriceEvidence {
  const ExtractedPriceEvidence({
    required this.rawProcedureText,
    required this.rawPriceText,
    required this.priceMin,
    required this.priceMax,
    required this.currency,
    required this.sourceUrl,
    required this.extractionMethod,
    required this.rawEvidence,
    required this.confidence,
    this.priceType = PriceType.unknown,
    this.sourceType = PriceSourceType.officialClinic,
    this.procedureFamily = '',
    this.procedureCanonical = '',
    this.evidenceHash = '',
    this.providerClinic = '',
    this.sourcePlatform = '',
    this.unit = '',
    this.quantity,
  });

  final String rawProcedureText;
  final String rawPriceText;
  final double priceMin;
  final double priceMax;
  final String currency;
  final String sourceUrl;
  final PriceExtractionMethod extractionMethod;
  final String rawEvidence;
  final double confidence;
  final PriceType priceType;
  final PriceSourceType sourceType;
  final String procedureFamily;
  final String procedureCanonical;
  final String evidenceHash;
  final String providerClinic;
  final String sourcePlatform;
  final String unit;
  final double? quantity;

  bool get hasUsablePrice =>
      priceMin > 0 &&
      rawPriceText.trim().isNotEmpty &&
      sourceUrl.trim().isNotEmpty;

  ExtractedPriceEvidence copyWith({
    String? rawProcedureText,
    String? rawPriceText,
    double? priceMin,
    double? priceMax,
    String? procedureFamily,
    String? procedureCanonical,
    String? evidenceHash,
    PriceSourceType? sourceType,
    String? providerClinic,
    String? sourcePlatform,
    double? confidence,
    String? unit,
    double? quantity,
  }) {
    return ExtractedPriceEvidence(
      rawProcedureText: rawProcedureText ?? this.rawProcedureText,
      rawPriceText: rawPriceText ?? this.rawPriceText,
      priceMin: priceMin ?? this.priceMin,
      priceMax: priceMax ?? this.priceMax,
      currency: currency,
      sourceUrl: sourceUrl,
      extractionMethod: extractionMethod,
      rawEvidence: rawEvidence,
      confidence: confidence ?? this.confidence,
      priceType: priceType,
      sourceType: sourceType ?? this.sourceType,
      procedureFamily: procedureFamily ?? this.procedureFamily,
      procedureCanonical: procedureCanonical ?? this.procedureCanonical,
      evidenceHash: evidenceHash ?? this.evidenceHash,
      providerClinic: providerClinic ?? this.providerClinic,
      sourcePlatform: sourcePlatform ?? this.sourcePlatform,
      unit: unit ?? this.unit,
      quantity: quantity ?? this.quantity,
    );
  }
}

class ProcedureLabelClassification {
  const ProcedureLabelClassification({
    required this.family,
    required this.canonical,
    required this.confidence,
    this.rejectReason = '',
  });

  final String family;
  final String canonical;
  final double confidence;
  final String rejectReason;

  bool get isRejected => rejectReason.isNotEmpty;
}

/// SHA-256 prefix so a verified price can be traced and reused.
String buildEvidenceHash({
  required String sourceUrl,
  required String rawProcedureText,
  required String rawPriceText,
}) {
  final raw =
      '${sourceUrl.trim()}|${rawProcedureText.trim()}|${rawPriceText.trim()}';
  return sha256.convert(utf8.encode(raw)).toString().substring(0, 24);
}

final _kRonEquivalentInParens = cachedRegExp(
  r'\(\s*\d[\d.\s]*\s*(?:lei|ron)\s*\)',
  caseSensitive: false,
);

final _kRonEquivalentAfterSlash = cachedRegExp(
  r'\s*[\/|,]\s*\d[\d.\s]*\s*(?:lei|ron)\b',
  caseSensitive: false,
);

/// Romanian menus print `7000€ (35000 lei)` or `154€ / 800 lei`.
/// The lei amount is FX, not a second price.
String _stripRonEquivalentBesideEuro(String raw) {
  var t = raw.replaceAll('\u00a0', ' ');
  final hasEuro =
      t.contains('€') ||
      cachedRegExp(r'\beuros?\b|\beur\b', caseSensitive: false).hasMatch(t);
  if (!hasEuro) return t;
  t = t.replaceAll(_kRonEquivalentInParens, ' ');
  t = t.replaceAll(_kRonEquivalentAfterSlash, ' ');
  return t.replaceAll(cachedRegExp(r'\s+'), ' ').trim();
}

const _kCurrencyBesideAmount =
    r'€|£|\$|₺|eur|euro|euros|usd|gbp|ron|lei|mdl|try|tl|pln|zł|bgn|лв|'
    r'aed|dirhams?|درهم|د\.إ';

/// Amounts written against a currency token, plus their range partners.
///
/// A clinic fee carries the currency; a list ordinal ("1. Paketa") and a
/// duration ("90 min") never do. Tirana peels rejected every myspatirana row
/// as `implausible_amount` because "1. Paketa 33€ 👉🏻 90 min" parsed as 1.
Set<double> _amountsBesideCurrency(String raw) {
  final out = <double>{};
  if (raw.isEmpty) return out;
  void add(String? token) {
    final n = parseLocaleNumber(token ?? '');
    if (n != null && n >= 1) out.add(n);
  }

  // Leading currency ("€60", "AED 1200"). The lookbehinds keep a *trailing*
  // symbol from claiming the next number: in "33€ 90 min" the € prices 33,
  // and 90 is the duration.
  for (final m in cachedRegExp(
    r'(?<!\d)(?<!\d )'
    '(?:$_kCurrencyBesideAmount)'
    r'\s{0,2}(\d[\d.,]*)',
    caseSensitive: false,
  ).allMatches(raw)) {
    add(m.group(1));
  }
  // Trailing currency also prices the range partner: "120 - 180 €" is both.
  for (final m in cachedRegExp(
    r'(\d[\d.,]*)(?:\s*(?:[-–—/]|to|or|pana\s+la|până\s+la)\s*(\d[\d.,]*))?'
    '\\s*(?:$_kCurrencyBesideAmount)',
    caseSensitive: false,
  ).allMatches(raw)) {
    add(m.group(1));
    add(m.group(2));
  }
  return out;
}

/// A numbered menu row ("1. Paketa …", "4) Peeling …") starts with its
/// position in the list, not its price. Requires trailing whitespace so a
/// decimal separator ("1.500 €") is never mistaken for an ordinal.
String _stripLeadingListOrdinal(String raw) {
  return raw.replaceFirst(cachedRegExp(r'^\s*\d{1,2}\s*[.)\]:]\s+(?=\D)'), '');
}

/// Time a treatment takes, never what it costs.
const _kDurationUnitAlt =
    r'min|mins|minute|minutes|minuta|minuti|minutat|dakika|dk|'
    r'ore|ora|orë|hour|hours|hrs|h|'
    r'zile|ditë|dite|day|days|jave|javë|week|weeks|saat|ساعة|دقيقة';

final _kDurationUnitAfterAmount = cachedRegExp(
  '^(?:$_kDurationUnitAlt)'
  r'\b',
  caseSensitive: false,
);

/// Digits glued into a brand token (`SKIN111`) are not prices.
/// Spaced phrases like `from 799` / `1 ml` must stay intact.
String stripClinicBrandNumericTokens(String raw) {
  var t = raw.replaceAllMapped(
    cachedRegExp(r'\b([A-Za-z][A-Za-z._-]{1,24})(\d{2,5})\b'),
    (m) => m.group(1) ?? '',
  );
  t = t.replaceAllMapped(
    cachedRegExp(
      r'\b(?:at\s+)([A-Za-z][A-Za-z._-]{1,24})\s+(\d{2,4})\b',
      caseSensitive: false,
    ),
    (m) => 'at ${m.group(1) ?? ''}',
  );
  return t;
}

/// Canonical numeric parser. Never ask an LLM to fix formatting.
ParsedPrice? parsePriceText(String raw) {
  final original = stripExplorePhoneContacts(stripClinicBrandNumericTokens(
    _stripRonEquivalentBesideEuro(raw),
  )).trim();
  if (original.isEmpty) return null;

  final currency = detectExploreCurrencyToken(original);
  final graftSessionQty = hairGraftSessionQuantity(original);
  // Amounts that carry the currency, read before the tokens are stripped for
  // number parsing. Used to keep an ordinal / duration from winning below.
  final pricedAmounts = _amountsBesideCurrency(original);
  var working = _stripLeadingListOrdinal(
    stripClinicBrandNumericTokens(
      stripDosageQuantityPhrases(stripGraftQuantityPhrases(original)),
    ),
  );

  if (looksLikePhoneNumber(original) ||
      looksLikeAddressNumber(original) ||
      looksLikeEmergencyOrHelpNumber(original)) {
    return null;
  }
  if (looksLikeGraftOrFollicleQuantity(original)) {
    return null;
  }
  // Implant projection ratios / bare decimals with no currency (1,00 · 1,12).
  if (currency.isEmpty &&
      cachedRegExp(r'^\s*\d{1,2}[,.]\d{2}\s*$').hasMatch(original)) {
    return null;
  }
  if (cachedRegExp(
        r'\b\d+\s*months?\b',
        caseSensitive: false,
      ).hasMatch(original) &&
      currency.isEmpty) {
    return null;
  }
  if (cachedRegExp(r'\d+\s*[-–—]\s*\d+\s*%').hasMatch(original) ||
      cachedRegExp(
        r'\d+\s*%\s*(less|off|daha\s+az)',
        caseSensitive: false,
      ).hasMatch(original)) {
    return null;
  }

  final perGraftQuote = looksLikePerGraftQuotedPrice(original);
  // Unit/quantity metadata must come from the original line — dosage stripping
  // removes "1 ml" so the fee can be parsed, but we still need that quantity.
  final unitQty = exploreParsePriceUnitQuantity(original);
  // "1 ml" in a procedure name is package quantity, not a /ml rate.
  // Only treat as per-unit when the source literally prices per/slash unit.
  final explicitPerUnit = cachedRegExp(
    r'(?:per|/)\s*(?:ml|cc|iu|unit|units|syringe|syringes|vial|مل|وحدات)\b',
    caseSensitive: false,
  ).hasMatch(original);
  final explicitPerArea = cachedRegExp(
    r'(?:per|/)\s*(?:area|areas|zone|zones|منطقة)\b',
    caseSensitive: false,
  ).hasMatch(original);
  ParsedPrice finish(ParsedPrice p) {
    var type = p.priceType;
    // Uncertainty belongs to the source amount, not unrelated page copy such
    // as an approximate treatment duration. Preserve numeric interval bounds.
    final roughAmount =
        cachedRegExp(
          r'\b(?:approximately|approx\.?|roughly|around|about|aproximadamente|aproximad[oa]s?|suele\s+rondar|ronda|en\s+torno\s+a)\s+(?:(?:los?|unos?|entre)\s+)?(?:[€£$]|EUR\s*|GBP\s*|USD\s*)?(\d[\d.,]*)',
          caseSensitive: false,
        ).allMatches(original).any((m) {
          final amount = parseLocaleNumber(m.group(1) ?? '');
          return amount != null && (amount - p.priceMin).abs() < 0.01;
        });
    if (roughAmount && type != PriceType.sale) type = PriceType.approximate;
    var unit = unitQty.unit;
    var qty = graftSessionQty ?? unitQty.quantity;
    if (type == PriceType.fixed || type == PriceType.from) {
      final u = unit;
      if (explicitPerArea &&
          (u == 'area' ||
              u == 'areas' ||
              u == 'zone' ||
              u == 'zones' ||
              u == 'منطقة')) {
        type = PriceType.perArea;
      } else if (explicitPerUnit &&
          (u == 'unit' ||
              u == 'units' ||
              u == 'iu' ||
              u == 'وحدات' ||
              u == 'ml' ||
              u == 'cc' ||
              u == 'مل' ||
              u == 'syringe' ||
              u == 'syringes')) {
        type = PriceType.perUnit;
      } else if (u == 'graft' || u == 'grafts') {
        if (perGraftQuote) {
          type = PriceType.perUnit;
        } else {
          unit = '';
          qty = graftSessionQty ?? unitQty.quantity;
        }
      } else if (!explicitPerUnit &&
          !explicitPerArea &&
          (u == 'ml' ||
              u == 'cc' ||
              u == 'مل' ||
              u == 'syringe' ||
              u == 'syringes' ||
              u == 'area' ||
              u == 'areas' ||
              u == 'zone' ||
              u == 'zones' ||
              u == 'منطقة')) {
        // Keep quantity metadata; do not flip exact/from → perUnit/perArea.
        type = type;
      }
    }
    return ParsedPrice(
      priceMin: p.priceMin,
      priceMax: p.priceMax,
      currency: p.currency,
      priceType: type,
      unit: unit,
      quantity: qty,
    );
  }

  var type = PriceType.fixed;
  final fromRe = cachedRegExp(
    r'(?:from|starts?\s+from|starts?\s+at|starting(?:\s+(?:at|from))?|desde|de\s+la|'
    r'a\s+partir\s+de|ab|od|'
    r'à\s+partir\s+de|porneste(?:\s+de\s+la)?|pornește(?:\s+de\s+la)?|'
    r'începe(?:\s+de\s+la)?|incepe(?:\s+de\s+la)?|'
    r"(?:['']?den|['']?dan)\s+ba[sş]layan|"
    r"(?:['']?den|['']?dan)\s+itibaren|"
    r'\bitibaren\b|'
    r'يبدأ من|تبدأ من|تبدا من)\b',
    caseSensitive: false,
  );
  final fromMatch = fromRe.firstMatch(working);
  if (fromMatch != null ||
      cachedRegExp(r'\d\s*\+\s*$').hasMatch(working.trim())) {
    type = PriceType.from;
  }
  if (fromMatch != null) {
    // English/prefix: "from 100". Turkish suffix: "100.000 TL'den başlayan"
    // — do not slice away the leading amount.
    final before = working.substring(0, fromMatch.start);
    if (!cachedRegExp(r'\d').hasMatch(before)) {
      working = working.substring(fromMatch.start);
    }
  }

  final saleDel = cachedRegExp(
    r'<del[^>]*>([\s\S]*?)</del>',
    caseSensitive: false,
  ).firstMatch(working);
  final saleIns = cachedRegExp(
    r'<ins[^>]*>([\s\S]*?)</ins>',
    caseSensitive: false,
  ).firstMatch(working);
  if (saleIns != null) {
    final active = parseLocaleNumber(_stripTags(saleIns.group(1) ?? ''));
    final originalAmt = saleDel == null
        ? null
        : parseLocaleNumber(_stripTags(saleDel.group(1) ?? ''));
    if (active != null && active > 0) {
      return finish(
        ParsedPrice(
          priceMin: active,
          priceMax: (originalAmt != null && originalAmt > active)
              ? originalAmt
              : active,
          currency: currency,
          priceType: originalAmt != null && originalAmt > active
              ? PriceType.sale
              : PriceType.fixed,
        ),
      );
    }
  }

  working = stripCurrencyTokensForNumberParse(
    working,
  ).replaceAll(cachedRegExp(r'\s+'), ' ').trim();
  // Turkish "100 bin TL" → 100000 before digit parse.
  working = working.replaceAllMapped(
    cachedRegExp(r'(\d[\d.,]*)\s*bin\b', caseSensitive: false),
    (m) {
      final n = parseLocaleNumber(m.group(1) ?? '');
      if (n == null) return m.group(0) ?? '';
      return '${(n * 1000).round()}';
    },
  );
  // WooCommerce / BG locales often emit "163 61 €" for European 163,61.
  // "33 90 min" is a fee plus a duration, not 33.90 — gluing them produced an
  // amount that then looked like a duration and the whole row was dropped.
  working = working.replaceAllMapped(
    cachedRegExp(
      r'\b(\d{1,6})\s+(\d{2})\b(?!\s*(?:'
      '$_kDurationUnitAlt'
      r')\b)'
      r'(?=\s*(?:€|eur|euro|euros|£|gbp|\$|usd|ron|lei|'
      r'bgn|лв|lv\.?|try|tl|aed|د\.?إ)?(?:\s|$|[^\d]))',
      caseSensitive: false,
    ),
    (m) => '${m.group(1)}.${m.group(2)}',
  );
  working = working.replaceAllMapped(
    cachedRegExp(r'\b(\d{1,3}(?:\s\d{3})+)\b'),
    (m) => (m.group(1) ?? '').replaceAll(' ', ''),
  );

  // Turkish "100.000 TL ile 150.000 TL arasında"
  final trRange = cachedRegExp(
    r'(\d[\d.,\s]*)\s*(?:TL|₺)?\s*ile\s+(\d[\d.,\s]*)\s*(?:TL|₺)?\s*aras[iı]nda',
    caseSensitive: false,
  ).firstMatch(working);
  if (trRange != null) {
    final lo = parseLocaleNumber(trRange.group(1) ?? '');
    final hi = parseLocaleNumber(trRange.group(2) ?? '');
    if (lo != null && hi != null && lo > 0 && hi >= lo) {
      return finish(
        ParsedPrice(
          priceMin: lo,
          priceMax: hi,
          currency: currency.isNotEmpty ? currency : 'TRY',
          priceType: PriceType.range,
        ),
      );
    }
  }

  final rangeRe = cachedRegExp(
    r'(\d[\d.,\s]*)\s*(?:–|—|-|to|until|hasta|pana\s+la|până\s+la|\ba\b|ile)\s*\+?\s*(\d[\d.,\s]*)',
    caseSensitive: false,
  );
  final range = rangeRe.firstMatch(working);
  if (range != null) {
    final lo = parseLocaleNumber(range.group(1) ?? '');
    final hi = parseLocaleNumber(range.group(2) ?? '');
    if (lo != null && hi != null && lo > 0 && hi >= lo) {
      return finish(
        ParsedPrice(
          priceMin: lo,
          priceMax: hi,
          currency: currency,
          priceType: PriceType.range,
        ),
      );
    }
  }

  final numRe = cachedRegExp(r'(?<![A-Za-z])\d[\d.,]*');
  var nums = <double>[];
  for (final m in numRe.allMatches(working)) {
    final after = working.substring(m.end).trimLeft();
    // Skip "1 ml" / "3 areas" quantity prefixes — not the clinic fee.
    if (cachedRegExp(
      r'^(ml|cc|iu|syringe|syringes|area|areas|zone|zones|session|sessions|'
      r'vial|vials|package|packages|graft|grafts|unit|units|unitate|unitati|'
      r'unități|ampoule|ampoules|sedinte|ședințe|sedințe|%|cm|mm|'
      r'مل|منطقة|جلسة|وحدات)\b',
      caseSensitive: false,
    ).hasMatch(after)) {
      continue;
    }
    final n = parseLocaleNumber(m.group(0) ?? '');
    if (n == null || n < 1) continue;
    // "90 min" / "2 ore" is how long the treatment runs. A fee that happens to
    // precede the word "min" keeps its currency, so it is never dropped here.
    if (_kDurationUnitAfterAmount.hasMatch(after) &&
        !pricedAmounts.contains(n)) {
      continue;
    }
    nums.add(n);
  }
  if (nums.isEmpty) return null;
  // The leading number is not the one the page prices: drop everything that
  // does not carry the currency ("Package 1: … – €60" is 60, not 1).
  if (pricedAmounts.isNotEmpty && !pricedAmounts.contains(nums.first)) {
    final priced = [
      for (final n in nums)
        if (pricedAmounts.contains(n)) n,
    ];
    if (priced.isNotEmpty) nums = priced;
  }
  if (type == PriceType.from || nums.length == 1) {
    return finish(
      ParsedPrice(
        priceMin: nums.first,
        priceMax: nums.first,
        currency: currency,
        priceType: type,
      ),
    );
  }
  if (nums.length >= 3) {
    return finish(
      ParsedPrice(
        priceMin: nums.first,
        priceMax: nums.first,
        currency: currency,
        priceType: PriceType.fixed,
      ),
    );
  }
  final lo = nums[0] <= nums[1] ? nums[0] : nums[1];
  final hi = nums[0] <= nums[1] ? nums[1] : nums[0];
  if (hi >= lo * 3) {
    return finish(
      ParsedPrice(
        priceMin: nums.first,
        priceMax: nums.first,
        currency: currency,
        priceType: PriceType.fixed,
      ),
    );
  }
  if (lo.round().abs().toString().length >= 8) return null;
  return finish(
    ParsedPrice(
      priceMin: lo,
      priceMax: hi,
      currency: currency,
      priceType: PriceType.range,
    ),
  );
}

/// Distinct amounts in a blob after currency tokens are stripped.
///
/// Dose ranges are stripped alongside graft counts: "$18.00 per unit. On
/// average, 40-50 units are used" publishes one price, not three, and callers
/// like [exploreEvidenceLooksLikeStitchedCatalogBlob] treat three amounts as a
/// stitched-together catalog and throw the row away.
int countPriceLikeAmounts(String raw) {
  var working = _stripLeadingListOrdinal(
    stripClinicBrandNumericTokens(
      stripDosageQuantityPhrases(
        stripGraftQuantityPhrases(raw.replaceAll('\u00a0', ' ')),
      ),
    ),
  );
  working = working
      .replaceAll(
        cachedRegExp(
          r'(?:€|eur|euro|euros|£|gbp|\$|usd|ron|lei|try|tl|pln|zł|aed|'
          r'dirhams?|درهم|د\.إ)',
          caseSensitive: false,
        ),
        ' ',
      )
      .replaceAll(cachedRegExp(r'\s+'), ' ')
      .trim();
  working = working.replaceAllMapped(
    cachedRegExp(r'\b(\d{1,3}(?:\s\d{3})+)\b'),
    (m) => (m.group(1) ?? '').replaceAll(' ', ''),
  );
  final pricedAmounts = _amountsBesideCurrency(raw);
  var n = 0;
  for (final m in cachedRegExp(r'(?<![A-Za-z])\d[\d.,]*').allMatches(working)) {
    final amount = parseLocaleNumber(m.group(0) ?? '');
    if (amount == null || amount < 1) continue;
    // How long the treatment takes is not a second quote. Spa-style menus
    // ("Peeling 33€ 👉🏻 90 min") counted two amounts, so the row failed the
    // single-price menu-line check and never became evidence at all.
    final after = working.substring(m.end).trimLeft();
    if (_kDurationUnitAfterAmount.hasMatch(after) &&
        !pricedAmounts.contains(amount)) {
      continue;
    }
    n += 1;
  }
  return n;
}

/// FAQ/SEO paragraphs list several figures; that is not one clinic quote.
bool exploreEvidenceLooksLikeStitchedCatalogBlob({
  required String rawPriceText,
  required String rawEvidence,
  required double priceMin,
  required String extractionMethod,
}) {
  if (!isWeakPriceExtractionMethod(extractionMethod)) return false;
  final source = rawEvidence.trim().length >= rawPriceText.trim().length
      ? rawEvidence
      : rawPriceText;
  final own = clinicOwnPublishedPriceWindow('$rawPriceText\n$rawEvidence');
  if (own != null && publishedAmountMatchesWindow(own, priceMin)) {
    return false;
  }
  return countPriceLikeAmounts(source) >= 3;
}

double? parseLocaleNumber(String raw) {
  var s = raw.replaceAll('\u00a0', ' ').trim();
  if (s.isEmpty) return null;
  s = s.replaceAll("'", '').replaceAll('’', '');
  s = s.replaceAll(cachedRegExp(r'[^\d.,\s]'), '');
  s = s.replaceAll(cachedRegExp(r'\s+'), '');
  if (s.isEmpty) return null;

  final hasComma = s.contains(',');
  final hasDot = s.contains('.');
  if (hasComma && hasDot) {
    if (s.lastIndexOf(',') > s.lastIndexOf('.')) {
      s = s.replaceAll('.', '').replaceAll(',', '.');
    } else {
      s = s.replaceAll(',', '');
    }
  } else if (hasComma) {
    if (cachedRegExp(r',\d{1,2}$').hasMatch(s) &&
        !cachedRegExp(r',\d{3}$').hasMatch(s)) {
      s = s.replaceAll(',', '.');
    } else if (cachedRegExp(r',\d{3}(?:\d{3})*$').hasMatch(s)) {
      s = s.replaceAll(',', '');
    } else {
      s = s.replaceAll(',', '.');
    }
  } else if (hasDot) {
    if (cachedRegExp(r'\.\d{3}(?:\d{3})*$').hasMatch(s) &&
        !cachedRegExp(r'\.\d{1,2}$').hasMatch(s)) {
      s = s.replaceAll('.', '');
    }
  }
  return double.tryParse(s);
}

String _stripTags(String raw) => raw
    .replaceAll(cachedRegExp(r'<[^>]+>'), ' ')
    .replaceAll(cachedRegExp(r'\s+'), ' ')
    .trim();

/// Serp / listing titles that are promotions or prices, not clinics.
bool isInvalidClinicIdentity(String name) =>
    clinicIdentityRejectReason(name) != null;

/// Blog/guide pages quote market ranges, not a clinic's own treatment menu.
bool isNonLiteralClinicPriceUrl(String sourceUrl) {
  final raw = sourceUrl.trim().toLowerCase();
  if (raw.isEmpty) return false;
  var path = raw;
  try {
    path = Uri.parse(
      raw.contains('://') ? raw : 'https://$raw',
    ).path.toLowerCase();
  } catch (_) {}
  if (path.contains('/blog/') ||
      path.contains('/article/') ||
      path.contains('/articles/') ||
      path.contains('/articole/') ||
      path.contains('/articulos/') ||
      path.contains('/artículos/') ||
      path.contains('/noticias/') ||
      path.contains('/stiri/') ||
      path.contains('/știri/') ||
      path.contains('/ghid/') ||
      path.contains('/guides/') ||
      path.contains('/guide/') ||
      path.contains('aftercare') ||
      path.contains('complete-guide') ||
      path.contains('complete-pricing-guide') ||
      path.contains('complete-price-guide') ||
      path.contains('complete-cost-guide') ||
      path.contains('complete-breakdown') ||
      path.contains('the-cost-of-') ||
      path.contains('cost-of-hair-transplant') ||
      path.contains('how-to-') ||
      path.contains('how-long') ||
      path.contains('/emergency') ||
      path.contains('emergency.html') ||
      path.contains('emergency-tips') ||
      path.contains('-template') ||
      path.contains('/template') ||
      path.contains('page-editor') ||
      raw.contains('preview_theme')) {
    return true;
  }
  if (looksLikeMarketEstimateDirectoryUrl(raw)) return true;
  // Generic market-guide / average-price URLs — never city allowlists.
  return cachedRegExp(
    r'cost-london|precio-medio|price-range|average-price|average-cost|'
    r'cat-costa|cat_costa|how-much-does|how-much-do|cuanto-cuesta|cât-costă|'
    r'market[-_]?average|typical[-_]?price|city[-_]?average|'
    r'london-prices|'
    r'glutathione|salmon-dna|iv-drip|migraine',
  ).hasMatch(raw);
}

/// Shrink a DOM/PDF text window to the smallest span that still contains
/// both the procedure label and the quoted price (never invents numbers).
String shrinkEvidenceToProcedureAndPrice({
  required String block,
  required String procedure,
  required String priceRaw,
}) {
  final text = block.replaceAll(cachedRegExp(r'\s+'), ' ').trim();
  if (text.isEmpty) return text;
  final proc = procedure.replaceAll(cachedRegExp(r'\s+'), ' ').trim();
  final price = priceRaw.replaceAll(cachedRegExp(r'\s+'), ' ').trim();
  if (proc.isEmpty || price.isEmpty) return text;
  final lo = text.toLowerCase();
  final procLo = proc.toLowerCase();
  final priceLo = price.toLowerCase();
  var pIdx = lo.indexOf(procLo);
  if (pIdx < 0 && procLo.length > 12) {
    pIdx = lo.indexOf(procLo.substring(0, 12));
  }
  var priceIdx = lo.indexOf(priceLo);
  if (priceIdx < 0) {
    final amount = cachedRegExp(r'\d[\d.,]*').firstMatch(priceLo)?.group(0);
    if (amount != null) priceIdx = lo.indexOf(amount);
  }
  if (pIdx < 0 || priceIdx < 0) return text;
  final start = pIdx < priceIdx ? pIdx : priceIdx;
  final endProc = (pIdx + proc.length).clamp(0, text.length);
  final endPrice = (priceIdx + price.length).clamp(0, text.length);
  final end = endProc > endPrice ? endProc : endPrice;
  if (end <= start || end > text.length) return text;
  final slice = text.substring(start, end).trim();
  return slice.length >= 8 ? slice : text;
}

/// Clinic-owned editorial ("/post/best-botox-in-dubai-reviews-and-prices").
/// Not a menu: a single listed amount is usable, brand ranges are not.
bool looksLikeClinicArticlePriceUrl(String sourceUrl) {
  final raw = sourceUrl.trim().toLowerCase();
  if (raw.isEmpty) return false;
  var path = raw;
  try {
    path = Uri.parse(
      raw.contains('://') ? raw : 'https://$raw',
    ).path.toLowerCase();
  } catch (_) {}
  for (final seg in const [
    '/post/',
    '/posts/',
    '/news/',
    '/insights/',
    '/resources/',
    '/magazine/',
    '/articles/',
    '/tips/',
    '/for-men/',
    '/for-women/',
    '/ask-the-expert/',
  ]) {
    if (path.contains(seg)) return true;
  }
  return cachedRegExp(
    r'/post/|/posts/|/news/|/insights/|/resources/|/magazine/|/tips/|'
    r'/articles?/|'
    r'complete-breakdown|complete-pricing-guide|complete-price-guide|'
    r'complete-cost-guide|the-cost-of-hair|'
    r'best-[a-z-]{2,40}-in-|top-\d+-|reviews-and-price|price-comparison|'
    r'/best-botox|/the-best-anti-wrinkle|/the-best-botox|'
    r'/for-men/|/ask-the-expert/',
  ).hasMatch(raw);
}

/// Gulf clinic CMSs keep current AED menus on `/en/` and leave `/ar/` on an
/// older campaign. Prefer the English twin when Google returned Arabic.
String exploreEnglishLocaleUrl(String sourceUrl) {
  final raw = sourceUrl.trim();
  if (raw.isEmpty) return raw;
  try {
    final uri = Uri.parse(raw.contains('://') ? raw : 'https://$raw');
    final segs = [
      for (final s in uri.pathSegments)
        if (s.trim().isNotEmpty) s,
    ];
    if (segs.isEmpty) return raw;
    if (segs.first.toLowerCase() != 'ar') return raw;
    final next = uri.replace(pathSegments: ['en', ...segs.skip(1)]);
    var out = next.toString();
    if (raw.endsWith('/') && !out.endsWith('/')) out = '$out/';
    return out;
  } catch (_) {
    return raw;
  }
}

/// When a clinic homepage is the English/default shell but the priced menu
/// lives on a language prefix (`/sq/`, `/ro/`, `/bg/`, …), prefer that twin.
///
/// Example: botoxtirana.com English shell vs `/sq/` which lists BioRePeel 70€.
String exploreLocalLocaleHomepageUrl(String sourceUrl, {required String lang}) {
  final raw = sourceUrl.trim();
  final l = lang.trim().toLowerCase();
  if (raw.isEmpty || l.isEmpty || l == 'en') return raw;
  // Only rewrite bare homepage / short paths — never rewrite a deep EN article.
  try {
    final uri = Uri.parse(raw.contains('://') ? raw : 'https://$raw');
    final segs = [
      for (final s in uri.pathSegments)
        if (s.trim().isNotEmpty) s,
    ];
    if (segs.isNotEmpty) {
      final first = segs.first.toLowerCase();
      // Already on a locale prefix.
      if (first == l ||
          first == 'en' ||
          first == 'ar' ||
          first == 'sq' ||
          first == 'ro' ||
          first == 'bg' ||
          first.length == 2) {
        if (first == 'en' && segs.length <= 1) {
          final next = uri.replace(pathSegments: [l]);
          var out = next.toString();
          if (!out.endsWith('/')) out = '$out/';
          return out;
        }
        return raw;
      }
      // Deep path — leave alone.
      if (segs.length > 1) return raw;
    }
    final next = uri.replace(pathSegments: [l]);
    var out = next.toString();
    if (!out.endsWith('/')) out = '$out/';
    return out;
  } catch (_) {
    return raw;
  }
}

/// "<treatment>-cost-in-<city>" and city "common prices" surgery guides.
/// These mix clinic rows with market prose — never treat as a dedicated menu.
bool looksLikeCityCostArticleUrl(String sourceUrl) {
  final raw = sourceUrl.trim().toLowerCase();
  if (raw.isEmpty) return false;
  var path = raw;
  try {
    path = Uri.parse(
      raw.contains('://') ? raw : 'https://$raw',
    ).path.toLowerCase();
  } catch (_) {}
  if (path.contains('/uncategorized/')) return true;
  return cachedRegExp(
    r'(?:cost|costs|price|prices|pricing)-in-[a-z][a-z-]{2,30}|'
    r'cost-of-[a-z][a-z-]{2,40}|'
    r'(?:cost|price)-\d{4}(?:/|$)|'
    r'-cost-london(?:/|$)|'
    r'cost-london|'
    r'london-prices|'
    r'plastic-surgery-cost|'
    r'plastic-surgery-price|'
    r'surgery-cost-in-|'
    r'surgery-prices?-in-|'
    r'common-prices?|'
    r'average-(?:cost|price)|'
    r'complete-pricing-guide|complete-price-guide|complete-cost-guide|'
    r'(?:^|/)botox-cost(?:/|$)',
  ).hasMatch(path);
}

/// Broad “plastic surgery / common prices in city” guides (not a treatment menu).
bool looksLikeGenericCitySurgeryGuideUrl(String sourceUrl) {
  final raw = sourceUrl.trim().toLowerCase();
  if (raw.isEmpty) return false;
  var path = raw;
  try {
    path = Uri.parse(
      raw.contains('://') ? raw : 'https://$raw',
    ).path.toLowerCase();
  } catch (_) {}
  return cachedRegExp(
    r'plastic-surgery-cost|'
    r'plastic-surgery-price|'
    r'surgery-cost-in-|'
    r'surgery-prices?-in-|'
    r'common-prices?|'
    r'average-(?:cost|price)|'
    r'cost-of-plastic-surgery',
  ).hasMatch(path);
}

/// "AED 750 to AED 1,800 per area" — a spread across brands or clinics.
bool exploreEvidenceQuotesPriceRange({
  required String rawProcedureText,
  required String rawPriceText,
  required double priceMin,
  required double priceMax,
}) {
  if (priceMin > 0 && priceMax > priceMin + 0.5) return true;
  final re = cachedRegExp(
    r'\d[\d.,]*\s*(?:aed|eur|euro|usd|gbp|ron|lei|try|€|£|\$|درهم)?\s*'
    r'(?:to|–|—|-|until|hasta|pana la|până la)\s*'
    r'(?:aed|eur|euro|usd|gbp|ron|lei|try|€|£|\$|درهم)?\s*\d',
    caseSensitive: false,
  );
  return re.hasMatch(rawProcedureText) || re.hasMatch(rawPriceText);
}

/// Generic price-list slugs used by clinic CMSs in every city.
/// Do not add per-clinic or per-city URLs here — probe these paths, then
/// follow priced links on the homepage.
bool looksLikePriceMenuUrl(String url) {
  final raw = url.trim().toLowerCase();
  if (raw.isEmpty) return false;
  var path = raw;
  try {
    path = Uri.parse(raw.contains('://') ? raw : 'https://$raw').path;
  } catch (_) {}
  return _pricePathRe(extra: const ['book-online']).hasMatch(path);
}

/// How a clinic names its price page, in every market Explore searches.
///
/// One list, because the URL scorers and the Firecrawl map query used to keep
/// separate copies and drift. Albanian (`cmimet`), Czech (`cenik`), Nordic
/// (`priser`), Dutch (`tarieven`), Balkan (`cenovnik`) and Greek were missing
/// entirely, so a Tirana or Belgrade price page scored zero and discovery
/// reported "no ranked urls" on sites that publish a full menu.
///
/// Language vocabulary only — never clinic names or amounts.
const kExplorePricePathWords = <String>[
  // English
  'prices', 'pricing', 'price-list', 'pricelist', 'price-guide', 'price-lists',
  'our-prices', 'treatment-prices', 'rates', 'fees', 'our-fees', 'tariff',
  // Romanian
  'preturi', 'prețuri', 'tarife', 'lista-de-preturi', 'lista-preturi',
  'preturi-injectari',
  // Spanish / Portuguese
  'precios', 'precos', 'preços', 'tarifas', 'tarifario', 'lista-de-precios',
  'tabla-de-precios', 'tabela-de-precos',
  // French
  'tarifs', 'nos-tarifs', 'prix', 'grille-tarifaire',
  // Italian
  'prezzi', 'tariffe', 'listino', 'listino-prezzi', 'tariffario',
  // German
  'preise', 'preisliste', 'kosten',
  // Albanian
  'cmimet', 'cmime', 'cmimi', 'çmimet', 'çmime', 'lista-e-cmimeve',
  // Turkish
  'fiyatlar', 'fiyat', 'ucretler', 'ücretler',
  // Polish / Czech / Slovak / Slovenian
  'cennik', 'ceny', 'cenik', 'ceník', 'cenovnik',
  // Serbian / Croatian / Bosnian
  'cjenik', 'cene', 'cijene',
  // Hungarian
  'arak', 'árak', 'arlista', 'árlista',
  // Dutch
  'tarieven', 'prijzen', 'prijs',
  // Nordic / Finnish
  'priser', 'prisliste', 'prislista', 'hinnat', 'hinnasto',
  // Greek
  'τιμές', 'τιμες', 'timokatalogos',
  // Cyrillic
  'цены', 'ціни', 'цени', 'ценоразпис',
  // Arabic
  'الأسعار', 'اسعار',
];

RegExp _pricePathRe({List<String> extra = const []}) {
  final words = <String>{
    ...kExplorePricePathWords,
    ...extra,
  }.map(RegExp.escape).join('|');
  return RegExp(
    '(?:^|/)(?:$words)'
    r'(?:/|$|\.|-)',
    caseSensitive: false,
  );
}

/// Official published menu — outranks booking widgets and treatment landings.
bool looksLikeOfficialPriceListUrl(String url) {
  final raw = url.trim().toLowerCase();
  if (raw.isEmpty) return false;
  var path = raw;
  try {
    path = Uri.parse(raw.contains('://') ? raw : 'https://$raw').path;
  } catch (_) {}
  if (cachedRegExp(r'book-online|/booking|/book-now').hasMatch(path))
    return false;
  if (cachedRegExp(r'special-?offers?|/offers?/|/deals?/').hasMatch(path)) {
    return false;
  }
  if (looksLikeCityCostArticleUrl(raw)) return false;
  return _pricePathRe(
    extra: const [
      'hair-transplant-cost',
      'cost-and-prices',
      'information-and-fees',
      'rhinoplasty-cost',
      'cost',
    ],
  ).hasMatch(path);
}

bool looksLikeBookingOrCheckoutUrl(String url) {
  final raw = url.trim().toLowerCase();
  if (raw.isEmpty) return false;
  var path = raw;
  try {
    path = Uri.parse(raw.contains('://') ? raw : 'https://$raw').path;
  } catch (_) {}
  return cachedRegExp(
    r'(?:^|/)(?:book-online|booking|book-now|book-now|reserve|reservation)(?:/|$)',
    caseSensitive: false,
  ).hasMatch(path);
}

bool looksLikeSpecialOfferUrl(String url) {
  final raw = url.trim().toLowerCase();
  if (raw.isEmpty) return false;
  return cachedRegExp(
    r'special-?offers?|/(?:offers|deals|promotions?|promo)(?:/|$)',
    caseSensitive: false,
  ).hasMatch(raw);
}

String _exploreBareHost(String domain) {
  var host = domain.trim().toLowerCase();
  if (host.isEmpty) return '';
  host = host.replaceFirst(cachedRegExp(r'^https?://'), '');
  host = host.split('/').first;
  host = host.replaceFirst(cachedRegExp(r'^www\.'), '');
  return host;
}

/// Locale price-page paths for [domain]. Same slugs work in Bucharest,
/// Barcelona, Paris — 404s are cheap; a hardcoded clinic URL is not.
List<String> explorePriceMenuPathsForHost(String domain) {
  final host = _exploreBareHost(domain);
  if (host.endsWith('.ro')) {
    return const [
      '/preturi',
      '/preturi.php',
      '/preturi.html',
      '/tarife',
      '/lista-de-preturi',
      '/lista-preturi',
      '/pages/preturi-injectari',
      '/prices',
    ];
  }
  if (host.endsWith('.es') ||
      host.endsWith('.mx') ||
      host.endsWith('.ar') ||
      host.endsWith('.cl') ||
      host.endsWith('.co')) {
    return const [
      '/precios',
      '/tarifas',
      '/lista-de-precios',
      '/book-online',
      '/prices',
    ];
  }
  if (host.endsWith('.it')) {
    return const ['/prezzi', '/tariffe', '/listino', '/prices'];
  }
  if (host.endsWith('.fr') || host.endsWith('.be')) {
    return const ['/tarifs', '/prix', '/grille-tarifaire', '/prices'];
  }
  if (host.endsWith('.de') || host.endsWith('.at') || host.endsWith('.ch')) {
    return const ['/preise', '/preisliste', '/prices'];
  }
  if (host.endsWith('.uk') || host.endsWith('.ie')) {
    return const [
      '/prices',
      '/prices/injectables',
      '/price-list',
      '/pricing',
      '/fees',
    ];
  }
  if (host.endsWith('.tr')) {
    return const ['/fiyatlar', '/fiyat-listesi', '/prices'];
  }
  if (host.endsWith('.pl')) {
    return const ['/cennik', '/ceny', '/prices'];
  }
  if (host.endsWith('.pt') || host.endsWith('.br')) {
    return const ['/precos', '/tabela-de-precos', '/prices'];
  }
  if (host.endsWith('.ae') || host.endsWith('.sa')) {
    return const [
      '/prices',
      '/price-list',
      '/pricing',
      '/packages',
      '/offers',
      '/fees',
      '/ar/prices',
      '/ar/price-list',
      '/ar/pricing',
    ];
  }
  if (host.endsWith('.kr')) {
    return const ['/prices', '/price', '/pricing'];
  }
  if (host.endsWith('.jp')) {
    return const ['/price', '/prices', '/pricing'];
  }
  return const [
    '/prices',
    '/price-list',
    '/pricing',
    '/precios',
    '/preturi',
    '/tarifs',
    '/prezzi',
  ];
}

List<String> explorePriceMenuProbeUrls(String domain) {
  final host = _exploreBareHost(domain);
  if (host.isEmpty) return const [];
  final base = 'https://$host';
  final out = <String>{base};
  for (final path in explorePriceMenuPathsForHost(host)) {
    out.add('$base$path');
  }
  return out.toList();
}

PriceSourceType classifyPriceSourceType(String sourceUrl) {
  if (isNonLiteralClinicPriceUrl(sourceUrl)) {
    return PriceSourceType.searchSnippet;
  }
  final host = _hostOf(sourceUrl);
  if (host.isEmpty) return PriceSourceType.searchSnippet;
  if (host.contains('google.') ||
      host.contains('bing.com') ||
      host.contains('yahoo.')) {
    return PriceSourceType.searchSnippet;
  }
  if (isMarketplaceOrDirectoryHost(host)) {
    const aggregators = {
      'doctoralia.es',
      'doctoralia.com',
      'topdoctors.es',
      'topdoctors.com',
      'saludestetica.com',
      'estheticon.com',
      'medigence.com',
    };
    if (aggregators.any((h) => host == h || host.endsWith('.$h'))) {
      return PriceSourceType.aggregator;
    }
    return PriceSourceType.marketplace;
  }
  return PriceSourceType.officialClinic;
}

String _hostOf(String url) {
  try {
    final uri = Uri.parse(url.contains('://') ? url : 'https://$url');
    return uri.host.toLowerCase().replaceFirst(cachedRegExp(r'^www\.'), '');
  } catch (_) {
    return '';
  }
}

/// SPA shells that need a headless renderer later — never invent a price.
bool htmlLooksLikeJsShell(String html) {
  final raw = html.trim();
  if (raw.isEmpty) return true;
  final lower = raw.toLowerCase();
  if (lower.contains('enable javascript') ||
      lower.contains('enable js') ||
      lower.contains('noscript') && lower.contains('javascript')) {
    final stripped = raw
        .replaceAll(
          cachedRegExp(r'<script[\s\S]*?</script>', caseSensitive: false),
          '',
        )
        .replaceAll(
          cachedRegExp(r'<style[\s\S]*?</style>', caseSensitive: false),
          '',
        )
        .replaceAll(cachedRegExp(r'<[^>]+>'), ' ')
        .replaceAll(cachedRegExp(r'\s+'), ' ')
        .trim();
    if (stripped.length < 250) return true;
  }
  final stripped = raw
      .replaceAll(
        cachedRegExp(r'<script[\s\S]*?</script>', caseSensitive: false),
        '',
      )
      .replaceAll(
        cachedRegExp(r'<style[\s\S]*?</style>', caseSensitive: false),
        '',
      )
      .replaceAll(cachedRegExp(r'<[^>]+>'), ' ')
      .replaceAll(cachedRegExp(r'\s+'), ' ')
      .trim();
  if (raw.length > 1500 && stripped.length < 180) return true;
  return false;
}

/// Keep the already-parsed number. Ignore any AI `price` / `price_min` fields.
ExtractedPriceEvidence applyLabelClassification({
  required ExtractedPriceEvidence evidence,
  required Map<String, Object?> aiJson,
}) {
  for (final key in [
    'price',
    'price_min',
    'price_max',
    'priceMin',
    'priceMax',
    'cost',
    'price_label',
    'amount',
  ]) {
    if (aiJson.containsKey(key) && aiJson[key] != null) {
      debugPrint('[GP PRICE] AI numeric field ignored');
      break;
    }
  }
  final family = '${aiJson['family'] ?? aiJson['procedure_family'] ?? ''}'
      .trim();
  final canonical =
      '${aiJson['canonical'] ?? aiJson['canonical_procedure'] ?? ''}'.trim();
  final confidence = (aiJson['confidence'] as num?)?.toDouble();
  return evidence.copyWith(
    procedureFamily: family.isNotEmpty ? family : evidence.procedureFamily,
    procedureCanonical: canonical.isNotEmpty
        ? canonical
        : evidence.procedureCanonical,
    confidence: confidence ?? evidence.confidence,
  );
}

void logExtractedEvidence(
  ExtractedPriceEvidence row, {
  String clinicName = '',
}) {
  if (clinicName.isNotEmpty) {
    debugPrint('[GP EXTRACT] $clinicName');
  }
  debugPrint('[GP EXTRACT] method=${row.extractionMethod.wire}');
  debugPrint('[GP EXTRACT] procedure="${row.rawProcedureText}"');
  debugPrint('[GP EXTRACT] rawPrice="${row.rawPriceText}"');
  debugPrint(
    '[GP EXTRACT] parsed=${row.priceMin.toStringAsFixed(0)} ${row.currency}',
  );
}
