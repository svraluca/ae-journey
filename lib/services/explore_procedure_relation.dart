import 'package:flutter/foundation.dart';

import 'explore_price_evidence.dart';
import 'explore_price_sanity.dart';
import 'explore_clinic_identity.dart';
import 'explore_url_discovery.dart';
import 'explore_regex_cache.dart';

/// How an extracted price candidate relates to the requested Explore procedure.
///
/// Scoring / lowest-price selection runs only after this gate.
enum ProcedureRelation {
  /// Same treatment the user asked for (menu / treatment page line).
  exact,

  /// Same treatment sold by brand, amount, area, zone, or session.
  variant,

  /// Two or more distinct treatments sold together.
  bundle,

  /// Optional extra charged on top of another treatment.
  addOn,

  /// Same clinic catalogue family but a different bookable procedure.
  differentProcedure,

  /// City / market / “typical cost” copy — not a clinic menu price.
  marketInformation,

  /// Not enough signal to verify as a starting price.
  ambiguous,
}

/// Result of [classifyProcedureRelation].
class ProcedureRelationResult {
  const ProcedureRelationResult({required this.relation, required this.reason});

  final ProcedureRelation relation;
  final String reason;

  /// Only exact (always) and same-treatment variants may become FROM prices.
  bool get eligibleForFromPrice =>
      relation == ProcedureRelation.exact ||
      relation == ProcedureRelation.variant;

  String get logToken {
    switch (relation) {
      case ProcedureRelation.exact:
        return 'exact';
      case ProcedureRelation.variant:
        return 'variant';
      case ProcedureRelation.bundle:
        return 'bundle';
      case ProcedureRelation.addOn:
        return 'add_on';
      case ProcedureRelation.differentProcedure:
        return 'different_procedure';
      case ProcedureRelation.marketInformation:
        return 'market_information';
      case ProcedureRelation.ambiguous:
        return 'ambiguous';
    }
  }
}

String _fold(String raw) {
  const from = 'áàäâãåéèëêíìïîóòöôõúùüûñçşșță';
  const to = 'aaaaaaeeeeiiiiooooouuuuncssta';
  final b = StringBuffer();
  for (final ch in raw.toLowerCase().split('')) {
    final i = from.indexOf(ch);
    b.write(i >= 0 ? to[i] : ch);
  }
  return b.toString();
}

bool _hasAny(String folded, List<String> needles) {
  for (final n in needles) {
    final f = _fold(n);
    if (f.length >= 3 && folded.contains(f)) return true;
  }
  return false;
}

/// Requested Explore family (botox / filler / …) — language-agnostic keywords.
String exploreRelationRequestedFamily(String procedure) {
  final t = _fold(procedure);
  if (t.isEmpty || t == 'all') return 'other';
  if (t.contains('filler') ||
      t.contains('hialuron') ||
      t.contains('hyaluron') ||
      t.contains('relleno') ||
      t.contains('juvederm') ||
      t.contains('филър') ||
      t.contains('хиалуронова') ||
      t.contains('فيلر')) {
    return 'filler';
  }
  if (t.contains('botox') ||
      t.contains('toxin') ||
      t.contains('dysport') ||
      t.contains('ботокс') ||
      t.contains('ботулин') ||
      t.contains('بوتوكس')) {
    return 'botox';
  }
  if (t.contains('hydrafacial') || t.contains('hydra facial')) {
    return 'hydrafacial';
  }
  if (t.contains('profhilo') ||
      t.contains('sculptra') ||
      t.contains('skin booster') ||
      t.contains('rejuran') ||
      t.contains('jalupro')) {
    return 'skin';
  }
  if (cachedRegExp(r'\bprp\b').hasMatch(t) || t.contains('platelet')) return 'prp';
  if (t.contains('microneedl') ||
      t.contains('dermapen') ||
      t.contains('skinpen')) {
    return 'microneedling';
  }
  if (t.contains('hifu') || t.contains('ultherapy')) return 'hifu';
  if (t.contains('laser') ||
      t.contains('epilare') ||
      t.contains('depilacion') ||
      t.contains('ليزر') ||
      t.contains('лазер') ||
      t.contains('photo rejuvenation') ||
      t.contains('photorejuvenation') ||
      t.contains('photofacial') ||
      t.contains('byonik') ||
      t.contains('ipl')) {
    return 'laser';
  }
  if (t.contains('peel') ||
      t.contains('تقشير') ||
      t.contains('пилинг') ||
      t.contains('химичен')) {
    return 'peel';
  }
  if (t.contains('rhino') ||
      t.contains('rinoplast') ||
      t.contains('nose job') ||
      t.contains('ринопласт') ||
      t.contains('операция на носа') ||
      t.contains('корекция на носа') ||
      t.contains('تجميل الانف') ||
      t.contains('تجميل الأنف')) {
    return 'rhinoplasty';
  }
  if (t.contains('breast') ||
      t.contains('boob') ||
      t.contains('pecho') ||
      t.contains('mamar') ||
      t.contains('marire sani') ||
      t.contains('marirea sanilor') ||
      t.contains('уголемяване') ||
      t.contains('гръдни имплант') ||
      t.contains('импланти за бюст') ||
      t.contains('تكبير الثدي') ||
      t.contains('تكبير الصدر')) {
    return 'breast_augmentation';
  }
  if (t.contains('hair') ||
      t.contains('fue') ||
      t.contains('dhi') ||
      t.contains('graft') ||
      t.contains('injerto') ||
      t.contains('transplant de par') ||
      t.contains('трансплантация на коса') ||
      t.contains('присаждане на коса') ||
      t.contains('زراعة الشعر')) {
    return 'hair';
  }
  return 'other';
}

/// Distinct treatment signals found in a label / evidence / URL path.
class ProcedureTreatmentSignals {
  const ProcedureTreatmentSignals({
    this.botox = false,
    this.filler = false,
    this.laser = false,
    this.peel = false,
    this.rhinoplasty = false,
    this.hair = false,
    this.energyDevice = false,
    this.hydrafacial = false,
    this.skin = false,
    this.prp = false,
    this.microneedling = false,
    this.hifu = false,
    this.breastAugmentation = false,
    this.breastLift = false,
    this.breastReduction = false,
    this.breastRemoval = false,
    this.fatTransfer = false,
  });

  final bool botox;
  final bool filler;
  final bool laser;
  final bool peel;
  final bool rhinoplasty;
  final bool hair;
  final bool energyDevice;
  final bool hydrafacial;
  final bool skin;
  final bool prp;
  final bool microneedling;
  final bool hifu;
  final bool breastAugmentation;
  final bool breastLift;
  final bool breastReduction;
  final bool breastRemoval;
  final bool fatTransfer;

  Set<String> get families {
    final out = <String>{};
    if (botox) out.add('botox');
    if (filler) out.add('filler');
    if (laser) out.add('laser');
    if (peel) out.add('peel');
    if (rhinoplasty) out.add('rhinoplasty');
    if (hair) out.add('hair');
    if (energyDevice) out.add('energy_device');
    if (hydrafacial) out.add('hydrafacial');
    if (skin) out.add('skin');
    if (prp) out.add('prp');
    if (microneedling) out.add('microneedling');
    if (hifu) out.add('hifu');
    if (breastAugmentation) out.add('breast_augmentation');
    if (breastLift) out.add('breast_lift');
    if (breastReduction) out.add('breast_reduction');
    if (breastRemoval) out.add('breast_removal');
    if (fatTransfer) out.add('fat_transfer');
    return out;
  }

  bool matchesRequested(String want) {
    switch (want) {
      case 'botox':
        return botox;
      case 'filler':
        return filler;
      case 'laser':
        return laser;
      case 'peel':
        return peel;
      case 'rhinoplasty':
        return rhinoplasty;
      case 'hair':
        return hair;
      case 'energy_device':
        return energyDevice;
      case 'hydrafacial':
        return hydrafacial;
      case 'skin':
      case 'profhilo':
      case 'sculptra':
      case 'skin_booster':
        return skin;
      case 'prp':
        return prp;
      case 'microneedling':
        return microneedling;
      case 'hifu':
        return hifu;
      case 'breast_augmentation':
      case 'breast':
        return breastAugmentation;
      case 'fat_transfer':
        return fatTransfer;
      default:
        return false;
    }
  }

  /// Other bookable procedures present besides [want].
  Set<String> extrasBeside(String want) {
    final all = families;
    switch (want) {
      case 'breast_augmentation':
      case 'breast':
        all.remove('breast_augmentation');
        break;
      case 'profhilo':
      case 'sculptra':
      case 'skin_booster':
        all.remove('skin');
        break;
      case 'hair':
        all.remove('hair');
        break;
      default:
        all.remove(want);
    }
    return all;
  }
}

ProcedureTreatmentSignals detectProcedureTreatmentSignals(String raw) {
  final t = _fold(raw);
  if (t.trim().isEmpty) return const ProcedureTreatmentSignals();

  final breastRemoval =
      _hasAny(t, const [
        'implant removal',
        'breast implant removal',
        'explant',
        'explantacion',
        'extraccion de protesis',
        'extracción de prótesis',
        'scoatere implant',
        'indepartare implant',
        'إزالة الزرعة',
        'إزالة الثدي',
      ]) ||
      (t.contains('removal') && t.contains('implant') && t.contains('breast'));

  final breastReduction = _hasAny(t, const [
    'breast reduction',
    'reduction mammoplasty',
    'reduccion de pecho',
    'reducción de pecho',
    'reductie mamara',
    'reducere sani',
    'mamoplastia de reduccion',
    'تصغير الثدي',
  ]);

  final breastLift = _hasAny(t, const [
    'breast lift',
    'mastopex',
    'mastopexy',
    'lifting pecho',
    'lifting de pecho',
    'ridicare sani',
    'شد الثدي',
    'رفع الثدي',
  ]);

  // Augmentation may share a page with “breast” — require positive aug cues.
  final breastAug =
      _hasAny(t, const [
        'breast augmentation',
        'augmentation mammoplasty',
        'aumento de pecho',
        'aumento mamario',
        'mamoplastia de aumento',
        'implant mamar',
        'breast implant',
        'implants mammaires',
        'marire sani',
        'marire de sani',
        'marirea sanilor',
        'augmentare mamara',
        'proteza mamara',
        'proteze mamare',
        'mastoplast',
        'boob job',
        'уголемяване на бюст',
        'уголемяване на гърди',
        'гръдни импланти',
        'импланти за бюст',
        'تكبير الثدي',
        'تكبير الصدر',
        'زراعة الثدي',
      ]) ||
      (t.contains('breast') &&
          (t.contains('augment') ||
              t.contains('implant') ||
              t.contains('enlarg'))) ||
      (t.contains('sani') &&
          (t.contains('marire') ||
              t.contains('implant') ||
              t.contains('protez')));

  final botox =
      _hasAny(t, const [
        'botox',
        'botulinum',
        'toxina botulin',
        'botulotoxin',
        'dysport',
        'xeomin',
        'neuronox',
        'jeuveau',
        'daxxify',
        'azzalure',
        'vistabel',
        'neuromodul',
        'wrinkle relaxer',
        'neurotoxin',
        'ботокс',
        'ботулин',
        'ботулотоксин',
        'بوتوكس',
      ]) ||
      _looksLikeLipFlipOrGummySmile(t) ||
      cachedRegExp(r'\btox\b', caseSensitive: false).hasMatch(t) ||
      (cachedRegExp(r'\banti[\s-]?wrinkle\b|\bantiarrugas\b').hasMatch(t) &&
          cachedRegExp(
            r'\binject|toxin|unit|units|\biu\b|treatments?|injections?|'
            r'\b(?:1|2|3|one|two|three)\s*(?:area|areas|zona|zone)',
          ).hasMatch(t) &&
          !cachedRegExp(
            r'\b(?:cream|serum|moistur|lotion|skincare|pad|mask)\b',
          ).hasMatch(t));

  final filler =
      _hasAny(t, const [
        'filler',
        'dermal filler',
        'hyaluronic',
        'acido hialuronico',
        'acid hialuronic',
        'relleno',
        'juvederm',
        'restylane',
        'teosyal',
        'belotero',
        'revolax',
        'radiesse',
        'fillmed',
        'art filler',
        'artfiller',
        'lip filler',
        'lip augmentation',
        'cheek filler',
        'aumento de labios',
        'relleno de labios',
        'relleno de pomulos',
        'relleno de pómulos',
        'marire buze',
        'volumizare buze',
        'филър',
        'хиалуронова киселина',
        'филър за устни',
        'дермален филър',
        'فيلر',
      ]) ||
      (t.contains('lip') &&
          (t.contains('augment') ||
              t.contains('filler') ||
              t.contains('inject'))) ||
      (t.contains('labios') && t.contains('aumento')) ||
      // Brand + lips/cheeks menu rows (e.g. "Fillmed Lips", "Restylane Kysse").
      (cachedRegExp(
            r'\b(?:juvederm|restylane|teosyal|belotero|revolax|radiesse|'
            r'fillmed|stylage|volbella|voluma|volift|kysse)\b',
            caseSensitive: false,
          ).hasMatch(t) &&
          cachedRegExp(
            r'\b(?:lips?|labios?|cheeks?|buze|pomulos?|pómulos?)\b',
            caseSensitive: false,
          ).hasMatch(t)) ||
      // Stylage M/L/XL (+ ml) is HA filler. Hydro/Hydromax stay skin booster.
      (cachedRegExp(r'\bstylage\s+[mlx]\b', caseSensitive: false).hasMatch(t)) ||
      (cachedRegExp(r'\bstylage\b', caseSensitive: false).hasMatch(t) &&
          !cachedRegExp(
            r'\bstylage\s+hydro|\bhydromax\b',
            caseSensitive: false,
          ).hasMatch(t) &&
          cachedRegExp(
            r'\b\d+(?:[.,]\d+)?\s*ml\b',
            caseSensitive: false,
          ).hasMatch(t));
  final hairFillerOrScalpTx = cachedRegExp(
    r'\bhair\s+filler\b|\bfiller\s+(?:for\s+)?hair\b|\bdr\.?\s*cyj\b|'
    r'\bhair\s+mesotherap|\bmesotherap(?:y|ie)\s+(?:for\s+)?hair\b|'
    r'\bxl\s*hair\b|\bplinest\s+hair\b',
    caseSensitive: false,
  ).hasMatch(t);
  final fillerSignal = filler && !hairFillerOrScalpTx;

  final laser = _hasAny(t, const [
    'laser',
    'depilacion laser',
    'epilare laser',
    'fraxel',
    'ipl',
    'photo rejuvenation',
    'photorejuvenation',
    'photofacial',
    'byonik',
    'лазерна епилация',
    'лазер',
    'ليزر',
  ]);

  final peel = _hasAny(t, const [
    'peel',
    'peeling',
    'chemical peel',
    'glycolic',
    'jessner',
    'химичен пилинг',
    'пилинг',
    'تقشير',
  ]);

  final rhino = _hasAny(t, const [
    'rhinoplasty',
    'rinoplastia',
    'rinoplastie',
    'nose job',
    'nose reshaping',
    'ринопластика',
    'операция на носа',
    'корекция на носа',
    'تجميل الانف',
    'تجميل الأنف',
  ]);

  final hair =
      _hasAny(t, const [
        'hair transplant',
        'hair implant',
        'injerto capilar',
        'transplant de par',
        'fue',
        'dhi',
        'graft',
        'трансплантация на коса',
        'присаждане на коса',
        'زراعة الشعر',
      ]) ||
      hairFillerOrScalpTx;

  final energy =
      looksLikeEnergyOrDeviceTreatment(t) ||
      cachedRegExp(
        r'\bradiofrequency\b|\brf\s*microneedl|\bthread lift\b|\bpdo threads?\b',
        caseSensitive: false,
      ).hasMatch(t);
  final hydrafacial = _hasAny(t, const ['hydrafacial', 'hydra facial']);
  final skin = _hasAny(t, const [
    'profhilo',
    'sculptra',
    'skin booster',
    'skinbooster',
    'rejuran',
    'jalupro',
    'nucleofill',
    'stylage hydro',
    'hydromax',
    'biorevital',
  ]);
  final prp = _hasAny(t, const ['prp', 'platelet rich', 'vampire facial']);
  final microneedling = _hasAny(t, const [
    'microneedling',
    'dermapen',
    'skinpen',
  ]);
  final hifu = _hasAny(t, const ['hifu', 'ultherapy', 'ulthera']);
  // Fat grafting is not Botox/filler — polluted price-page blobs that also
  // mention toxina must not promote Nanofat/Lipofilling as same_treatment.
  final fatTransfer =
      _hasAny(t, const [
        'nanofat',
        'microfat',
        'lipofilling',
        'lipofiling',
        'fat transfer',
        'fat grafting',
        'fat graft',
        'greffe de graisse',
        'transfert de graisse',
        'grasime proprie',
      ]) ||
      (t.contains('fat') &&
          (t.contains('transfer') ||
              t.contains('graft') ||
              t.contains('inject')));

  return ProcedureTreatmentSignals(
    botox: botox,
    filler: fillerSignal,
    laser: laser,
    peel: peel,
    rhinoplasty: rhino,
    hair: hair,
    energyDevice: energy,
    hydrafacial: hydrafacial,
    skin: skin,
    prp: prp,
    microneedling: microneedling,
    hifu: hifu,
    breastAugmentation: breastAug && !breastRemoval && !breastReduction,
    breastLift: breastLift,
    breastReduction: breastReduction,
    breastRemoval: breastRemoval,
    fatTransfer: fatTransfer,
  );
}

bool pageHasRequestedFamilyWitness({
  required Iterable<ExtractedPriceEvidence> rows,
  required String procedure,
}) {
  final want = exploreRelationRequestedFamily(procedure);
  if (want == 'other') return false;
  for (final r in rows) {
    if (detectProcedureTreatmentSignals(
      '${r.rawProcedureText} ${r.rawEvidence} ${r.sourceUrl}',
    ).matchesRequested(want)) {
      return true;
    }
  }
  // Official injectables/botox price URLs count as a page-level family witness
  // so area-only rows ("1 Area") can inherit under a Botox menu.
  final urls = rows.map((r) => r.sourceUrl).where((u) => u.trim().isNotEmpty);
  for (final url in urls) {
    final u = url.toLowerCase();
    if (want == 'botox' &&
        cachedRegExp(r'botox|anti-?wrinkle|injectable|neuromodulat').hasMatch(u)) {
      return true;
    }
    if (want == 'filler' &&
        cachedRegExp(r'filler|dermal|injectable|hyaluron').hasMatch(u)) {
      return true;
    }
  }
  return false;
}

bool _hasComboSyntax(String folded) {
  return cachedRegExp(
    r'\+|/\s*(?:and|&)|(?:^|[^\w])&\s*|'
    r'\b(?:plus|combo|bundle|package|pack|paquet[e]?|pachet|باقة)\b|'
    r'\b(?:together with|combined with|along with)\b|'
    r'\bwith\s+(?:breast\s+)?(?:lift|mastopex|reduction|botox|filler|peel|laser)\b|'
    r'\b(?:and|&)\s+(?:breast\s+)?(?:lift|mastopex|reduction|botox|filler|peel|laser)\b|'
    r'\bbotox\s*(?:\+|and|&)\s*filler\b|'
    r'\bfiller\s*(?:\+|and|&)\s*botox\b|'
    r'\b(?:face\s+)?tox\s*(?:\+|and|&)\s*(?:\d+\s+syringes?\s+)?filler\b|'
    r'\bfiller\s*(?:\+|and|&)\s*(?:\d+\s+syringes?\s+)?(?:face\s+)?tox\b',
    caseSensitive: false,
  ).hasMatch(folded);
}

bool _looksLikeExplicitAddOn(String folded) {
  return cachedRegExp(
    r'\badd[\s-]?on\b|\baddon\b',
    caseSensitive: false,
  ).hasMatch(folded);
}

bool _looksLikeAddOn(String folded) {
  return _looksLikeExplicitAddOn(folded) ||
      cachedRegExp(
        r'\bextra\b|\boptional\b|'
        r'\bsupplement\b|\bcomplemento\b|\bsupliment\b|'
        r'\bin addition\b|\badditionally\b|'
        r'when added to another',
        caseSensitive: false,
      ).hasMatch(folded);
}

bool _looksLikeBotoxZoneOrAreaLabel(String folded) {
  // Counted starting zones only. Bare "area" matches "area-based pricing"
  // on Forma / RF pages and must not inherit Botox.
  return cachedRegExp(
    r'\b(?:periocular|glabel|glabelar|frontal|frunte|crow|coada och|'
    r'laba g|frown|forehead|glabella)\b|'
    r'\b(?:1|2|3|una|doua|două|trei|one|two|three|single)\s*(?:zon|area)',
    caseSensitive: false,
  ).hasMatch(folded);
}

/// Area-only menu labels may inherit the requested family. Named devices may not.
bool looksLikeInheritableAreaOnlyLabel({
  required String label,
  required String requestedFamily,
}) {
  final folded = _fold(label);
  if (folded.trim().isEmpty) return false;
  if (looksLikeEnergyOrDeviceTreatment(label) ||
      looksLikeEnergyOrDeviceTreatment(folded)) {
    return false;
  }
  switch (requestedFamily) {
    case 'botox':
      return _looksLikeBotoxZoneOrAreaLabel(folded);
    case 'filler':
      if (_looksLikeLipFlipOrGummySmile(folded) ||
          cachedRegExp(
            r'\bmasseter\b|\bbruxism\b|teeth grind|jawline slimming|'
            r'filler[\s-]?dissolv|dissolv(?:e|ing)',
            caseSensitive: false,
          ).hasMatch(folded)) {
        return false;
      }
      return _looksLikeFillerAreaLabel(folded);
    case 'laser':
      return _looksLikeLaserAreaLabel(folded);
    default:
      return false;
  }
}

bool _looksLikeLaserAreaLabel(String folded) {
  if (cachedRegExp(
    r'\b(?:shav(?:e|ing)|wax(?:ing)?|thread(?:ing)?|sugaring)\b',
    caseSensitive: false,
  ).hasMatch(folded)) {
    return false;
  }
  return cachedRegExp(
    r'\b(?:underarm|under[\s-]?arms?|bikini|brazilian|hollywood|'
    r'peri[\s-]?anal|intimate|full\s+face|half\s+leg|'
    r'full\s+leg|full\s+body|upper\s+lip|back|chest|face|legs?|arms?|'
    r'photo\s*rejuvenation|photorejuvenation|photofacial|byonik|\bipl\b)\b',
    caseSensitive: false,
  ).hasMatch(folded);
}

bool _looksLikeLipFlipOrGummySmile(String folded) {
  return cachedRegExp(
    r'\blip[\s-]?flip\b|\blipflip\b|\bgummy\s*smile\b',
    caseSensitive: false,
  ).hasMatch(folded);
}

bool _looksLikeFillerAreaLabel(String folded) {
  if (_looksLikeLipFlipOrGummySmile(folded)) return false;
  return cachedRegExp(
    r'\b(?:lips?|labios?|cheeks?|tear\s*trough|smile\s*lines?|nasolabial|'
    r'jaw\s*lines?|chin|marionette|russian\s+lips?|'
    r'\d+(?:[.,]\d+)?\s*ml)\b',
    caseSensitive: false,
  ).hasMatch(folded);
}

/// Bare tariff cells like "1100 Lei/1 ml" / "1.650 Ron / ml" on /preturi pages.
bool _looksLikeBareFillerPerMlRate(String label) {
  final t = label.replaceAll('\u00a0', ' ').trim();
  if (t.isEmpty) return false;
  return cachedRegExp(
    r'^(?:from|de\s+la|desde)?\s*'
    r'(?:€|£|\$)?\s*\d{2,5}(?:[.,]\d{3})*(?:[.,]\d+)?\s*'
    r'(?:lei|ron|eur|euro|€|£|\$|gbp|usd)?\s*'
    r'(?:\/|per)\s*(?:1\s*)?ml\s*$',
    caseSensitive: false,
  ).hasMatch(t);
}

/// Official price-menu paths count as a family witness for bare ml/zone cells.
bool exploreSourceUrlLooksLikePriceMenu(String sourceUrl) {
  final u = sourceUrl.trim().toLowerCase();
  if (u.isEmpty) return false;
  // Match path segments: /prices, /price-list, /price-list-medical/, /ceni, …
  // Do not require an immediate / after "price-list" — clinics often use
  // /price-list-medical/ or /price_list_botox.
  return cachedRegExp(
    r'/(?:preturi|prețuri|preţuri|tarife|prices?|pricing|price[-_]?lists?|'
    r'our-pricing|cena|ceni|цени|ценоразпис|pricelists?|lista-preturi|'
    r'listino|tarifario|honorarios|fees?)'
    r'(?:[-_/]|$|\?)',
    caseSensitive: false,
  ).hasMatch(u);
}

bool _sourceUrlLooksLikePriceMenu(String sourceUrl) =>
    exploreSourceUrlLooksLikePriceMenu(sourceUrl);

bool _looksLikeSameTreatmentVariant(String folded, String want) {
  final qtyOrUnit = cachedRegExp(
    r'\b\d+(?:[.,]\d+)?\s*(?:ml|cc|syringe|jeringa|fiola|unit|units|iu|zona|zone|zones|'
    r'area|areas|session|sesion|sedinta|graft|grafts)\b|'
    r'(?:per|/)\s*(?:ml|unit|units|iu|syringe|area|session|graft)\b|'
    r'\bpor\s+unidad\b|\bper\s+unit\b',
    caseSensitive: false,
  ).hasMatch(folded);
  final brandOrSku = cachedRegExp(
    r'\b(?:juvederm|restylane|teosyal|belotero|revolax|stylage|volbella|voluma|volift|'
    r'fillmed|art\s*filler|kysse|dysport|xeomin|neuronox|azzalure|vistabel|'
    r'mentor|motiva|polytech|nagor|sebbin|soprano|fotona|fraxel)\b',
    caseSensitive: false,
  ).hasMatch(folded);
  final zoneOrArea = cachedRegExp(
    r'\b(?:\d+|one|two|three|1|2|3)\s*(?:zone|zones|zona|zone|area|areas)\b|'
    r'\b(?:forehead|frown|crow|glabel|masseter|jaw|lip|cheek|underarm|full\s+face)\b',
    caseSensitive: false,
  ).hasMatch(folded);
  if (want == 'botox' && _looksLikeBotoxZoneOrAreaLabel(folded)) return true;
  if (want == 'laser' && _looksLikeLaserAreaLabel(folded)) return true;
  if (want == 'filler' && _looksLikeFillerAreaLabel(folded)) return true;
  if (!(qtyOrUnit || brandOrSku || zoneOrArea)) return false;
  switch (want) {
    case 'botox':
    case 'filler':
    case 'laser':
    case 'peel':
    case 'hair':
    case 'breast_augmentation':
    case 'rhinoplasty':
      return true;
    default:
      return qtyOrUnit || brandOrSku;
  }
}

bool _looksLikeMarketCopy(String blob) {
  return looksLikeMarketAveragePriceBlurb(blob) ||
      looksLikeCityCommonPriceGuideBlurb(blob) ||
      looksLikeGoogleAreaEstimateBlurb(blob);
}

/// "Treatment" / "Procedure" column leftovers — URL may carry the family.
bool _looksLikeGenericPricedColumnLabel(String raw) {
  final t = raw
      .replaceAll('\u00a0', ' ')
      .toLowerCase()
      .replaceAll(cachedRegExp(r'[^a-z0-9]+'), ' ')
      .trim();
  if (t.isEmpty) return true;
  return cachedRegExp(
    r'^(?:treatment|treatments|procedure|procedures|service|services|'
    r'item|guide price|guide price from|price from)$',
  ).hasMatch(t);
}

String _urlPathTextForRelation(String sourceUrl) {
  final raw = sourceUrl.trim();
  if (raw.isEmpty) return '';
  try {
    final uri = Uri.parse(raw.contains('://') ? raw : 'https://$raw');
    return '${uri.path} ${uri.query}'.replaceAll(cachedRegExp(r'[/#?&=._\-]+'), ' ');
  } catch (_) {
    return raw.replaceAll(cachedRegExp(r'[/#?&=._\-]+'), ' ');
  }
}

/// Classify how [label] / [evidence] relate to [requestedProcedure].
ProcedureRelationResult classifyProcedureRelation({
  required String requestedProcedure,
  String label = '',
  String evidence = '',
  String sourceUrl = '',
  bool clinicOwnQuoted = false,
  String parentHeading = '',
  bool pageHasFamilyWitness = false,
}) {
  final want = exploreRelationRequestedFamily(requestedProcedure);
  final blob = '$label\n$evidence';
  final folded = _fold(blob);
  // Hostnames like londonpremierlaser.co.uk must not mark a Botox row as laser.
  final urlFolded = _fold(_urlPathTextForRelation(sourceUrl));

  if (looksLikeFinancingOrPaymentHeading(label)) {
    return const ProcedureRelationResult(
      relation: ProcedureRelation.ambiguous,
      reason: 'financing_heading',
    );
  }

  if (looksLikeCityMarketPricingGuideUrl(sourceUrl) ||
      looksLikeMarketEstimateDirectoryUrl(sourceUrl)) {
    return const ProcedureRelationResult(
      relation: ProcedureRelation.marketInformation,
      reason: 'city_market_pricing_guide',
    );
  }
  if (looksLikeTreatmentFinanceUrl(sourceUrl)) {
    return const ProcedureRelationResult(
      relation: ProcedureRelation.ambiguous,
      reason: 'treatment_finance_page',
    );
  }

  if (!clinicOwnQuoted && _looksLikeMarketCopy(blob)) {
    return const ProcedureRelationResult(
      relation: ProcedureRelation.marketInformation,
      reason: 'market_or_city_average_copy',
    );
  }
  if (cachedRegExp(
    r'\btypical(?:ly)?\s+sessions?\s+rang|'
    r'\bprices?\s+vary\s+depending\b',
    caseSensitive: false,
  ).hasMatch(folded)) {
    return const ProcedureRelationResult(
      relation: ProcedureRelation.marketInformation,
      reason: 'typical_market_range_copy',
    );
  }

  if (looksLikeMixedServiceBundle(blob) || looksLikeMixedServiceBundle(label)) {
    return const ProcedureRelationResult(
      relation: ProcedureRelation.bundle,
      reason: 'mixed_service_package',
    );
  }

  final signals = detectProcedureTreatmentSignals(blob);
  final urlSignals = detectProcedureTreatmentSignals(urlFolded);
  final labelSignals = detectProcedureTreatmentSignals(label);
  // A /botox-fillers/ landing must not turn a clean "1 Area £175" row
  // into a bundle. URL extras only gate URL-only fallback below.
  final extras = signals.extrasBeside(want);

  // Label-only fat grafting must never become a Botox/filler FROM just because
  // the same price-page blob also mentions toxina / HA elsewhere.
  if ((want == 'botox' || want == 'filler') &&
      labelSignals.fatTransfer &&
      !labelSignals.matchesRequested(want)) {
    _noteRelationReject('fat_transfer');
    return const ProcedureRelationResult(
      relation: ProcedureRelation.differentProcedure,
      reason: 'competing_family_fat_transfer',
    );
  }

  // Breast siblings are different procedures, not variants of augmentation.
  if (want == 'breast_augmentation' || want == 'breast') {
    if (signals.breastRemoval || urlSignals.breastRemoval) {
      return const ProcedureRelationResult(
        relation: ProcedureRelation.differentProcedure,
        reason: 'breast_implant_removal',
      );
    }
    if (signals.breastReduction || urlSignals.breastReduction) {
      return const ProcedureRelationResult(
        relation: ProcedureRelation.differentProcedure,
        reason: 'breast_reduction',
      );
    }
    if ((signals.breastLift || urlSignals.breastLift) &&
        !signals.breastAugmentation &&
        !urlSignals.breastAugmentation) {
      return const ProcedureRelationResult(
        relation: ProcedureRelation.differentProcedure,
        reason: 'breast_lift_only',
      );
    }
    if (cachedRegExp(
          r'\binverted nipple\b|\bnipple (?:lift|reduction|correction)\b',
        ).hasMatch(folded) &&
        !signals.breastAugmentation &&
        !urlSignals.breastAugmentation) {
      return const ProcedureRelationResult(
        relation: ProcedureRelation.differentProcedure,
        reason: 'breast_nipple_only',
      );
    }
    if (looksLikeUnilateralBreastStartingRow(folded) ||
        looksLikeUnilateralBreastStartingRow(label)) {
      return const ProcedureRelationResult(
        relation: ProcedureRelation.differentProcedure,
        reason: 'breast_unilateral',
      );
    }
    if (looksLikeBreastAugmentationAddOnRow(folded) ||
        looksLikeBreastAugmentationAddOnRow(label)) {
      return const ProcedureRelationResult(
        relation: ProcedureRelation.addOn,
        reason: 'breast_addon_or_areola',
      );
    }
    if (signals.breastAugmentation &&
        (signals.breastLift || signals.breastReduction)) {
      return const ProcedureRelationResult(
        relation: ProcedureRelation.bundle,
        reason: 'breast_aug_plus_lift_or_reduction',
      );
    }
  }

  if (extras.isNotEmpty && _hasComboSyntax(folded)) {
    return ProcedureRelationResult(
      relation: ProcedureRelation.bundle,
      reason: 'combo_with_${extras.join('_')}',
    );
  }

  // Two+ families in a short menu label ⇒ package / combo line.
  if (extras.isNotEmpty &&
      signals.matchesRequested(want) &&
      folded.trim().length <= 160 &&
      (extras.length >= 1 &&
          (folded.contains('+') ||
              cachedRegExp(r'\b(?:package|combo|bundle|باقة)\b').hasMatch(folded) ||
              extras.length >= 2))) {
    return ProcedureRelationResult(
      relation: ProcedureRelation.bundle,
      reason: 'multi_procedure_line_${extras.join('_')}',
    );
  }

  if (_looksLikeExplicitAddOn(folded) ||
      (_looksLikeAddOn(folded) && extras.isNotEmpty)) {
    return const ProcedureRelationResult(
      relation: ProcedureRelation.addOn,
      reason: 'add_on_modifier',
    );
  }
  if (want == 'botox' &&
      cachedRegExp(
        r'when added to another|targeted areas|higher[- ]dosage supplement',
        caseSensitive: false,
      ).hasMatch(folded) &&
      !cachedRegExp(
        r'\b(?:1|one|single)\s*area\b',
        caseSensitive: false,
      ).hasMatch(folded)) {
    return const ProcedureRelationResult(
      relation: ProcedureRelation.addOn,
      reason: 'botox_addon_or_targeted',
    );
  }

  if (want == 'rhinoplasty' &&
      looksLikePartialRhinoplastyStarting(label) &&
      !looksLikePrimaryRhinoplastyStarting(label)) {
    return const ProcedureRelationResult(
      relation: ProcedureRelation.differentProcedure,
      reason: 'rhino_tip_or_partial',
    );
  }

  if (want != 'other' && !signals.matchesRequested(want)) {
    final parentSignals = detectProcedureTreatmentSignals(parentHeading);
    final competing = <String>{
      ...signals.extrasBeside(want),
      ...urlSignals.extrasBeside(want),
      ...labelSignals.extrasBeside(want),
    };
    if (competing.isNotEmpty && !labelSignals.matchesRequested(want)) {
      final got = competing.join(',');
      // Menu pages reject dozens of off-family rows; aggregate so the console
      // is not flooded with normal different_procedure noise.
      _noteRelationReject(got);
      return ProcedureRelationResult(
        relation: ProcedureRelation.differentProcedure,
        reason: 'competing_family_$got',
      );
    }
    final familyWitness =
        labelSignals.matchesRequested(want) ||
        urlSignals.matchesRequested(want) ||
        parentSignals.matchesRequested(want) ||
        pageHasFamilyWitness;
    if (want == 'botox' &&
        _looksLikeBotoxZoneOrAreaLabel(_fold(label)) &&
        (familyWitness || _sourceUrlLooksLikePriceMenu(sourceUrl)) &&
        competing.isEmpty) {
      return const ProcedureRelationResult(
        relation: ProcedureRelation.variant,
        reason: 'botox_zone_or_area_variant',
      );
    }
    if (want == 'laser' &&
        _looksLikeLaserAreaLabel(_fold(label)) &&
        familyWitness &&
        competing.isEmpty) {
      return const ProcedureRelationResult(
        relation: ProcedureRelation.variant,
        reason: 'laser_area_or_session_variant',
      );
    }
    if (want == 'filler' &&
        (_looksLikeFillerAreaLabel(_fold(label)) ||
            _looksLikeBareFillerPerMlRate(label)) &&
        (familyWitness || _sourceUrlLooksLikePriceMenu(sourceUrl)) &&
        competing.isEmpty) {
      return const ProcedureRelationResult(
        relation: ProcedureRelation.variant,
        reason: 'filler_area_or_ml_variant',
      );
    }
    // URL may carry the treatment while the row label is a zone/brand / Cost: line.
    if (urlSignals.matchesRequested(want) &&
        urlSignals.extrasBeside(want).isEmpty) {
      // Nav / mixed menus: "Breast Surgery £6,995" on /nose-job-cost is breast.
      if (signals.families.isNotEmpty && !signals.matchesRequested(want)) {
        final got = signals.families.join(',');
        return ProcedureRelationResult(
          relation: ProcedureRelation.differentProcedure,
          reason: 'family_mismatch_want_${want}_got_$got',
        );
      }
      final strippedLabel = label.replaceAll(cachedRegExp(r'[\s*]+$'), '').trim();
      final namedRow =
          strippedLabel.length >= 4 &&
          !looksLikeBarePriceLabel(label) &&
          !looksLikeBarePriceLabel(strippedLabel) &&
          !looksLikePriceMenuHeadingOnly(label) &&
          !looksLikePriceMenuHeadingOnly(strippedLabel) &&
          !_looksLikeGenericPricedColumnLabel(strippedLabel);
      if (namedRow && !signals.matchesRequested(want)) {
        return const ProcedureRelationResult(
          relation: ProcedureRelation.differentProcedure,
          reason: 'named_row_not_requested_treatment',
        );
      }
      if (_looksLikeSameTreatmentVariant(folded, want) ||
          _looksLikeSameTreatmentVariant(urlFolded, want)) {
        return const ProcedureRelationResult(
          relation: ProcedureRelation.variant,
          reason: 'url_treatment_variant',
        );
      }
      return const ProcedureRelationResult(
        relation: ProcedureRelation.exact,
        reason: 'url_treatment_match',
      );
    } else if (signals.families.isNotEmpty || urlSignals.families.isNotEmpty) {
      final got = {...signals.families, ...urlSignals.families}.join(',');
      return ProcedureRelationResult(
        relation: ProcedureRelation.differentProcedure,
        reason: 'family_mismatch_want_${want}_got_$got',
      );
    } else if (label.trim().isEmpty && evidence.trim().length < 40) {
      return const ProcedureRelationResult(
        relation: ProcedureRelation.ambiguous,
        reason: 'no_procedure_signal',
      );
    } else if (!cachedRegExp(
      r'[a-z\u0600-\u06ff]',
      caseSensitive: false,
    ).hasMatch(label)) {
      return const ProcedureRelationResult(
        relation: ProcedureRelation.ambiguous,
        reason: 'bare_price_without_procedure',
      );
    } else {
      return const ProcedureRelationResult(
        relation: ProcedureRelation.ambiguous,
        reason: 'unmatched_procedure_signal',
      );
    }
  }

  if (extras.isNotEmpty && !signals.matchesRequested(want)) {
    return ProcedureRelationResult(
      relation: ProcedureRelation.differentProcedure,
      reason: 'extra_procedures_${extras.join('_')}',
    );
  }

  // Same family present, but also another family without clear combo syntax
  // on a long FAQ — treat as ambiguous rather than FROM evidence.
  if (extras.isNotEmpty && folded.length > 220) {
    return ProcedureRelationResult(
      relation: ProcedureRelation.ambiguous,
      reason: 'mixed_families_in_long_blob_${extras.join('_')}',
    );
  }

  if (extras.isNotEmpty) {
    return ProcedureRelationResult(
      relation: ProcedureRelation.bundle,
      reason: 'extra_procedure_${extras.join('_')}',
    );
  }

  if (!signals.matchesRequested(want) &&
      !urlSignals.matchesRequested(want) &&
      want != 'other') {
    return const ProcedureRelationResult(
      relation: ProcedureRelation.ambiguous,
      reason: 'requested_family_not_found',
    );
  }

  if (_looksLikeSameTreatmentVariant(folded, want)) {
    return const ProcedureRelationResult(
      relation: ProcedureRelation.variant,
      reason: 'brand_amount_area_or_session_variant',
    );
  }

  return const ProcedureRelationResult(
    relation: ProcedureRelation.exact,
    reason: 'same_treatment',
  );
}

void logProcedureRelation(ProcedureRelationResult result, {String label = ''}) {
  // Only log eligible rows — reject/ambiguous storms freeze the debug console.
  if (!result.eligibleForFromPrice) return;
  final short = label.trim();
  final clipped = short.length > 72 ? '${short.substring(0, 72)}…' : short;
  final suffix = clipped.isEmpty ? '' : ' · "$clipped"';
  debugPrint(
    '[PROCEDURE RELATION] ${result.logToken} · ${result.reason}$suffix',
  );
}

final Map<String, int> _relationRejectCounts = {};
int _relationRejectTotal = 0;
DateTime? _relationRejectLastFlush;

void _noteRelationReject(String familyKey) {
  _relationRejectTotal++;
  _relationRejectCounts[familyKey] =
      (_relationRejectCounts[familyKey] ?? 0) + 1;
  final now = DateTime.now();
  final last = _relationRejectLastFlush;
  if (last != null && now.difference(last) < const Duration(seconds: 2)) {
    return;
  }
  if (_relationRejectTotal < 8 &&
      (last == null || now.difference(last) < const Duration(seconds: 2))) {
    // Still warm up — wait for a batch.
    if (_relationRejectTotal < 8) return;
  }
  _flushRelationRejectSummary();
}

void _flushRelationRejectSummary() {
  if (_relationRejectTotal <= 0) return;
  final parts = _relationRejectCounts.entries
      .map((e) => '${e.key}×${e.value}')
      .take(8)
      .join(', ');
  debugPrint(
    '[RELATION REJECT] menu_rows=$_relationRejectTotal · $parts '
    '(normal off-family menu filtering — not clinic rejects)',
  );
  _relationRejectCounts.clear();
  _relationRejectTotal = 0;
  _relationRejectLastFlush = DateTime.now();
}

/// URL quality adjustment from procedure-relation signals (before price score).
double procedureRelationUrlScore({
  required String sourceUrl,
  required String procedure,
}) {
  final raw = sourceUrl.trim().toLowerCase();
  if (raw.isEmpty) return 0;
  var path = raw;
  try {
    path = Uri.parse(
      raw.contains('://') ? raw : 'https://$raw',
    ).path.toLowerCase();
  } catch (_) {}
  final want = exploreRelationRequestedFamily(procedure);
  final pathText = path.replaceAll(cachedRegExp(r'[/#?&=._\-]+'), ' ');
  final signals = detectProcedureTreatmentSignals(pathText);
  var score = 0.0;

  if (cachedRegExp(
    r'package|combo|bundle|paquet|pachet|offer-pack|/offers?/|/deals?/',
  ).hasMatch(path)) {
    score -= 0.45;
  }
  if (looksLikeSpecialOfferUrl(raw)) score -= 0.35;
  if (looksLikeCityCostArticleUrl(raw) ||
      looksLikeClinicArticlePriceUrl(raw) ||
      isNonLiteralClinicPriceUrl(raw)) {
    score -= 0.55;
  }
  if (looksLikeOfficialPriceListUrl(raw)) {
    score += 0.85;
    if (cachedRegExp(
      r'price-guide|price-list|pricelist|(?:^|/)prices(?:/|$)|'
      r'(?:^|/)(?:our-)?fees(?:/|$)',
    ).hasMatch(path)) {
      score += 0.3;
    }
  } else if (looksLikeBotoxSpecialtyVariantUrl(raw)) {
    score -= 0.55;
  } else if (looksLikeBotoxStandardStartingUrl(raw)) {
    score += 0.4;
  } else if (looksLikeBookingOrCheckoutUrl(raw)) {
    score += 0.28;
  } else if (looksLikePriceMenuUrl(raw)) {
    score += 0.42;
  }

  final extras = signals.extrasBeside(want);
  if (extras.isNotEmpty) {
    score -= 0.35 * extras.length.clamp(1, 3);
  }

  if (want != 'other' && signals.matchesRequested(want) && extras.isEmpty) {
    // Dedicated /prices and /price-guide beat SEO "{procedure}-cost" landings.
    score += looksLikeOfficialPriceListUrl(raw) ? 0.12 : 0.52;
  } else if (want != 'other' && signals.matchesRequested(want)) {
    score += 0.12;
  }
  return score;
}

/// Stylage Hydro / Hydromax is a skin booster, not a lips/cheeks filler FROM.
bool looksLikeSkinBoosterMenuRow(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').toLowerCase();
  if (t.trim().isEmpty) return false;
  final booster = cachedRegExp(
    r'\bstylage\s+hydro|\bhydromax\b|\bskin\s*boost|\bbiorevital',
    caseSensitive: false,
  ).hasMatch(t);
  if (!booster) return false;
  if (cachedRegExp(
    r'\bstylage\s+[mlx]\b|\b1(?:[.,]0)?\s*ml\b|\blip\s+filler|\bbuze\b',
    caseSensitive: false,
  ).hasMatch(t)) {
    return false;
  }
  return true;
}
