import 'package:flutter/foundation.dart';

import 'explore_price_evidence.dart';
import 'explore_search_locale.dart';

/// Cheap JSON classifier for ambiguous page evidence only.
/// Does not browse the web.
const kExplorePriceVerifierModel = 'gpt-4o-mini';
const kExplorePriceVerifierMinConfidence = 0.85;

const Duration kExploreVerifiedPriceTtl = Duration(days: 21);
const Duration kExploreUnverifiedPriceRetry = Duration(hours: 12);

/// `sourceType` stamped on rows from the curated public-site dataset. Kept in
/// lockstep with `CURATED_SOURCE` in functions/explore/curatedStore.js.
const kExploreCuratedSourceType = 'curated_public_site';

/// Public clinic prices are re-checked after this long. A stale curated row is
/// still shown while a refresh runs — see stale-while-revalidate in
/// [ExploreCuratedPriceStore].
const Duration kExploreCuratedStaleAfter = Duration(days: 30);

/// How a procedure price was confirmed. Distinct from numeric plausibility.
enum PriceVerificationStatus {
  unverified,
  officialWebsite,
  freshaMarketplace,
  booksyMarketplace,
  marketplaceMenu,
  /// Hand-audited price read off a public clinic site, imported from the
  /// curated dataset rather than produced by the live evidence-lock pipeline.
  /// Carries a source URL and a check date but no DOM evidence, so it is
  /// trusted only through the curated branch of [explorePriceIsVerified].
  curatedPublicSite,
  searchEvidence,
  aiVerified,
  legacyUnverified;

  /// Missing field on old documents → [legacyUnverified] when a price exists.
  static PriceVerificationStatus fromJson(Object? raw, {bool hasPrice = false}) {
    final s = '$raw'.trim().toLowerCase();
    switch (s) {
      case 'official_website':
      case 'verifiedofficialwebsite':
        return PriceVerificationStatus.officialWebsite;
      case 'fresha_marketplace':
        return PriceVerificationStatus.freshaMarketplace;
      case 'booksy_marketplace':
        return PriceVerificationStatus.booksyMarketplace;
      case 'marketplace_menu':
        return PriceVerificationStatus.marketplaceMenu;
      case 'curated_public_site':
        return PriceVerificationStatus.curatedPublicSite;
      case 'search_evidence':
      case 'verifiedsearchevidence':
        return PriceVerificationStatus.searchEvidence;
      case 'ai_verified':
      case 'verifiedbyai':
        return PriceVerificationStatus.aiVerified;
      case 'legacy_unverified':
        return PriceVerificationStatus.legacyUnverified;
      case 'legacy_untrusted':
        // Migration-invalidated AI/legacy prices — never trusted for Explore pool.
        return PriceVerificationStatus.legacyUnverified;
      case 'unverified':
        return PriceVerificationStatus.unverified;
      default:
        return hasPrice
            ? PriceVerificationStatus.legacyUnverified
            : PriceVerificationStatus.unverified;
    }
  }

  String get wire => switch (this) {
        PriceVerificationStatus.officialWebsite => 'official_website',
        PriceVerificationStatus.freshaMarketplace => 'fresha_marketplace',
        PriceVerificationStatus.booksyMarketplace => 'booksy_marketplace',
        PriceVerificationStatus.marketplaceMenu => 'marketplace_menu',
        PriceVerificationStatus.curatedPublicSite => 'curated_public_site',
        PriceVerificationStatus.searchEvidence => 'search_evidence',
        PriceVerificationStatus.aiVerified => 'ai_verified',
        PriceVerificationStatus.legacyUnverified => 'legacy_unverified',
        PriceVerificationStatus.unverified => 'unverified',
      };

  /// Trusted for Explore cards, Typical range, and the reusable Firestore pool.
  /// Official website first; identity-matched Fresha/Booksy booking menus next.
  /// AI-verified numbers are never trusted.
  bool get isTrusted =>
      this == PriceVerificationStatus.officialWebsite ||
      this == PriceVerificationStatus.freshaMarketplace ||
      this == PriceVerificationStatus.booksyMarketplace ||
      this == PriceVerificationStatus.marketplaceMenu;
}

enum ExplorePriceVerifyDecision { verified, rejected, ambiguous }

class ExplorePriceVerifyResult {
  const ExplorePriceVerifyResult({
    required this.decision,
    this.priceMin = 0,
    this.currency = '',
    this.evidence = '',
    this.reason = '',
    this.confidence = 0,
  });

  final ExplorePriceVerifyDecision decision;
  final double priceMin;
  final String currency;
  final String evidence;
  final String reason;
  final double confidence;

  bool get isVerified =>
      decision == ExplorePriceVerifyDecision.verified && priceMin > 0;
}

String sanitizePriceEvidence(String raw, {int maxChars = 180}) {
  final t = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (t.length <= maxChars) return t;
  return t.substring(0, maxChars);
}

void logExplorePrice({
  required String clinicName,
  required String procedure,
  required double amount,
  String currency = '',
  String sourceUrl = '',
  String context = '',
  String? verdict,
}) {
  final cur = currency.trim();
  final amt = amount > 0
      ? (cur.isEmpty ? '$amount' : '$cur$amount')
      : 'none';
  debugPrint(
    '[GP PRICE] Candidate · $clinicName · $procedure · $amt',
  );
  if (sourceUrl.trim().isNotEmpty) {
    debugPrint('[GP PRICE] Source · ${sourceUrl.trim()}');
  }
  final excerpt = sanitizePriceEvidence(context);
  if (excerpt.isNotEmpty) {
    debugPrint('[GP PRICE] Context · "$excerpt"');
  }
  if (verdict != null && verdict.trim().isNotEmpty) {
    debugPrint('[GP PRICE] $verdict');
  }
}

/// Generic words that must not establish a procedure match on their own.
const _kGenericProcedureWords = {
  'tratamiento',
  'tratamientos',
  'treatment',
  'treatments',
  'precio',
  'precios',
  'price',
  'prices',
  'clinica',
  'clínica',
  'clinic',
  'desde',
  'from',
  'zona',
  'zonas',
  'zone',
  'area',
};

List<String> exploreProcedureMatchPhrases(String procedure) {
  final t = procedure.toLowerCase().trim();
  final fam = _familyKey(t);
  final out = <String>{};
  void addAll(Iterable<String> xs) {
    for (final x in xs) {
      final n = x.toLowerCase().trim();
      if (n.length < 4) continue;
      if (_kGenericProcedureWords.contains(n)) continue;
      out.add(n);
    }
  }

  addAll([t, procedure.trim()]);
  if (fam.isNotEmpty) {
    addAll(exploreProcedureNamesForLang(fam, 'en'));
    addAll(exploreProcedureNamesForLang(fam, 'es'));
    addAll(exploreProcedureNamesForLang(fam, 'ro'));
    addAll(exploreProcedureNamesForLang(fam, 'fr'));
    addAll(exploreProcedureNamesForLang(fam, 'it'));
    addAll(exploreLocalProcedureTokens(fam));
  }
  switch (fam) {
    case 'botox':
      addAll([
        'botox',
        'botulinum',
        'toxina botulinica',
        'toxina botulínica',
        'neuromoduladores',
        'neuromodulator',
        'anti-wrinkle',
        'antiarrugas',
        'anti-arrugas',
        'arrugas de expresion',
        'arrugas de expresión',
        'tratamiento antiarrugas',
      ]);
    case 'filler':
      addAll([
        'filler',
        'fillers',
        'hyaluronic',
        'hialuronico',
        'hialurónico',
        'juvederm',
        'restylane',
        'relleno',
        'lip filler',
        'dermal filler',
        'فيلر',
      ]);
    case 'laser':
      addAll([
        'laser hair',
        'laser hair removal',
        'depilacion laser',
        'depilación láser',
        'epilare laser',
        'hair removal',
        'ليزر ازالة الشعر',
        'إزالة الشعر بالليزر',
      ]);
    case 'peel':
      addAll([
        'chemical peel',
        'peeling quimico',
        'peeling químico',
        'peeling chimic',
        'peels',
        'tca peel',
        'تقشير كيميائي',
      ]);
    case 'rhinoplasty':
      addAll([
        'rhinoplasty',
        'rinoplastia',
        'rinoplastie',
        'nose job',
        'nose reshaping',
        'تجميل الانف',
        'تجميل الأنف',
      ]);
    case 'breast':
      addAll([
        'breast augmentation',
        'breast implants',
        'boob job',
        'aumento de pecho',
        'implant mamar',
        'mammaire',
        'تكبير الثدي',
      ]);
    case 'hair':
      addAll([
        'hair transplant',
        'hair restoration',
        'fue',
        'dhi',
        'injerto capilar',
        'transplant de par',
        'transplant par',
        'implant de par',
        'implant par',
        'fir cu fir',
        'greffe de cheveux',
        'trapianto capelli',
        'haartransplantation',
        'sac ekimi',
        'زراعة الشعر',
      ]);
  }
  return out.toList();
}

/// Tokens used to keep a Google result for this procedure, including
/// local spellings (`rinoplastie`, `rinoplastia`) — not only English.
List<String> exploreSerpProcedureMatchTokens(
  String procedure, {
  String lang = '',
}) {
  final out = <String>{};
  void add(String raw) {
    final full = raw.toLowerCase().trim();
    if (full.length >= 4) out.add(full);
    for (final part in full.split(RegExp(r'[\s/_-]+'))) {
      if (part.length >= 4 && !_kGenericProcedureWords.contains(part)) {
        out.add(part);
      }
    }
  }

  add(procedure);
  for (final p in exploreProcedureMatchPhrases(procedure)) {
    add(p);
  }
  if (lang.trim().isNotEmpty) {
    for (final n in exploreProcedureNamesForLang(_familyKey(procedure), lang)) {
      add(n);
    }
  }
  return out.toList();
}

/// Fetch this Google row when it looks like a clinic, price list, or
/// procedure page. The snippet does not need to quote 499 / 1,500 / etc.
/// Card prices always come from the clinic HTML afterwards.
bool exploreSerpHitWorthFetching({
  required String url,
  required String title,
  required String snippet,
  required String procedure,
}) {
  final rawUrl = url.trim();
  if (rawUrl.isEmpty) return false;
  final blob = _foldSerpMatchText('$title $snippet $rawUrl');
  if (RegExp(
    r'best clinics|mejores centros|mejores clinicas|mejores cl[ií]nicas|'
    r'\btop 10\b|\branking\b',
  ).hasMatch(blob)) {
    return false;
  }
  if (looksLikePriceMenuUrl(rawUrl)) return true;
  var path = rawUrl.toLowerCase();
  try {
    path = Uri.parse(rawUrl.contains('://') ? rawUrl : 'https://$rawUrl').path;
  } catch (_) {}
  if (RegExp(
    r'price|pricing|prices|offer|package|preturi|precios|tarif|cost',
  ).hasMatch(path)) {
    return true;
  }
  const clinicHints = [
    'clinic',
    'clinica',
    'medico',
    'doctor',
    'dra.',
    'estetic',
    'aesthetic',
    'cosmetic',
    'plastic',
    'cirugia',
    'chirurg',
    'dermatol',
    'medspa',
    'med spa',
  ];
  if (clinicHints.any(blob.contains)) return true;
  final host = Uri.tryParse(
        rawUrl.contains('://') ? rawUrl : 'https://$rawUrl',
      )?.host.toLowerCase() ??
      '';
  if (host.contains('clinic') ||
      host.startsWith('dr') ||
      host.startsWith('dra')) {
    return true;
  }
  for (final token in exploreSerpProcedureMatchTokens(procedure)) {
    if (token.length >= 4 && blob.contains(_foldSerpMatchText(token))) {
      return true;
    }
  }
  return false;
}

String _foldSerpMatchText(String raw) {
  const from = 'áàäâãåéèëêíìïîóòöôõúùüûñçýÿăâîșşțţ';
  const to = 'aaaaaaeeeeiiiiooooouuuuncyyaaisstt';
  final lower = raw.toLowerCase();
  final b = StringBuffer();
  for (final rune in lower.runes) {
    final ch = String.fromCharCode(rune);
    final i = from.indexOf(ch);
    b.write(i >= 0 ? to[i] : ch);
  }
  return b.toString();
}

String? explorePriceNegativeReason(String window) {
  final t = window.toLowerCase();
  if (RegExp(
    r'financiaci[oó]n|financing|finance\b|cuotas?\b|installments?|'
    r'\bloan\b|cr[eé]dito|credit\b|mensual|monthly|\bal mes\b|/mes\b|'
    r'desde\s+\d.{0,12}al\s+mes|minimum financing',
  ).hasMatch(t)) {
    return 'financing_price';
  }
  if (RegExp(
    r'\bdep[oó]sito\b|\bdeposit\b|booking fee|reservation fee|'
    r'down payment|a cuenta|se[nñ]al\b|descontado del precio|'
    r'se descontar[aá]|ser[aá] descontado',
  ).hasMatch(t)) {
    return 'deposit_price';
  }
  if (RegExp(
    r'consulta(?:\s+inicial)?|consultation|primera visita|valoraci[oó]n|'
    r'assessment fee|evaluation fee',
  ).hasMatch(t)) {
    return 'consultation_price';
  }
  if (RegExp(r'\bvoucher\b|gift\s*card|bono\s+regalo|tarjeta\s+regalo').hasMatch(t)) {
    return 'voucher_price';
  }
  if (RegExp(r'subscription|membership|suscripci[oó]n|membres[ií]a').hasMatch(t)) {
    return 'membership_price';
  }
  if (RegExp(
    r'\d{2,5}\s*(?:rese[nñ]as|reviews?|valoraciones|opiniones|'
    r'google\s*reviews|estrellas)\b|'
    r'(?:rese[nñ]as|reviews?|valoraciones|opiniones)\s*\d{2,5}',
  ).hasMatch(t)) {
    return 'review_count';
  }
  // Per-unit Botox is a valid starting price — do not treat as negative scope.
  return null;
}

bool _windowMentionsProcedure(String window, List<String> phrases) {
  final t = window.toLowerCase();
  for (final p in phrases) {
    if (p.length < 4) continue;
    if (p.contains(' ') ? t.contains(p) : RegExp('\\b${RegExp.escape(p)}\\b').hasMatch(t)) {
      return true;
    }
  }
  return false;
}

final _priceAmountRe = RegExp(
  r'(from|de\s+la|ab|desde|à\s+partir\s+de)?\s*[€£₩$]?\s*'
  r'(\d{1,3}(?:[.,\s]\d{3})+|\d{2,6}(?:[.,]\d{1,2})?)'
  r'\s*(?:€|eur|£|gbp|\$|usd|try|ron|lei|₩|krw|aed|hkd|sgd|thb|درهم|د\.إ)?',
  caseSensitive: false,
);

double? parseExploreEvidenceAmount(String raw) {
  final digits = raw.replaceAll(RegExp(r'[^\d.,]'), '');
  if (digits.isEmpty) return null;
  var t = digits.trim();
  if (t.contains(',') && t.contains('.')) {
    if (t.lastIndexOf(',') > t.lastIndexOf('.')) {
      t = t.replaceAll('.', '').replaceAll(',', '.');
    } else {
      t = t.replaceAll(',', '');
    }
  } else if (t.contains(',')) {
    final parts = t.split(',');
    t = parts.length == 2 && parts.last.length <= 2
        ? '${parts.first}.${parts.last}'
        : t.replaceAll(',', '');
  } else if (RegExp(r'\.\d{3}$').hasMatch(t)) {
    t = t.replaceAll('.', '');
  }
  return double.tryParse(t.replaceAll(' ', ''));
}

/// Local-window verification: the procedure must sit next to the amount,
/// and financing / consult / deposit copy must not.
ExplorePriceVerifyResult verifyPriceDeterministically({
  required String pageText,
  required String procedure,
  String clinicName = '',
  double? candidateAmount,
  String candidateCurrency = '',
  int windowChars = 280,
}) {
  // candidateAmount is a leftover search hint only — never the amount
  // we try to confirm. Any listed procedure price on the page is enough.
  assert(candidateAmount == null || candidateAmount >= 0);
  assert(clinicName.isEmpty || clinicName.isNotEmpty);
  if (pageText.trim().isEmpty) {
    return const ExplorePriceVerifyResult(
      decision: ExplorePriceVerifyDecision.rejected,
      reason: 'page_unreadable',
    );
  }
  final phrases = exploreProcedureMatchPhrases(procedure);
  if (phrases.isEmpty) {
    return const ExplorePriceVerifyResult(
      decision: ExplorePriceVerifyDecision.rejected,
      reason: 'different_procedure',
    );
  }
  final lower = pageText.toLowerCase();
  ExplorePriceVerifyResult? bestVerified;
  ExplorePriceVerifyResult? bestAmbiguous;
  String lastReject = 'no_price_near_procedure';

  for (final m in _priceAmountRe.allMatches(pageText)) {
    final parsed = parseExploreEvidenceAmount(m.group(0) ?? '');
    if (parsed == null || parsed < 20) continue;
    final start = (m.start - windowChars).clamp(0, pageText.length);
    final end = (m.end + windowChars).clamp(0, pageText.length);
    final window = lower.substring(start, end);
    final excerpt = sanitizePriceEvidence(pageText.substring(start, end));
    final neg = explorePriceNegativeReason(window);
    if (neg != null) {
      lastReject = neg;
      continue;
    }
    final mentions = _windowMentionsProcedure(window, phrases);
    if (!mentions) {
      lastReject = 'no_price_near_procedure';
      continue;
    }
    final hasFrom = (m.group(1) ?? '').trim().isNotEmpty;
    final cand = ExplorePriceVerifyResult(
      decision: ExplorePriceVerifyDecision.verified,
      priceMin: parsed,
      currency: candidateCurrency,
      evidence: excerpt,
      reason: hasFrom ? 'desde_prefix' : 'procedure_adjacent',
      confidence: hasFrom ? 0.96 : 0.9,
    );
    if (bestVerified == null) {
      bestVerified = cand;
    } else if (hasFrom && !bestVerified.reason.contains('desde')) {
      bestVerified = cand;
    }
  }

  if (bestVerified != null) return bestVerified;

  // Procedure + amount on the page but never in the same clean window.
  final pageHasProc = _windowMentionsProcedure(lower, phrases);
  if (pageHasProc && lastReject != 'no_price_near_procedure') {
    bestAmbiguous = ExplorePriceVerifyResult(
      decision: ExplorePriceVerifyDecision.ambiguous,
      reason: lastReject.isEmpty ? 'ambiguous_low_confidence' : lastReject,
      evidence: sanitizePriceEvidence(pageText),
    );
    return bestAmbiguous;
  }
  if (pageHasProc) {
    return ExplorePriceVerifyResult(
      decision: ExplorePriceVerifyDecision.ambiguous,
      reason: 'ambiguous_low_confidence',
      evidence: sanitizePriceEvidence(pageText),
    );
  }
  return ExplorePriceVerifyResult(
    decision: ExplorePriceVerifyDecision.rejected,
    reason: lastReject.isEmpty ? 'different_procedure' : lastReject,
  );
}

String _familyKey(String procedure) {
  final t = procedure.toLowerCase();
  if (t.contains('botox') ||
      t.contains('toxin') ||
      t.contains('wrinkle') ||
      t.contains('arruga') ||
      t.contains('neuromodul')) {
    return 'botox';
  }
  if (t.contains('filler') ||
      t.contains('hyaluron') ||
      t.contains('hialuron') ||
      t.contains('labio') ||
      t.contains('lip ')) {
    return 'filler';
  }
  if (t.contains('laser') || t.contains('depil') || t.contains('epilare')) {
    return 'laser';
  }
  if (t.contains('peel')) return 'peel';
  if (t.contains('rhino') || t.contains('rinoplast')) return 'rhinoplasty';
  if (t.contains('breast') || t.contains('boob') || t.contains('mamar')) {
    return 'breast';
  }
  if (t.contains('hair') || t.contains('fue') || t.contains('capilar')) {
    return 'hair';
  }
  return '';
}
