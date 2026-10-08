import '../services/openai_service.dart';
import '../services/explore_clinic_identity.dart';
import '../services/explore_html_price_extractor.dart';
import '../services/explore_price_ownership.dart';
import '../services/explore_price_sanity.dart';
import '../services/explore_procedure_family.dart';
import '../services/explore_price_binding.dart';

String _formatComparePriceNum(double v, {bool compactThousands = true}) {
  if (compactThousands && v >= 10000) {
    final k = (v / 1000).round();
    return '${k}k';
  }
  // Listed clinic euros: keep 299, never round 299.4/299.5 up to 300.
  final n = (v - v.truncateToDouble()).abs() < 0.05
      ? v.truncate()
      : v.truncate();
  final s = n.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}

String _formatCompareRangeBody(double lo, double hi, String currency) {
  final cur = currency.trim();
  // Compact high surgery ranges: 15,000–25,000 → 15–25k.
  // When only the high end is ≥10k, keep the low end as a full amount (350–25k).
  if (lo >= 10000 || hi >= 10000) {
    final hiK = (hi / 1000).round();
    final String body;
    if (lo >= 10000) {
      final loK = (lo / 1000).round();
      body = loK == hiK ? '${loK}k' : '$loK–${hiK}k';
    } else {
      body = '${_formatComparePriceNum(lo)}–${hiK}k';
    }
    if (cur.isEmpty) return body;
    return '$body $cur';
  }
  final loN = _formatComparePriceNum(lo);
  final hiN = _formatComparePriceNum(hi);
  if (cur.isEmpty) return '$loN–$hiN';
  return '$loN–$hiN $cur';
}

/// One clinic's published min–max. A range already means from–to, so no
/// "from" prefix, and no 15k shorthand — `$5,000–$15,000`.
String _formatPublishedCardRange(double lo, double hi, String currency) {
  final loN = _formatComparePriceNum(lo, compactThousands: false);
  final hiN = _formatComparePriceNum(hi, compactThousands: false);
  final cur = currency.trim();
  if (cur == r'$' || cur.toUpperCase() == 'USD') {
    return '\$$loN–\$$hiN';
  }
  if (cur == '£' || cur.toUpperCase() == 'GBP') {
    return '£$loN–£$hiN';
  }
  if (cur == '€' || cur.toUpperCase() == 'EUR') {
    return '€$loN–€$hiN';
  }
  if (cur.isEmpty) return '$loN–$hiN';
  return '$loN–$hiN $cur';
}

/// Strips model suffixes like "per session" for a compact price line.
String _stripComparePriceNoise(String raw) {
  var t = raw.trim();
  if (t.isEmpty) return t;
  t = t.replaceAll(
    RegExp(r'\s*/\s*per\s+sessions?\b', caseSensitive: false),
    '',
  );
  t = t.replaceAll(RegExp(r'\bper\s+sessions?\b\.?', caseSensitive: false), '');
  t = t.replaceAll(RegExp(r'\s*/\s*pe\s+sesiuni?\b', caseSensitive: false), '');
  t = t.replaceAll(RegExp(r'\bpe\s+sesiuni?\b\.?', caseSensitive: false), '');
  t = t.replaceAll(
    RegExp(r'\s*interval\s+de\s+pre[țt]u\w*.*$', caseSensitive: false),
    '',
  );
  t = t.replaceAll(
    RegExp(r'\s*\bprice\s+range\b.*$', caseSensitive: false),
    '',
  );
  t = t.replaceAll(
    RegExp(
      r'\s*\(\s*varies\s+with\s+(?:the\s+)?(?:number\s+of\s+)?(?:areas?|zones?)\s*\)',
      caseSensitive: false,
    ),
    '',
  );
  t = t.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
  return t.replaceAll(RegExp(r'[\s/·–\-—,]+$'), '').trim();
}

String _stripLeadingFromPrefix(String s) {
  final t = s.trim();
  if (t.length > 5 && t.toLowerCase().startsWith('from ')) {
    return t.substring(5).trim();
  }
  return t;
}

String _formatFromComparePrice(double amount, String currency) {
  final lo = _formatComparePriceNum(amount);
  final cur = currency.trim();
  if (cur.isEmpty) return 'from $lo';
  // Always amount then currency (codes and symbols).
  return 'from $lo $cur';
}

String _formatExactComparePrice(double amount, String currency) {
  final lo = _formatComparePriceNum(amount);
  final cur = currency.trim();
  if (cur.isEmpty) return lo;
  return '$lo $cur';
}

/// Exact published price — not a "from"/starting band.
///
/// Prefer an explicit [OpenAIClinic.priceType] of `fixed`/`exact`. Otherwise
/// only suppress "from" when the source text has no starting-price wording and
/// min==max.
bool exploreClinicShowsExactPrice(OpenAIClinic c) {
  final type = c.priceType.trim().toLowerCase();
  if (type == 'from' ||
      type == 'range' ||
      type == 'perunit' ||
      type == 'per_unit' ||
      type == 'perarea' ||
      type == 'per_area') {
    return false;
  }
  if (c.priceMax > c.priceMin + 0.5) return false;
  final blob = '${c.rawPriceText} ${c.priceLabel} ${c.priceEvidenceText}'
      .toLowerCase();
  if (RegExp(
    r'\b(?:from|starting\s+(?:from|at|price|cost)|starts?\s+(?:from|at)|de la|desde|a partir)\b',
  ).hasMatch(blob)) {
    return false;
  }
  // Only treat as exact when the extractor marked it fixed/exact.
  // Legacy rows without priceType keep the historical "from" card style.
  return type == 'fixed' || type == 'exact';
}

String _ensureFromPrefix(String body) {
  final t = body.trim();
  if (t.isEmpty) return t;
  if (t.toLowerCase().startsWith('from ')) return t;
  return 'from $t';
}

/// Compacts long typical-range strings: "from 15,000–25,000 $" → "from 15–25k $".
String compactExplorePriceRangeLabel(String raw) {
  var t = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (t.isEmpty) return t;

  final hasFrom = t.toLowerCase().startsWith('from ');
  var body = hasFrom ? t.substring(5).trim() : t;

  final match = RegExp(
    r'^([£€$₽₺]?)\s*([\d.,]+)\s*[–\-—]\s*([£€$₽₺]?)\s*([\d.,]+)\s*([A-Za-z£€$₽₺]*)\s*$',
  ).firstMatch(body);
  if (match == null) {
    // Single amount: "15,000 $" / "from 15000 USD"
    final single = RegExp(
      r'^([£€$₽₺]?)\s*([\d.,]+)\s*([A-Za-z£€$₽₺]*)\s*$',
    ).firstMatch(body);
    if (single == null) return t;
    final amount = _parseLooseAmount(single.group(2)!);
    if (amount == null || amount < 10000) return t;
    final sym = single.group(1) ?? '';
    final code = single.group(3)?.trim() ?? '';
    final k = (amount / 1000).round();
    final formatted = code.isNotEmpty || sym.isNotEmpty
        ? '${k}k ${code.isNotEmpty ? code : sym}'.trim()
        : '${k}k';
    return hasFrom ? 'from $formatted' : formatted;
  }

  final lo = _parseLooseAmount(match.group(2)!);
  final hi = _parseLooseAmount(match.group(4)!);
  if (lo == null || hi == null) return t;
  if (lo < 10000 && hi < 10000) return t;

  final hiK = (hi / 1000).round();
  final sym = (match.group(1)?.isNotEmpty == true)
      ? match.group(1)!
      : (match.group(3) ?? '');
  final code = match.group(5)?.trim() ?? '';
  final curr = code.isNotEmpty ? code : sym;
  final String span;
  if (lo >= 10000) {
    final loK = (lo / 1000).round();
    span = loK == hiK ? '${loK}k' : '$loK–${hiK}k';
  } else {
    span = '${_formatComparePriceNum(lo)}–${hiK}k';
  }
  final formatted = curr.isEmpty ? span : '$span $curr';
  return hasFrom ? 'from $formatted' : formatted;
}

double? _parseLooseAmount(String raw) {
  final cleaned = raw.replaceAll(',', '').replaceAll(' ', '').trim();
  return double.tryParse(cleaned);
}

/// Puts currency code/symbol after the amount: "from AED 27,000" → "from 27,000 AED".
String priceLabelCurrencyAfter(String raw) {
  var t = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (t.isEmpty) return t;
  t = t.replaceAll(RegExp(r'\bLEI\b', caseSensitive: false), 'RON');
  t = _trimListedPriceCentsAndUp(t);

  final hasFrom = t.length > 5 && t.toLowerCase().startsWith('from ');
  var body = hasFrom ? t.substring(5).trim() : t;

  final codeFirst = RegExp(r'^([A-Za-z]{3})\s+(.+)$').firstMatch(body);
  if (codeFirst != null) {
    final code = codeFirst.group(1)!.toUpperCase();
    final amount = codeFirst.group(2)!.trim();
    final out = '$amount $code';
    return hasFrom ? 'from $out' : out;
  }

  final symFirst = RegExp(r'^([£€$₽₺])\s*(.+)$').firstMatch(body);
  if (symFirst != null) {
    final sym = symFirst.group(1)!;
    var amount = symFirst.group(2)!.trim();
    amount = amount.replaceAll(RegExp(r'[£€$₽₺]'), '').trim();
    amount = _trimListedPriceCentsAndUp(amount);
    final out = '$amount $sym';
    return hasFrom ? 'from $out' : out;
  }

  return t;
}

List<OpenAIClinic> _justifiedPricedClinics(
  List<OpenAIClinic> clinics, {
  String? procedure,
}) {
  return clinics
      .where(
        (c) =>
            c.priceMin > 0 &&
            explorePriceIsVerified(c) &&
            isJustifiedProcedurePrice(c, procedure: procedure) &&
            explorePriceIsComparableTypicalStart(
              procedure: procedure ?? '',
              rawProcedureText: c.rawProcedureText,
              brand: c.brand,
              rawPriceText: c.rawPriceText,
              rawEvidence: c.priceEvidenceText,
              sourceUrl: c.priceSourceUrl,
              priceMin: c.priceMin,
              priceMax: c.priceMax,
              currency: c.currency,
            ),
      )
      .toList();
}

/// Topic header: "from 200–1.400 RON" using only plausible clinic prices.
/// When clinics mix currencies, the range uses the most common currency only.
String clinicCompareAggregateRangeDisplay(
  List<OpenAIClinic> clinics, {
  String? procedure,
}) {
  final priced = _justifiedPricedClinics(clinics, procedure: procedure);
  if (priced.length < 2) return '';
  final sameCurrency = clinicsSharingDominantCurrency(priced);
  sameCurrency.sort((a, b) => a.priceMin.compareTo(b.priceMin));
  final lo = sameCurrency.first.priceMin;
  // Current listed starting prices only — ignore sale "was" amounts in priceMax.
  final hi = sameCurrency
      .map((c) => c.priceMin)
      .reduce((a, b) => a > b ? a : b);
  final curr = sameCurrency.first.currency;
  final perGraft = sameCurrency.every(
    (c) => looksLikeHairPerGraftPrice(c, procedure: procedure),
  );
  if (hi <= lo) {
    return perGraft
        ? formatHairPerGraftPriceLabel(lo, curr)
        : _formatFromComparePrice(lo, curr);
  }
  final body = _formatCompareRangeBody(lo, hi, curr);
  return perGraft ? 'from $body/graft' : 'from $body';
}

/// Lowest price across [clinics] — e.g. "from 200 RON" for compact subtitles.
String clinicCompareAggregateFromDisplay(
  List<OpenAIClinic> clinics, {
  String? procedure,
}) {
  final priced = _justifiedPricedClinics(clinics, procedure: procedure);
  if (priced.isEmpty) return '';
  priced.sort((a, b) => a.priceMin.compareTo(b.priceMin));
  final lowest = priced.first;
  return _formatFromComparePrice(lowest.priceMin, lowest.currency);
}

/// True when the clinic has a concrete price to show (not "Price on request").
bool clinicHasListedComparePrice(OpenAIClinic c, {String? procedure}) {
  if (!c.hasProcedure) return false;
  if (c.pricePending) return false;
  if (!explorePriceIsVerified(c)) return false;

  final label = c.priceLabel.trim().toLowerCase();
  if (label.contains('on request')) return false;

  if (c.priceMin > 0) {
    return isJustifiedProcedurePrice(c, procedure: procedure);
  }

  if (RegExp(r'\d').hasMatch(c.priceLabel)) {
    return clinicCompareProcedurePriceDisplay(
      c,
      procedure: procedure,
    ).isNotEmpty;
  }

  return c.priceGbp > 0;
}

/// User-facing copy when Explore cannot show verified prices for a city.
String exploreInsufficientDataMessage(
  String city, {
  String? procedure,
  bool cityHasCatalog = false,
  String coverageStatus = '',
  bool technicalFailure = false,
}) {
  final place = city.trim().isEmpty ? 'this area' : city.trim();
  final proc = procedure?.trim();
  final namedProc =
      proc != null && proc.isNotEmpty && proc.toLowerCase() != 'all';
  final status = coverageStatus.trim().toLowerCase();

  if (technicalFailure || status == 'failed') {
    return namedProc
        ? 'We could not finish verifying $proc prices in $place. Tap retry — this was a temporary lookup issue, not proof that clinics are missing.'
        : 'We could not finish verifying clinic prices in $place. Tap retry — this was a temporary lookup issue, not proof that clinics are missing.';
  }
  if (const {'pending', 'queued', 'running', 'searching', 'discovering',
    'verifying', 'in_progress', 'accepted'}.contains(status)) {
    return exploreSearchingVerifiedMessage(place);
  }
  if (status == 'thin' || status == 'partial') {
    return namedProc
        ? 'Limited verified pricing is currently available for this procedure in $place.\nMore official sources will be checked.'
        : 'Limited verified pricing is currently available in $place.\nMore official sources will be checked.';
  }

  final searched =
      'We could not verify a matching price from the sources checked.';
  final extra = cityHasCatalog
      ? ' Try All or another filter.'
      : ' Try another city or filter.';
  if (namedProc) {
    return 'No verified $proc prices found in $place yet.\n$searched$extra';
  }
  return 'No verified clinic prices found in $place yet.\n$searched$extra';
}

/// Cold-start / progressive discovery banner copy.
String exploreSearchingVerifiedMessage(String city, {bool hasPartial = false}) {
  final place = city.trim().isEmpty ? 'this area' : city.trim();
  if (hasPartial) {
    return 'Searching for more verified clinics…';
  }
  return 'Searching verified clinic prices in $place…\nResults will appear as they are verified.';
}

/// Explore Top Clinics: priced rows in mix order (up to 4 Firestore, then
/// optional 2 fresh in the tail).
List<OpenAIClinic> exploreCompareClinics(
  List<OpenAIClinic> clinics, {
  String? procedure,
  String city = '',
  bool worldwide = false,
}) {
  var source = worldwide
      // Free Worldwide catalog is hand-curated published guide prices — not
      // live scrape-verified. Keep any listed amount; hide on-request only.
      ? [
          for (final c in clinics)
            if (!exploreClinicIsNoPublicPrice(c) &&
                c.hasProcedure &&
                !c.pricePending &&
                (c.priceMin > 0 || RegExp(r'\d').hasMatch(c.priceLabel)))
              c,
        ]
      : clinicsForCompareDisplay(clinics, procedure: procedure, city: city);
  final proc = procedure?.trim() ?? '';
  // All-tab topic is "All · City" — never treat that as a procedure filter or
  // every card gets justified against the wrong family and slots vanish.
  final isAllTopic =
      proc.isEmpty ||
      proc.toLowerCase() == 'all' ||
      RegExp(r'^all\b', caseSensitive: false).hasMatch(proc);
  if (proc.isNotEmpty && !isAllTopic) {
    source = [
      for (final c in source)
        if (exploreClinicFitsCompareProcedure(c, proc)) c,
    ];
  }

  if (source.length <= kExploreCompareMaxClinics) return source;
  return source.take(kExploreCompareMaxClinics).toList(growable: false);
}

/// Clinics shown in the compare list: verified listed prices only.
/// "Price on request" rows are never painted.
class _CompareValidationCache {
  _CompareValidationCache(List<OpenAIClinic> rows)
      : snapshot = List<OpenAIClinic>.of(rows), created = DateTime.now();
  final List<OpenAIClinic> snapshot;
  final DateTime created;
  final selections = <String, List<OpenAIClinic>>{};

  bool matches(List<OpenAIClinic> rows) {
    if (DateTime.now().difference(created) >= const Duration(seconds: 30) ||
        rows.length != snapshot.length) return false;
    for (var i = 0; i < rows.length; i++) {
      if (!identical(rows[i], snapshot[i])) return false;
    }
    return true;
  }
}

final _compareValidationCache = Expando<_CompareValidationCache>();

List<OpenAIClinic> clinicsForCompareDisplay(
  List<OpenAIClinic> clinics, {
  String? procedure,
  String city = '',
}) {
  // Clinic records are immutable. Reuse validation across repeated builds,
  // but invalidate when any row, selection, city, or freshness window changes.
  var cache = _compareValidationCache[clinics];
  if (cache == null || !cache.matches(clinics)) {
    cache = _CompareValidationCache(clinics);
    _compareValidationCache[clinics] = cache;
  }
  final key = '${city.trim().toLowerCase()}|${procedure?.trim().toLowerCase() ?? ''}';
  final cached = cache.selections[key];
  if (cached != null) return List<OpenAIClinic>.of(cached);
  final selected = _clinicsForCompareDisplayUncached(
    clinics, procedure: procedure, city: city,
  );
  if (cache.selections.length >= 8) cache.selections.clear();
  cache.selections[key] = List<OpenAIClinic>.of(selected);
  return selected;
}

List<OpenAIClinic> _clinicsForCompareDisplayUncached(
  List<OpenAIClinic> clinics, {
  String? procedure,
  String city = '',
}) {
  final searchCity = city.trim();
  final proc = procedure?.trim() ?? '';
  final isAllTopic =
      proc.isEmpty || RegExp(r'^all\b', caseSensitive: false).hasMatch(proc);
  final filterProc = isAllTopic ? '' : proc;
  final eligibleLegacy =
      filterComparisonClinicsWithJustifiedPrices(
        clinics: clinics
            .where((c) => c.sourceType != 'discovery_tool')
            .toList(),
        procedure: filterProc,
      ).where(
        (c) =>
            !exploreClinicIsNoPublicPrice(c) &&
            clinicHasListedComparePrice(
              c,
              procedure: isAllTopic ? null : procedure,
            ),
      );
  final accepted = [
    for (final c in clinics)
      if (c.sourceType == 'discovery_tool' &&
          c.hasProcedure &&
          !c.pricePending &&
          c.priceMin > 0 &&
          explorePriceIsVerified(c) &&
          clinicCompareProcedurePriceDisplay(
            c, procedure: isAllTopic ? c.brand : procedure,
          ).trim().isNotEmpty &&
          (procedure == null ||
              procedure.trim().isEmpty ||
              RegExp(
                r'^all\b',
                caseSensitive: false,
              ).hasMatch(procedure.trim()) ||
              exploreClinicFitsCompareProcedure(c, procedure)) &&
          (searchCity.isEmpty ||
              searchCity.toLowerCase() == 'worldwide' ||
              exploreClinicFitsSearchCity(c, searchCity)))
        c
      else if (c.sourceType != 'discovery_tool' &&
          eligibleLegacy.contains(c) &&
          (searchCity.isEmpty ||
              searchCity.toLowerCase() == 'worldwide' ||
              exploreClinicFitsSearchCity(c, searchCity)))
        c,
  ];
  // Mixed saved/live sources share one list; finding a tool row must never
  // discard the independently verified Firestore rows beside it.
  return accepted.where((c) => clinicCompareProcedurePriceDisplay(
    c, procedure: isAllTopic ? c.brand : procedure,
  ).trim().isNotEmpty).take(kExploreCompareMaxClinics).toList(growable: false);
}

String _tariffTitleFromEvidence(OpenAIClinic clinic) {
  final text = clinic.priceEvidenceText.replaceAll('\u00a0', ' ');
  final money = RegExp(
    r'(?:\b(?:RON|lei|AED|EUR|USD|GBP)\s*|[$€£]\s*)\d[\d., ]*|'
    r'(?<![\w.,])\d[\d., ]*\s*(?:RON|lei|AED|EUR|USD|GBP)\b',
    caseSensitive: false,
  ).allMatches(text).toList();
  // An old cache row with one explicit price still has a usable tariff name.
  // Multiple prices require the source extractor to bind the correct row.
  if (money.isEmpty || money.length > 2) return '';
  if (money.length == 2 && !RegExp(r'^\s*(?:to|[-–—])\s*$',
      caseSensitive: false).hasMatch(text.substring(money.first.end, money.last.start))) {
    return '';
  }
  var label = text.substring(0, money.first.start).trim()
      .replaceFirst(RegExp(r'[|\s]+$'), '').split('|').last.trim();
  label = label.replaceFirst(RegExp(r'^/?\s*(?:ml|unit|session)\b\s*',
      caseSensitive: false), '');
  label = label.replaceFirst(RegExp(r'\s*(?:starts?\s+from|starting\s+(?:from|at)|from|de\s+la)\s*$',
      caseSensitive: false), '').trim();
  if (label.isEmpty) {
    final tail = text.substring(money.last.end).trim();
    label = RegExp(r'^for\s+(.{1,80})$', caseSensitive: false)
        .firstMatch(tail)?.group(1) ?? '';
  }
  if (label.length > 160) return '';
  return exploreWebsiteProcedureTitle(label);
}

/// Card title: the clinic's listed treatment name, like clinic detail rows.
String exploreCardProcedureLabel(
  OpenAIClinic clinic, {
  String? selectedPill,
  String? topic,
}) {
  final pill = selectedPill?.trim() ?? '';
  final topicHead = topic?.split('·').first.trim() ?? '';
  // Persisted display name wins — never surface article sentences.
  final persisted = exploreProcedureTitleWithoutPromotion(clinic.procedureDisplayName);
  final isFiller = pill == 'Fillers' || clinic.procedureCanonical == 'filler';
  final isPeel = pill == 'Peels' || clinic.procedureCanonical == 'chemical_peel';
  final genericFillerTitle = isFiller && RegExp(
    r'^(?:dermal\s+)?fillers?(?:\s+lips\s+cheeks)?$',
    caseSensitive: false,
  ).hasMatch(persisted);
  final genericPeelTitle = isPeel && RegExp(r'^(?:chemical\s+)?peels?$',
      caseSensitive: false).hasMatch(persisted);
  final genericBotoxTitle = clinic.procedureCanonical == 'botox' &&
      RegExp(r'^(?:botox|anti[- ]wrinkle(?:\s+injection)?)$', caseSensitive: false).hasMatch(persisted);
  final genericTariffTitle = genericFillerTitle || genericPeelTitle || genericBotoxTitle;
  if (isFiller && RegExp(r'full[ -]face', caseSensitive: false)
      .hasMatch(clinic.procedureDetail)) {
    return 'Dermal filler · Full face rejuvenation';
  }
  final isBreastAugmentation =
      pill == 'Boob job' ||
      clinic.procedureCanonical == 'breast_augmentation' ||
      persisted.toLowerCase().contains('breast augmentation') ||
      topicHead.toLowerCase().contains('breast augmentation');
  if (isBreastAugmentation) {
    return exploreBreastProcedureDisplayName(
      rawProcedureText: clinic.rawProcedureText.isNotEmpty
          ? clinic.rawProcedureText
          : persisted,
      procedureDetail: clinic.procedureDetail,
      evidence: clinic.priceEvidenceText,
      priceMin: clinic.priceMin,
      currency: clinic.currency,
    );
  }
  if (!genericTariffTitle && persisted.isNotEmpty &&
      !looksLikeCountryMarketPriceMarketing(persisted) &&
      !looksLikeRawScrapedProcedureTitle(persisted) &&
      !looksLikePricingProseProcedureTitle(persisted)) {
    return isFiller ? stripGenericFillerMethodSubtitle(persisted) : persisted;
  }
  final brand = exploreWebsiteProcedureTitle(clinic.brand);
  final rawText = exploreWebsiteProcedureTitle(exploreProcedureTitleWithoutPromotion(clinic.rawProcedureText));
  final evidenceTitle = genericTariffTitle ? _tariffTitleFromEvidence(clinic) : '';
  final canonical = clinic.procedureCanonical.trim();
  final query = pill.isEmpty || pill == 'All'
      ? ''
      : explorePillAiSearchQuery(pill);

  final isRhinoplastyTab =
      pill == 'Rhinoplasty' ||
      topicHead.toLowerCase().contains('rhinoplast') ||
      explorePillAiSearchQuery(pill).toLowerCase().contains('rhinoplast');
  final brandIsRhino =
      brand.toLowerCase().contains('rhinoplast') ||
      brand == 'Rhinoplasty' ||
      (isBroadExploreCategoryName(brand) && brand == 'Rhinoplasty');

  // Rhinoplasty tab, or All-tab row tagged as rhinoplasty.
  if (isRhinoplastyTab || brandIsRhino) {
    return _rhinoplastyCardLabel(clinic);
  }

  bool matchesPill(String label) {
    if (query.isEmpty) return true;
    if (isFiller && RegExp(
      r'buze|pome[tț]i|cearc[aă]ne|menton|mandibul|nazo.?genien|'
      r'lip\s+filler|cheek\s+filler|tear\s+trough',
      caseSensitive: false,
    ).hasMatch(label)) return true;
    final fam = exploreTreatmentFamily(label);
    if (fam == ExploreTreatmentFamily.other) {
      // "Crows Feet" after stripping "What Is Botox Injection? · …"
      if (exploreTreatmentFamily(query) == ExploreTreatmentFamily.botox &&
          _looksLikeBotoxAreaLabel(label)) {
        return true;
      }
      if (exploreTreatmentFamily(query) == ExploreTreatmentFamily.laser &&
          _looksLikeLaserSkinOrAreaLabel(label)) {
        return true;
      }
      return false;
    }
    return exploreClinicMatchesProcedure(
      clinic.copyWith(brand: label, rawProcedureText: label),
      query,
    );
  }

  bool usableWebsiteName(String label) {
    if (label.isEmpty) return false;
    if (looksLikeGenericLaserCardTitle(label)) return false;
    if (looksLikeInternalProcedureId(label)) return false;
    if (isExploreTopicPlaceholder(label)) return false;
    if (isBroadExploreCategoryName(label)) return false;
    if (looksLikeRawScrapedProcedureTitle(label)) return false;
    if (looksLikeUnilateralBreastStartingRow(label)) return false;
    // Section headings and laundry-list bags are never card titles, even when
    // they also contain a real treatment word ("Filler dermatological…").
    if (looksLikeCatalogSectionHeading(label)) return false;
    if (looksLikeGenericInjectableCategoryHeading(label)) return false;
    if (looksLikeLaundryListProcedureTitle(label)) return false;
    if (looksLikeCommerceChromeLabel(label)) return false;
    if (looksLikeProcedureLabelChromeFragment(label)) return false;
    if (looksLikePublishedPriceUnitLabel(label)) return false;
    if (looksLikeBarePriceLabel(label)) return false;
    if (looksLikeMarketAveragePriceBlurb(label)) return false;
    if (looksLikeCountryMarketPriceMarketing(label)) return false;
    if (looksLikeNonLatinProcedureLabel(label)) return false;
    if (_brandLooksLikeSpecialtyVariant(label)) return false;
    if (!matchesPill(label)) return false;
    return true;
  }

  // Prefer the scraped menu row (clinic-detail treatment.name), then brand.
  for (final candidate in [rawText, evidenceTitle, brand]) {
    if (usableWebsiteName(candidate)) return candidate;
  }
  // Backend detail (Crow's feet / Three areas / Partial) beats a bare "Botox".
  if (clinic.procedureCanonical == 'botox') {
    final detail = clinic.procedureDetail.trim();
    if (detail.isNotEmpty) {
      final short = detail
          .replaceFirst(
            RegExp(r'^upper face\s*/\s*forehead\s*/\s*glabella\s*/\s*eyes$',
                caseSensitive: false),
            'Upper face',
          )
          .replaceFirst(RegExp(r'^full botox$', caseSensitive: false), 'Full face')
          .replaceFirst(RegExp(r'^single area$', caseSensitive: false), 'Partial')
          .replaceFirst(RegExp(r'^masseter\s*/\s*bruxism$', caseSensitive: false), 'Masseter')
          .replaceFirst(RegExp(r'^add-on area$', caseSensitive: false), 'Add-on');
      if (persisted.isEmpty || genericBotoxTitle) {
        if (RegExp(r'^baby\s+botox$', caseSensitive: false).hasMatch(short)) {
          return 'Baby Botox';
        }
        return 'Botox · $short';
      }
      if (!persisted.toLowerCase().contains(short.toLowerCase().split(' · ').first) &&
          (_looksLikeBotoxAreaLabel(short) ||
              RegExp(
                r'three areas|full face|upper face|partial|single area|masseter|add-on',
                caseSensitive: false,
              ).hasMatch(short))) {
        return '$persisted · $short';
      }
    }
  }
  if (genericTariffTitle && persisted.isNotEmpty) return persisted;

  // FAQ/SEO headings and Arabic menu rows still name a family — show
  // "Lip filler", not the question or the untranslated row.
  for (final candidate in [rawText, brand]) {
    if (candidate.isEmpty) continue;
    final needsFallback =
        looksLikeRawScrapedProcedureTitle(candidate) ||
        looksLikeMarketAveragePriceBlurb(candidate) ||
        looksLikeCountryMarketPriceMarketing(candidate) ||
        looksLikeNonLatinProcedureLabel(candidate) ||
        looksLikeUnilateralBreastStartingRow(candidate) ||
        looksLikeCatalogSectionHeading(candidate) ||
        looksLikeGenericInjectableCategoryHeading(candidate) ||
        looksLikeLaundryListProcedureTitle(candidate);
    if (!needsFallback) continue;
    final fromFam = exploreFamilyCardFallback(
      exploreTreatmentFamily(candidate),
      query: query,
    );
    if (fromFam != null) {
      final lo = candidate.toLowerCase();
      if (lo.contains('baby botox') || lo.contains('microtox')) {
        return 'Baby Botox';
      }
      return fromFam;
    }
  }

  // Matcher ids (`filler`, `lip_filler`) are not titles unless that is all
  // the website gave us.
  if (canonical.isNotEmpty) {
    return humanizeExploreProcedureCanonical(canonical);
  }
  if (brand.isNotEmpty && isBroadExploreCategoryName(brand)) {
    return explorePillCardFallback(brand);
  }

  final fromPrice = _procedureHintFromPriceLabel(clinic.priceLabel);
  if (fromPrice != null && matchesPill(fromPrice)) return fromPrice;

  final fromName = _procedureHintFromClinicName(clinic.name, pill: pill);
  if (fromName != null) return fromName;

  // Surgery-priced rows on All with no brand — prefer Rhinoplasty over Treatment.
  if ((pill == 'All' || pill.isEmpty) && _looksLikeRhinoplastyClinic(clinic)) {
    return _rhinoplastyCardLabel(clinic);
  }

  if (pill.isNotEmpty && pill != 'All') {
    return explorePillCardFallback(pill);
  }

  if (topicHead.isNotEmpty && !isBroadExploreCategoryName(topicHead)) {
    return topicHead;
  }

  return 'Treatment';
}

/// Menu row title as listed — split glued prices ("Rehydra310 RON…").
String exploreWebsiteProcedureTitle(String raw) {
  var t = repairUtf8Mojibake(
    decodeExploreHtmlEntities(raw.replaceAll('\u00a0', ' ')),
  ).trim();
  if (t.isEmpty) return '';
  t = stripExploreProcedureLabelChrome(t);
  if (t.isEmpty) return '';
  t = stripSurroundingPageCopyFromProcedureTitle(t);
  if (t.isEmpty) return '';
  t = _titleCaseAllCapsProcedureLabel(t);
  if (t.isEmpty) return '';
  if (looksLikeCommerceChromeLabel(t)) return '';
  t = t.replaceAllMapped(RegExp(r'(?<=[A-Za-zăâîșțÁ-ÿ])(?=\d)'), (_) => ' ');
  t = t.replaceAllMapped(RegExp(r'(?<=\d)(?=[A-Za-zăâîșțÁ-ÿ])'), (_) => ' ');
  // "1497leiCumpără" needs a gap. "hialuronic" must stay one word.
  t = t.replaceAllMapped(
    RegExp(
      r'(?<=\d)\s*(ron|lei|eur|usd|gbp)(?=[A-Za-zăâîșț])',
      caseSensitive: false,
    ),
    (m) => '${m.group(1)} ',
  );
  t = t.replaceAll(
    RegExp(
      r'\b\d[\d.,]*\s*(ron|lei|eur|usd|gbp|aed|try|€|£|\$)\b',
      caseSensitive: false,
    ),
    ' ',
  );
  // AED/USD menus put the code first ("AED 750 to AED 1,800 per area").
  t = t.replaceAll(
    RegExp(
      r'\b(ron|lei|eur|usd|gbp|aed|try)\s*\d[\d.,]*|[€£$]\s*\d[\d.,]*',
      caseSensitive: false,
    ),
    ' ',
  );
  t = t.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
  t = _stripPriceOnlyTail(t);
  t = _stripCatalogSectionPrefix(t);
  t = firstTreatmentClauseFromLaundryList(t);
  t = _stripPublishedPriceUnitChrome(t);
  final cut = RegExp(
    r'\s*[:–—-]?\s*(?:între|intre|de la|from|desde)\s*[\d€£$]',
    caseSensitive: false,
  ).firstMatch(t);
  if (cut != null && cut.start >= 3) {
    t = t.substring(0, cut.start).trim();
  }
  t = _stripPublishedPriceUnitChrome(t);
  if (looksLikePublishedPriceUnitLabel(t) || looksLikeBarePriceLabel(t)) {
    return '';
  }
  return stripGenericFillerMethodSubtitle(t);
}

/// "Injectare acid hialuronic" repeats on every row. A dose in parentheses stays.
String stripGenericFillerMethodSubtitle(String title) {
  return title.replaceFirst(
    RegExp(r'\s+injectare acid hialuronic(?!\s*\()', caseSensitive: false),
    '',
  ).trim();
}

/// `FACE VI PEEL` → `Face VI Peel`. Leave mixed-case clinic titles alone.
String _titleCaseAllCapsProcedureLabel(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return t;
  final letters = t.replaceAll(RegExp(r'[^A-Za-z]'), '');
  if (letters.length < 4) return t;
  if (t != t.toUpperCase()) return t;
  return t
      .split(RegExp(r'\s+'))
      .map((w) {
        if (w.isEmpty) return w;
        if (w.length <= 2) return w;
        return '${w[0]}${w.substring(1).toLowerCase()}';
      })
      .join(' ');
}

/// `$13 per unit` / `Per Unit Botox` leftovers after the amount is stripped.
String _stripPublishedPriceUnitChrome(String raw) {
  var t = raw.replaceAll('\u00a0', ' ').trim();
  if (t.isEmpty) return '';
  t = t.replaceFirst(RegExp(r'^(?:to|and|from)\s+', caseSensitive: false), '');
  t = t.replaceFirst(
    RegExp(r'^(?:per\s+)?units?\s+', caseSensitive: false),
    '',
  );
  t = t.replaceFirst(
    RegExp(
      r'\s+(?:per\s+|/\s*)(?:unit|units|iu|unidad(?:es)?|syringe|vial|'
      r'session|area|graft)s?\s*$',
      caseSensitive: false,
    ),
    '',
  );
  t = t.replaceAll(RegExp(r'^[\s/–—,-]+|[\s/–—,-]+$'), '').trim();
  if (looksLikePublishedPriceUnitLabel(t)) return '';
  if (RegExp(
    r'^(?:to|and|from|starting|starts?)$',
    caseSensitive: false,
  ).hasMatch(t)) {
    return '';
  }
  return t;
}

/// `Botulax Botox: AED 750 to AED 1,800 per area` → `Botulax Botox`.
/// Only cuts when the tail is the quote itself, so `Lip filler 1 ml` survives.
String _stripPriceOnlyTail(String raw) {
  final colon = raw.indexOf(':');
  if (colon < 3) return raw;
  final tail = raw.substring(colon + 1).trim();
  if (tail.isEmpty) return raw.substring(0, colon).trim();
  if (!RegExp(
    r'^(?:to|and|per|each|[-–—,./\s\d])*(?:area|areas|zone|zones|unit|units)?'
    r'[.\s]*$',
    caseSensitive: false,
  ).hasMatch(tail)) {
    return raw;
  }
  return raw.substring(0, colon).trim();
}

/// `DERMATOLOGIE ESTETICĂ · Augmentare buze 1 ml` → the listed row.
String _stripCatalogSectionPrefix(String raw) {
  final parts = raw.split(RegExp(r'\s*[·•∙･|]\s*'));
  if (parts.length < 2) return raw;
  final left = parts.first.trim();
  final right = parts.sublist(1).join(' · ').trim();
  if (looksLikeProcedureLabelChromeFragment(right)) return left;
  if (right.isEmpty || !looksLikeCatalogSectionHeading(left)) return raw;
  return right;
}

bool _brandLooksLikeSpecialtyVariant(String brand) {
  final t = brand.toLowerCase();
  return RegExp(
    r'masseter|brux|hiperhidros|hyperhidros|platism|gingival|gummy|'
    r'lip[\s-]?lift|queiloplast',
  ).hasMatch(t);
}

/// Arabic/Cyrillic/Greek/CJK menu rows are real, but the card is English:
/// show the family name instead of the untranslated row.
bool looksLikeNonLatinProcedureLabel(String label) {
  final t = label.trim();
  if (t.isEmpty) return false;
  if (!RegExp(
    r'[\u0370-\u04ff\u0600-\u06ff\u3040-\u9fff\uac00-\ud7af]',
  ).hasMatch(t)) {
    return false;
  }
  return !RegExp(r'[A-Za-zÀ-ÿ]{3}').hasMatch(t);
}

/// Standard wrinkle zones listed under Botox — not masseter / gummy extras.
bool _looksLikeBotoxAreaLabel(String label) {
  return RegExp(
    r"crow.?s?\s*feet|crows?\s*feet|forehead|glabella|entrecejo|"
    r"periocular|laba\s*g[aâ]s|coada\s*ochi",
    caseSensitive: false,
  ).hasMatch(label);
}

bool _looksLikeLaserSkinOrAreaLabel(String label) {
  if (looksLikeGenericLaserCardTitle(label)) return false;
  return exploreLaserRowSubtype(label) != 'generic' ||
      RegExp(
        r'photo\s*rejuvenation|photorejuvenation|photofacial|byonik|'
        r'\bipl\b|fraxel|pigment|rosacea|peri[\s-]?anal|hollywood|'
        r'hydrating\s+laser|laser\s+facial',
        caseSensitive: false,
      ).hasMatch(label);
}

bool _looksLikeRhinoplastyClinic(OpenAIClinic clinic) {
  final n = clinic.name.toLowerCase();
  final b = clinic.brand.toLowerCase();
  if (n.contains('rhino') ||
      n.contains('nose') ||
      b.contains('rhino') ||
      b.contains('nose')) {
    return true;
  }
  // Typical surgical rhinoplasty price band (local currency units).
  return clinic.priceMin >= 2500;
}

/// Rhinoplasty cards: "Rhinoplasty" for surgery prices; consultation only when
/// the listing is clearly a consult (label or low fee), never because of "Dr".
String _rhinoplastyCardLabel(OpenAIClinic clinic) {
  // Full surgery quotes — never label these as consultation.
  if (clinic.priceMin >= 800) return 'Rhinoplasty';

  final brand = clinic.brand.trim().toLowerCase();
  final priceLabel = clinic.priceLabel.trim().toLowerCase();
  final haystack = '$brand $priceLabel';

  final labelSaysConsult =
      haystack.contains('consult') &&
      !haystack.contains('including consult') &&
      !haystack.contains('with consult');

  if (labelSaysConsult || (clinic.priceMin > 0 && clinic.priceMin < 800)) {
    return 'Rhinoplasty consultation';
  }
  return 'Rhinoplasty';
}

String? _procedureHintFromPriceLabel(String raw) {
  var t = raw.trim();
  if (t.isEmpty || !RegExp(r'[A-Za-z]').hasMatch(t)) return null;
  t = t.replaceAll(RegExp(r'[\d,.\s€£\$₺]+'), ' ').trim();
  t = t.replaceAll(
    RegExp(
      r'\b(from|to|per|session|sessions|RON|AED|EUR|GBP|USD|TRY|LEI)\b',
      caseSensitive: false,
    ),
    '',
  );
  t = t.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
  if (looksLikePublishedPriceUnitLabel(t) || looksLikeBarePriceLabel(t)) {
    return null;
  }
  if (t.length >= 4 && !isBroadExploreCategoryName(t)) return t;
  return null;
}

String? _procedureHintFromClinicName(String name, {required String pill}) {
  final n = name.toLowerCase();
  if (pill == 'Boob job' || n.contains('breast')) {
    if (n.contains('augment')) return 'Breast augmentation';
    if (n.contains('lift')) return 'Breast lift';
  }
  if (pill == 'Hair' ||
      n.contains('hair transplant') ||
      n.contains(' fue') ||
      n.contains('fue ')) {
    return 'Hair transplant';
  }
  if (pill == 'Fillers' && (n.contains('lip') || n.contains('filler'))) {
    return 'Lip filler';
  }
  if (pill == 'Botox' && n.contains('botox')) return 'Botox';
  return null;
}

/// SerpApi stores the search topic as brand ("dermal filler"). That is a
/// category, not a clinic menu name — All should not show it as the title.
bool isExploreTopicPlaceholder(String brand) {
  final t = brand.toLowerCase().trim();
  if (t.isEmpty) return true;
  const topics = {
    'dermal filler',
    'dermal filler lips cheeks',
    'botox',
    'botox anti-wrinkle injection',
    'laser hair removal',
    'laser skin treatment hair removal',
    'laser skin rejuvenation',
    'laser skin rejuvenation ipl',
    'chemical peel',
    'rhinoplasty',
    'breast augmentation',
    'hair transplant',
    'skin booster',
    'aesthetic treatment',
  };
  return topics.contains(t);
}

/// Matcher / Firestore ids like `chemical_peel` / `filler` — never show these
/// on cards when a website treatment name exists.
bool looksLikeInternalProcedureId(String raw) {
  final t = raw.trim().toLowerCase();
  if (t.isEmpty) return false;
  if (RegExp(r'^[a-z][a-z0-9]*(?:_[a-z0-9]+)+$').hasMatch(t)) return true;
  const tokens = {
    'filler',
    'fillers',
    'botox',
    'laser',
    'peel',
    'peels',
    'treatment',
  };
  return tokens.contains(t);
}

/// Turns `chemical_peel` / `lip_filler` into the All-tab card title.
String humanizeExploreProcedureCanonical(String raw) {
  switch (raw.trim().toLowerCase().replaceAll(' ', '_')) {
    case 'chemical_peel':
    case 'peel':
      return 'Chemical peel';
    case 'lip_filler':
      return 'Lip filler';
    case 'cheek_filler':
      return 'Cheek filler';
    case 'filler':
      return 'Lip filler';
    case 'botox':
      return 'Botox treatment';
    case 'laser':
      return 'Laser skin treatment';
    case 'rhinoplasty':
      return 'Rhinoplasty';
    case 'breast_augmentation':
      return 'Breast augmentation';
    case 'hair_transplant':
      return 'Hair transplant';
    default:
      if (!looksLikeInternalProcedureId(raw)) return raw.trim();
      return raw
          .trim()
          .split('_')
          .where((w) => w.isNotEmpty)
          .map((w) => '${w[0].toUpperCase()}${w.substring(1)}')
          .join(' ');
  }
}

/// Card title when the scrape only named a treatment family (FAQ, SEO heading).
String? exploreFamilyCardFallback(
  ExploreTreatmentFamily family, {
  String query = '',
}) {
  switch (family) {
    case ExploreTreatmentFamily.filler:
      return 'Lip filler';
    case ExploreTreatmentFamily.botox:
      return 'Botox treatment';
    case ExploreTreatmentFamily.laser:
      return exploreLaserRequestedSubtype(query) == 'hair'
          ? 'Laser hair removal'
          : 'Laser skin treatment';
    case ExploreTreatmentFamily.peel:
      return 'Chemical peel';
    case ExploreTreatmentFamily.rhinoplasty:
      return 'Rhinoplasty';
    case ExploreTreatmentFamily.breast:
      return 'Breast augmentation';
    case ExploreTreatmentFamily.hair:
      return 'Hair transplant';
    case ExploreTreatmentFamily.skin:
      return 'Skin booster';
    case ExploreTreatmentFamily.other:
      return null;
  }
}

/// When [brand] is missing, use a readable procedure line — not bare filter pills.
String explorePillCardFallback(String pill) {
  switch (pill.trim()) {
    case 'Rhinoplasty':
      return 'Rhinoplasty';
    case 'Boob job':
      return 'Breast augmentation';
    case 'Hair':
      return 'Hair transplant';
    case 'Botox':
      return 'Botox treatment';
    case 'Fillers':
      return 'Lip filler';
    case 'Laser':
    case 'Hair removal':
    case 'Skin laser':
      return 'Laser skin treatment';
    case 'Peels':
      return 'Chemical peel';
    case 'Skin':
      return 'Skin booster';
    default:
      return pill.trim();
  }
}

/// Price line for procedure comparison (cards, pins): listed website amount.
String clinicCompareProcedurePriceDisplay(OpenAIClinic c, {String? procedure}) {
  if (!c.hasProcedure) return '';
  if (c.pricePending) return '';
  if (exploreClinicIsNoPublicPrice(c)) return '';
  if (!explorePriceIsVerified(c)) return '';

  if (c.priceMin > 0) {
    if (looksLikeBotoxPerUnitPrice(c, procedure: procedure)) {
      return formatBotoxPerUnitPriceLabel(c.priceMin, c.currency);
    }
    if (!isJustifiedProcedurePrice(c, procedure: procedure)) {
      return '';
    }
    if (looksLikeHairPerGraftPrice(c, procedure: procedure)) {
      return formatHairPerGraftPriceLabel(c.priceMin, c.currency);
    }
  }

  final listed = _listedWebsitePriceText(c);
  if (listed.isNotEmpty) {
    if (c.priceMax > c.priceMin + 0.5 &&
        RegExp(r'\d[\d.,]*\s*[–—-]\s*[£€$]?\s*\d').hasMatch(listed)) {
      return _withHospitalFeesOnlySuffix(
        _withHairGraftAllowanceSuffix(
          _ensurePriceUnitSuffix(
            _formatPublishedCardRange(c.priceMin, c.priceMax, c.currency),
            c,
          ),
          c,
          procedure,
        ),
        c,
        procedure,
      );
    }
    final withUnit = _ensurePriceUnitSuffix(
      exploreClinicShowsExactPrice(c)
          ? _normalizeStartingFromPrefix(listed)
          : _ensureFromPrefix(_normalizeStartingFromPrefix(listed)),
      c,
    );
    return _withHospitalFeesOnlySuffix(
      _withHairGraftAllowanceSuffix(withUnit, c, procedure),
      c,
      procedure,
    );
  }

  if (c.priceMin > 0 && isJustifiedProcedurePrice(c, procedure: procedure)) {
    // Sale "was" amounts must never widen the FROM display into a range.
    final isSale = c.priceType.trim().toLowerCase() == 'sale';
    if (!isSale && c.priceMax > c.priceMin + 0.5) {
      return _withHospitalFeesOnlySuffix(
        _withHairGraftAllowanceSuffix(
          _ensurePriceUnitSuffix(
            _formatPublishedCardRange(c.priceMin, c.priceMax, c.currency),
            c,
          ),
          c,
          procedure,
        ),
        c,
        procedure,
      );
    }
    final amountLabel = exploreClinicShowsExactPrice(c)
        ? _formatExactComparePrice(c.priceMin, c.currency)
        : _formatFromComparePrice(c.priceMin, c.currency);
    return _withHospitalFeesOnlySuffix(
      _withHairGraftAllowanceSuffix(
        _ensurePriceUnitSuffix(amountLabel, c),
        c,
        procedure,
      ),
      c,
      procedure,
    );
  }

  if (c.priceGbp > 0) return 'from ${c.priceGbp} £';
  return '';
}

/// Keep `/ml`, `/session`, `/graft`, `/unit` only when the clinic published a
/// per-unit rate. A procedure containing "1 ml" is not a /ml price.
String _ensurePriceUnitSuffix(String label, OpenAIClinic c) {
  var t = label.trim();
  // Old cache entries can carry /unit from a neighbouring Botox tariff.
  // A fixed one-syringe filler price must display its printed syringe size.
  final source = '${c.rawPriceText} ${c.priceEvidenceText}';
  if (c.procedureCanonical == 'filler' &&
      RegExp(r'\b1\s*ml\s+syringe\b', caseSensitive: false).hasMatch(source) &&
      !RegExp(r'(?:per|/)\s*units?\b', caseSensitive: false).hasMatch(source)) {
    t = t.replaceFirst(RegExp(r'/unit\b', caseSensitive: false), '').trim();
    if (RegExp(r'\b1\s*ml\s+syringe\b', caseSensitive: false).hasMatch(t)) {
      return t;
    }
    return '$t · 1 ml syringe';
  }
  if (t.isEmpty) return t;
  if (RegExp(
    r'/(?:ml|unit|iu|session|graft|areas?|zones?|syringe)\b',
    caseSensitive: false,
  ).hasMatch(t)) {
    return t
        .replaceFirst(RegExp(r'/areas\b', caseSensitive: false), '/area')
        .replaceFirst(RegExp(r'/zones\b', caseSensitive: false), '/zone');
  }
  final type = c.priceType.trim().toLowerCase();
  final isPerRate =
      type == 'perunit' ||
      type == 'per_unit' ||
      type == 'perarea' ||
      type == 'per_area';
  final published = '${c.rawPriceText} ${c.priceLabel} ${c.priceEvidenceText}'
      .toLowerCase();
  // "Botox (1 unit) — 40 AED" is an explicit one-unit tariff too.
  if (looksLikeBotoxPerUnitQuote(
      '${c.rawProcedureText} $published', procedure: c.procedureCanonical)) {
    return t.endsWith('/unit') ? t : '$t/unit';
  }
  bool publishedPer(String u) =>
      RegExp('(?:per|/)\\s*$u\\b', caseSensitive: false).hasMatch(published);

  // Exact/from/range cards never invent /ml from dosage text.
  if (!isPerRate) {
    for (final u in ['ml', 'unit', 'iu', 'graft', 'area', 'syringe']) {
      if (publishedPer(u)) {
        return t.endsWith('/$u') ? t : '$t/$u';
      }
    }
    return t;
  }

  final unit = c.priceUnit.trim().toLowerCase();
  if (unit.isEmpty) {
    for (final u in ['ml', 'unit', 'iu', 'graft', 'area', 'syringe']) {
      if (publishedPer(u)) {
        return t.endsWith('/$u') ? t : '$t/$u';
      }
    }
    return t;
  }
  final canon = switch (unit) {
    'units' || 'iu' || 'unidad' => 'unit',
    'sessions' || 'sesion' || 'sedinta' => 'session',
    'grafts' || 'grafturi' => 'graft',
    'areas' || 'zones' || 'zone' => 'area',
    'syringes' => 'syringe',
    'packages' || 'pack' => 'package',
    _ => unit,
  };
  if (canon == 'package' || canon == 'session') {
    if (!publishedPer(canon) && !(canon == 'package' && publishedPer('pack'))) {
      return t;
    }
  }
  if (canon == 'graft') {
    if (!publishedPer('graft') && !publishedPer('grafts')) {
      return t;
    }
  }
  // ml/cc/syringe: only when source literally prices per unit, or type=perUnit.
  if (canon == 'ml' || canon == 'cc' || canon == 'syringe' || canon == 'unit') {
    if (!publishedPer(canon) && !isPerRate) return t;
  }
  if (RegExp('/$canon\\b', caseSensitive: false).hasMatch(t)) return t;
  return '$t/$canon';
}

/// Package total with a graft allowance ("from £3,500 / 500 grafts"), not £/graft.
String _withHairGraftAllowanceSuffix(
  String label,
  OpenAIClinic c,
  String? procedure,
) {
  final t = label.trim();
  if (t.isEmpty) return t;
  if (looksLikeHairPerGraftPrice(c, procedure: procedure)) return t;
  if (RegExp(r'graft', caseSensitive: false).hasMatch(t)) return t;
  final qty = c.priceQuantity;
  if (qty == null || qty < 50 || qty > 12000) return t;
  if (!isHairExploreProcedure(procedure) &&
      !isHairExploreProcedure(c.brand) &&
      !isHairExploreProcedure(c.rawProcedureText)) {
    return t;
  }
  final n = qty.round();
  final formatted = n >= 1000
      ? n.toString().replaceAllMapped(
          RegExp(r'(\d)(?=(\d{3})+$)'),
          (m) => '${m[1]},',
        )
      : '$n';
  return '$t / $formatted grafts';
}

/// HJE-style hospital guide: keep the card, mark that surgeon fees are extra.
String _withHospitalFeesOnlySuffix(
  String label,
  OpenAIClinic c,
  String? procedure,
) {
  final t = label.trim();
  if (t.isEmpty) return t;
  if (RegExp(r'hospital fees only', caseSensitive: false).hasMatch(t)) {
    return t;
  }
  final proc = procedure ?? c.brand;
  final blob =
      '${c.rawProcedureText}\n${c.rawPriceText}\n${c.priceEvidenceText}\n${c.priceLabel}';
  if (looksLikeHospitalFeesOnlyQuote(blob) ||
      looksLikeStarredHospitalGuidePrice(
        blob: blob,
        priceMin: c.priceMin,
        procedure: proc,
      )) {
    return '$t · hospital fees only';
  }
  return t;
}

/// "Starting From AED 200" / "Starts from 799" → canonical "from …".
String _normalizeStartingFromPrefix(String raw) {
  var t = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
  t = t.replaceFirst(
    RegExp(
      r'^(?:starting\s+from|starts?\s+from|start\s+from|de la|desde|'
      r'يبدأ من|تبدأ من)\s*',
      caseSensitive: false,
    ),
    '',
  );
  t = priceLabelCurrencyAfter(t.trim());
  return t;
}

String _listedWebsitePriceText(OpenAIClinic c) {
  for (final raw in [c.rawPriceText, c.priceLabel]) {
    var t = _stripComparePriceNoise(repairUtf8Mojibake(raw.trim()));
    t = _stripFormerComparePrice(t);
    if (t.isEmpty) continue;
    if (t.toLowerCase().contains('on request')) continue;
    if (!RegExp(r'\d').hasMatch(t)) continue;
    if (_listedPriceLooksLikeProcedureHeading(t)) continue;
    if (!_listedPriceIsQuoteOnly(t)) continue;
    if (c.priceMax > c.priceMin + 0.5 &&
        RegExp(r'^from\s', caseSensitive: false).hasMatch(t) &&
        !RegExp(r'[–—-]').hasMatch(t)) {
      continue;
    }
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    t = _trimListedPriceCentsAndUp(t);
    t = _compactDualListedPrices(t);
    t = _ensureListedPriceCurrency(t, c.currency);
    return t;
  }
  return '';
}

/// Clinic menus often keep a struck-through original. Compare only shows
/// the current listed amount.
String _stripFormerComparePrice(String raw) {
  var t = raw.trim();
  if (t.isEmpty) return t;
  t = t.replaceAll(RegExp(r'\s*\(\s*was\b[^)]*\)', caseSensitive: false), '');
  t = t.replaceAll(RegExp(r'\s*~~[^~]+~~'), '');
  return t.replaceAll(RegExp(r'\s+'), ' ').trim();
}

String _compactDualListedPrices(String raw) {
  final m = RegExp(
    r'^(\d[\d.]*)\s*(lei|ron|€|eur)?\s*,?\s+(\d[\d.]*)\s*(lei|ron|€|eur)?$',
    caseSensitive: false,
  ).firstMatch(raw.trim());
  if (m == null) return raw;
  final b = m.group(3)!;
  final cur = (m.group(4) ?? m.group(2) ?? '').trim();
  return cur.isEmpty ? b : '$b $cur';
}

String _trimListedPriceCentsAndUp(String raw) {
  var t = raw.replaceAll(RegExp(r'[.,]00(?=\s|$|[A-Za-z€£$+])'), '');
  // Menus write "$330+" for a starting price. The card already prefixes "from".
  t = t.replaceAll(RegExp(r'(?<=\d)\s*\+(?=\s|$|[A-Za-z£€$])'), '');
  t = t.replaceAll(RegExp(r'\s*\+\s*$'), '');
  return t.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
}

/// Words a listed quote may contain. Anything else means the scrape kept a
/// sentence ("How much does lip augmentation cost in Dubai? … 2025"), so the
/// card shows the formatted amount instead of the raw text.
const _kListedPriceWords = <String>{
  'from',
  'desde',
  'ab',
  'starting',
  'incepe',
  'începe',
  'porneste',
  'pornește',
  'intre',
  'între',
  'pana',
  'până',
  'hasta',
  'and',
  'the',
  'per',
  'pe',
  'each',
  'only',
  'doar',
  'aprox',
  'approx',
  'cca',
  'incl',
  'inclusive',
  'vat',
  'tva',
  'iva',
  'ml',
  'unit',
  'units',
  'unitate',
  'unitati',
  'unități',
  'area',
  'areas',
  'zone',
  'zones',
  'zona',
  'session',
  'sessions',
  'sesiune',
  'sedinta',
  'ședință',
  'sedinte',
  'graft',
  'grafts',
  'grafturi',
  'syringe',
  'syringes',
  'seringa',
  'seringă',
  'ron',
  'lei',
  'eur',
  'euro',
  'euros',
  'usd',
  'gbp',
  'aed',
  'try',
  'pln',
  'dirham',
  'dirhams',
  'درهم',
};

bool _listedPriceIsQuoteOnly(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return false;
  if (t.contains('?') || t.contains('؟')) return false;
  final words = t.toLowerCase().split(RegExp(r'[^a-zà-ÿăâîșț\u0600-\u06ff]+'));
  for (final w in words) {
    if (w.length < 3) continue;
    if (!_kListedPriceWords.contains(w)) return false;
  }
  return true;
}

bool _listedPriceLooksLikeProcedureHeading(String raw) {
  final t = raw.trim();
  if (t.length <= 28) return false;
  return RegExp(
    r'augmentare|mamar|rinoplast|implant|botox|filler|marire|'
    r'sani|sâni|pretul|prețul',
    caseSensitive: false,
  ).hasMatch(t);
}

bool _listedPriceHasCurrencyToken(String raw) {
  return RegExp(
    r'(ron|lei|eur|usd|gbp|aed|try|€|£|\$)',
    caseSensitive: false,
  ).hasMatch(raw);
}

String _ensureListedPriceCurrency(String listed, String currency) {
  if (_listedPriceHasCurrencyToken(listed)) return listed;
  final cur = currency.trim();
  if (cur.isEmpty) return listed;
  return '$listed $cur';
}
