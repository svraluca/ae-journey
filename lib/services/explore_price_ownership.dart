import 'explore_regex_cache.dart';
import 'explore_clinic_identity.dart';
import 'explore_search_locale.dart';

/// Page-level ownership of a quoted amount on a clinic (or guide) URL.
///
/// Fragment-level extractors can look "exact" while the surrounding page is
/// a country cost guide. Page context must travel with every evidence row.
enum ExplorePricePageContext {
  officialPriceList,
  officialServicePrice,
  officialPackagePrice,
  informationalArticle,
  countryCostGuide,
  marketAverage,
  comparisonArticle,
  foreignPriceComparison,
  blog,
  unknown,
  nonClinicPrices,
}

String explorePricePageContextWire(ExplorePricePageContext c) {
  switch (c) {
    case ExplorePricePageContext.officialPriceList:
      return 'official_price_list';
    case ExplorePricePageContext.officialServicePrice:
      return 'official_service_price';
    case ExplorePricePageContext.officialPackagePrice:
      return 'official_package_price';
    case ExplorePricePageContext.informationalArticle:
      return 'informational_article';
    case ExplorePricePageContext.countryCostGuide:
      return 'country_cost_guide';
    case ExplorePricePageContext.marketAverage:
      return 'market_average';
    case ExplorePricePageContext.comparisonArticle:
      return 'comparison_article';
    case ExplorePricePageContext.foreignPriceComparison:
      return 'foreign_price_comparison';
    case ExplorePricePageContext.blog:
      return 'blog';
    case ExplorePricePageContext.unknown:
      return 'unknown';
    case ExplorePricePageContext.nonClinicPrices:
      return 'non_clinic_prices';
  }
}

ExplorePricePageContext explorePricePageContextFromWire(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'official_price_list':
      return ExplorePricePageContext.officialPriceList;
    case 'official_service_price':
      return ExplorePricePageContext.officialServicePrice;
    case 'official_package_price':
      return ExplorePricePageContext.officialPackagePrice;
    case 'informational_article':
      return ExplorePricePageContext.informationalArticle;
    case 'country_cost_guide':
      return ExplorePricePageContext.countryCostGuide;
    case 'market_average':
      return ExplorePricePageContext.marketAverage;
    case 'comparison_article':
      return ExplorePricePageContext.comparisonArticle;
    case 'foreign_price_comparison':
      return ExplorePricePageContext.foreignPriceComparison;
    case 'blog':
      return ExplorePricePageContext.blog;
    case 'non_clinic_prices':
      return ExplorePricePageContext.nonClinicPrices;
    default:
      return ExplorePricePageContext.unknown;
  }
}

bool explorePageContextIsAutomaticallyOwned(ExplorePricePageContext c) {
  return c == ExplorePricePageContext.officialPriceList ||
      c == ExplorePricePageContext.officialServicePrice ||
      c == ExplorePricePageContext.officialPackagePrice;
}

bool explorePageContextBlocksFragmentBypass(ExplorePricePageContext c) {
  return c == ExplorePricePageContext.countryCostGuide ||
      c == ExplorePricePageContext.nonClinicPrices ||
      c == ExplorePricePageContext.marketAverage ||
      c == ExplorePricePageContext.comparisonArticle ||
      c == ExplorePricePageContext.foreignPriceComparison ||
      c == ExplorePricePageContext.informationalArticle ||
      c == ExplorePricePageContext.blog;
}

bool _looksLikeCostGuideUrl(String sourceUrl) {
  final url = sourceUrl.trim().toLowerCase();
  if (url.isEmpty) return false;
  return cachedRegExp(
    r'/cost-of-[a-z0-9-]+-in-[a-z0-9-]+|'
    r'/prices?-in-[a-z0-9-]+|'
    r'/cost-guide|/price-guide/[^/?#]|/fiyat-rehberi|'
    r'/cost-savings|/cost-saving|'
    r'cost-of-breast|/breast-augmentation-cost|'
    r'/how-much-does-|/average-cost|'
    r'albania-vs-|vs-italy|vs-uk|vs-europe|'
    r'getclearbeauty\.|trueclinic\.|mymeditravel\.',
    caseSensitive: false,
  ).hasMatch(url);
}

final _doseAverageSentence = cachedRegExp(
  r'\bon average\s*,?\s*\d+(?:\s*[-–—]\s*\d+)?\s+(?:units?|grafts?)\b'
  r'([^.!?\n]{0,120}\b(?:are|is)\s+(?:used|required|needed)\b[^.!?\n]*(?:[.!?]|$))',
  caseSensitive: false,
);
final _monetaryAverage = cachedRegExp(
  r'[€£$]|\b(?:costs?|prices?|fees?|aed|eur|usd|gbp|ron|lei)\b',
  caseSensitive: false,
);
final _additionalAverageAmount = cachedRegExp(r'\d');

String _withoutDoseAverages(String raw) => raw.replaceAllMapped(
      _doseAverageSentence,
      (match) => _monetaryAverage.hasMatch(match.group(0)!) ||
              _additionalAverageAmount.hasMatch(match.group(1)!)
          ? match.group(0)!
          : '',
    );

/// An explicit disclaimer outweighs tariff-shaped fragments on the page.
bool looksLikeExplicitNonClinicPriceDisclaimer(String raw) {
  final text = foldExploreCityText(raw).replaceAll(cachedRegExp(r'\s+'), ' ');
  return cachedRegExp(
    r'\bno\s+representan\s+(?:los\s+)?precios\s+(?:aplicados|cobrados)\b|'
    r'\b(?:do\s+not|don.t)\s+represent\s+(?:the\s+)?(?:prices|fees)\s+'
    r'(?:charged|applied)\b|'
    r'\b(?:these|listed)\s+(?:prices|fees)\s+are\s+not\s+'
    r'(?:our|the\s+clinic.s)\s+(?:prices|fees)\b',
  ).hasMatch(text);
}

/// Classify the *page* (URL + body), not a single DOM fragment.
ExplorePricePageContext classifyExplorePricePageContext({
  required String sourceUrl,
  String pageText = '',
  String title = '',
}) {
  final url = sourceUrl.trim().toLowerCase();
  // Average quantities do not describe average prices. Keep monetary claims
  // intact, including sentences that mention a dose and a total fee together.
  final blob = _withoutDoseAverages('$title\n$pageText')
      .replaceAll('\u00a0', ' ')
      .toLowerCase();

  if (looksLikeExplicitNonClinicPriceDisclaimer(blob)) {
    return ExplorePricePageContext.nonClinicPrices;
  }

  if (_looksLikeCostGuideUrl(sourceUrl)) {
    return ExplorePricePageContext.countryCostGuide;
  }

  if (cachedRegExp(
    r'\bcompared with\b|\bcompare(?:d)?\s+(?:to|with)\b|'
    r'\bvs\.?\s+(?:italy|uk|uk prices|europe|abroad)\b|'
    r'\bpatients? can save\b|\bsave up to\b|'
    r'\bprices? in \w+ (?:range|vary|start)\b|'
    r'\bin albania (?:offers|starts|range)\b|'
    r'\bacross (?:clinics|the country|albania|turkey)\b',
    caseSensitive: false,
  ).hasMatch(blob)) {
    if (cachedRegExp(
      r'\bitaly|france|uk|germany|europe|abroad\b',
      caseSensitive: false,
    ).hasMatch(blob)) {
      return ExplorePricePageContext.foreignPriceComparison;
    }
    return ExplorePricePageContext.comparisonArticle;
  }

  if (cachedRegExp(
    r'\baverage price\b|\bon average\b|\btypically (?:cost|range|start)\b|'
    r'\bstarts? at roughly\b|\baround \d',
    caseSensitive: false,
  ).hasMatch(blob)) {
    return ExplorePricePageContext.marketAverage;
  }

  if (cachedRegExp(r'/blog/|/news/|/article/|/insights/', caseSensitive: false)
          .hasMatch(url) ||
      cachedRegExp(r'\bblog\b|\bin this article\b', caseSensitive: false)
          .hasMatch(blob)) {
    return ExplorePricePageContext.blog;
  }

  if (cachedRegExp(
    r'/price-list|/pricelist|/prices?(?:/|$|[?#])|/price-guide(?:/|$|[?#])|/precios|/preturi|/prezzi|/tarifs|'
    r'/cmimet|/çmimet|/fiyat|/cennik|/pricing\b',
    caseSensitive: false,
  ).hasMatch(url)) {
    return ExplorePricePageContext.officialPriceList;
  }

  if (cachedRegExp(
    r'\bprice list\b|\bour prices?\b|\btariffs?\b|\bcmimet\b|\bçmimet\b',
    caseSensitive: false,
  ).hasMatch(blob)) {
    return ExplorePricePageContext.officialPriceList;
  }

  if (cachedRegExp(
    r'\bour package\b|\bpackage (?:includes|starts|price)\b|'
    r'\bincludes 1 pair of implants\b',
    caseSensitive: false,
  ).hasMatch(blob)) {
    return ExplorePricePageContext.officialPackagePrice;
  }

  if (cachedRegExp(
    r'\bour (?:breast|botox|filler|rhinoplast|peel).{0,40}\bprice\b|'
    r'\bstarting (?:at|from)\b|'
    r'(?:^|\s)(?:عرضنا|أسعارنا)(?:\s|$)',
    caseSensitive: false,
  ).hasMatch('$title\n$pageText')) {
    return ExplorePricePageContext.officialServicePrice;
  }

  if (cachedRegExp(
    r'\bin (?:albania|turkey|dubai|london|italy)\b.{0,48}\b(?:offers|starts)|'
    r'\bwith only\b.{0,48}\b(?:breast|botox|filler|euros?|€)',
    caseSensitive: false,
  ).hasMatch(blob)) {
    return ExplorePricePageContext.countryCostGuide;
  }

  return ExplorePricePageContext.unknown;
}

/// Explicit clinic-owned price language on the fragment / nearby evidence.
bool looksLikeExplicitClinicOwnPriceLanguage(
  String raw, {
  String clinicName = '',
}) {
  final t = raw.replaceAll('\u00a0', ' ').trim();
  if (t.isEmpty) return false;
  if (cachedRegExp(
    r'\bour (?:breast|botox|filler|rhinoplast|peel|package|price|prices)\b|'
    r'\bour package starts\b|'
    r'\bour\s+(?:clinic|hospital|practice)\s+charges?\b|'
    r'\bprice list\s*:|'
    r'\bat\s+[A-Z][\w.\s-]{1,40}\s+(?:clinic|hospital|centre|center)\b|'
    r'\bstarts? from\b|'
    r'\bstarting (?:at|from)\b|'
    r'(?:^|\s)(?:عرضنا|أسعارنا)(?:\s|$)',
    caseSensitive: false,
  ).hasMatch(t)) {
    return true;
  }
  final clinic = clinicName.trim();
  if (clinic.length >= 3) {
    final folded = foldExploreCityText(clinic);
    if (folded.isNotEmpty &&
        foldExploreCityText(t).contains(folded) &&
        cachedRegExp(r'(€|£|\$|eur|gbp|usd|\d)', caseSensitive: false).hasMatch(t)) {
      return true;
    }
  }
  return false;
}

/// Country / market marketing that must never mint a clinic card alone.
bool looksLikeCountryMarketPriceMarketing(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').toLowerCase();
  if (t.trim().isEmpty) return false;
  return cachedRegExp(
    r'\bstarts? at roughly\b|'
    r'\bwith only\b.{0,48}\b(?:breast|botox|filler|euros?|€)\b|'
    r'\bbreast augmentation in \w+ offers\b|'
    r'\bin albania (?:offers|starts|range|prices)\b|'
    r'\bprices? in albania\b|'
    r'\bcompared with italy\b|'
    r'\bpatients? can save\b|'
    r'\bcost of breast augmentation in\b|'
    r'\ba breast augmentation starts at roughly\b',
    caseSensitive: false,
  ).hasMatch(t);
}

/// True when this evidence may drive a verified clinic price card.
bool exploreEvidenceIsClinicOwnedPrice({
  required ExplorePricePageContext pageContext,
  required String rawEvidence,
  required String rawProcedureText,
  String rawPriceText = '',
  String clinicName = '',
  bool treatProseAsUnowned = false,
}) {
  final blob = '$rawProcedureText\n$rawEvidence\n$rawPriceText';
  if (pageContext == ExplorePricePageContext.nonClinicPrices ||
      looksLikeExplicitNonClinicPriceDisclaimer(blob)) {
    return false;
  }
  if (looksLikeCountryMarketPriceMarketing(blob)) {
    if (!looksLikeExplicitClinicOwnPriceLanguage(blob, clinicName: clinicName)) {
      return false;
    }
  }
  if (explorePageContextBlocksFragmentBypass(pageContext)) {
    return looksLikeExplicitClinicOwnPriceLanguage(
      blob,
      clinicName: clinicName,
    );
  }
  if (explorePageContextIsAutomaticallyOwned(pageContext)) {
    return true;
  }
  if (treatProseAsUnowned) {
    return looksLikeExplicitClinicOwnPriceLanguage(
      blob,
      clinicName: clinicName,
    );
  }
  return true;
}

/// Optional subtitle when the source names a package detail (Mentor, etc.).
String exploreNormalizeProcedureDetail(String rawProcedureText) {
  final t = rawProcedureText.replaceAll('\u00a0', ' ').trim();
  if (t.isEmpty) return '';
  final mentor = cachedRegExp(r'\bmentor\b', caseSensitive: false).hasMatch(t);
  final includes = cachedRegExp(
    r'\bincludes?\b.{0,40}\bimplants?\b',
    caseSensitive: false,
  ).hasMatch(t);
  if (mentor && includes) return 'Mentor implants included';
  if (mentor) return 'Mentor implants';
  if (includes) return 'Implants included';
  return '';
}

/// Canonical / family → clean card title (never raw article sentences).
String exploreNormalizeProcedureDisplayName({
  required String procedureCanonical,
  String procedureFamily = '',
  String rawProcedureText = '',
  String brand = '',
  String selectedPill = '',
}) {
  final canonical = procedureCanonical.trim().toLowerCase().replaceAll(' ', '_');
  switch (canonical) {
    case 'chemical_peel':
    case 'peel':
      return 'Chemical Peel';
    case 'lip_filler':
      return 'Lip filler';
    case 'cheek_filler':
      return 'Cheek filler';
    case 'filler':
    case 'dermal_filler':
      return 'Lip filler';
    case 'botox':
      return 'Botox';
    case 'laser':
      return 'Laser skin treatment';
    case 'rhinoplasty':
      return 'Rhinoplasty';
    case 'breast_augmentation':
    case 'breast':
      return 'Breast Augmentation';
    case 'hair_transplant':
    case 'hair':
      return 'Hair transplant';
  }
  final fam = procedureFamily.trim().toLowerCase();
  switch (fam) {
    case 'breast':
    case 'breast_augmentation':
      return 'Breast Augmentation';
    case 'botox':
      return 'Botox';
    case 'filler':
      return 'Lip filler';
    case 'peel':
    case 'chemical_peel':
      return 'Chemical Peel';
    case 'rhinoplasty':
      return 'Rhinoplasty';
    case 'hair':
      return 'Hair transplant';
  }
  for (final candidate in [rawProcedureText, brand]) {
    final cleaned = candidate.replaceAll('\u00a0', ' ').trim();
    if (cleaned.isEmpty) continue;
    if (looksLikeCountryMarketPriceMarketing(cleaned) ||
        looksLikeRawScrapedProcedureTitle(cleaned) ||
        looksLikePricingProseProcedureTitle(cleaned)) {
      continue;
    }
    if (cleaned.length <= 48 &&
        !cachedRegExp(
          r'\b(includes|starts at|with only|roughly|offers:)\b',
          caseSensitive: false,
        ).hasMatch(cleaned)) {
      return cleaned;
    }
  }
  final pill = selectedPill.trim();
  if (pill.isNotEmpty && pill != 'All') {
    if (pill.toLowerCase().contains('boob') ||
        pill.toLowerCase().contains('breast')) {
      return 'Breast Augmentation';
    }
    return pill;
  }
  return 'Treatment';
}

