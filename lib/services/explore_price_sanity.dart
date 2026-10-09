import 'explore_regex_cache.dart';
import 'explore_injectable_scope.dart';
import 'package:flutter/foundation.dart';

import 'explore_url_discovery.dart';
import 'explore_currency_tokens.dart';
import 'explore_price_ownership.dart';
import 'explore_search_locale.dart';
import 'explore_clinic_identity.dart';
import 'explore_price_binding.dart';

/// Bump when HTML extraction rules change. Cached Firestore/Google numbers
/// without this stamp are dropped on read and re-fetched. Do not bump
/// [kExploreComparisonCacheRevision] for the same reason — that empties the
/// clinic pool; this only invalidates the amount.
/// e17: Stylage M/L/XL filler brands; Neuronox/botulotoxina; strip
/// dermatocosmetolog / Prețuri section titles from compare cards.
/// e18: exact prices stay exact (no auto /ml from "1 ml"); cross-city cache purge.
/// e19: page-level clinicOwnPrice / country cost guides; display-title normalization.
/// e20: Fresha JSON-LD Offer.itemOffered names; cost-savings URL reject; Fresha/Booksy discovery.
/// e21: service-bound marketplace prices; consultation/market/seasonal exclusions.
/// e22: preserve owned tariffs beside dosage averages and multilingual offers.
/// e23: bind current tariffs to their scope; exclude finance, combinations and market disclaimers.
/// e24: retain marketplace technique; reject hair Botox, topical and needleless fillers.
/// e25: revalidate informational average tables and literal range endpoints.
const kExplorePriceExtractRevision = 'e25';

/// Hard gate: a number from clinic HTML is not a procedure price until this
/// passes. AI must never invent a replacement amount.
class PriceSanityResult {
  const PriceSanityResult.accept()
      : accepted = true,
        reason = '';

  const PriceSanityResult.reject(this.reason) : accepted = false;

  final bool accepted;
  final String reason;
}

bool isWeakPriceExtractionMethod(String method) {
  switch (method.trim().toLowerCase()) {
    case 'dom_block':
    case 'domblock':
    case 'list_item':
    case 'listitem':
    case 'text_proximity':
    case 'textproximity':
    case 'official_article':
      return true;
    default:
      return false;
  }
}

bool isStructuredPriceExtractionMethod(String method) {
  switch (method.trim().toLowerCase()) {
    case 'jsonld':
    case 'json_ld':
    case 'schemaoffer':
    case 'schema_offer':
    case 'html_table':
    case 'htmltable':
    case 'woocommerce':
    case 'shopify':
    case 'product_card':
    case 'productcard':
    case 'fresha_menu':
    case 'marketplace_menu':
    case 'booksy_menu':
    case 'treatwell_menu':
    case 'whatclinic_page':
      return true;
    default:
      return false;
  }
}

final _phoneCue = cachedRegExp(
  r'\b(?:tel(?:e(?:fono|phone))?|tel[eé]fono|whatsapp|m[oó]vil|mobile|'
  r'contact(?:o|ar)?|llam(?:ar|enos)|call\s+us)\b',
  caseSensitive: false,
);

/// UAE 999/998, US 911, EU 112 — Mediclinic pages say "ring 999".
final _emergencyHelpCue = cachedRegExp(
  r'\b(?:emergency|emergencias|urgencias|ambulance|ambulancia|'
  r'helpline|help[\s-]*line|help[\s-]*desk|help\s+number|hotline|'
  r'toll[\s-]*free|police|polic[ií]a|'
  // Require brigade/department/service — bare "fire" is Romanian for PDO
  // threads ("2 fire", "extragere fire sutura"), not the fire service.
  r'fire\s+(?:brigade|department|service)|'
  r'ring\s+(?:999|998|911|112)|dial\s+(?:999|998|911|112)|'
  r'call\s+(?:999|998|911|112)|'
  r'طوارئ|إسعاف|الاسعاف|الإسعاف|رقم الطوارئ|الشرطة)\b|'
  r'999\s*/\s*998',
  caseSensitive: false,
);

final _addressCue = cachedRegExp(
  r'\b(?:c\/|calle|carrer|avenida|avda\.?|av\.|street|road|plaza|passeig|'
  r'postal|c\.?p\.?|codigo postal|c[oó]digo postal|building|floor|'
  r'planta|izq\.?|dcha\.?|izquierda|derecha)\b',
  caseSensitive: false,
);

final _durationCue = cachedRegExp(
  r'\b(?:\d+\s*(?:min|mins|minutes?|hora?s?|hours?|h|days?|d[ií]as?|'
  r'months?|meses|sesiones?|sessions?))\b',
  caseSensitive: false,
);

final _percentCue = cachedRegExp(r'\d+(?:[.,]\d+)?\s*%');

final _reviewCue = cachedRegExp(
  r'\b(?:reviews?|rese[nñ]as|opiniones|valoraciones|google\s+reviews?)\b',
  caseSensitive: false,
);

final _pricingLanguage = cachedRegExp(
  r'\b(?:price|precio|precios|preț|pret|tarifa|tarifas|cost|coste|costo|'
  r'from|desde|a\s+partir\s+de|de\s+la|starting(?:\s+at)?|starts\s+from)\b|'
  r'(?:سعر|بسعر|أسعار|اسعار|تكلفة|يبدأ من|تبدأ من|تبدا من)',
  caseSensitive: false,
);

String digitsOnly(String raw) => raw.replaceAll(cachedRegExp(r'\D'), '');

/// Remove contact numbers before interpreting a tariff's amount. A footer
/// WhatsApp number must not invalidate a separately bound currency quote.
/// Number-only inputs become empty and remain invalid prices.
String stripExplorePhoneContacts(String raw) {
  return raw.replaceAll(cachedRegExp(
    r'\b(?:tel(?:e(?:fono|phone))?|tel[eé]fono|phone|whatsapp|mobile|m[oó]vil)'
    r'\s*[:：]?\s*\+?\d(?:[\s()./\-]*\d){5,14}(?!\d)|'
    r'\+\d(?:[\s()./\-]*\d){7,14}(?!\d)',
    caseSensitive: false,
  ), ' ').trim();
}

bool looksLikePhoneNumber(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').trim();
  if (t.isEmpty) return false;
  final lower = t.toLowerCase();
  if (lower.contains('tel:') ||
      lower.contains('telephone:') ||
      lower.contains('telefono:') ||
      lower.contains('teléfono:') ||
      lower.contains('phone:') ||
      lower.contains('whatsapp:') ||
      lower.contains('contact:')) {
    return true;
  }
  if (_phoneCue.hasMatch(lower)) return true;

  final compact = t.replaceAll(cachedRegExp(r'[\s().\-./]'), '');
  if (cachedRegExp(r'^\+\d{8,15}$').hasMatch(compact)) return true;
  if (cachedRegExp(r'^00\d{8,15}$').hasMatch(compact) &&
      !hasCurrencySignal(t) &&
      !_pricingLanguage.hasMatch(t)) {
    return true;
  }
  if (cachedRegExp(r'(?:\+|00)\s*3[0-9]\b').hasMatch(t) &&
      digitsOnly(t).length >= 9) {
    return true;
  }
  // Grouped ES mobiles/landlines: 621 145 099, 933 623 707.
  if (cachedRegExp(
        r'(?:\+|00)?\s*(?:34[\s.\-/]*)?[6-9]\d{2}[\s.\-/]+\d{3}[\s.\-/]+\d{3}\b',
      ).hasMatch(t) &&
      digitsOnly(t).length >= 9) {
    return true;
  }
  return false;
}

bool _emergencyCueTouchesAmount(String raw, int amount) {
  final t = raw.replaceAll('\u00a0', ' ').toLowerCase();
  if (!_emergencyHelpCue.hasMatch(t)) return false;
  final code = amount > 0 ? '$amount' : '999';
  for (final m in _emergencyHelpCue.allMatches(t)) {
    final start = m.start > 48 ? m.start - 48 : 0;
    final end = m.end + 48 < t.length ? m.end + 48 : t.length;
    if (t.substring(start, end).contains(code)) return true;
  }
  return false;
}

/// UAE ambulance/help 999 (and 911/112) must not become a clinic price.
///
/// Never reject only because the amount equals an emergency code. A real
/// `999 AED` Botox Monday offer is valid when no emergency/help wording is
/// near that number.
bool looksLikeEmergencyOrHelpNumber(
  String raw, {
  double priceMin = 0,
  String extractionMethod = '',
}) {
  final t = raw.replaceAll('\u00a0', ' ').trim();
  if (t.isEmpty) return false;
  final digits = digitsOnly(t);
  final amount = priceMin.round() > 0
      ? priceMin.round()
      : int.tryParse(digits) ?? 0;
  return _emergencyCueTouchesAmount(t, amount > 0 ? amount : 999);
}

bool looksLikeAddressNumber(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').trim();
  if (t.isEmpty) return false;
  if (_addressCue.hasMatch(t)) return true;
  if (cachedRegExp(r'\b\d{5}\s+[A-Za-zÀ-ÿ]').hasMatch(t) &&
      !hasCurrencySignal(t) &&
      !hasPricingLanguage(t)) {
    return true; // 08021 Barcelona
  }
  if (cachedRegExp(r'\b\d{4,5}\s*[-–]\s*[A-Za-zÀ-ÿ]').hasMatch(t)) return true;
  if (cachedRegExp(r'\b\d+º').hasMatch(t)) return true;
  if (cachedRegExp(r'\bE-\d\b').hasMatch(t)) return true;
  return false;
}

bool looksLikeDuration(String raw) => _durationCue.hasMatch(raw);

const _kDurationUnit =
    r'(?:min|mins|minutes?|hora?s?|hours?|h|days?|d[ií]as?|months?|meses|sesiones?|sessions?)';

bool _amountHasCurrencyQuote(int n, String raw) {
  if (n <= 0 || raw.trim().isEmpty) return false;
  final amount = RegExp.escape('$n');
  return cachedRegExp(
    r'(?:\$|€|£)\s*'
    '$amount'
    r'(?:[.,]\d+)?'
    r'|'
    '$amount'
    r'(?:[.,]\d+)?\s*(?:usd|eur|gbp|aed|ron|lei|\$|€|£|/\s*unit|per\s+unit)',
    caseSensitive: false,
  ).hasMatch(raw);
}

bool _amountAttachedToDurationUnit(int n, String raw) {
  if (n <= 0 || raw.trim().isEmpty) return false;
  final amount = RegExp.escape('$n');
  return cachedRegExp(
    '(?<![\\d.,\$€£])$amount(?:[.,]\\d+)?\\s*$_kDurationUnit\\b',
    caseSensitive: false,
  ).hasMatch(raw);
}

/// "Lasts 3–4 months" on a Botox menu must not kill `$13/unit` in the same row.
/// Reject only when [priceMin] itself is the time/session count.
bool looksLikeDurationQuotedAsPrice({
  required double priceMin,
  required String rawPriceText,
  required String blob,
}) {
  final n = priceMin.round();
  if (n <= 0) return false;
  final price = rawPriceText.replaceAll('\u00a0', ' ');
  final all = '$blob\n$price'.replaceAll('\u00a0', ' ');
  if (_amountHasCurrencyQuote(n, price) || _amountHasCurrencyQuote(n, all)) {
    return false;
  }
  if (_amountAttachedToDurationUnit(n, price)) return true;
  if (looksLikeDuration(price) && !hasCurrencySignal(price)) return true;
  return _amountAttachedToDurationUnit(n, all);
}

bool _amountAttachedToMonthlyUnit(int n, String raw) {
  if (n <= 0 || raw.trim().isEmpty) return false;
  final amount = RegExp.escape('$n');
  return cachedRegExp(
    r'(?:\$|€|£)?\s*'
    '$amount'
    r'(?:[.,]\d+)?\s*(?:/\s*mo(?:nth)?s?\b|\bper\s+month\b|\ba\s+month\b)',
    caseSensitive: false,
  ).hasMatch(raw);
}

bool _amountLooksLikeMonthlyInstallment(int n, String raw) {
  if (_amountAttachedToMonthlyUnit(n, raw)) return true;
  final amount = RegExp.escape('$n');
  return cachedRegExp(
    r'\bmonthly\s+(?:from|payment|instalments?|installments?|finance|financing)\b'
    r'.{0,32}(?:\$|€|£)?\s*'
    '$amount'
    r'|'
    r'(?:\$|€|£)?\s*'
    '$amount'
    r'(?:[.,]\d+)?.{0,32}'
    r'\bmonthly\s+(?:from|payment|instalments?|installments?|finance|financing)\b',
    caseSensitive: false,
  ).hasMatch(raw);
}

/// `$99/mo` is financing. `$950 per syringe` next to "in a month" / CareCredit
/// copy is a treatment price and must survive.
bool looksLikeMonthlyFinancingQuotedAsPrice({
  required double priceMin,
  required String rawPriceText,
  required String blob,
}) {
  final n = priceMin.round();
  if (n <= 0) return false;
  final price = rawPriceText.replaceAll('\u00a0', ' ');
  final all = '$blob\n$price'.replaceAll('\u00a0', ' ');
  if (cachedRegExp(
    r'(?:per|/)\s*(?:unit|syringe|ml|vial|session|area|graft)\b',
    caseSensitive: false,
  ).hasMatch(price)) {
    return false;
  }
  if (_amountHasCurrencyQuote(n, price) &&
      !_amountLooksLikeMonthlyInstallment(n, price)) {
    return false;
  }
  return _amountLooksLikeMonthlyInstallment(n, price) ||
      _amountLooksLikeMonthlyInstallment(n, all);
}

/// "Typical sessions ranging from $500 to $800" is market copy, not a menu.
/// A short brand line like `Restylane $950 per syringe` is not.
bool looksLikeTypicalMarketRangeQuotedAsPrice({
  required double priceMin,
  required String rawPriceText,
  required String blob,
}) {
  final n = priceMin.round();
  if (n <= 0) return false;
  final price = rawPriceText.replaceAll('\u00a0', ' ');
  final hay = '$price\n$blob';
  if (price.length <= 90 &&
      !cachedRegExp(
        r'\btypical|\bprices?\s+vary|\bon average\b|\branging from\b|'
        r'\bmight\s+cost\b|\bwill\s+vary\b|\bcost\s+between\b',
        caseSensitive: false,
      ).hasMatch(price) &&
      _amountHasCurrencyQuote(n, price)) {
    return false;
  }
  return cachedRegExp(
    r'\btypical(?:ly)?\s+sessions?\s+rang|'
    r'\bprices?\s+vary\s+depending\b|'
    r'\b(?:cost|price)s?\s+will\s+vary\s+depending\b|'
    r'\bmight\s+cost\s+between\b|'
    r'\b(?:can|may|might|could)\s+cost\s+between\b|'
    r'\bcosts?\s+between\s+\$?\d|'
    r'\branging\s+from\s+\$?\d[\d,]*(?:\.\d+)?\s*(?:to|–|-|and)\s+\$?\d|'
    r'\btypical(?:ly)?\s+(?:session|treatment)s?\s+rang(?:e|ing)\s+from\b|'
    r'\ba\s+typical\s+[^.?]{0,48}\b(?:might\s+|can\s+|may\s+)?cost\b|'
    r'\btypical\s+\w+(?:\s+\w+){0,6}\s+might\s+cost\b',
    caseSensitive: false,
  ).hasMatch(hay);
}

bool looksLikePercent(String raw) => _percentCue.hasMatch(raw);

bool looksLikeReviewCount(String raw) => _reviewCue.hasMatch(raw);

bool hasCurrencySignal(String raw) => hasExploreCurrencySignal(raw);

bool hasPricingLanguage(String raw) => _pricingLanguage.hasMatch(raw);

// Concatenate — Dart raw strings do not interpolate `$name`.
const _kHairTechniqueWord =
    r'(?:fue|fut|dhi|sapphire|micro[- ]?sapphire)';

/// "1,000 grafts" / "1,000 FUE grafts" / "Up to 3.000 Grafts" is a session
/// size, not a clinic price.
bool looksLikeGraftOrFollicleQuantity(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').trim();
  if (t.isEmpty) return false;
  if (looksLikePerGraftQuotedPrice(t)) return false;
  return cachedRegExp(
    r'^\s*(?:up\s+to\s+|area\s*\d+\s*[–\-—]\s*)?'
    r'\d[\d.,\s]*'
    r'(?:\s*(?:–|—|-|to|و|\+)\s*\d[\d.,\s]*)?'
    r'\s*(?:' +
        _kHairTechniqueWord +
        r'\s+)?-?\s*'
    r'(?:grafts?|grafturi|follicles?|folicul(?:i|e)?|بصيلة|بصيلات)'
    r'\s*\+?\s*\.?\s*$',
    caseSensitive: false,
  ).hasMatch(t);
}

/// Menu rows like "Cost of 500 FUE grafts" — not an SEO "cost of Botox" heading.
bool looksLikeHairGraftPackageMenuLabel(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').trim();
  if (t.isEmpty || t.length > 90 || t.contains('?') || t.contains('؟')) {
    return false;
  }
  return cachedRegExp(
    r'\d[\d.,]*\s*(?:' +
        _kHairTechniqueWord +
        r'\s+)?-?\s*'
    r'(?:grafts?|grafturi|follicles?|بصيلة|بصيلات)\b',
    caseSensitive: false,
  ).hasMatch(t);
}

/// Listed rate for one graft, e.g. "8 AED / graft".
bool looksLikePerGraftQuotedPrice(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').toLowerCase();
  if (t.isEmpty) return false;
  if (looksLikeEffectivePerGraftMarketing(t)) return false;
  return cachedRegExp(
    r'(?:per\s+graft|/graft|per\s+follicle|/follicle|'
    r'لكل\s+بصيلة|للبصيلة|per\s+grafturi)',
    caseSensitive: false,
  ).hasMatch(t);
}

bool looksLikeBotoxPerUnitQuote(String raw, {String procedure = ''}) {
  final t = '$raw $procedure'.replaceAll('\u00a0', ' ').toLowerCase();
  if (t.trim().isEmpty) return false;
  if (!cachedRegExp(
    r'(?:per|/)\s*units?\b|'
    r'(?:per|/)\s*iu\b|'
    r'\b1\s*units?\b|'
    r'\b1\s*unitate|'
    r'\bpe\s+unitate|'
    r'/\s*unitate|'
    r'\(\s*1\s*unit',
    caseSensitive: false,
  ).hasMatch(t)) {
    return false;
  }
  return cachedRegExp(
    r'botox|toxin|dysport|xeomin|neuromod|wrinkle\s+relax|toxina|botulin',
  ).hasMatch(t);
}

/// Hair conditioning products called Botox are not injectable neurotoxin.
bool looksLikeNonInjectableBotox(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').toLowerCase();
  if (!cachedRegExp(r'botox|bótox|botulin').hasMatch(t)) return false;
  return cachedRegExp(
    r'anti[- ]?frizz|anti[- ]?pluis|antiencresp|anti[- ]?encresp|'
    r'botox\s+(?:capilar|hair|haar|capillaire)|(?:hair|haar|capillary)\s+botox|'
    r'haar[- ]?botox|botox[- ]?haar|'
    r'(?:keratin|keratina|straightening|alisado|peluquería|peluqueria|kapper)|'
    r'botox[ -]*like|brow\s+lamination|lash\s+lift',
  ).hasMatch(t);
}

/// Lei/MDL published unit rates run higher than USD/EUR (AMC 150 lei/unit).
double botoxPerUnitJustifiedMax(String currency) {
  final curr = currency.trim().toUpperCase();
  if (curr == 'RON' || curr == 'LEI' || curr == 'MDL' || curr == 'HUF') {
    return 400;
  }
  return 150;
}

/// FKS-style "£0.76 effective cost per graft" is marketing maths, not a FROM.
bool looksLikeEffectivePerGraftMarketing(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').toLowerCase();
  if (t.isEmpty) return false;
  return cachedRegExp(
    r'effective\s+cost\s+per\s+graft|'
    r'lowest\s+effective\s+cost|'
    r'cost\s+per\s+graft\s+at\s+full|'
    r'per\s+graft\s+at\s+full\s+allowance|'
    r'works\s+out\s+(?:at|to|between)|'
    r'what\s+each\s+package\s+works\s+out|'
    r'honest\s+way\s+to\s+compare',
    caseSensitive: false,
  ).hasMatch(t);
}

/// Consult / deposit / SMP / beard — not the generic FUE package FROM.
bool looksLikeHairNonStartingRow(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').toLowerCase();
  if (t.isEmpty) return false;
  if (cachedRegExp(
    r'\bconsultation\b|theatre\s+deposit|non[- ]?refundable|'
    r'no\s+wait\s+booking|'
    r'female\s+hair\s+loss\s+specialist|'
    r'pre[- ]assessment|video consultation|follow[- ]up appointment|'
    r'scalp\s+micro|micropigment|\bsmp\b|'
    r'scar\s+revision|'
    r'\beyebrows?\b|\bbeard\b|\bsideburn|'
    r'highest (?:package|total)|maximum grafts|prices valid',
    caseSensitive: false,
  ).hasMatch(t)) {
    return true;
  }
  // Standalone add-on line, not "£3,199 including the £200 arrangement fee".
  return cachedRegExp(r'arrangement\s+fee', caseSensitive: false).hasMatch(t) &&
      !hairRowIncludesMandatoryAddOnFee(t);
}

/// Package 2 / 5,000-graft band — not the generic FUE FROM when a 3,000 start exists.
bool looksLikeHairLargerThanStartingPackage(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').toLowerCase();
  if (t.trim().isEmpty) return false;
  if (cachedRegExp(
    r'lowest (?:total )?payable|lowest package|package\s*1\b|'
    r'min(?:imum)?\s+fee|up to\s*3[.,]?000',
    caseSensitive: false,
  ).hasMatch(t)) {
    return false;
  }
  return cachedRegExp(
    r'package\s*[2-9]\b|up to\s*5[.,]?000|5,?000\s*grafts|'
    r'full coverage|including the crown',
    caseSensitive: false,
  ).hasMatch(t);
}

/// Wimpole / UK-average columns on a clinic cost page.
bool looksLikeHairMarketComparisonRow(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').toLowerCase();
  if (t.trim().isEmpty) return false;
  return cachedRegExp(
    r'uk average|central london and harley|greater london,|'
    r'grafts actually needed|estimated market|wimpole|'
    r'estimated difference|around £\s*\d|market range|'
    r'estimated cost per graft',
    caseSensitive: false,
  ).hasMatch(t);
}

bool looksLikeHairDhiWhenFueRequested({
  required String procedure,
  required String blob,
}) {
  final want = procedure.replaceAll('\u00a0', ' ').toLowerCase();
  if (!cachedRegExp(r'\bfue\b').hasMatch(want)) return false;
  final t = blob.replaceAll('\u00a0', ' ').toLowerCase();
  if (!cachedRegExp(r'\bdhi\b|\bchoi pen\b').hasMatch(t)) return false;
  if (cachedRegExp(r'\bfue\b|\bsapphire\b').hasMatch(t)) return false;
  return true;
}

bool looksLikeHairStartingPackageRow(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').toLowerCase();
  if (t.trim().isEmpty) return false;
  return cachedRegExp(
    r'lowest total payable|lowest package|'
    r'package\s*1\b|min(?:imum)?\s+fee|'
    r'starts?\s+at|up to\s*3[.,]?000',
    caseSensitive: false,
  ).hasMatch(t);
}

bool hairRowIncludesMandatoryAddOnFee(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').toLowerCase();
  return cachedRegExp(
    r'total payable|including the .{0,24}(?:arrangement|admin|booking) fee|'
    r'incl(?:udes|uding)?\.?\s*(?:the\s+)?(?:arrangement|admin|booking) fee',
    caseSensitive: false,
  ).hasMatch(t);
}

/// £200 arrangement/admin fee that applies to every package (FKS).
double? exploreMandatoryPackageAddOnFee(String blob) {
  final t = blob.replaceAll('\u00a0', ' ');
  if (t.trim().isEmpty) return null;
  if (!cachedRegExp(
    r'arrangement fee|admin(?:istration)? fee|booking fee',
    caseSensitive: false,
  ).hasMatch(t)) {
    return null;
  }
  if (!cachedRegExp(
    r'every package|all packages|applies to every|added to every|'
    r'total payable.{0,40}arrangement',
    caseSensitive: false,
  ).hasMatch(t)) {
    return null;
  }
  final m = cachedRegExp(
    r'(?:arrangement|admin(?:istration)?|booking)\s+fee[^£$€\d]{0,48}'
    r'[£$€]\s*(\d{2,4})|'
    r'[£$€]\s*(\d{2,4})\s+(?:arrangement|admin(?:istration)?|booking)\s+fee',
    caseSensitive: false,
  ).firstMatch(t);
  if (m == null) return 200;
  final raw = (m.group(1) ?? m.group(2) ?? '').replaceAll(',', '');
  final n = double.tryParse(raw) ?? 0;
  if (n < 50 || n > 800) return 200;
  return n;
}

/// Official fees / cost menu — used to catch flattened Package 2 cache hits.
bool looksLikeHairOfficialCostMenuUrl(String sourceUrl) {
  final raw = sourceUrl.trim().toLowerCase();
  if (raw.isEmpty) return false;
  var path = raw;
  try {
    path =
        Uri.parse(raw.contains('://') ? raw : 'https://$raw').path.toLowerCase();
  } catch (_) {}
  return cachedRegExp(
    r'(?:^|/)(?:fees|our-fees|prices?|pricing|price-list|pricelist|'
    r'price-guide|hair-transplant-cost|cost-and-prices|cost)'
    r'(?:/|$|\.|-)',
    caseSensitive: false,
  ).hasMatch(path);
}

/// Cached Package 2 / DHI / market total painted as a generic FROM.
bool looksLikeHairCachedNonStartingPackageFrom({
  required String sourceUrl,
  required String blob,
  required double priceMin,
}) {
  if (looksLikeHairStartingPackageRow(blob) ||
      hairRowIncludesMandatoryAddOnFee(blob)) {
    return false;
  }
  if (looksLikeHairLargerThanStartingPackage(blob) ||
      looksLikeHairMarketComparisonRow(blob)) {
    return true;
  }
  final n = priceMin.round();
  // Flattened second-band / DHI totals when the row text was dropped.
  if (n == 3599 ||
      n == 3799 ||
      n == 3899 ||
      n == 4099 ||
      n == 4799 ||
      n == 4999) {
    return looksLikeHairOfficialCostMenuUrl(sourceUrl);
  }
  return false;
}

/// "FUE often costs £2–£3/graft" / "FUT starting at £1.50 per graft" is
/// city-market copy, not that clinic's published tariff.
bool looksLikeHairMarketPerGraftBlurb(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').toLowerCase();
  if (t.isEmpty) return false;
  if (!cachedRegExp(
    r'\b(?:fue|fut|grafts?|follicles?|hair transplants?)\b',
  ).hasMatch(t)) {
    return false;
  }
  return cachedRegExp(
    r'\bhair transplants?\s+in\s+(?:london|the\s+uk)\s+typically\b|'
    r'(?:often|typically|usually|commonly).{0,48}\bper graft\b|'
    r'\bper graft\b.{0,40}(?:often|typically|usually|common)|'
    r'\bfue\b.{0,80}\boften\b.{0,40}per graft|'
    r'\bfut\b.{0,80}starting at.{0,40}per graft|'
    r'\bfut\b.{0,48}may be slightly cheaper|'
    r'\boften\s+(?:cost|costs)\s+[£$€]?\s*\d.{0,24}per graft',
    caseSensitive: false,
  ).hasMatch(t);
}

/// Compare asked for FUE; this row is a FUT/strip quote.
bool looksLikeHairFutWhenFueRequested({
  required String procedure,
  required String blob,
}) {
  final want = procedure.replaceAll('\u00a0', ' ').toLowerCase();
  if (!cachedRegExp(r'\bfue\b').hasMatch(want)) return false;
  final t = blob.replaceAll('\u00a0', ' ').toLowerCase();
  if (!cachedRegExp(r'\bfut\b|\bstrip method\b|\bstrip (?:surgery|procedure)\b')
      .hasMatch(t)) {
    return false;
  }
  if (cachedRegExp(r'\bfue\b').hasMatch(t) &&
      !cachedRegExp(
        r'\bfut\b.{0,48}(?:£|gbp|per graft)|(?:£|gbp|per graft).{0,24}\bfut\b',
      ).hasMatch(t)) {
    return false;
  }
  return true;
}

/// `/fue-hair-transplant/` marketing page — not `/fees/` or a cost menu.
bool looksLikeHairProcedureLandingUrl(String sourceUrl) {
  final raw = sourceUrl.trim().toLowerCase();
  if (raw.isEmpty) return false;
  var path = raw;
  try {
    path =
        Uri.parse(raw.contains('://') ? raw : 'https://$raw').path.toLowerCase();
  } catch (_) {}
  if (cachedRegExp(
    r'cost-and-prices|hair-transplant-cost|transplant-cost|'
    r'/(?:our-)?fees(?:/|$)|/prices?(?:/|$)|/pricing(?:/|$)|'
    r'/price-list|/pricelist|/price-guide',
  ).hasMatch(path)) {
    return false;
  }
  return cachedRegExp(
    r'fue-hair-transplant|/fue(?:/|$)|hair-restoration|'
    r'/hair-transplant(?:/|$)',
  ).hasMatch(path);
}

/// "Rhinoplasty Cost in London: Complete Pricing Guide" — city market essay.
bool looksLikeCityMarketPricingGuideUrl(String sourceUrl) {
  final raw = sourceUrl.trim().toLowerCase();
  if (raw.isEmpty) return false;
  var path = raw;
  try {
    path =
        Uri.parse(raw.contains('://') ? raw : 'https://$raw').path.toLowerCase();
  } catch (_) {}
  return cachedRegExp(
    r'complete-pricing-guide|complete-price-guide|complete-cost-guide|'
    r'complete-pricing|typical-[-]?cost|cost-in-london-complete',
    caseSensitive: false,
  ).hasMatch(path);
}

/// "starts from £5,400 to £7,600" on a treatment landing, with no graft table.
bool looksLikeHairStaleLandingQuote({
  required String sourceUrl,
  required String blob,
  required double priceMin,
  double priceMax = 0,
}) {
  if (!looksLikeHairProcedureLandingUrl(sourceUrl)) return false;
  if (hairGraftSessionQuantity(blob) != null) return false;
  if (cachedRegExp(
    r'min(?:imum)?\s+fee|2,?400\s*[-–—]\s*3,?000\s*grafts',
    caseSensitive: false,
  ).hasMatch(blob)) {
    return false;
  }
  // Amount, currency and the absence of a graft table cannot establish age.
  // Ownership, location and method are checked independently by the caller.
  return cachedRegExp(
    r'\b(?:expired|superseded|archived|discontinued|no longer available)\b'
    r'.{0,70}\b(?:price|offer|tariff|package)\b|'
    r'\b(?:price|offer|tariff|package)\b.{0,70}'
    r'\b(?:expired|superseded|discontinued|no longer available)\b',
    caseSensitive: false,
  ).hasMatch(blob);
}

bool looksLikeUnshavenHairVariant(String raw) {
  return cachedRegExp(
    r'\bunshaven\b|\bun-shaven\b|\bno[- ]shave\b',
    caseSensitive: false,
  ).hasMatch(raw);
}

/// Session size printed beside a package ("500 FUE grafts → from £3,500").
double? hairGraftSessionQuantity(String raw) {
  final t = raw.replaceAll('\u00a0', ' ');
  if (t.trim().isEmpty) return null;
  if (looksLikePerGraftQuotedPrice(t)) return null;
  final m = cachedRegExp(
    r'(?:up\s+to\s+)?'
    r'(\d{1,3}(?:[.,]\d{3})+|\d{2,4})'
    r'\s*(?:' +
        _kHairTechniqueWord +
        r'\s+)?-?\s*'
    r'grafts?\+?',
    caseSensitive: false,
  ).firstMatch(t);
  if (m == null) return null;
  final n = double.tryParse(
    (m.group(1) ?? '').replaceAll(',', '').replaceAll('.', ''),
  );
  if (n == null || n < 50 || n > 12000) return null;
  // "3.000" European thousands vs "3.5" — 3.000 → 3000 after stripping dots
  // when the source used a thousands separator.
  final rawNum = m.group(1) ?? '';
  if (rawNum.contains('.') &&
      !cachedRegExp(r'^\d{1,3}(?:\.\d{3})+$').hasMatch(rawNum) &&
      cachedRegExp(r'^\d+\.\d{1,2}$').hasMatch(rawNum)) {
    final dec = double.tryParse(rawNum);
    if (dec != null && dec >= 50 && dec <= 12000) return dec;
    return null;
  }
  if (rawNum.contains('.') && cachedRegExp(r'^\d{1,3}(?:\.\d{3})+$').hasMatch(rawNum)) {
    return double.tryParse(rawNum.replaceAll('.', ''));
  }
  return n;
}

/// "Cost of 1,000 FUE grafts – from £3500" parsed as £1,000.
bool looksLikeGraftCountMistakenForPrice({
  required double priceMin,
  required String blob,
}) {
  if (priceMin < 50 || priceMin > 8000) return false;
  if (looksLikePerGraftQuotedPrice(blob)) return false;
  final qty = hairGraftSessionQuantity(blob);
  if (qty == null || (qty - priceMin).abs() > 0.5) return false;
  if (!hasCurrencySignal(blob)) return true;
  return hasPricingLanguage(blob);
}

/// Strip "3,000-graft" / "1,000 FUE grafts" so the parser sees "from £3,500".
String stripGraftQuantityPhrases(String raw) {
  return raw.replaceAll(
    cachedRegExp(
      r'\b(?:up\s+to\s+)?\d{1,3}(?:[.,]\d{3})+\s*(?:' +
          _kHairTechniqueWord +
          r'\s+)?-?\s*grafts?\+?\b|'
      r'\b(?:up\s+to\s+)?\d{2,4}\s*(?:' +
          _kHairTechniqueWord +
          r'\s+)?-?\s*grafts?\+?\b|'
      r'\b\d[\d.,]*\s*(?:–|—|-|to)\s*\d[\d.,]*\s*(?:' +
          _kHairTechniqueWord +
          r'\s+)?'
      r'(?:grafts?|بصيلة|بصيلات)\b',
      caseSensitive: false,
    ),
    ' ',
  );
}

/// Strip a dose range like "40-50 units" so the parser sees "$18.00 per unit".
///
/// Per-unit menus quote the fee and the average dose in one breath — "BOTOX®
/// Cosmetic $18.00 per unit. On average, 40-50 units are used to treat the
/// entire upper face". [parsePriceText] looks for a numeric range before it
/// looks for currency-marked amounts, so the dose won and the row parsed as a
/// $40–50 "price", which then failed the Botox band and dropped the row
/// entirely. Only ranges are stripped: a lone "40 units" is already skipped as
/// a quantity while parsing amounts.
///
/// The number must touch the unit word. "$2,500 - $4,000 per session" keeps its
/// range because "per" sits between the amount and the unit.
String stripDosageQuantityPhrases(String raw) {
  var out = raw.replaceAll(
    cachedRegExp(
      r'\b(?:up\s+to\s+)?\d[\d.,]*\s*(?:–|—|-|to|and)\s*\d[\d.,]*\s*'
      r'(?:units?|unitate|unitati|unități|iu|ml|cc|syringes?|vials?|ampoules?|'
      r'areas?|zones?|zone|sessions?|sedinte|ședințe|sedințe|'
      r'وحدات|مل|منطقة|جلسة)\b',
      caseSensitive: false,
    ),
    ' ',
  );
  // Singular doses must not become prices: "50 unități", "3 zone".
  out = out.replaceAll(
    cachedRegExp(
      r'\b\d[\d.,]*\s*(?:units?|unitate|unitati|unități|iu|ml|cc|syringes?|'
      r'vials?|ampoules?|areas?|zones?|zone|sessions?|sedinte|ședințe|sedințe|'
      r'%|cm|mm|وحدات|مل|منطقة|جلسة)\b',
      caseSensitive: false,
    ),
    ' ',
  );
  return out;
}

/// Upper bound for a believable per-graft rate in local currency.
double hairPerGraftPlausibleMax(String currency) {
  final c = currency.trim().toUpperCase();
  return switch (c) {
    'TRY' || 'TL' || '₺' => 500,
    'AED' || 'د.إ' => 150,
    'RON' || 'LEI' => 250,
    'PLN' || 'ZŁ' => 400,
    'RUB' || '₽' => 5000,
    '₩' || 'KRW' || 'WON' => 8000,
    'JPY' || '¥' => 5000,
    'HKD' => 150,
    'INR' || '₹' => 200,
    'SGD' => 50,
    'THB' || '฿' => 500,
    _ => 100,
  };
}

bool isBareYear(double amount, String raw) {
  final n = amount.round();
  if (n < 1900 || n > 2100) return false;
  if (hasCurrencySignal(raw) || hasPricingLanguage(raw)) return false;
  return true;
}

/// "Rinoplastie preț 2026" is a calendar year, not €2026.
bool looksLikeCalendarYearPrice(double amount, String raw) {
  final n = amount.round();
  if (n < 2000 || n > 2100) return false;
  final t = raw.toLowerCase();
  return cachedRegExp(
    r'(?:pre[tț]|price|precio|tarife?|preturi)\s*20\d{2}|'
    r'20\d{2}\s*(?:pre[tț]|edition|ghid|guide)',
  ).hasMatch(t);
}

const _kClinicOwnCurrency =
    r'(?:aed|usd|eur|gbp|€|£|\$|درهم|د\.إ)';
const _kClinicOwnAttachedRange =
    r'(?:\s*(?:to|-|–|—)\s*'
    '$_kClinicOwnCurrency?'
    r'\s*\d[\d.,]*'
    r'(?:\s*'
    '$_kClinicOwnCurrency'
    r')?)?';

/// Menu fact rows (`Cost: 500 AED to 1000 AED`) and "starts from AED 1500".
final _kClinicLabeledCostRe = cachedRegExp(
  r'(?:cost|price|fee)\s*:\s*'
  '$_kClinicOwnCurrency?'
  r'\s*\d[\d.,]*'
  r'(?:\s*'
  '$_kClinicOwnCurrency'
  r')?'
  r'(?:\s*(?:to|-|–|—)\s*'
  '$_kClinicOwnCurrency?'
  r'\s*\d[\d.,]*)?'
  r'|'
  r'(?:starts?\s+from|starting(?:\s+from)?)\s+'
  r'(?:approximately\s+|about\s+|around\s+)?'
  '$_kClinicOwnCurrency'
  r'\s*\d[\d.,]*'
  '$_kClinicOwnAttachedRange'
  r'(?:\s*(?:per\s+ml|\/\s*ml|per\s+area|per\s+unit))?',
  caseSensitive: false,
);

final _kClinicOwnPublishedPriceRe = cachedRegExp(
  r'(?:cost|price|fee)\s*:\s*'
  '$_kClinicOwnCurrency?'
  r'\s*\d[\d.,]*'
  r'(?:\s*'
  '$_kClinicOwnCurrency'
  r')?'
  r'(?:\s*(?:to|-|–|—)\s*'
  '$_kClinicOwnCurrency?'
  r'\s*\d[\d.,]*)?'
  r'|'
  r'(?:the\s+)?price for [^.]{0,80}?(?:starts?\s+from|starting(?:\s+from)?)\s+'
  '$_kClinicOwnCurrency?'
  r'\s*\d[\d.,]*'
  '$_kClinicOwnAttachedRange'
  r'|'
  r'(?:starts?\s+from|starting(?:\s+from)?)\s+'
  r'(?:approximately\s+|about\s+|around\s+)?'
  '$_kClinicOwnCurrency'
  r'\s*\d[\d.,]*'
  '$_kClinicOwnAttachedRange'
  r'(?:\s*(?:per\s+ml|\/\s*ml|per\s+area|per\s+unit))?'
  r'|'
  // Cadogan: "a boob job costs from £5,900" — not the UK market £5k–£7k band.
  r'(?:cost|price)s?\s+from\s+'
  '$_kClinicOwnCurrency'
  r'\s*\d[\d.,]*'
  r'|'
  r'(?:one|1|two|2|three|3)\s*areas?\s+from\s+'
  '$_kClinicOwnCurrency'
  r'\s*\d[\d.,]*'
  r'|'
  r'(?:closed|open|primary)\s+rhinoplasty\s+(?:–|-|from)\s+'
  '$_kClinicOwnCurrency?'
  r'\s*\d[\d.,]*'
  r'|'
  r'(?:at\s+[^.]{3,90}[,.]?\s+)?(?:the\s+)?price usually ranges from\s+'
  '$_kClinicOwnCurrency?'
  r'\s*\d[\d,]*(?:\s*(?:to|-|–|—)\s*'
  '$_kClinicOwnCurrency?'
  r'\s*\d[\d,]*)?'
  r'|'
  r'our (?:price|prices|fee)s?\s+(?:for [^.]{0,40})?'
  r'(?:start|range|usually)\s+(?:from\s+)?'
  '$_kClinicOwnCurrency?'
  r'\s*\d[\d,]*'
  r'|'
  r'our\s+(?:clinic|hospital|practice)\s+charges?\s+'
  r'(?:(?:approximately|roughly|around|about)\s+)?'
  '$_kClinicOwnCurrency?'
  r'\s*\d[\d.,]*'
  '$_kClinicOwnAttachedRange'
  r'(?:\s*'
  '$_kClinicOwnCurrency'
  r')?'
  r'|'
  // Tajmeels-style treatment landing page, not "typically range from".
  r'(?:cost|price)s?\s+(?:in\s+)?'
  r'(?:dubai|uae|abudhabi|abu dhabi|sharjah)\s+ranges from\s+'
  '$_kClinicOwnCurrency?'
  r'\s*\d[\d,]*'
  r'(?:\s*'
  '$_kClinicOwnCurrency'
  r')?'
  r'\s*(?:to|-|–|—)\s*'
  '$_kClinicOwnCurrency?'
  r'\s*\d[\d,]*',
  caseSensitive: false,
);

/// One clinic-attributed quote found in page HTML/prose.
class ClinicOwnPriceHit {
  const ClinicOwnPriceHit({required this.window, required this.context});

  final String window;
  final String context;
}

/// Every labeled / "ranges from" quote on the page, with nearby words.
List<ClinicOwnPriceHit> clinicOwnPublishedPriceHits(String raw) {
  final t = raw.replaceAll('\u00a0', ' ');
  if (t.trim().isEmpty) return const [];
  final out = <ClinicOwnPriceHit>[];
  final seen = <String>{};
  for (final m in _kClinicOwnPublishedPriceRe.allMatches(t)) {
    final window = (m.group(0) ?? '').trim();
    if (window.isEmpty || !seen.add(window.toLowerCase())) continue;
    final start = (m.start - 180).clamp(0, t.length);
    final end = (m.end + 80).clamp(0, t.length);
    out.add(
      ClinicOwnPriceHit(
        window: window,
        context: t.substring(start, end).trim(),
      ),
    );
  }
  return out;
}

/// Blog/guide copy ("în general în București 3000–4000€"), not a clinic menu.
/// "At [hospital], the price usually ranges from AED 22000 to AED 40,000".
/// Clinic-attributed copy, not a city typical/average sentence.
String? clinicOwnPublishedPriceWindow(String raw) {
  final hits = clinicOwnPublishedPriceHits(raw);
  return hits.isEmpty ? null : hits.first.window;
}

/// Official menu row: `Cost: 500 AED to 1000 AED` or `starts from AED 1500 per ml`.
bool looksLikeClinicLabeledCostFact(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').trim();
  if (t.isEmpty) return false;
  return _kClinicLabeledCostRe.hasMatch(t);
}

/// `SKIN111` / `SKIN 111` in the clinic name is not AED 111.
bool looksLikeBrandEmbeddedDigitPrice(double priceMin, String blob) {
  final n = priceMin.round();
  if (n < 100 || n > 9999) return false;
  final t = blob.replaceAll('\u00a0', ' ');
  final digits = n.toString();
  final brand = cachedRegExp(
    r'\b(?:at\s+)?skin\s*-?\s*' + digits + r'\b',
    caseSensitive: false,
  );
  if (!brand.hasMatch(t)) return false;
  final listed = cachedRegExp(
    r'(?:starts?\s+from|starting(?:\s+from)?|cost\s*:|price\s*:)\s*'
    r'(?:aed|usd|eur|gbp|€|£|\$|درهم|د\.إ)\s*' +
        digits +
        r'\b',
    caseSensitive: false,
  );
  return !listed.hasMatch(t);
}

bool looksLikeBarePriceLabel(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return false;
  if (looksLikePublishedPriceUnitLabel(t)) return true;
  const cur = r'(?:aed|usd|eur|gbp|ron|lei|try|dhs|dirhams?|€|£|\$|د\.إ|درهم)';
  const unit = r'(?:(?:per|/)\s*(?:unit|units|iu|unidad(?:es)?|syringe|'
      r'ml|vial|session|area|graft)s?)';
  return cachedRegExp(
    r'^(?:from|starting(?:\s+(?:at|from))?|starts\s+(?:at|from)|'
    r'cost|price|de la|desde|يبدأ من|تبدأ من)?\s*'
    '$cur?' r'\s*'
    r'[\d.,\s]+'
    r'(?:(?:to|-|–|—)\s*' '$cur?' r'\s*[\d.,\s]+)?'
    r'\s*' '$cur?' r'\s*'
    '$unit?' r'\s*$',
    caseSensitive: false,
  ).hasMatch(t);
}

/// Menu leftover after stripping "$13" / "AED 42" — never a treatment name.
bool looksLikePublishedPriceUnitLabel(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').trim().toLowerCase();
  if (t.isEmpty) return false;
  final compact = t
      .replaceAll(cachedRegExp(r'[–—/,]+'), ' ')
      .replaceAll(cachedRegExp(r'\s+'), ' ')
      .trim();
  return cachedRegExp(
    r'^(?:per\s+|/\s*)?(?:unit|units|iu|unidad(?:es)?|syringe|ml|cc|'
    r'vial|session|area|areas|zone|zones|graft|grafts)$',
    caseSensitive: false,
  ).hasMatch(compact);
}

/// Finance / monthly-payment headings are not treatment names.
/// Keep the nearby menu amount; never show "Breast surgery financing" as the card title.
bool looksLikeFinancingOrPaymentHeading(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').trim().toLowerCase();
  if (t.isEmpty) return false;
  return cachedRegExp(
    r'\bfinanc(?:e|ing|ial|iaci[oó]n)\b|'
    r'\bmonthly payments?\b|'
    r'\bpayment plans?\b|'
    r'\b0\s*%\s*(?:apr|finance|interest)\b|'
    r'\binstallments?\b|'
    r'\bcuotas?\b|'
    r'\bloan\b|'
    r'\bhow to pay\b|'
    r'\bpay monthly\b',
    caseSensitive: false,
  ).hasMatch(t);
}

/// Previous/list-price columns do not own the current payable treatment fee.
bool looksLikeSupersededPriceColumnHeader(String raw) => cachedRegExp(
      r'^(?:antes|was|old\s+price|previous\s+price|precio\s+anterior)'
      r'(?:\s*\([^()]*\))?\s*$',
    ).hasMatch(foldExploreCityText(raw).trim());

/// One-breast / unilateral rows are not the standard BA FROM price.
bool looksLikeUnilateralBreastStartingRow(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').toLowerCase();
  if (t.trim().isEmpty) return false;
  return cachedRegExp(
    r'\bunilateral\b|\bone[- ]breast\b|\bsingle[- ]breast\b',
    caseSensitive: false,
  ).hasMatch(t);
}

/// FAQ / complication H3s glued onto a real fee table
/// ("Pain following breast enlargement surgery · Treatment").
bool looksLikeComplicationOrAftercareHeading(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').trim().toLowerCase();
  if (t.isEmpty) return false;
  return cachedRegExp(
    r'\bpain following\b|'
    r'\bfollowing .{0,48}(?:surgery|augmentation|enlargement|procedure)\b|'
    r'\bside effects?\b|'
    r'\b(?:recovery|aftercare)\b.{0,32}(?:after|following)\b|'
    r'^(?:recovery|aftercare|complications?|side effects?|faqs?|'
    r'frequently asked)\b|'
    r'\bcomplications?\s+(?:of|after|following)\b',
    caseSensitive: false,
  ).hasMatch(t);
}

/// SEO H1 such as "Breast Enlargement Cost" — keep the amount, not the heading.
bool looksLikeSeoCostPageHeading(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').trim();
  if (t.isEmpty) return false;
  final lo = t.toLowerCase();
  if (cachedRegExp(
    r'\bcosts?\s+from\b|\bprices?\s+from\b|\bfrom\s+[£$€]?\s*\d',
    caseSensitive: false,
  ).hasMatch(lo)) {
    return false;
  }
  return cachedRegExp(
    r'\b(?:breast|boob|enlargement|augmentation|implants?|surgery|'
    r'procedure|rhinoplast|botox|filler|laser|peel|hair)\b'
    r'.{0,48}\b(?:cost|costs|prices?|pricing)\s*$',
    caseSensitive: false,
  ).hasMatch(lo);
}

/// Round-thousand GBP BA bands like £5,000–£7,000 are city/market copy,
/// not a clinic menu FROM (Cadogan’s own from-price is £5,900 / £5,995).
bool looksLikeRoundedMarketPriceSpread({
  required double priceMin,
  required double priceMax,
  required String currency,
  required String procedure,
}) {
  final curr = currency.trim().toUpperCase();
  if (curr != 'GBP' && curr != '£') return false;
  if (priceMin <= 0 || priceMax <= priceMin + 500) return false;
  final proc = procedure.toLowerCase();
  final breast = proc.contains('breast') ||
      proc.contains('boob') ||
      proc.contains('pecho') ||
      proc.contains('mamar') ||
      proc.contains('enlargement') ||
      proc.contains('augmentation');
  final rhino = proc.contains('rhino') ||
      proc.contains('rinoplast') ||
      proc.contains('nose');
  if (breast) {
    if (priceMin % 1000 != 0 || priceMax % 1000 != 0) return false;
    final span = priceMax - priceMin;
    return span >= 1500 && span <= 5000;
  }
  if (rhino) {
    // LPH city guide: "Tip rhinoplasty: £3,500–£5,500" is not a closed FROM.
    final span = priceMax - priceMin;
    if (priceMin <= 5500 && span >= 1500 && span <= 4000) return true;
    // Arda-style London survey: "ethnic rhinoplasty £7,000–£15,000".
    // Townley "£12,500–£15,000" stays — min is above the survey band.
    if (priceMin % 1000 == 0 &&
        priceMax % 1000 == 0 &&
        priceMin >= 6000 &&
        priceMin <= 9000 &&
        span >= 4000) {
      return true;
    }
  }
  return false;
}

/// "Price guide" / "Our fees" / "The price of the procedure" are not a row.
bool looksLikePriceMenuHeadingOnly(String raw) {
  final t = raw
      .replaceAll('\u00a0', ' ')
      .toLowerCase()
      .replaceAll(cachedRegExp(r'[^a-z0-9ăâîșț]+'), ' ')
      .trim();
  if (t.isEmpty) return false;
  return cachedRegExp(
    r'^(?:price guide|price list|our fees|our prices|prices|pricing|'
    r'tariffs?|fees|cost|costs|'
    r'(?:the )?price of the procedures?|'
    r'(?:the )?cost of (?:the )?procedures?|'
    r'(?:the )?cost of offered services|'
    r'pretul procedurii|pre[tț]ul procedurii|costul procedurii|'
    r'pretul serviciului|pre[tț]ul serviciului|'
    r'pre[tț]uri(?: la servicii)?)$',
  ).hasMatch(t);
}

/// Areola / explant / contracture lines that mention "breast augmentation".
bool looksLikeBreastAugmentationAddOnRow(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').toLowerCase();
  if (t.trim().isEmpty) return false;
  if (cachedRegExp(
    r'\bareolas?\b|\bareole\b|\bareolei\b|\bareolelor\b',
    caseSensitive: false,
  ).hasMatch(t)) {
    return true;
  }
  return cachedRegExp(
    r'in case of breast augment|'
    r'correction of areola|'
    r'corec[tț]ie(?:a)? (?:de )?areol|'
    r'liquidation of breast contraction|'
    r'removing breast implants|'
    r'extragerea implantelor|'
    r'scoatere(?:a)? implantelor|'
    r'capsulectom',
    caseSensitive: false,
  ).hasMatch(t);
}

/// Tip / alar / revision lines are not the generic rhinoplasty Compare FROM.
bool looksLikePartialRhinoplastyStarting(String raw) {
  final folded = raw.replaceAll('\u00a0', ' ').toLowerCase();
  if (folded.trim().isEmpty) return false;
  return cachedRegExp(
    r'\btip\s+rhino|\brhinoplasty\s+tip|\bnose\s+tip|'
    r'\btip-only|\balarplasty|\balar\s+base|'
    r'revision\s+rhino|\bsecondary\s+rhino|\bethnic\s+rhino|'
    r'\brinoplastia\s+(?:racial|[eé]tnica|secundaria)|'
    r'\bpartial\s+rhino|'
    r'\brinoplastie\s+par[tț]ial|'
    r'\bcartilaginous area of the nasal tip|'
    r'\bseptum region\b|\bwing region\b',
    caseSensitive: false,
  ).hasMatch(folded);
}

/// Hospital / theatre guide that excludes surgeon + anaesthetist (HJE £3,000*).
/// Inclusive clinic packages that mention a hospital stay must not match.
bool looksLikeHospitalFeesOnlyQuote(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').toLowerCase();
  if (t.trim().isEmpty) return false;
  if (cachedRegExp(
    r'inclusive of.{0,48}hospital|'
    r'includes?.{0,32}hospital (?:stay|costs?|fees?)|'
    r'night.?s stay in hospital|'
    r'hospital stay is included',
    caseSensitive: false,
  ).hasMatch(t)) {
    return false;
  }
  return cachedRegExp(
    r'hospital charges|'
    r'\bguide price\b|'
    r'estimated guide to the hospital|'
    r'excludes?\s+(?:consultation|diagnostic|professional|surgeon)|'
    r'professional fees charged separately|'
    r'(?:surgeon|anaesthetist|consultant).{0,48}charged separately|'
    r'does not include.{0,48}(?:surgeon|anaesthetist|consultation)|'
    r'hospital fee(?:s)?(?:\s+only)?\b.{0,40}exclud',
    caseSensitive: false,
  ).hasMatch(t);
}

/// "from £3,000*" on a rhinoplasty treatment page — starred hospital guide.
bool looksLikeStarredHospitalGuidePrice({
  required String blob,
  required double priceMin,
  required String procedure,
}) {
  final proc = procedure.toLowerCase();
  if (!proc.contains('rhino') &&
      !proc.contains('rinoplast') &&
      !proc.contains('nose')) {
    return false;
  }
  if (priceMin <= 0 || priceMin >= 5000) return false;
  return cachedRegExp(r'\d[\d,]*\s*\*').hasMatch(blob.replaceAll('\u00a0', ' '));
}

bool looksLikePrimaryRhinoplastyStarting(String raw) {
  final folded = raw.replaceAll('\u00a0', ' ').toLowerCase();
  if (looksLikePartialRhinoplastyStarting(folded)) return false;
  return cachedRegExp(
    r'\bprimary\b|\bstandard primary\b|\bopen rhino|\bclosed rhino',
    caseSensitive: false,
  ).hasMatch(folded);
}

/// Reviews / "a patient paid £12,500 in 2023" — not a current tariff.
bool looksLikePatientAnecdotePrice(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').toLowerCase();
  if (t.trim().isEmpty) return false;
  return cachedRegExp(
    r'\bi paid\b|\bwe paid\b|'
    r'\bpatient(?:s)?\s+(?:reported|paid|who reported|who paid)\b|'
    r'\breviews?\s+mention\b|'
    r'\breported\s+(?:paying|a price)\b',
    caseSensitive: false,
  ).hasMatch(t);
}

/// Last-reviewed / price-list year in page copy (0 if unknown).
int explorePublishedOrReviewedYear(String raw) {
  final t = raw.replaceAll('\u00a0', ' ');
  if (t.trim().isEmpty) return 0;
  final m = cachedRegExp(
    r'(?:last\s+(?:reviewed|updated|modified)|published(?:\s+on)?|'
    r'revised(?:\s+in)?|updated(?:\s+on)?|medically reviewed)'
    r'[^\d]{0,48}((?:19|20)\d{2})|'
    r'\b((?:19|20)\d{2})\s+procedure\s+prices|'
    r'(?:june|july|january|february|march|april|may|august|september|'
    r'october|november|december)\s+((?:19|20)\d{2})',
    caseSensitive: false,
  ).firstMatch(t);
  if (m == null) return 0;
  for (var i = 1; i <= m.groupCount; i++) {
    final y = int.tryParse(m.group(i) ?? '');
    if (y != null && y >= 2018 && y <= 2035) return y;
  }
  return 0;
}

/// Promo "worth", free assessments, related-product widgets — not a menu price.
bool looksLikeNonTreatmentPriceLabel(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').toLowerCase();
  if (t.trim().isEmpty) return false;
  return cachedRegExp(
    r'\bworth\s+(?:aed|usd|eur|gbp|€|£|\$|د\.إ|درهم)?\s*\d|'
    r'\(\s*worth\b|'
    r'\bfree\s+(?:comprehensive\s+)?assessment\b|'
    r'\brelated\s+products?\b|'
    r'\bgift\s+(?:voucher|card)\b|'
    r'\bquick\s+pricing\b.*\b(?:gp|checkup|check-up|consultation)\b|'
    r'\bgp\s+checkup\b|'
    r'\bpage\s*editor\b|'
    r'\blorem\s+ipsum\b|'
    r'^procedures?\s+from\b',
    caseSensitive: false,
  ).hasMatch(t);
}

String _hostFromSourceUrl(String sourceUrl) {
  final raw = sourceUrl.trim();
  if (raw.isEmpty) return '';
  try {
    final uri = Uri.parse(raw.contains('://') ? raw : 'https://$raw');
    return uri.host.toLowerCase().replaceFirst(cachedRegExp(r'^www\.'), '');
  } catch (_) {
    return '';
  }
}

/// `.co.uk` / `.uk` clinic sites publish GBP menus, not USD.
bool hostLooksLikeUkClinic(String sourceUrl) {
  final host = _hostFromSourceUrl(sourceUrl);
  if (host.isEmpty) return false;
  return host.endsWith('.uk') || host.endsWith('.london') || host.endsWith('.scot');
}

bool currencyLooksLikeUsd(String currency, String blob) {
  final c = currency.trim().toUpperCase();
  if (c == 'USD' || c == r'$' || c == r'US$' || c == 'DOLLAR') return true;
  final t = blob.replaceAll('\u00a0', ' ').toLowerCase();
  if (t.contains('£') ||
      t.contains('gbp') ||
      t.contains('€') ||
      cachedRegExp(r'\beur\b').hasMatch(t)) {
    return false;
  }
  return t.contains(r'$') || cachedRegExp(r'\busd\b').hasMatch(t);
}

/// Shopify Dawn/page-editor default product (`from $399.99`), not a clinic menu.
bool looksLikeShopifyThemeDummyPrice({
  required String rawPriceText,
  required double priceMin,
  required String currency,
  String rawEvidence = '',
  String procedure = '',
}) {
  final blob = '$rawPriceText\n$rawEvidence\n$procedure'
      .replaceAll('\u00a0', ' ')
      .toLowerCase();
  if (cachedRegExp(
    r'page\s*editor|lorem ipsum|placeholder product|theme preview',
  ).hasMatch(blob)) {
    return true;
  }
  if (!currencyLooksLikeUsd(currency, blob)) return false;
  if (cachedRegExp(r'\$\s*399(?:\.99)?\b|\b399\.99\b').hasMatch(blob)) {
    return true;
  }
  final rounded = priceMin.round();
  if ((priceMin - 399.99).abs() < 0.02 || rounded == 399 || rounded == 400) {
    return cachedRegExp(r'399|from\s*\$').hasMatch(blob);
  }
  return false;
}

/// `$` / USD on a UK host is a theme dummy or a misread, never a London menu.
bool looksLikeUsdQuotedOnUkHost({
  required String sourceUrl,
  required String currency,
  String rawPriceText = '',
  String rawEvidence = '',
}) {
  if (sourceUrl.trim().isEmpty) return false;
  if (!hostLooksLikeUkClinic(sourceUrl)) return false;
  return currencyLooksLikeUsd(currency, '$rawPriceText\n$rawEvidence');
}

/// Google AI Overview / aggregator chrome — not a clinic `Cost:` menu row.
bool looksLikeSearchQuickFactsBlob(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').trim();
  if (t.isEmpty) return false;
  if (cachedRegExp(
    r'rezumat generat de ai|'
    r'\bai overview\b|'
    r'\bwhat to expect\b|'
    r'\bgeneral (?:uae|dubai|abu dhabi) pricing\b|'
    r'cost breakdown\s*&\s*factors|'
    r'\bstarts around\b|'
    r'\bmedigence\b',
    caseSensitive: false,
  ).hasMatch(t)) {
    return true;
  }
  if (!cachedRegExp(r'\bquick facts\b', caseSensitive: false).hasMatch(t)) {
    return false;
  }
  return !looksLikeClinicLabeledCostFact(t);
}

/// SEO title/H1 such as "Laser Hair Removal Price Abu Dhabi — From AED 100".
bool looksLikeSeoQuotedPriceHeadline(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').trim();
  if (t.isEmpty) return false;
  if (cachedRegExp(r'\bquick facts\b', caseSensitive: false).hasMatch(t) &&
      !looksLikeClinicLabeledCostFact(t)) {
    return true;
  }
  final lo = t.toLowerCase();
  final hasPriceWord = cachedRegExp(
    r'\b(price|prices|cost|costs|pricing|tarif|precio|preț|pret)\b',
    caseSensitive: false,
  ).hasMatch(lo);
  if (!hasPriceWord) return false;
  final titleLike = t.contains('|') ||
      cachedRegExp(r'[—–-]\s*from\b', caseSensitive: false).hasMatch(lo) ||
      cachedRegExp(
        r'\bprice\s+(?:in\s+)?(?:abu dhabi|dubai|sharjah)\b',
        caseSensitive: false,
      ).hasMatch(lo);
  if (!titleLike) return false;
  final stuffedCity = cachedRegExp(
    r'\b(abu dhabi|dubai|sharjah|uae|united arab emirates)\b',
    caseSensitive: false,
  ).hasMatch(lo);
  final fromAmount = cachedRegExp(
    r'\b(from|starting(?:\s+from)?|starts\s+from)\b.{0,24}'
    r'(?:aed|usd|eur|gbp|dhs|dirhams?|€|£|\$)?\s*\d',
    caseSensitive: false,
  ).hasMatch(lo);
  if (stuffedCity && fromAmount) return true;
  if (stuffedCity && (t.contains('|') || t.contains('—') || t.contains('–'))) {
    return true;
  }
  return false;
}

/// Gold/platinum bundles that mix laser + hydrafacial + meso, not Botox.
bool looksLikeMixedServiceBundle(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').trim();
  if (t.isEmpty) return false;
  if (cachedRegExp(
    r'الباقة\s*(الذهبية|الماسية|البلاتينية)|'
    r'\b(gold|diamond|platinum)\s+package\b|'
    r'اختر أي\s*\d|'
    r'choose any\s+\d|'
    r'any\s+\d\s+of the following|'
    r'hydrafacial.{0,80}(?:anti[\s-]?wrinkle|botox)|'
    r'(?:anti[\s-]?wrinkle|botox).{0,80}hydrafacial',
    caseSensitive: false,
  ).hasMatch(t)) {
    return true;
  }
  // A combined skin-booster + neurotoxin service is not the price of either
  // treatment alone. Require a connector so separate tariff rows survive.
  const booster = r'(?:skin[\s-]*boosters?|profhilo|jalupro|rejuran)';
  const toxin =
      r'(?:neuromodul\w*|neurotoxin\w*|botox|b[oó]tox|botulin\w*|'
      r'toxina\s+botulin\w*|anti[\s-]?wrinkle)';
  const connector = r'\s*(?:\+|&|and|y|con|with|plus)\s*';
  return cachedRegExp(
    '\\b$booster$connector$toxin\\b|\\b$toxin$connector$booster\\b',
    caseSensitive: false,
  ).hasMatch(t);
}

/// Surgical chin augmentation must not inherit the injectable filler family.
/// Only row-local injectable evidence can disambiguate a mentoplasty URL;
/// unrelated HA copy elsewhere on a surgical page cannot establish a price.
bool looksLikeSurgicalChinProcedure({
  String label = '',
  String evidence = '',
  String sourceUrl = '',
}) {
  final rowLabel = foldExploreCityText(label);
  final rowEvidence = foldExploreCityText(evidence);
  final local = '$rowLabel\n$rowEvidence';
  final uri = Uri.tryParse(sourceUrl);
  final path = foldExploreCityText(uri?.path ?? '')
      .replaceAll(cachedRegExp(r'[/_.-]+'), ' ');
  final surgery = cachedRegExp(
    r'\b(?:mentoplast\w*|genioplast\w*)\b|'
    r'\bchin\s+(?:implants?|reduction|surgery|osteotomy)\b|'
    r'\b(?:implants?|reduction|osteotomy)\s+(?:of\s+(?:the\s+)?)?chin\b|'
    r'\b(?:implante\w*|protesis|reduccion|cirugia|osteotomia)\s+'
    r'(?:de\s+|del\s+)?menton\b|'
    r'\bmenton\s+(?:con\s+)?(?:implante\w*|protesis)\b',
  );
  final nonSurgical = cachedRegExp(
    r'\bnon[\s-]?surgical\b|\bnonsurgical\b|'
    r'\bsin\s+cirugia\b|\bno\s+quirurgic\w*\b|'
    r'\bfara\s+operatie\b',
  );
  final injectable = cachedRegExp(
    r'\bhyaluron\w*\b|\b(?:acido|acid)\s+hialuron\w*\b|'
    r'\b(?:juvederm|restylane|teosyal|belotero|revolax|radiesse)\b|'
    r'\binject\w*\b|\binfiltrac\w*\b|\bsyringes?\b|\bjeringas?\b',
  ).hasMatch(local);
  // Explicit surgery labels remain surgical even if the evidence also quotes
  // an injectable treatment from a neighbouring menu row.
  if (surgery.hasMatch(rowLabel) &&
      !(nonSurgical.hasMatch(rowLabel) && injectable)) {
    return true;
  }
  if (surgery.hasMatch(rowEvidence) &&
      !(injectable && nonSurgical.hasMatch(local))) {
    return true;
  }
  if (surgery.hasMatch(path) && !injectable) return true;
  return false;
}

/// Revision, trauma reconstruction and functional surgery have distinct fees.
/// Ultrasound is a primary-surgery technique, so it remains eligible for a
/// general rhinoplasty request. Specific requests may use their matching row.
bool looksLikeNonGenericRhinoplastyVariant({
  required String procedure,
  String label = '',
  String evidence = '',
  String sourceUrl = '',
}) {
  final requested = foldExploreCityText(procedure);
  if (!cachedRegExp(r'rhinoplast|rinoplast|nose\s+job').hasMatch(requested)) {
    return false;
  }
  final candidate = foldExploreCityText('$label\n$evidence');
  final path = foldExploreCityText(Uri.tryParse(sourceUrl)?.path ?? '')
      .replaceAll(cachedRegExp(r'[/_.-]+'), ' ');
  for (final subtype in _distinctRhinoplastySubtypes) {
    if ((subtype.hasMatch(candidate) || subtype.hasMatch(path)) &&
        !subtype.hasMatch(requested)) {
      return true;
    }
  }
  return false;
}

final _distinctRhinoplastySubtypes = [
  cachedRegExp(r'\b(?:secondary|secondaria|secundaria|secondaire|revision\w*)\b'),
  cachedRegExp(r'\bpost[\s-]*traum\w*\b|\btraumati\w*\b'),
  cachedRegExp(r'\bfunctional\b|\bfuncional\b|\bfunzional\w*\b|'
      r'\bseptor?hinoplast\w*\b|\bseptoplast\w*\b'),
];

bool looksLikeRequestedRhinoplastySubtype({
  required String procedure,
  required String candidate,
}) {
  final requested = foldExploreCityText(procedure);
  final row = foldExploreCityText(candidate);
  final present = _distinctRhinoplastySubtypes.where((p) => p.hasMatch(row));
  return present.isNotEmpty && present.every((p) => p.hasMatch(requested));
}

/// "series of 3" / "3 for $600" is not a single-treatment starting price.
bool looksLikeMultiSessionSeriesQuote(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').toLowerCase();
  if (t.trim().isEmpty) return false;
  return cachedRegExp(
    r'\b(?:a\s+)?(?:full\s+)?series\s+(?:of\s+)?\d|'
    r'\bfull series\b|'
    r'\bpackage of\s+\d|'
    r'\b(?:series|package)\s+of\s+\d|'
    r'\b\d\s*(?:x|×)\s*(?:sessions?|treatments?|peels?)\b|'
    r'\b\d+\s+sessions?\s+for\b|'
    r'\b(?:[2-9]|[1-9]\d+)\s*(?:sesiones|sessions|sedinte|seances|sitzungen)\b|'
    r'\b3\s+for\s*[\$£€]|'
    r'\bpack(?:age)?\s+of\s+[3-9]\b',
    caseSensitive: false,
  ).hasMatch(t);
}

/// Cosmelan / Dermamelan kits are a depigmentation package (clinic + homecare),
/// not a comparable chemical peel facial session.
bool looksLikeDepigmentationPeelPackage(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').toLowerCase();
  if (t.isEmpty) return false;
  if (cachedRegExp(
    r'cosmelan|dermamelan|melanostop|'
    r'depigmentation\s+peel|pigmentation\s+peel\s+kit',
    caseSensitive: false,
  ).hasMatch(t)) {
    return true;
  }
  if (cachedRegExp(r'starter\s+kit').hasMatch(t) &&
      cachedRegExp(r'peel|homecare|home[\s-]?care').hasMatch(t)) {
    return true;
  }
  return false;
}

/// The menu row that owns [priceMin], not the next row.
String exploreLineOwningAmount(String evidence, double priceMin) {
  final text = evidence.replaceAll('\u00a0', ' ');
  if (text.trim().isEmpty || priceMin <= 0) return text;
  final target = priceMin.round().toString();
  final amount = cachedRegExp(r'\d{1,3}(?:[.\s]\d{3})+|\d+(?:[.,]\d+)?');
  final matches = amount.allMatches(text).toList();
  RegExpMatch? hit;
  for (final match in matches) {
    final digits = match.group(0)!.replaceAll(cachedRegExp(r'[.\s,]'), '');
    if (digits == target) {
      hit = match;
      break;
    }
  }
  if (hit == null) return text;
  var start = 0;
  for (final match in matches) {
    if (match.end <= hit.start) start = match.end;
  }
  var end = text.length;
  for (final match in matches) {
    if (match.start >= hit.end) {
      end = match.start;
      break;
    }
  }
  final later = text.substring(hit.end, end);
  final cut = cachedRegExp(
    r'cosmelan|dermamelan|\bkit\b|home\s*care|home\s*kit|pachet',
    caseSensitive: false,
  ).firstMatch(later);
  if (cut != null) end = hit.end + cut.start;
  return text.substring(start, end);
}

/// Package, kit, travel bundle, or a different surgery on this price's row.
bool explorePricedLineIsIncomparablePackage({
  required String procedure,
  required String evidence,
  required double priceMin,
}) {
  final line = exploreLineOwningAmount(evidence, priceMin).toLowerCase();
  if (line.trim().isEmpty) return false;
  final want = procedure.toLowerCase();
  final peel = want.contains('peel');
  final filler = want.contains('filler') || want.contains('hialur');
  final rhino = want.contains('rhino') || want.contains('nose job');
  final breast =
      want.contains('breast') || want.contains('augment') || want.contains('boob');
  final botox = want.contains('botox') || want.contains('wrinkle');
  if (peel &&
      (cachedRegExp(r'\bcorporal\w*|\bcuerpo\b|\bbody\b|\bscrub\b|\bsales\b|'
          r'\bsalt\b|\bsugar\b|autobronceador|enzim[aá]tic|enzymatic|'
          r'microdermabrasion|peel\s*off|gommage\s+corporel',
          caseSensitive: false).hasMatch('$procedure $line') ||
       looksLikeDepigmentationPeelPackage(line) ||
          cachedRegExp(r'\bdiamond\s+peel|carbon\s+(?:laser|peel)|microdermabrasion',
              caseSensitive: false).hasMatch(line) ||
          looksLikeMultiSessionSeriesQuote(line))) {
    return true;
  }
  if (filler &&
      cachedRegExp(
        r'box of|pack of|buy online|buy now|add to cart|shopping cart|webshop',
      ).hasMatch(line)) {
    return true;
  }
  if (rhino &&
      (looksLikeNonGenericRhinoplastyVariant(
        procedure: procedure,
        evidence: line,
      ) ||
          cachedRegExp(
            r'all[- ]inclusive|tutto incluso|\bflight\b|\bhotel\b|'
            r'ethnic\s+rhino|rinoplastia\s+(?:racial|[eé]tnica)',
          ).hasMatch(line))) {
    return true;
  }
  if (breast &&
      cachedRegExp(
        r'mastopexy|breast\s+lift|reconstruction|\blift\s*\+\s*implant',
      ).hasMatch(line)) {
    return true;
  }
  if (botox &&
      cachedRegExp(r'hyperhidrosis|masseter|bruxism').hasMatch(line) &&
      !cachedRegExp(r'forehead|glabella|crow|wrinkle|one area').hasMatch(line)) {
    return true;
  }
  return false;
}

bool publishedAmountMatchesWindow(String window, double priceMin) {
  if (window.trim().isEmpty || priceMin <= 0) return false;
  final digits = priceMin.round().toString();
  final compact = window.replaceAll(cachedRegExp(r'[,\s]'), '');
  return compact.contains(digits);
}

/// Google AI Overview / “typical in this city” copy — never a clinic menu.
/// Unlike [looksLikeMarketAveragePriceBlurb], a `Cost:` window must not
/// override this: “AED 600–2,500 per zone in the area” is not Tajmeels’ price.
bool looksLikeGoogleAreaEstimateBlurb(String raw) {
  final t = raw.replaceAll('\u00a0', ' ');
  if (t.trim().isEmpty) return false;
  return cachedRegExp(
    r'\bin the area\b|'
    r'\bgeneral aesthetic\b|'
    r'\btypically range\b|'
    r'\btypical(?:ly)?\s+(?:range|ranges)\s+from\b|'
    r'\btypical(?:ly)?\s+sessions?\s+rang|'
    r'\bprices?\s+vary\s+depending\b|'
    r'precise pricing.{0,100}consultation|'
    r'determined on an individual|'
    r'\bindividual basis\b|'
    r'rezumat generat de ai|'
    r'\bai overview\b|'
    r'\bai[- ]generated\b|'
    r'\bapproximately\b|'
    r'\baround\s+(?:aed|usd|eur|gbp|£|€|\$|درهم|د\.إ)\b|'
    r'\bstarts?\s+from\s+around\b|'
    r'has run from approximately|'
    r'\bper zone\b.{0,48}(?:typically|range|average)|'
    r'(?:typically|range|average).{0,48}\bper zone\b',
    caseSensitive: false,
  ).hasMatch(t);
}

bool looksLikeMarketAveragePriceBlurb(String raw) {
  if (looksLikeLocalizedMarketPriceEstimate(raw)) return true;
  final t = raw.toLowerCase();
  if (t.trim().isEmpty) return false;
  if (looksLikeGoogleAreaEstimateBlurb(raw)) return true;
  if (cachedRegExp(
    r'\bpromedio\b|\b(?:precio|coste|costo)s?\s+medi[oa]s?\b|'
    r'\baverage\s+(?:price|cost|range)(?:\s+range)?\s+(?:for|in|of)\b|'
    r'\btypical\s+(price|cost|range)\b|'
    r'\btypically\s+(?:range|ranging|cost|costs|priced)|'
    r'\bin\s+london\s+typically\b|'
    r'\blondon\s+(?:rhinoplasty|nose\s+job)\s+prices?\s+typically\b|'
    r'in the region typically|'
    r'starts around\s+(?:aed|usd|eur|gbp)?\s*\d|'
    r'price range for .{2,80} in |'
    r'\bcosts?\s+in\s+\w+\s+typically|'
    r'\bcost\s+(?:in\s+)?(?:dubai|abudhabi|abu dhabi|sharjah)\s+ranges|'
    r'(?:chemical\s+)?peels?\s+cost\s+(?:in\s+)?dubai\s+ranges|'
    r'\b(?:price|prices)\s+(?:in\s+)?(?:dubai|uae)\s+ranges|'
    r'\b(fillers?|botox|dermal fillers?|peels?)\s+cost in\b|'
    r'\bacross\s+[a-z\s]{2,30}\bclinics\b|'
    r'\bclinics\s+in\s+[a-z\s]{2,30}\s+(?:charge|start|range|ask)|'
    r'\b(?:generally|commonly|often|usually)\s+(?:range|ranges|cost|costs|start|starts)\b|'
    r'\bcan vary (?:between|significantly|widely|substantially)\b|'
    r'\bsurgery can vary\b|'
    r'\bgenerally falls within\b|'
    r'\bbasic hyaluronic acid fillers?\b|'
    r'\bpremium brand fillers?\b|'
    r'\bcommon prices?\b|'
    r'\bfamous (?:methods|procedures|treatments)\b.{0,48}\bin\b|'
    r'\bapproximate(?:ly)?\b.{0,40}\b(?:cost|price|prices)\b|'
    r'\bprices?\s+across\s+(?:clinics|the\s+(?:city|area|region))\b|'
    r'\bhigh[- ]end\b.{0,24}\b(?:budget\b)?clinics?\b|'
    r'\bbudget\b.{0,24}\bclinics?\b|'
    r'\bbreakdown of common\b|'
    r'\bmarket\s+(?:rate|price|average)\b|'
    r'\bgenel\s+piyasa\b|'
    r'\bpiyasa\s+(?:de[gğ]er|fiyat|ortalama)\b|'
    r'\baverage (?:starting )?price\s+(?:in|for|of|range)\b|'
    r'\baverage costs?\s+(?:in|for|of)\b|'
    r'should be no less than|'
    r'\bno less than\s+[£$€]?\s*\d|'
    r'\bcost of a good\b|'
    r'\bgood boob job\b|'
    r'most reputable clinics|'
    r'reputable clinics.{0,48}in this region|'
    r'\bin this region given\b|'
    r'\bstarts? at roughly\b|'
    r'\bwith only\b.{0,48}\b(?:euros?|€|breast|botox|filler)\b|'
    r'\bbreast augmentation in \w+ offers\b|'
    r'\bin albania (?:offers|starts|range|prices)\b|'
    r'\bcost of breast augmentation in\b|'
    r'\ba breast augmentation starts at roughly\b',
    caseSensitive: false,
  ).hasMatch(t)) {
    return true;
  }
  if (cachedRegExp(
    r'تتراوح\s+تكلفة.{0,80}في\s+(?:دبي|أبوظبي|أبو ظبي|الشارقة)\s+بين|'
    r'متوسط\s+تكلفة|'
    r'متوسط\s+سعر|'
    r'التكلفة\s+العادية|'
    r'التكلفة\s+المتوسطة',
  ).hasMatch(raw)) {
    return true;
  }
  final general = t.contains('in general') ||
      t.contains('în general') ||
      t.contains('on average') ||
      t.contains('preț mediu') ||
      t.contains('pret mediu') ||
      t.contains('prix moyen') ||
      t.contains('precio medio');
  if (!general) return false;
  return t.contains('cost') ||
      t.contains('preț') ||
      t.contains('pret') ||
      t.contains('precio') ||
      t.contains('price');
}

/// Comparison-table headers / provider rows that quote *other* clinics.
bool looksLikeCompetitorPriceColumnHeader(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').toLowerCase().trim();
  if (t.isEmpty) return false;
  return cachedRegExp(
    r'high street salon|'
    r'non[- ]medical|'
    r'harley street average|'
    r'harley street clinics|'
    r'central london average|'
    r'other clinics?|'
    r'other providers?',
    caseSensitive: false,
  ).hasMatch(t);
}

/// "Harley Street (doctor-led, 1 area)" in a vs-us table — not this clinic.
bool looksLikeThirdPartyProviderPriceLabel(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').toLowerCase();
  if (t.trim().isEmpty) return false;
  if (looksLikeCompetitorPriceColumnHeader(t)) return true;
  return cachedRegExp(
    r'harley street\s*\((?:doctor[- ]led|avg|average)|'
    r'high street salon|'
    r'central london average|'
    r'your saving vs',
    caseSensitive: false,
  ).hasMatch(t);
}

/// Warning copy / market tables that quote someone else's Botox amount.
bool looksLikeCompetitorOrThirdPartyPriceQuote(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').toLowerCase();
  if (t.trim().isEmpty) return false;
  if (looksLikeCompetitorPriceColumnHeader(t)) return true;
  return cachedRegExp(
    r'some clinics that are offering|'
    r'ridiculously cheap|'
    r'cheapest is not always best|'
    r'other clinics (?:that )?are offering|'
    r'clinics that are offering|'
    r'other providers|'
    r'other practitioners|'
    r'unscrupulous practitioners|'
    r'fake botox|'
    r'high street salon|'
    r'harley street average|'
    r'central london average',
    caseSensitive: false,
  ).hasMatch(t);
}

/// City-wide “common prices / famous methods” guide copy — not a clinic menu.
bool looksLikeCityCommonPriceGuideBlurb(String raw) {
  final t = raw.replaceAll('\u00a0', ' ');
  if (t.trim().isEmpty) return false;
  return cachedRegExp(
    r'\bcommon prices?\b|'
    r'\bfamous (?:methods|procedures|treatments)\b.{0,60}\bin\b|'
    r'\bbreakdown of (?:common |typical )?prices?\b|'
    r'\bprices? (?:can )?vary (?:substantially|significantly|widely)\b|'
    r'\bhigh[- ]end\b.{0,30}\bclinics?\b|'
    r'\bbudget\b.{0,30}\bclinics?\b|'
    r'\bapproximate(?:ly)?\b.{0,40}\b(?:cost|price)|'
    r'\bprices?\s+across\s+(?:clinics|the\s+(?:city|area|region))\b|'
    r'\btypical london price ranges\b|'
    r'\bprices? vary among surgeons\b|'
    r'\bhelpful reference\b|'
    r'\bon average:\b',
    caseSensitive: false,
  ).hasMatch(t);
}

/// EUR/GBP/USD-like sanity band. RON/LEI use a ~5x scale. Never clamp.
({double min, double max}) plausibleAmountBand({
  required String currency,
  required String procedure,
}) {
  final curr = currency.trim().toUpperCase();
  final proc = procedure.toLowerCase();
  var min = 10.0;
  var max = 100000.0;

  final botox = proc.contains('botox') ||
      proc.contains('toxin') ||
      proc.contains('dysport') ||
      proc.contains('xeomin');
  final filler = proc.contains('filler') ||
      proc.contains('hialuron') ||
      proc.contains('hyaluron') ||
      proc.contains('relleno') ||
      proc.contains('labio');
  final laser = proc.contains('laser') ||
      proc.contains('epilare') ||
      proc.contains('depilacion');
  final peel = proc.contains('peel');
  final rhino = proc.contains('rhino') ||
      proc.contains('rinoplast') ||
      proc.contains('nose');
  final breast = proc.contains('breast') ||
      proc.contains('boob') ||
      proc.contains('pecho') ||
      proc.contains('mamar');
  final hair = proc.contains('hair') ||
      proc.contains('fue') ||
      proc.contains('injerto') ||
      proc.contains('transplant');

  if (botox) {
    // Session totals and per-unit rates share this band; per-unit AED ~25–60
    // is a published starting price, not an implausible amount.
    // Cap sessions ~€800 / ~4000 RON — Cronos Med Timisoara lists 1–3 zones
    // at 920–1770 lei; 6500 RON was a surgery quote mis-attached as Botox.
    min = 8;
    max = 800;
    if (curr == 'BGN') {
      min = 80;
      max = 4000;
    }
  } else if (filler) {
    min = 30;
    max = 5000;
  } else if (laser || peel) {
    min = 10;
    max = 5000;
  } else if (rhino) {
    // Cosmedica / RO menus publish primary rhino from €1,800–€2,000.
    // Keep the floor below that published band — not at 2000.
    min = 1500;
    max = 100000;
  } else if (breast) {
    // GBP full augmentation in 2026 is not a £500–£3,500 “from” on a cost guide.
    // EUR/TRY medical-tourism menus still use the 500 floor.
    min = 500;
    max = 100000;
  } else if (hair) {
    min = 300;
    max = 100000;
  }

  if (curr == 'RON' || curr == 'LEI' || curr == 'MDL') {
    return (min: min * 5, max: max * 5);
  }
  // Albanian lek (~100 ALL ≈ €1). Klaudia'S Aesthetic lists lip filler at
  // 15–25k ALL; without this scale every Tirana Fresha menu failed the
  // eurozone filler ceiling of 5,000.
  if (curr == 'ALL' || curr == 'LEK') {
    return (min: min * 80, max: max * 120);
  }
  if (curr == 'TRY' || curr == 'TL') {
    return (min: min * 10, max: max * 35);
  }
  if (curr == 'KRW' || curr == '₩') {
    return (min: min * 400, max: max * 2000);
  }
  if (curr == 'JPY' || curr == '¥') {
    return (min: min * 50, max: max * 200);
  }
  if (curr == 'IDR' || curr == 'RP') {
    return (min: min * 5000, max: max * 20000);
  }
  if (curr == 'INR' || curr == '₹') {
    return (min: min * 30, max: max * 100);
  }
  if (curr == 'THB' || curr == '฿') {
    return (min: min * 12, max: max * 40);
  }
  if (curr == 'HUF') {
    return (min: min * 120, max: max * 400);
  }
  if (curr == 'CZK') {
    return (min: min * 8, max: max * 30);
  }
  if (curr == 'COP' || curr == 'CLP' || curr == 'ARS') {
    return (min: min * 200, max: max * 2000);
  }
  if (curr == 'AED' || curr == 'SAR' || curr == 'QAR') {
    // The €800 Botox session cap is about 3,200 AED. A flat ×2 (1,600)
    // rejected a published Dubai starting price of AED 1,800.
    final scaledMax = botox ? max * 4 : max * 2;
    return (min: min, max: scaledMax);
  }
  if (curr == 'KWD' || curr == 'BHD' || curr == 'OMR') {
    return (min: (min / 4).clamp(1, min), max: max / 2);
  }
  if ((curr == 'GBP' || curr == '£') && breast) {
    min = min < 4000 ? 4000 : min;
  }
  return (min: min, max: max);
}

double _priceMaxHintFromRaw(String rawPriceText, double priceMin) {
  final t = rawPriceText.replaceAll('\u00a0', ' ');
  final m = cachedRegExp(
    r'(\d{1,3}(?:,\d{3})+|\d+)\s*(?:€|£|\$|eur|euro|gbp|usd)?\s*[–—-]\s*'
    r'(?:€|£|\$|eur|euro|gbp|usd)?\s*(\d{1,3}(?:,\d{3})+|\d+)',
    caseSensitive: false,
  ).firstMatch(t);
  if (m == null) return priceMin;
  final hi = double.tryParse((m.group(2) ?? '').replaceAll(',', '')) ?? 0;
  return hi > priceMin ? hi : priceMin;
}

/// Reject blocks already printed, so one page re-read by several waves does
/// not repeat the same eight lines. `debugPrint` is synchronous marshalling —
/// a 400-row menu re-scanned per candidate was itself stalling frames.
final Set<String> _loggedPriceRejects = <String>{};

@visibleForTesting
void resetLoggedPriceRejectsForTest() => _loggedPriceRejects.clear();

PriceSanityResult evaluateExtractedPriceCandidate({
  required String rawPriceText,
  required double priceMin,
  required String currency,
  required String extractionMethod,
  String rawEvidence = '',
  String rawProcedureText = '',
  String procedure = '',
  String sourceUrl = '',
  double priceMax = 0,
  bool structuredOffer = false,
  bool logRejects = true,
  String pageText = '',
  String pageTitle = '',
  String clinicName = '',
  String pageContextWire = '',
}) {
  final blob = '$rawPriceText\n$rawEvidence'.replaceAll('\u00a0', ' ');
  final method = extractionMethod.trim();
  final weak = isWeakPriceExtractionMethod(method);
  final structured = structuredOffer || isStructuredPriceExtractionMethod(method);

  var workingMin = priceMin;
  var workingMax = priceMax > priceMin ? priceMax : 0.0;

  // Repair joined range digits (2800–3000 → 28003000) before digit-cap reject.
  if (workingMin > 0) {
    final digits = workingMin.round().abs().toString().length;
    if (digits >= 7 || workingMin >= 50000) {
      final repaired = _repairedRangeFromRaw(rawPriceText) ??
          _repairedRangeFromRaw(blob);
      if (repaired != null &&
          repaired.min > 0 &&
          repaired.min < workingMin &&
          repaired.min.toString().length <= 6) {
        workingMin = repaired.min;
        workingMax = repaired.max > repaired.min ? repaired.max : workingMin;
      }
    }
  }

  void logReject(String reason) {
    if (!logRejects) return;
    final seenKey = '$reason|$sourceUrl|$procedure|$rawPriceText|$priceMin';
    if (!_loggedPriceRejects.add(seenKey)) return;
    if (_loggedPriceRejects.length > 2000) _loggedPriceRejects.clear();
    debugPrint(
      '[PRICE REJECT]\n'
      'reason=$reason\n'
      'priceMin=${workingMin.round()}\n'
      'priceMax=${(workingMax > workingMin ? workingMax : workingMin).round()}\n'
      'currency=$currency\n'
      'procedure=$procedure\n'
      'rawPriceText=$rawPriceText\n'
      'rawEvidence=${rawEvidence.length > 160 ? rawEvidence.substring(0, 160) : rawEvidence}\n'
      'sourceUrl=$sourceUrl\n'
      'extractionMethod=$method',
    );
    debugPrint('[GP PRICE] REJECT · $reason');
  }

  final sourceUri = Uri.tryParse(sourceUrl);
  final sourceHost = sourceUri?.host.toLowerCase() ?? '';
  if (const ['beautyforqueens.com', 'cliniciestetice.ro', 'clinici-estetice.ro']
      .any((host) => sourceHost == host || sourceHost.endsWith('.$host')) ||
      cachedRegExp(r'(?:^|/)(?:demo|template|example)(?:[-/]|$)', caseSensitive: false)
          .hasMatch(sourceUri?.path ?? '')) {
    logReject('directory_or_demo_price');
    return const PriceSanityResult.reject('directory_or_demo_price');
  }
  if (workingMin <= 0) {
    return const PriceSanityResult.reject('missing_price_semantics');
  }
  final injectableFailure = exploreInjectableScopeRejection(
    procedure: procedure, label: rawProcedureText, evidence: rawEvidence,
    provider: clinicName, sourceUrl: sourceUrl,
  );
  if (injectableFailure != null) {
    logReject(injectableFailure);
    return PriceSanityResult.reject(injectableFailure);
  }
  final nonTreatment = exploreNonTreatmentPriceReason(
    evidence: '$rawProcedureText\n${rawEvidence.isNotEmpty ? rawEvidence : rawPriceText}',
    priceMin: workingMin, currency: currency,
  );
  if (nonTreatment != null) {
    logReject(nonTreatment);
    return PriceSanityResult.reject(nonTreatment);
  }
  if (looksLikeNonGenericRhinoplastyVariant(
    procedure: procedure,
    label: rawProcedureText,
    evidence: exploreLineOwningAmount(blob, workingMin),
    sourceUrl: sourceUrl,
  )) {
    logReject('rhinoplasty_variant_not_requested');
    return const PriceSanityResult.reject('rhinoplasty_variant_not_requested');
  }
  if (looksLikeNonInjectableBotox('$procedure $blob $clinicName $sourceUrl')) {
    logReject('noninjectable_botox');
    return const PriceSanityResult.reject('noninjectable_botox');
  }
  if (cachedRegExp(r'botox|botulin|toxin|neuromodulat', caseSensitive: false).hasMatch(procedure) &&
      exploreBotoxAmountOwnedByFiller(evidence: rawEvidence, priceMin: workingMin, currency: currency)) {
    logReject('neighbouring_filler_amount');
    return const PriceSanityResult.reject('neighbouring_filler_amount');
  }
  if (explorePricedLineIsIncomparablePackage(
    procedure: procedure,
    evidence: rawEvidence.isNotEmpty ? rawEvidence : rawPriceText,
    priceMin: workingMin,
  )) {
    logReject('incomparable_procedure_line');
    return const PriceSanityResult.reject('incomparable_procedure_line');
  }

  final pageContext = pageContextWire.trim().isNotEmpty
      ? explorePricePageContextFromWire(pageContextWire)
      : method == 'official_article'
      ? ExplorePricePageContext.informationalArticle
      : classifyExplorePricePageContext(
          sourceUrl: sourceUrl,
          pageText: pageText.isNotEmpty ? pageText : rawEvidence,
          title: pageTitle.isNotEmpty ? pageTitle : procedure,
        );
  final proseLike = looksLikePricingProseProcedureTitle(procedure) ||
      looksLikeRawScrapedProcedureTitle(procedure) ||
      looksLikeCountryMarketPriceMarketing(blob) ||
      looksLikeMarketAveragePriceBlurb(blob);
  if (!exploreEvidenceIsClinicOwnedPrice(
    pageContext: pageContext,
    rawEvidence: rawEvidence,
    rawProcedureText: procedure,
    rawPriceText: rawPriceText,
    clinicName: clinicName,
    // A bound tariff table is structured evidence even when its inherited
    // heading describes hair loss in a full sentence. Page-level market and
    // guide contexts still enforce their explicit ownership requirement.
    treatProseAsUnowned: proseLike &&
        method.toLowerCase() != 'html_table' &&
        method.toLowerCase() != 'htmltable',
  )) {
    logReject('not_clinic_owned_price');
    return const PriceSanityResult.reject('not_clinic_owned_price');
  }

  if (looksLikeShopifyThemeDummyPrice(
        rawPriceText: rawPriceText,
        priceMin: workingMin,
        currency: currency,
        rawEvidence: rawEvidence,
        procedure: procedure,
      )) {
    logReject('theme_placeholder');
    return const PriceSanityResult.reject('theme_placeholder');
  }
  if (looksLikeUsdQuotedOnUkHost(
        sourceUrl: sourceUrl,
        currency: currency,
        rawPriceText: rawPriceText,
        rawEvidence: rawEvidence,
      )) {
    logReject('tld_currency_mismatch');
    return const PriceSanityResult.reject('tld_currency_mismatch');
  }

  final priceWithoutContacts = stripExplorePhoneContacts(rawPriceText);
  if ((rawPriceText.trim().isNotEmpty && priceWithoutContacts.isEmpty) ||
      looksLikePhoneNumber(priceWithoutContacts) ||
      looksLikePhoneNumber(stripExplorePhoneContacts(blob))) {
    logReject('phone_number');
    return const PriceSanityResult.reject('phone_number');
  }
  if (looksLikeEmergencyOrHelpNumber(
        rawPriceText,
        priceMin: workingMin,
        extractionMethod: method,
      ) ||
      looksLikeEmergencyOrHelpNumber(
        rawEvidence,
        priceMin: workingMin,
        extractionMethod: method,
      )) {
    logReject('help_number');
    return const PriceSanityResult.reject('help_number');
  }

  final intDigits = workingMin.round().abs().toString().length;
  final currUp = currency.trim().toUpperCase();
  const highDenom = {
    'KRW', 'JPY', 'IDR', 'VND', 'HUF', 'COP', 'CLP', 'ARS', 'IRR',
  };
  final digitCap = highDenom.contains(currUp) ? 12 : 8;
  final absCap = highDenom.contains(currUp) ? 1e12 : 1e8;
  if (workingMin >= absCap || intDigits >= digitCap) {
    logReject('implausible_amount');
    return const PriceSanityResult.reject('implausible_amount');
  }

  if (looksLikeAddressNumber(rawPriceText) ||
      (weak && looksLikeAddressNumber(blob))) {
    logReject('address_number');
    return const PriceSanityResult.reject('address_number');
  }

  if (looksLikeBrandEmbeddedDigitPrice(workingMin, blob) ||
      looksLikeBrandEmbeddedDigitPrice(workingMin, rawPriceText) ||
      looksLikeBrandEmbeddedDigitPrice(workingMin, procedure)) {
    logReject('brand_embedded_digits');
    return const PriceSanityResult.reject('brand_embedded_digits');
  }

  if (looksLikeNonTreatmentPriceLabel(rawPriceText) ||
      looksLikeNonTreatmentPriceLabel(procedure) ||
      looksLikeNonTreatmentPriceLabel(blob)) {
    logReject('non_treatment_label');
    return const PriceSanityResult.reject('non_treatment_label');
  }

  if (looksLikeDurationQuotedAsPrice(
        priceMin: workingMin,
        rawPriceText: rawPriceText,
        blob: blob,
      )) {
    logReject('duration');
    return const PriceSanityResult.reject('duration');
  }

  if (looksLikePercent(rawPriceText) && !hasCurrencySignal(rawPriceText)) {
    logReject('missing_price_semantics');
    return const PriceSanityResult.reject('missing_price_semantics');
  }

  if (looksLikeReviewCount(blob)) {
    logReject('missing_price_semantics');
    return const PriceSanityResult.reject('missing_price_semantics');
  }

  final yearBare = isBareYear(workingMin, blob);
  if (yearBare && !structured) {
    logReject('missing_price_semantics');
    return const PriceSanityResult.reject('missing_price_semantics');
  }
  if (looksLikeCalendarYearPrice(workingMin, blob)) {
    logReject('calendar_year');
    return const PriceSanityResult.reject('calendar_year');
  }
  if (looksLikeSearchQuickFactsBlob(blob) ||
      looksLikeSearchQuickFactsBlob(rawPriceText)) {
    logReject('search_quick_facts');
    return const PriceSanityResult.reject('search_quick_facts');
  }
  if (looksLikeGoogleAreaEstimateBlurb(blob) ||
      looksLikeGoogleAreaEstimateBlurb(rawPriceText)) {
    final own = clinicOwnPublishedPriceWindow(blob) ??
        clinicOwnPublishedPriceWindow(rawPriceText);
    final clinicOwnAmount =
        own != null && publishedAmountMatchesWindow(own, workingMin);
    if (!clinicOwnAmount) {
      logReject('market_average');
      return const PriceSanityResult.reject('market_average');
    }
  }
  if (looksLikeSeoQuotedPriceHeadline(blob) ||
      looksLikeSeoQuotedPriceHeadline(rawPriceText) ||
      looksLikeSeoQuotedPriceHeadline(procedure)) {
    logReject('seo_price_headline');
    return const PriceSanityResult.reject('seo_price_headline');
  }
  if (looksLikeMixedServiceBundle(rawProcedureText) ||
      looksLikeMixedServiceBundle(procedure) ||
      looksLikeMixedServiceBundle(blob) ||
      looksLikeMixedServiceBundle(rawPriceText)) {
    logReject('mixed_service_bundle');
    return const PriceSanityResult.reject('mixed_service_bundle');
  }
  final injectableRequest = cachedRegExp(
    r'filler|hyaluron|hialuron|relleno|botox|botulin|neuromodul|neurotoxin',
    caseSensitive: false,
  ).hasMatch(procedure);
  if (injectableRequest && looksLikeSurgicalChinProcedure(
    label: rawProcedureText.isNotEmpty ? rawProcedureText : procedure,
    evidence: blob,
    sourceUrl: sourceUrl,
  )) {
    logReject('surgical_chin_not_filler');
    return const PriceSanityResult.reject('surgical_chin_not_filler');
  }

  if (looksLikeCityMarketPricingGuideUrl(sourceUrl)) {
    logReject('market_information');
    return const PriceSanityResult.reject('market_information');
  }
  if (looksLikeTreatmentFinanceUrl(sourceUrl)) {
    logReject('finance_page');
    return const PriceSanityResult.reject('finance_page');
  }
  if (looksLikeMonthlyFinancingQuotedAsPrice(
        priceMin: workingMin,
        rawPriceText: rawPriceText,
        blob: blob,
      )) {
    logReject('monthly_financing');
    return const PriceSanityResult.reject('monthly_financing');
  }
  if (looksLikeTypicalMarketRangeQuotedAsPrice(
        priceMin: workingMin,
        rawPriceText: rawPriceText,
        blob: blob,
      )) {
    logReject('market_average');
    return const PriceSanityResult.reject('market_average');
  }
  if (cachedRegExp(
    r'\baverage\b[^.]{0,48}\bcost\b|\bcost in\b[^.]{0,40}\bis\b|'
    r'\bon average\b.{0,48}\b(?:cost|price|prices|range)\b|'
    r'\btypically costs?\b|'
    r'\bmight\s+cost\s+between\b|'
    r'\b(?:cost|price)s?\s+will\s+vary\s+depending\b|'
    r'\ba\s+typical\s+[^.?]{0,48}\b(?:might\s+|can\s+|may\s+)?cost\b',
    caseSensitive: false,
  ).hasMatch(blob)) {
    logReject('market_average');
    return const PriceSanityResult.reject('market_average');
  }

  if (looksLikeHairMarketPerGraftBlurb(blob) ||
      looksLikeHairMarketPerGraftBlurb(rawPriceText) ||
      looksLikeHairMarketPerGraftBlurb(procedure)) {
    logReject('hair_market_per_graft');
    return const PriceSanityResult.reject('hair_market_per_graft');
  }
  if (looksLikeHairFutWhenFueRequested(
    procedure: procedure,
    blob: '$blob\n$procedure',
  )) {
    logReject('hair_fut_not_fue');
    return const PriceSanityResult.reject('hair_fut_not_fue');
  }
  if (looksLikeHairStaleLandingQuote(
    sourceUrl: sourceUrl,
    blob: '$blob\n$procedure',
    priceMin: workingMin,
    priceMax: workingMax > workingMin ? workingMax : priceMax,
  )) {
    logReject('hair_stale_landing');
    return const PriceSanityResult.reject('hair_stale_landing');
  }
  if (looksLikeHairDhiWhenFueRequested(
    procedure: procedure,
    blob: '$blob\n$procedure',
  )) {
    logReject('hair_dhi_not_fue');
    return const PriceSanityResult.reject('hair_dhi_not_fue');
  }
  if (looksLikeHairMarketComparisonRow(blob) ||
      looksLikeHairMarketComparisonRow(rawPriceText)) {
    logReject('hair_market_comparison');
    return const PriceSanityResult.reject('hair_market_comparison');
  }
  if (looksLikeHairLargerThanStartingPackage(blob) ||
      looksLikeHairLargerThanStartingPackage(rawPriceText)) {
    logReject('hair_larger_package');
    return const PriceSanityResult.reject('hair_larger_package');
  }

  if (looksLikeMarketAveragePriceBlurb(blob)) {
    final own = clinicOwnPublishedPriceWindow(blob);
    final clinicOwnAmount =
        own != null && publishedAmountMatchesWindow(own, workingMin);
    if (!clinicOwnAmount) {
      logReject('market_average');
      return const PriceSanityResult.reject('market_average');
    }
  }

  if (looksLikeCityCommonPriceGuideBlurb(blob) ||
      looksLikeCityCommonPriceGuideBlurb(rawPriceText)) {
    final own = clinicOwnPublishedPriceWindow(blob);
    final clinicOwnAmount =
        own != null && publishedAmountMatchesWindow(own, workingMin);
    if (!clinicOwnAmount) {
      logReject('city_common_price_guide');
      return const PriceSanityResult.reject('city_common_price_guide');
    }
  }

  if (looksLikeThirdPartyProviderPriceLabel(procedure) ||
      looksLikeCompetitorOrThirdPartyPriceQuote(blob) ||
      looksLikeCompetitorOrThirdPartyPriceQuote(rawPriceText) ||
      looksLikeCompetitorOrThirdPartyPriceQuote(procedure)) {
    final own = clinicOwnPublishedPriceWindow(blob) ??
        clinicOwnPublishedPriceWindow(rawPriceText);
    final clinicOwnAmount =
        own != null && publishedAmountMatchesWindow(own, workingMin);
    if (!clinicOwnAmount) {
      logReject('competitor_quote');
      return const PriceSanityResult.reject('competitor_quote');
    }
  }

  final spreadMax = workingMax > workingMin
      ? workingMax
      : _priceMaxHintFromRaw(rawPriceText, workingMin);
  if (looksLikeRoundedMarketPriceSpread(
        priceMin: workingMin,
        priceMax: spreadMax,
        currency: currency,
        procedure: procedure,
      )) {
    logReject('market_price_spread');
    return const PriceSanityResult.reject('market_price_spread');
  }
  if (looksLikePatientAnecdotePrice(blob) ||
      looksLikePatientAnecdotePrice(rawPriceText)) {
    logReject('patient_anecdote');
    return const PriceSanityResult.reject('patient_anecdote');
  }
  if (looksLikePartialRhinoplastyStarting(rawPriceText) &&
      !looksLikePrimaryRhinoplastyStarting(rawPriceText) &&
      !looksLikeRequestedRhinoplastySubtype(
        procedure: procedure,
        candidate: rawPriceText,
      )) {
    logReject('rhino_tip_or_partial');
    return const PriceSanityResult.reject('rhino_tip_or_partial');
  }

  final currencyHere = currency.trim().isNotEmpty ||
      hasCurrencySignal(rawPriceText) ||
      hasCurrencySignal(blob);
  final pricingHere = hasPricingLanguage(rawPriceText) ||
      hasPricingLanguage(blob);

  if (!structured && !currencyHere && !pricingHere) {
    logReject('missing_price_semantics');
    return const PriceSanityResult.reject('missing_price_semantics');
  }
  if (weak && !currencyHere && !pricingHere) {
    logReject('missing_price_semantics');
    return const PriceSanityResult.reject('missing_price_semantics');
  }
  // "+" from a phone country code is not a currency.
  if (blob.contains('+') &&
      !currencyHere &&
      !pricingHere &&
      digitsOnly(blob).length >= 8) {
    logReject('phone_number');
    return const PriceSanityResult.reject('phone_number');
  }

  if (looksLikeGraftOrFollicleQuantity(rawPriceText) ||
      looksLikeGraftCountMistakenForPrice(priceMin: workingMin, blob: blob)) {
    logReject('graft_count');
    return const PriceSanityResult.reject('graft_count');
  }
  if (looksLikeEffectivePerGraftMarketing(blob) ||
      looksLikeEffectivePerGraftMarketing(rawPriceText) ||
      looksLikeEffectivePerGraftMarketing(procedure)) {
    logReject('effective_per_graft');
    return const PriceSanityResult.reject('effective_per_graft');
  }

  var band = plausibleAmountBand(currency: currency, procedure: procedure);
  if (looksLikePerGraftQuotedPrice(blob) ||
      looksLikePerGraftQuotedPrice(rawPriceText)) {
    if (workingMin > hairPerGraftPlausibleMax(currency)) {
      logReject('implausible_per_graft');
      return const PriceSanityResult.reject('implausible_per_graft');
    }
    band = (min: 1.0, max: hairPerGraftPlausibleMax(currency));
  }
  if (looksLikeBotoxPerUnitQuote(blob, procedure: procedure) ||
      looksLikeBotoxPerUnitQuote(rawPriceText, procedure: procedure)) {
    band = (min: 5.0, max: botoxPerUnitJustifiedMax(currency));
  }
  if (workingMin < band.min || workingMin > band.max) {
    logReject('implausible_amount');
    return const PriceSanityResult.reject('implausible_amount');
  }

  return const PriceSanityResult.accept();
}

/// When callers pass a concatenated range (`28003000` from `2800-3000`),
/// recover the real min/max from the raw text.
({double min, double max})? _repairedRangeFromRaw(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').trim();
  if (t.isEmpty) return null;
  final m = cachedRegExp(
    r'(\d{1,3}(?:[.,\s]\d{3})+|\d{3,6})\s*(?:–|—|-|to)\s*'
    r'(?:€|£|\$|eur|euro|gbp|usd)?\s*'
    r'(\d{1,3}(?:[.,\s]\d{3})+|\d{3,6})',
    caseSensitive: false,
  ).firstMatch(t);
  if (m == null) return null;
  double? parseChunk(String s) {
    final cleaned = s.replaceAll(cachedRegExp(r'[^\d.,]'), '');
    if (cachedRegExp(r'^\d{1,3}([.,]\d{3})+$').hasMatch(cleaned)) {
      return double.tryParse(cleaned.replaceAll(cachedRegExp(r'[.,]'), ''));
    }
    return double.tryParse(cleaned.replaceAll(',', ''));
  }

  final lo = parseChunk(m.group(1) ?? '');
  final hi = parseChunk(m.group(2) ?? '');
  if (lo == null || hi == null || lo <= 0 || hi < lo) return null;
  return (min: lo, max: hi);
}

bool isValidExtractedPriceCandidate({
  required String rawPriceText,
  required double priceMin,
  required String currency,
  required String extractionMethod,
  String rawEvidence = '',
  String rawProcedureText = '',
  String procedure = '',
  String sourceUrl = '',
  double priceMax = 0,
  bool structuredOffer = false,
  bool logRejects = true,
  String clinicName = '',
}) {
  return evaluateExtractedPriceCandidate(
    rawPriceText: rawPriceText,
    priceMin: priceMin,
    currency: currency,
    extractionMethod: extractionMethod,
    rawEvidence: rawEvidence,
    rawProcedureText: rawProcedureText,
    procedure: procedure,
    sourceUrl: sourceUrl,
    priceMax: priceMax,
    structuredOffer: structuredOffer,
    logRejects: logRejects,
    clinicName: clinicName,
  ).accepted;
}

void logPriceAccept({
  required String clinic,
  required String procedure,
  required String rawPriceText,
  required double parsedAmount,
  required String currency,
  required String extractionMethod,
  required String sourceUrl,
}) {
  debugPrint(
    '[GP PRICE] ACCEPT · clinic="$clinic" procedure="$procedure" '
    'raw="$rawPriceText" parsed=${parsedAmount.round()} $currency '
    'method=$extractionMethod url=$sourceUrl',
  );
}

/// Drop a poisoned cached numeric price. Ratings stay.
///
/// Valid e17 rows with complete locked evidence are migrated to e18 in-place
/// (no HTTP) by recalculating exact/from/unit semantics from stored text.
Map<String, Object?> stripInvalidCachedPriceJson(
  Map<String, Object?> row, {
  String procedure = '',
  String city = '',
  bool logRejects = true,
}) {
  final min = (row['price_min'] as num?)?.toDouble() ?? 0;
  if (min <= 0) return row;
  final scopeFailure = exploreInjectableScopeRejection(
    procedure: procedure.isNotEmpty ? procedure : '${row['procedure_canonical'] ?? row['brand'] ?? ''}',
    label: '${row['raw_procedure_text'] ?? ''}',
    evidence: '${row['procedure_detail'] ?? ''} ${row['price_evidence_text'] ?? ''}',
    provider: '${row['provider_clinic'] ?? row['name'] ?? ''}',
    sourceUrl: '${row['price_source_url'] ?? row['source_url'] ?? ''}',
  );
  if (scopeFailure != null) return {
    ...row, 'price_min': 0, 'price_max': 0, 'price_gbp': 0, 'price_label': '',
    'price_verified': false, 'verified': false, 'needs_revalidation': true,
    'price_verification_status': 'legacy_unverified', 'price_rejection_reason': scopeFailure,
  };
  final sourceType = '${row['source_type'] ?? row['source'] ?? ''}'.trim();
  final status = '${row['price_verification_status'] ?? ''}'.trim();
  if (sourceType == 'curated_public_site' && status == 'curated_public_site') {
    return row;
  }
  final rawPrice = '${row['raw_price_text'] ?? row['price_label'] ?? ''}'.trim();
  final currency = '${row['currency'] ?? ''}'.trim();
  final method = '${row['extraction_method'] ?? ''}'.trim();
  final evidence = '${row['price_evidence_text'] ?? ''}'.trim();
  final proc = procedure.trim().isNotEmpty
      ? procedure
      : '${row['brand'] ?? row['raw_procedure_text'] ?? ''}'.trim();
  final rawProc =
      '${row['raw_procedure_text'] ?? row['brand'] ?? ''}'.trim();
  final extractRev = '${row['price_extract_revision'] ?? ''}'.trim();
  final sourceUrl =
      '${row['price_source_url'] ?? row['source_url'] ?? ''}'.trim();
  final evidenceHash = '${row['evidence_hash'] ?? ''}'.trim();

  var working = Map<String, Object?>.from(row);
  if (extractRev == 'e17' &&
      rawPrice.isNotEmpty &&
      rawProc.isNotEmpty &&
      sourceUrl.isNotEmpty &&
      method.isNotEmpty &&
      currency.isNotEmpty &&
      (evidence.isNotEmpty || evidenceHash.isNotEmpty)) {
    final migrated = migrateE17CachedPriceRow(
      working,
      procedure: proc,
      city: city,
      logRejects: logRejects,
    );
    if (migrated != null) {
      working = migrated;
    }
  }

  final stampOk =
      '${working['price_extract_revision'] ?? ''}'.trim() ==
          kExplorePriceExtractRevision;
  final verdict = stampOk
      ? evaluateExtractedPriceCandidate(
        rawPriceText: rawPrice,
        priceMin: (working['price_min'] as num?)?.toDouble() ?? min,
        currency: '${working['currency'] ?? currency}'.trim(),
        extractionMethod: method,
        rawEvidence: evidence,
        rawProcedureText: rawProc,
        procedure: proc,
        sourceUrl: sourceUrl,
        clinicName: '${working['provider_clinic'] ?? working['name'] ?? ''}',
        priceMax: (working['price_max'] as num?)?.toDouble() ?? 0,
        logRejects: logRejects,
      )
      : const PriceSanityResult.reject('stale_extract_revision');
  if (verdict.accepted) return working;
  final next = Map<String, Object?>.from(working);
  next['price_min'] = 0;
  next['price_max'] = 0;
  next['price_gbp'] = 0;
  next['price_label'] = '';
  next['price_verified'] = false;
  next['verified'] = false;
  next['price_verification_status'] = 'legacy_unverified';
  next['needs_revalidation'] = true;
  next['price_extract_revision'] = '';
  next['price_rejection_reason'] = verdict.reason;
  return next;
}

/// Deterministic e17 → e18 rewrite from locked evidence. Returns null when
/// the row must be network-reverified or discarded.
Map<String, Object?>? migrateE17CachedPriceRow(
  Map<String, Object?> row, {
  String procedure = '',
  String city = '',
  bool logRejects = true,
}) {
  final sourceUrl =
      '${row['price_source_url'] ?? row['source_url'] ?? ''}'.trim();
  final searchCity = city.trim();
  if (searchCity.isNotEmpty &&
      sourceUrl.isNotEmpty &&
      exploreUrlConflictsWithSearchCity(sourceUrl, searchCity)) {
    if (logRejects) {
      debugPrint(
        '[GP PRICE] MIGRATE reject other_city · $sourceUrl · $searchCity',
      );
    }
    return null;
  }
  final name = '${row['name'] ?? row['clinicName'] ?? ''}'.trim();
  final hostLo = sourceUrl.toLowerCase();
  // Directory domains must never migrate into a visible clinic card.
  if (cachedRegExp(
        r'(?:^|[./])(?:med\.ro|whatclinic|bookimed|doctoralia|zwivel|groupon)\b',
      ).hasMatch(hostLo) ||
      cachedRegExp(
        r'\b(?:whatclinic|bookimed|doctoralia|med\.ro)\b',
        caseSensitive: false,
      ).hasMatch(name)) {
    return null;
  }
  final rawPrice = '${row['raw_price_text'] ?? row['price_label'] ?? ''}'.trim();
  final blob =
      '$rawPrice ${row['price_evidence_text'] ?? ''} ${row['raw_procedure_text'] ?? ''}';
  final inferred = inferLockedEvidencePriceSemantics(
    blob,
    priceMin: (row['price_min'] as num?)?.toDouble() ?? 0,
  );
  final next = Map<String, Object?>.from(row);
  next['price_type'] = inferred.priceType;
  next['priceType'] = inferred.priceType;
  if (inferred.unit.isNotEmpty) {
    next['price_unit'] = inferred.unit;
    next['unit'] = inferred.unit;
  } else if (inferred.priceType != 'perUnit' &&
      inferred.priceType != 'perArea') {
    // Clear stale /ml from e17 auto-upgrade.
    final prevUnit = '${row['price_unit'] ?? row['unit'] ?? ''}'.toLowerCase();
    if (prevUnit == 'ml' || prevUnit == 'cc') {
      next['price_unit'] = '';
      next['unit'] = '';
    }
  }
  next['price_extract_revision'] = kExplorePriceExtractRevision;
  next['extractRevision'] = kExplorePriceExtractRevision;
  next['needs_revalidation'] = false;
  if (logRejects) {
    debugPrint(
      '[GP PRICE] MIGRATE e17→e18 · ${row['name']} · '
      '${inferred.priceType}'
      '${inferred.unit.isNotEmpty ? "/${inferred.unit}" : ""} · no HTTP',
    );
  }
  return next;
}

/// e18 semantics from locked text: exact unless "from"/range; /ml only when
/// the source literally prices per unit.
({String priceType, String unit}) inferLockedEvidencePriceSemantics(
  String blob, {
  double priceMin = 0,
}) {
  final t = blob.toLowerCase();
  final explicitPerUnit = cachedRegExp(
    r'(?:per|/)\s*(?:ml|cc|iu|unit|units|syringe|syringes|vial)\b',
    caseSensitive: false,
  ).hasMatch(t);
  final explicitPerArea = cachedRegExp(
    r'(?:per|/)\s*(?:area|areas|zone|zones)\b',
    caseSensitive: false,
  ).hasMatch(t);
  final hasFrom = cachedRegExp(
    r'\b(?:from|starting\s+from|starts?\s+from|de la|desde|a partir)\b',
    caseSensitive: false,
  ).hasMatch(t);
  final hasRange = cachedRegExp(r'\d[\d.,]*\s*[–\-—]\s*\d').hasMatch(t);
  if (explorePublishedPriceIsApproximate(evidence: blob, priceMin: priceMin)) {
    return (
      priceType: 'approximate',
      unit: explicitPerUnit ? _unitFromBlob(t) : (explicitPerArea ? 'area' : ''),
    );
  }
  if (explicitPerUnit) return (priceType: 'perUnit', unit: _unitFromBlob(t));
  if (explicitPerArea) return (priceType: 'perArea', unit: 'area');
  if (hasFrom) return (priceType: 'from', unit: '');
  if (hasRange) return (priceType: 'range', unit: '');
  return (priceType: 'fixed', unit: '');
}

String _unitFromBlob(String t) {
  final m = cachedRegExp(
    r'(?:per|/)\s*(ml|cc|iu|unit|units|syringe|area|zone)\b',
    caseSensitive: false,
  ).firstMatch(t);
  return (m?.group(1) ?? '').toLowerCase();
}
