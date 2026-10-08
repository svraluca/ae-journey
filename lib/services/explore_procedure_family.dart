import 'package:flutter/foundation.dart';

import 'explore_price_evidence.dart';
import 'explore_price_sanity.dart';
import 'explore_procedure_relation.dart';
import 'explore_clinic_identity.dart';
import 'explore_url_discovery.dart';

/// Deterministic procedure-family match for extracted HTML labels.
///
/// Filler must not match from "lip" / "labios" / "aumento" alone.
class ProcedureFamilyMatch {
  const ProcedureFamilyMatch({
    required this.family,
    required this.canonical,
    required this.confidence,
    this.rejectReason = '',
  });

  final String family;
  final String canonical;
  final double confidence;
  final String rejectReason;

  bool get accepted => rejectReason.isEmpty && family.isNotEmpty;
}

int _gpMatchLogBudget = 8;
DateTime _gpMatchLogWindow = DateTime.fromMillisecondsSinceEpoch(0);

void _logGpMatch(String message) {
  // Peel menus mention "peel" on every row; uncapped debugPrint storms
  // freeze the Flutter debug console (and the UI isolate with it).
  final now = DateTime.now();
  if (now.difference(_gpMatchLogWindow) > const Duration(seconds: 2)) {
    _gpMatchLogWindow = now;
    _gpMatchLogBudget = 8;
  }
  if (_gpMatchLogBudget <= 0) return;
  _gpMatchLogBudget--;
  debugPrint('[GP MATCH] $message');
}

final _kFillerPositive = [
  'filler',
  'dermal filler',
  'hyaluronic acid',
  'acido hialuronico',
  'ácido hialurónico',
  'acid hialuronic',
  'relleno dermico',
  'relleno dérmico',
  'relleno',
  'juvederm',
  'restylane',
  'teosyal',
  'teoxane',
  'belotero',
  'revolax',
  'stylage',
  'volbella',
  'volift',
  'voluma',
  'radiesse',
  'aumento de labios',
  'aumento labial',
  'relleno de labios',
  'perfilado de labios',
  'lip filler',
  'lip augmentation',
  'marire buze',
  'mărire buze',
  'volumizare buze',
  'cheek filler',
  'dermal filler lips',
  'филър',
  'хиалуронова киселина',
  'филър за устни',
  'дермален филър',
  'فيلر',
  'الفيلر',
  'هيالورونيك',
  'حمض الهيالورونيك',
];

final _kBotoxPositive = [
  'botox',
  'botulinum',
  'toxina botulinica',
  'toxina botulínica',
  'toxina botulin',
  'dysport',
  'xeomin',
  'neuronox',
  'botulotoxina',
  'botulotoxin',
  'azzalure',
  'vistabel',
  'neuromodulador',
  'neuromodulator',
  'antiarrugas',
  'anti-wrinkle',
  'wrinkle relaxer',
  'wrinkle relaxers',
  'estompare riduri',
  'corectie riduri',
  'corecție riduri',
  'eliminare riduri',
  'glabelar',
  'ботокс',
  'ботулин',
  'ботулотоксин',
  'ботулинов токсин',
  'بوتوكس',
  'البوتولينوم',
  'توكسين البوتولينوم',
];

final _kLaserPositive = [
  'laser',
  'depilacion laser',
  'depilación láser',
  'epilare laser',
  'laser hair',
  'fraxel',
  'co2',
  'лазерна епилация',
  'лазер',
  'ipl',
  'photo rejuvenation',
  'photorejuvenation',
  'photofacial',
  'byonik',
  'ليزر',
  'بالليزر',
];

/// Hair-removal body zones vs facial/IPL/device skin work.
final _kLaserHairCue = RegExp(
  r'\b(?:hair\s*remov|epilare|depilacion|depilación|diode|alexandrite|'
  r'underarm|under[\s-]?arms?|bikini|brazilian|hollywood|peri[\s-]?anal|'
  r'intimate|full\s+body|full\s+leg|half\s+leg|upper\s+lip|'
  r'chest\s+hair|back\s+hair|beard)\b|'
  r'ازالة الشعر|إزالة الشعر|شعر بالليزر',
  caseSensitive: false,
);

final _kLaserSkinCue = RegExp(
  r'\b(?:byonik|fraxel|co2|moxi|genesis|photofacial|'
  r'photo\s*rejuvenation|photorejuvenation|pigment|pigmentation|'
  r'vascular|rosacea|acne\s+ipl|ipl\s+(?:face|skin|rejuven)|'
  r'hydrating\s+laser|laser\s+facial|carbon\s+laser|resurfacing|'
  r'skin\s+rejuvenation|intense\s+pulsed)\b',
  caseSensitive: false,
);

final _kLaserGenericCue = RegExp(
  r'^(?:laser(?:\s+hair)?(?:\s+removal)?(?:\s+treatments?)?|'
  r'laser\s+skin\s+treatment)\s*$',
  caseSensitive: false,
);

/// `hair` = bikini/underarm menus; `skin` = Byonik/IPL/photo rejuvenation;
/// `generic` = "Laser treatment" with no zone; `mixed` = both asked together.
String exploreLaserRequestedSubtype(String procedure) {
  final t = _fold(procedure);
  if (t.isEmpty) return 'mixed';
  final hair =
      _kLaserHairCue.hasMatch(t) ||
      t.contains('hair removal') ||
      t.contains('laser hair');
  final skin =
      _kLaserSkinCue.hasMatch(t) ||
      (t.contains('skin') &&
          (t.contains('rejuven') ||
              t.contains('ipl') ||
              t.contains('fraxel') ||
              t.contains('byonik')));
  // Legacy combined pill query: "laser skin treatment hair removal".
  if (hair && t.contains('skin')) return 'mixed';
  if (hair && skin) return 'mixed';
  if (hair) return 'hair';
  if (skin) return 'skin';
  if (t.contains('laser')) return 'mixed';
  return 'mixed';
}

String exploreLaserRowSubtype(String raw) {
  final t = _fold(raw);
  if (t.isEmpty) return 'generic';
  if (_kLaserGenericCue.hasMatch(t.trim())) return 'generic';
  final hair = _kLaserHairCue.hasMatch(t);
  final skin = _kLaserSkinCue.hasMatch(t);
  if (hair && !skin) return 'hair';
  if (skin && !hair) return 'skin';
  if (hair && skin) {
    return t.contains('hair') ? 'hair' : 'skin';
  }
  if (RegExp(
        r'\b(?:underarm|bikini|leg|arm|chest|back|body|full\s+face)\b',
      ).hasMatch(t) &&
      !skin &&
      !t.contains('facial') &&
      !t.contains('rejuven')) {
    return 'hair';
  }
  return 'generic';
}

bool exploreLaserRowFitsRequest({
  required String label,
  required String procedure,
}) {
  final want = exploreLaserRequestedSubtype(procedure);
  final got = exploreLaserRowSubtype(label);
  if (got == 'generic') return false;
  if (want == 'mixed') return true;
  return got == want;
}

bool looksLikeGenericLaserCardTitle(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').trim().toLowerCase();
  if (t.isEmpty) return false;
  return _kLaserGenericCue.hasMatch(t) || t == 'laser treatment';
}

final _kPeelPositive = [
  'peel',
  'peeling',
  'peeling quimico',
  'peeling químico',
  'peeling kimik',
  'peeling chimic',
  'chemical peel',
  'glycolic',
  'jessner',
  'tca peel',
  'tca',
  'biorepeel',
  'biorepell', // common misspelling on menus
  'prx',
  'prx-t33',
  'cosmelan',
  'dermamelan',
  'qërimi',
  'qerimi',
  'mikrodermoabrazion',
  'microdermabrasion',
  'химичен пилинг',
  'пилинг',
  'تقشير',
  'التقشير',
];

final _kRhinoSurgeryPositive = [
  'rhinoplasty',
  'rinoplastia',
  'rinoplastie',
  'nose job',
  'nose reshaping',
  'nose-reshaping',
  'nasal surgery',
  'septoplast',
  'ринопластика',
  'операция на носа',
  'корекция на носа',
  'تجميل الانف',
  'تجميل الأنف',
  'تعديل الأنف',
  'تعديل الانف',
  'رأب الأنف',
  'راب الانف',
];

final _kBreastAugPositive = [
  'breast augmentation',
  'breast enlargement',
  'boob job',
  'memorygel',
  'aumento de pecho',
  'aumento mamario',
  'mamoplastia de aumento',
  'implant mamar',
  'implantul mamar',
  'implanturi mamare',
  'implante mamare',
  'implants mammaires',
  'marire sani',
  'marire san',
  'marire de sani',
  'marire a sanilor',
  'marirea sanilor',
  'marirea san',
  'sani cu implant',
  'augmentare mamara',
  'endoprotez',
  'proteza mamara',
  'proteze mamare',
  'mastoplast',
  'augmentation mammaire',
  'brustvergro',
  'brustimplant',
  'meme buyutme',
  'meme implanti',
  'mellnagyobbitas',
  'mellimplantatum',
  'zmadhimi i gjirit',
  'implante gjoksi',
  'implantes mamarios',
  'уголемяване на бюст',
  'уголемяване на гърди',
  'гръдни импланти',
  'импланти за бюст',
  'تكبير الثدي',
  'تكبير الصدر',
  'زراعة الثدي',
];

final _kHairTxPositive = [
  'hair transplant',
  'hair implant',
  'injerto capilar',
  'transplant de par',
  'transplant par',
  'implant de par',
  'implant par',
  'implant capilar',
  'fir cu fir',
  'fue',
  'dhi',
  'graft',
  'grafts',
  'grafturi',
  'hairline',
  'per graft',
  'scalp',
  'greffe de cheveux',
  'greffe capillaire',
  'trapianto capelli',
  'haartransplantation',
  'saç ekimi',
  'sac ekimi',
  'трансплантация на коса',
  'присаждане на коса',
  'زراعة الشعر',
  'زراعة شعر',
  'زرع الشعر',
];

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

String? competingFamilyRejectReason(String rawLabel, String requestedFamily) {
  // Keyword-scanning a full page dump (thousands of chars) can find
  // unrelated words like "consultation" in a footer and reject an
  // otherwise-good procedure match. Only apply this check to short,
  // label-shaped strings.
  if (rawLabel.length > 140) return null;
  final t = _fold(rawLabel);
  final want = requestedFamily.trim().toLowerCase();

  final lipLift =
      t.contains('lip lift') ||
      t.contains('lip-lift') ||
      t.contains('liplift') ||
      t.contains('lifting labial') ||
      t.contains('bullhorn') ||
      t.contains('queiloplast') ||
      t.contains('cirugia labial') ||
      t.contains('cirugía labial');
  if (want == 'filler' && lipLift) return 'wrong_family_lip_lift';

  // DR.CYJ Hair Filler / scalp HA / hair mesotherapy — not facial dermal filler.
  if (want == 'filler' &&
      RegExp(
        r'\bhair\s+filler\b|\bfiller\s+(?:for\s+)?hair\b|\bdr\.?\s*cyj\b|'
        r'\bhair\s+mesotherap|\bmesotherap(?:y|ie)\s+(?:for\s+)?hair\b|'
        r'\bxl\s*hair\b|\bplinest\s+hair\b|\bhair\s+loss\s+treatment\b|'
        r'\bhair\s+treatments?\b',
        caseSensitive: false,
      ).hasMatch(t)) {
    return 'wrong_family_hair_filler';
  }

  if (want == 'filler' &&
      _hasAny(t, _kPeelPositive) &&
      !_hasAny(t, _kFillerPositive)) {
    return 'wrong_family_peel';
  }

  // Shaving / waxing prep is not laser hair removal.
  if (want == 'laser') {
    final shaveOrWax = RegExp(
      r'\b(?:shav(?:e|ing)|wax(?:ing)?|thread(?:ing)?|sugaring)\b',
      caseSensitive: false,
    ).hasMatch(t);
    if (shaveOrWax && !_hasAny(t, _kLaserPositive) && !t.contains('ipl')) {
      return 'wrong_family_shaving_or_wax';
    }
    // Mixed spa menus: HydraFacial / HIFU / cupping are not laser hair removal.
    if ((t.contains('hydrafacial') ||
            t.contains('hifu') ||
            RegExp(r'\b\d+\s*cups?\b').hasMatch(t) ||
            t.contains('fat dissolv')) &&
        !_hasAny(t, _kLaserPositive) &&
        !t.contains('ipl') &&
        !t.contains('hair remov')) {
      return 'wrong_family_not_laser';
    }
  }

  final dissolve = looksLikeFillerDissolvingLabel(t);
  if (want == 'filler' && dissolve) return 'wrong_family_hyaluronidase';
  if ((want == 'filler' || want == 'botox') &&
      looksLikeEnergyOrDeviceTreatment(t)) {
    return 'wrong_family_energy_device';
  }
  if (want == 'filler' &&
      RegExp(
        r'\bmasseter\b|\bbruxism\b|teeth grind',
        caseSensitive: false,
      ).hasMatch(t) &&
      !_hasAny(t, _kFillerPositive)) {
    return 'wrong_family_masseter_not_filler';
  }

  if (want == 'botox') {
    if (t.contains('polinucleotid') ||
        t.contains('polynucleotid') ||
        t.contains('nucleofill') ||
        t.contains('plla') ||
        t.contains('sculptra')) {
      if (!_hasAny(t, _kBotoxPositive)) return 'wrong_family_biostim';
    }
    if (_hasAny(t, _kFillerPositive) && !_hasAny(t, _kBotoxPositive)) {
      return 'wrong_family_filler';
    }
    if ((_hasAny(t, _kLaserPositive) ||
            t.contains('cheratoze') ||
            t.contains('thulium') ||
            t.contains('lasemd')) &&
        !_hasAny(t, _kBotoxPositive)) {
      return 'wrong_family_laser';
    }
  }

  final rhinoFiller =
      t.contains('rinomodel') ||
      t.contains('rhinomodel') ||
      t.contains('nose filler') ||
      t.contains('filler nariz') ||
      t.contains('acido hialuronico nariz') ||
      t.contains('non-surgical rhino') ||
      t.contains('nonsurgical rhino') ||
      t.contains('rinoplastia no quir') ||
      (t.contains('hyaluronic') && t.contains('nariz')) ||
      (t.contains('acido hialuronico') && t.contains('nariz'));
  if (rhinoFiller && (want == 'rhinoplasty' || want == 'filler')) {
    return 'wrong_family_rhinomodeling';
  }

  if (want == 'hair') {
    if (t.contains('prp capilar') ||
        t.contains('mesoterap') ||
        t.contains('consulta') ||
        (t.contains('product') &&
            !t.contains('fue') &&
            !t.contains('injerto'))) {
      if (!_hasAny(t, _kHairTxPositive)) return 'wrong_family_hair_nonsurgical';
    }
  }

  if (looksLikeFinancingOrPaymentHeading(rawLabel)) {
    return 'wrong_family_financing';
  }

  if (want == 'breast_augmentation' || want == 'breast') {
    if (t.contains('ginecomast') || t.contains('تثدي')) {
      return 'wrong_family_breast_other';
    }
    if ((t.contains('mastopex') ||
            t.contains('breast reduction') ||
            t.contains('reduccion de pecho') ||
            t.contains('reducción de pecho') ||
            t.contains('reductie mamara') ||
            t.contains('reductie mamara') ||
            t.contains('تصغير الثدي') ||
            t.contains('شد الثدي') ||
            t.contains('رفع الثدي') ||
            t.contains('inverted nipple') ||
            t.contains('nipple lift') ||
            t.contains('nipple reduction')) &&
        !_hasAny(t, _kBreastAugPositive)) {
      return 'wrong_family_breast_other';
    }
    // Chin / cheek / nose silicone implants are not a boob job.
    if ((t.contains('barbie') ||
            t.contains('pomet') ||
            t.contains('menton') ||
            t.contains('nasului') ||
            t.contains('chin implant')) &&
        !_hasAny(t, const [
          'mamar',
          'sanilor',
          'sani cu',
          'breast',
          'pecho',
          'boob',
        ])) {
      return 'wrong_family_facial_implant';
    }
  }

  if (t.contains('consulta') ||
      t.contains('consultation') ||
      t.contains('evaluacion medica') ||
      t.contains('evaluación médica') ||
      t.contains('valoracion') ||
      t.contains('primera visita') ||
      t.contains('استشارة') ||
      t.contains('checkup') ||
      t.contains('gp checkup') ||
      t.contains('check-up') ||
      t.contains('check up')) {
    if (want != 'consultation') return 'wrong_family_consultation';
  }

  if (looksLikeNonTreatmentPriceLabel(rawLabel)) {
    return 'wrong_family_non_treatment';
  }

  return null;
}

/// Promo "worth" / free assessments — delegated to [looksLikeNonTreatmentPriceLabel].
bool looksLikeNonTreatmentPriceRow(String raw) =>
    looksLikeNonTreatmentPriceLabel(raw);

ProcedureFamilyMatch matchRawProcedureLabel(
  String rawLabel, {
  String requestedProcedure = '',
}) {
  final folded = _fold(rawLabel);
  if (folded.trim().isEmpty) {
    return const ProcedureFamilyMatch(
      family: 'other',
      canonical: '',
      confidence: 0,
      rejectReason: 'empty_label',
    );
  }

  final requested = _requestedFamily(requestedProcedure);
  final conflict = competingFamilyRejectReason(rawLabel, requested);
  if (conflict != null) {
    final clipped = rawLabel.length > 72
        ? '${rawLabel.substring(0, 72)}…'
        : rawLabel;
    _logGpMatch('skip-line "$clipped" → $conflict');
    return ProcedureFamilyMatch(
      family: 'other',
      canonical: '',
      confidence: 0,
      rejectReason: conflict,
    );
  }

  String family = 'other';
  String canonical = '';
  var confidence = 0.0;

  if (_hasAny(folded, _kFillerPositive)) {
    family = 'filler';
    canonical =
        folded.contains('labio') ||
            folded.contains('lip') ||
            folded.contains('buze')
        ? 'lip_filler'
        : (folded.contains('pomet') ||
                  folded.contains('cheek') ||
                  folded.contains('mejilla')
              ? 'cheek_filler'
              : 'filler');
    confidence = 0.94;
  } else if (_hasAny(folded, _kBotoxPositive)) {
    family = 'botox';
    canonical = 'botox';
    confidence = 0.94;
  } else if (_hasAny(folded, _kLaserPositive)) {
    family = 'laser';
    canonical = 'laser';
    confidence = 0.9;
  } else if (_hasAny(folded, _kPeelPositive)) {
    family = 'peel';
    canonical = 'chemical_peel';
    confidence = 0.9;
  } else if (_hasAny(folded, _kRhinoSurgeryPositive)) {
    family = 'rhinoplasty';
    canonical = 'rhinoplasty';
    confidence = 0.92;
  } else if (_hasAny(folded, _kBreastAugPositive)) {
    family = 'breast_augmentation';
    canonical = 'breast_augmentation';
    confidence = 0.92;
  } else if (_hasAny(folded, _kHairTxPositive)) {
    family = 'hair_transplant';
    canonical = 'hair_transplant';
    confidence = 0.9;
  }

  if (requested.isNotEmpty &&
      requested != 'other' &&
      family != 'other' &&
      !_familiesCompatible(requested, family)) {
    final clipped = rawLabel.length > 72
        ? '${rawLabel.substring(0, 72)}…'
        : rawLabel;
    _logGpMatch('skip-line "$clipped" → wrong_family_$family');
    return ProcedureFamilyMatch(
      family: family,
      canonical: canonical,
      confidence: 0,
      rejectReason: 'wrong_family_$family',
    );
  }

  if (family != 'other') {
    final clipped = rawLabel.length > 72
        ? '${rawLabel.substring(0, 72)}…'
        : rawLabel;
    _logGpMatch('"$clipped" → $family/$canonical');
  }
  return ProcedureFamilyMatch(
    family: family,
    canonical: canonical,
    confidence: confidence,
  );
}

bool _familiesCompatible(String requested, String got) {
  if (requested == got) return true;
  if (requested == 'breast' && got == 'breast_augmentation') return true;
  if (requested == 'hair' && got == 'hair_transplant') return true;
  return false;
}

String _requestedFamily(String procedure) {
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
      t.contains('transplant par') ||
      t.contains('implant de par') ||
      t.contains('implant par') ||
      t.contains('fir cu fir') ||
      t.contains('трансплантация на коса') ||
      t.contains('присаждане на коса') ||
      t.contains('زراعة الشعر')) {
    return 'hair';
  }
  return 'other';
}

/// Hyaluronidase / filler-dissolving is not a Fillers-pill from-price.
bool looksLikeFillerDissolvingLabel(String raw) {
  final t = raw.toLowerCase();
  if (t.isEmpty) return false;
  return t.contains('hialuronidaz') ||
      t.contains('hyaluronidase') ||
      t.contains('hyaluronidas') ||
      t.contains('hylenex') ||
      t.contains('topirea acidului') ||
      t.contains('dizolvare') ||
      t.contains('dissolve filler') ||
      t.contains('dissolving filler') ||
      t.contains('filler dissolv') ||
      t.contains('dissolving clinic') ||
      t.contains('oplossen') ||
      t.contains('oplossen filler') ||
      t.contains('filler oplossen') ||
      t.contains('اذابة الفيلر') ||
      t.contains('إذابة الفيلر');
}

/// JSON-LD AggregateOffer min–max that spans unrelated menu rows
/// (BePerfect 600–5200 RON = hyaluronidase through full-face).
bool explorePriceLooksLikeCatalogAggregate({
  String rawPriceText = '',
  double priceMin = 0,
  double priceMax = 0,
}) {
  if (clinicOwnPublishedPriceWindow(rawPriceText) != null) return false;
  if (priceMin > 0 && priceMax >= priceMin * 3) return true;
  final range = RegExp(
    r'(\d+(?:[.,]\d{3})*)\s*[–—-]\s*(\d+(?:[.,]\d{3})*)',
  ).firstMatch(rawPriceText.replaceAll('\u00a0', ' '));
  if (range == null) return false;
  double parse(String raw) {
    final compact = raw.replaceAll(RegExp(r'[.\s]'), '').replaceAll(',', '.');
    return double.tryParse(compact) ?? 0;
  }

  final low = parse(range.group(1)!);
  final high = parse(range.group(2)!);
  return low > 0 && high >= low * 3;
}

double _menuRowScoreBoost(PriceExtractionMethod method) {
  switch (method) {
    case PriceExtractionMethod.htmlTable:
    case PriceExtractionMethod.listItem:
    case PriceExtractionMethod.wooCommerce:
    case PriceExtractionMethod.productCard:
      return 0.12;
    case PriceExtractionMethod.jsonLd:
    case PriceExtractionMethod.schemaOffer:
      return -0.05;
    case PriceExtractionMethod.textProximity:
      return -0.1;
    default:
      return 0;
  }
}

bool _extractIsMenuStructured(PriceExtractionMethod method) {
  switch (method) {
    case PriceExtractionMethod.htmlTable:
    case PriceExtractionMethod.listItem:
    case PriceExtractionMethod.wooCommerce:
    case PriceExtractionMethod.productCard:
      return true;
    default:
      return false;
  }
}

bool _extractIsProse(PriceExtractionMethod method) {
  switch (method) {
    case PriceExtractionMethod.textProximity:
    case PriceExtractionMethod.domBlock:
      return true;
    default:
      return false;
  }
}

/// Dedicated treatment / official menu URLs outrank city “cost in …” articles.
double _urlEvidenceQualityScore(String sourceUrl, String procedure) {
  // Relation-aware URL rank: exact treatment path > menu > packages / guides.
  // Extra procedure names in the path are penalized before any price score.
  return procedureRelationUrlScore(sourceUrl: sourceUrl, procedure: procedure);
}

String _urlPathAsProcedureLabel(String sourceUrl) {
  try {
    final path = Uri.parse(
      sourceUrl.contains('://') ? sourceUrl : 'https://$sourceUrl',
    ).path;
    return path.replaceAll(RegExp(r'[/_\-]+'), ' ').trim();
  } catch (_) {
    return '';
  }
}

/// When a menu row is only an area/zone label, map it to a useful canonical.
String _canonicalForInheritedAreaLabel({
  required String requested,
  required String label,
}) {
  final folded = _fold(label);
  switch (requested) {
    case 'filler':
      if (RegExp(r'\b(?:lip|lips|labio|buze)\b').hasMatch(folded)) {
        return 'lip_filler';
      }
      if (RegExp(
        r'\b(?:cheek|cheeks|pomet|tear\s*trough)\b',
      ).hasMatch(folded)) {
        return 'cheek_filler';
      }
      return 'filler';
    case 'botox':
      return 'botox';
    case 'laser':
      return 'laser';
    default:
      return requested;
  }
}

/// Prefer "Rhinoplasty" over a currency-only span or a city-average sentence.
String procedureLabelFromPricedBlob({
  required String rawProcedureText,
  required String rawEvidence,
  String requestedProcedure = '',
}) {
  ProcedureFamilyMatch? picked;
  for (final blob in [rawProcedureText, rawEvidence]) {
    if (blob.trim().isEmpty) continue;
    final match = matchRawProcedureLabel(
      blob,
      requestedProcedure: requestedProcedure,
    );
    if (!match.accepted || match.family == 'other') continue;
    picked = match;
    final folded = _fold(blob);
    if (!looksLikeBarePriceLabel(blob) &&
        !looksLikePricingProseProcedureTitle(blob) &&
        blob.trim().length <= 80 &&
        !folded.contains('typically') &&
        !folded.contains('average') &&
        !folded.contains('in general') &&
        !looksLikeSearchQuickFactsBlob(blob) &&
        !looksLikeSeoQuotedPriceHeadline(blob) &&
        !looksLikeMixedServiceBundle(blob) &&
        !RegExp(r'^\s*quick facts\b', caseSensitive: false).hasMatch(blob)) {
      return blob.trim();
    }
  }
  if (picked != null && picked.canonical.isNotEmpty) {
    return picked.canonical.replaceAll('_', ' ');
  }
  return rawProcedureText.trim();
}

ExtractedPriceEvidence _preferClinicOwnPublishedPrice(
  ExtractedPriceEvidence row, {
  required String procedure,
}) {
  final blob = '${row.rawPriceText}\n${row.rawEvidence}';
  final own = pickClinicOwnPublishedPrice(blob, procedure: procedure);
  if (own == null) return row;
  final parsed = parsePriceText(own);
  if (parsed == null || parsed.priceMin <= 0) return row;
  return row.copyWith(
    rawPriceText: own,
    priceMin: parsed.priceMin,
    priceMax: parsed.priceMax >= parsed.priceMin
        ? parsed.priceMax
        : parsed.priceMin,
  );
}

/// Prefer a labeled `Cost:` / family-matching quote over the first "ranges from"
/// on a mixed treatment page (peel 399 must not become the filler price).
String? pickClinicOwnPublishedPrice(String raw, {required String procedure}) {
  final hits = clinicOwnPublishedPriceHits(raw);
  if (hits.isEmpty) return null;
  final want = _requestedFamily(procedure);
  ClinicOwnPriceHit? familyHit;
  ClinicOwnPriceHit? labeledHit;
  ClinicOwnPriceHit? oneAreaHit;
  ClinicOwnPriceHit? rhinoClosedHit;
  for (final hit in hits) {
    final ctx = '${hit.context} ${hit.window}';
    if (want != 'other') {
      final conflict = competingFamilyRejectReason(ctx, want);
      if (conflict != null) continue;
      final match = matchRawProcedureLabel(ctx, requestedProcedure: procedure);
      if (match.rejectReason.startsWith('wrong_family')) continue;
      if (match.accepted &&
          match.family != 'other' &&
          _familiesCompatible(want, match.family)) {
        familyHit ??= hit;
      }
    }
    if (want == 'botox' &&
        _botoxIsStandardStartingArea(_fold(hit.window)) &&
        !_botoxLooksLikeAddOnOrTargeted(_fold(hit.window))) {
      oneAreaHit ??= hit;
    }
    if (want == 'rhinoplasty' &&
        looksLikePrimaryRhinoplastyStarting(hit.window) &&
        !looksLikePartialRhinoplastyStarting(hit.window) &&
        !looksLikePartialRhinoplastyStarting(ctx)) {
      rhinoClosedHit ??= hit;
    }
    if (looksLikeClinicLabeledCostFact(hit.window)) {
      final match = matchRawProcedureLabel(ctx, requestedProcedure: procedure);
      if (!match.rejectReason.startsWith('wrong_family')) {
        labeledHit ??= hit;
      }
    }
  }
  if (want == 'botox' && oneAreaHit != null) return oneAreaHit.window;
  if (want == 'rhinoplasty' && rhinoClosedHit != null) {
    return rhinoClosedHit.window;
  }
  if (want != 'other') {
    return familyHit?.window ?? labeledHit?.window;
  }
  return labeledHit?.window ?? hits.first.window;
}

ProcedureFamilyMatch _matchEvidenceRow(
  ExtractedPriceEvidence row, {
  required String procedure,
}) {
  var match = matchRawProcedureLabel(
    row.rawProcedureText,
    requestedProcedure: procedure,
  );
  if (match.accepted && match.family != 'other') return match;

  // Never let a checkout / promo / checkup row inherit family from the URL
  // (e.g. GP Checkup on /chemical-peel/, "Worth AED 1500" on /chemical-peel).
  if (looksLikeNonTreatmentPriceLabel(row.rawProcedureText) ||
      competingFamilyRejectReason(
            row.rawProcedureText,
            _requestedFamily(procedure),
          ) !=
          null) {
    return ProcedureFamilyMatch(
      family: 'other',
      canonical: '',
      confidence: 0,
      rejectReason: match.rejectReason.isNotEmpty
          ? match.rejectReason
          : 'non_treatment_label',
    );
  }

  match = matchRawProcedureLabel(
    '${row.rawProcedureText} ${row.rawEvidence}',
    requestedProcedure: procedure,
  );
  if (match.accepted && match.family != 'other') return match;
  if (match.rejectReason.isNotEmpty) return match;

  final label = row.rawProcedureText.trim();
  final want = _requestedFamily(procedure);
  final foldedLabel = _fold(label);
  final genericChromeLabel = foldedLabel
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim()
      .split(' ')
      .where((w) => w.isNotEmpty)
      .toList();
  final areaLabelForRequest =
      (want == 'botox' &&
          RegExp(
            r'\b(?:periocular|glabel|forehead|masseter|neck|chin|zona|zone|area)\b',
            caseSensitive: false,
          ).hasMatch(foldedLabel)) ||
      (want == 'laser' &&
          RegExp(
            r'\b(?:face|body|legs?|arms?|bikini|brazilian|underarm|chest|back)\b',
            caseSensitive: false,
          ).hasMatch(foldedLabel)) ||
      (want == 'filler' &&
          RegExp(
            r'\b(?:lips?|cheeks?|tear\s*trough|smile\s*line|jaw\s*line|ml)\b',
            caseSensitive: false,
          ).hasMatch(foldedLabel));
  final labelOkForUrlFallback =
      label.isEmpty ||
      looksLikeBarePriceLabel(label) ||
      label.length < 8 ||
      areaLabelForRequest ||
      (genericChromeLabel.isNotEmpty &&
          genericChromeLabel.every(_kGenericRowLabelWords.contains));
  if (!labelOkForUrlFallback) {
    // Concrete menu label that did not match — do not steal family from slug.
    return const ProcedureFamilyMatch(
      family: 'other',
      canonical: '',
      confidence: 0,
      rejectReason: 'label_url_mismatch',
    );
  }

  return matchRawProcedureLabel(
    _urlPathAsProcedureLabel(row.sourceUrl),
    requestedProcedure: procedure,
  );
}

/// Pick the best evidence row for a requested Explore procedure.
ExtractedPriceEvidence? selectEvidenceForProcedure({
  required List<ExtractedPriceEvidence> rows,
  required String procedure,
}) {
  ExtractedPriceEvidence? best;
  var bestScore = -1.0;
  final requested = _requestedFamily(procedure);
  final pageHasFamilyWitness = pageHasRequestedFamilyWitness(
    rows: rows,
    procedure: procedure,
  );
  var rejectLogsLeft = 6;
  void rejectLog(String msg) {
    if (rejectLogsLeft <= 0) return;
    rejectLogsLeft--;
    debugPrint(msg);
  }

  for (final original in rows) {
    if (!original.hasUsablePrice) continue;
    if (exploreUrlConflictsWithProcedure(original.sourceUrl, procedure)) {
      rejectLog('[GP PRICE] REJECT · wrong_page_family');
      continue;
    }
    var row = _preferClinicOwnPublishedPrice(original, procedure: procedure);
    final ownWindow = pickClinicOwnPublishedPrice(
      '${row.rawPriceText}\n${row.rawEvidence}',
      procedure: procedure,
    );
    final ownQuoted =
        ownWindow != null &&
        publishedAmountMatchesWindow(ownWindow, row.priceMin);
    final htmlCatalog =
        row.priceMin > 0 &&
        row.priceMax >= row.priceMin * 4 &&
        !ownQuoted &&
        row.extractionMethod != PriceExtractionMethod.jsonLd &&
        row.extractionMethod != PriceExtractionMethod.schemaOffer;
    if ((row.extractionMethod == PriceExtractionMethod.jsonLd ||
            row.extractionMethod == PriceExtractionMethod.schemaOffer) &&
        explorePriceLooksLikeCatalogAggregate(
          rawPriceText: row.rawPriceText,
          priceMin: row.priceMin,
          priceMax: row.priceMax,
        )) {
      rejectLog('[GP PRICE] REJECT · catalog_aggregate_range');
      continue;
    }
    if (htmlCatalog) {
      rejectLog('[GP PRICE] REJECT · catalog_aggregate_range');
      continue;
    }
    if (exploreEvidenceLooksLikeStitchedCatalogBlob(
      rawPriceText: row.rawPriceText,
      rawEvidence: row.rawEvidence,
      priceMin: row.priceMin,
      extractionMethod: row.extractionMethod.wire,
    )) {
      rejectLog('[GP PRICE] REJECT · stitched_price_blob');
      continue;
    }
    if (looksLikeClinicArticlePriceUrl(row.sourceUrl) &&
        exploreEvidenceQuotesPriceRange(
          rawProcedureText: row.rawProcedureText,
          rawPriceText: row.rawPriceText,
          priceMin: row.priceMin,
          priceMax: row.priceMax,
        )) {
      rejectLog('[GP PRICE] REJECT · article_price_range');
      continue;
    }
    final evidenceBlob = '${row.rawPriceText}\n${row.rawEvidence}';
    final own = pickClinicOwnPublishedPrice(evidenceBlob, procedure: procedure);
    var ownQuotedHere =
        own != null && publishedAmountMatchesWindow(own, row.priceMin);
    if (looksLikeCityMarketPricingGuideUrl(row.sourceUrl) ||
        looksLikeMarketEstimateDirectoryUrl(row.sourceUrl)) {
      ownQuotedHere = false;
    }
    if (looksLikeMarketEstimateDirectoryUrl(row.sourceUrl)) {
      rejectLog('[GP PRICE] REJECT · market_information');
      continue;
    }
    if (!ownQuotedHere &&
        (looksLikeThirdPartyProviderPriceLabel(row.rawProcedureText) ||
            looksLikeCompetitorOrThirdPartyPriceQuote(evidenceBlob) ||
            looksLikeCompetitorOrThirdPartyPriceQuote(row.rawPriceText))) {
      rejectLog('[GP PRICE] REJECT · competitor_quote');
      continue;
    }
    if (looksLikeGoogleAreaEstimateBlurb(evidenceBlob) && !ownQuotedHere) {
      rejectLog('[GP PRICE] REJECT · market_average');
      continue;
    }
    if (own == null && looksLikeMarketAveragePriceBlurb(evidenceBlob)) {
      rejectLog('[GP PRICE] REJECT · market_average');
      continue;
    }
    if (looksLikeRoundedMarketPriceSpread(
      priceMin: row.priceMin,
      priceMax: row.priceMax,
      currency: row.currency,
      procedure: procedure,
    )) {
      rejectLog('[GP PRICE] REJECT · market_price_spread');
      continue;
    }
    // Generic city surgery “common prices” guides — never a clinic menu.
    if (looksLikeGenericCitySurgeryGuideUrl(row.sourceUrl) && !ownQuotedHere) {
      rejectLog('[GP PRICE] REJECT · city_common_price_guide');
      continue;
    }
    if (looksLikeCityCommonPriceGuideBlurb(evidenceBlob) && !ownQuotedHere) {
      rejectLog('[GP PRICE] REJECT · city_common_price_guide');
      continue;
    }

    // Semantic eligibility BEFORE any price / URL score. A cheaper bundle
    // must never beat an exact treatment quote.
    final relation = classifyProcedureRelation(
      requestedProcedure: procedure,
      label: row.rawProcedureText,
      evidence: '${row.rawPriceText}\n${row.rawEvidence}',
      sourceUrl: row.sourceUrl,
      clinicOwnQuoted: ownQuotedHere,
      pageHasFamilyWitness: pageHasFamilyWitness,
    );
    logProcedureRelation(relation, label: row.rawProcedureText);
    if (!relation.eligibleForFromPrice) {
      continue;
    }
    if (requested == 'filler' &&
        looksLikeSkinBoosterMenuRow(
          '${row.rawProcedureText} ${row.rawPriceText} ${row.rawEvidence}',
        )) {
      rejectLog('[GP PRICE] REJECT · skin_booster_not_filler');
      continue;
    }
    if (looksLikeGenericInjectableCategoryHeading(row.rawProcedureText)) {
      rejectLog('[GP PRICE] REJECT · category_heading_not_row');
      continue;
    }

    final match = _matchEvidenceRow(row, procedure: procedure);
    if (!match.accepted) {
      continue;
    }
    var family = match.family;
    var canonical = match.canonical;
    var confidence = match.confidence;
    // Area-only menu labels ("Lips", "Face", "1 Area") often omit the
    // procedure word. If relation already scoped exact/variant via URL or
    // zone heuristics, inherit the requested family — do not no_family_match.
    if (requested != 'other' && family == 'other') {
      final inheritAreaOnly = requested == 'botox' || requested == 'filler';
      if (relation.eligibleForFromPrice &&
          (!inheritAreaOnly ||
              looksLikeInheritableAreaOnlyLabel(
                label: row.rawProcedureText,
                requestedFamily: requested,
              ))) {
        family = requested;
        canonical = _canonicalForInheritedAreaLabel(
          requested: requested,
          label: row.rawProcedureText,
        );
        confidence = 0.72;
        _logGpMatch(
          'inherit_family_$requested '
          '"${row.rawProcedureText}" via ${relation.reason}',
        );
      } else {
        debugPrint(
          '[GP PRICE] REJECT · no_family_match "${row.rawProcedureText}" '
          '(${row.rawPriceText})',
        );
        continue;
      }
    }
    if (looksLikeBarePriceLabel(row.rawProcedureText) ||
        row.rawProcedureText.trim().isEmpty) {
      final short = procedureLabelFromPricedBlob(
        rawProcedureText: row.rawProcedureText,
        rawEvidence: row.rawEvidence,
        requestedProcedure: procedure,
      );
      if (short.isNotEmpty) {
        row = row.copyWith(rawProcedureText: short);
      }
    }
    if (!isValidExtractedPriceCandidate(
      rawPriceText: row.rawPriceText,
      priceMin: row.priceMin,
      currency: row.currency,
      extractionMethod: row.extractionMethod.wire,
      rawEvidence: row.rawEvidence,
      procedure: procedure,
      sourceUrl: row.sourceUrl,
    )) {
      continue;
    }
    var score = confidence;
    // Exact slightly outranks variants; never enough to beat a clearly
    // cheaper same-treatment starting area/session/unit quote.
    if (relation.relation == ProcedureRelation.exact) {
      score += 0.12;
    } else if (relation.relation == ProcedureRelation.variant) {
      score += 0.1;
    }
    if (row.extractionMethod != PriceExtractionMethod.textProximity) {
      score += 0.2;
    }
    score += _menuRowScoreBoost(row.extractionMethod);
    score += _urlEvidenceQualityScore(row.sourceUrl, procedure);
    if (row.priceType == PriceType.from) score += 0.05;
    if (row.priceType == PriceType.perUnit ||
        row.priceType == PriceType.perArea) {
      score += 0.12;
    }
    // Prefer the smallest DOM/PDF block that still carries procedure + price.
    final evidenceLen = row.rawEvidence.trim().length;
    if (evidenceLen > 0 && evidenceLen <= 80) {
      score += 0.12;
    } else if (evidenceLen > 220) {
      score -= (evidenceLen / 1800).clamp(0.0, 0.18);
    }
    final startsFromListed = RegExp(
      r'(?:starts?\s+from|starting(?:\s+from)?|يبدأ من|تبدأ من)\s*'
              r'(?:aed|usd|eur|gbp|د\.إ|درهم)?\s*' +
          RegExp.escape(row.priceMin.round().toString()),
      caseSensitive: false,
    ).hasMatch('${row.rawPriceText} ${row.rawEvidence}');
    if (startsFromListed &&
        !looksLikePriceMenuHeadingOnly(row.rawProcedureText)) {
      score += 0.28;
    }
    if (looksLikeClinicLabeledCostFact(row.rawPriceText) ||
        looksLikeClinicLabeledCostFact(row.rawEvidence)) {
      score += 0.42;
    }
    if (requested == 'filler' && canonical == 'lip_filler') {
      score += 0.35;
    }
    final foldedLabel = _fold(row.rawProcedureText);
    if (requested == 'filler') {
      final fillerBlob = '$foldedLabel ${_fold(row.rawEvidence)}';
      if (RegExp(
        r'\b1(?:[.,]0)?\s*ml\b|\bbuze\b|\blips?\b|\bjuvederm\b|\bstylage\s+[mlx]\b',
      ).hasMatch(fillerBlob)) {
        score += 0.32;
      }
    }
    if (_looksLikePromoSavingLabel(foldedLabel)) {
      rejectLog('[GP PRICE] REJECT · promo_saving');
      continue;
    }
    if (looksLikePriceMenuHeadingOnly(foldedLabel)) {
      rejectLog('[GP PRICE] REJECT · menu_heading_not_row');
      continue;
    }
    if (requested == 'botox') {
      final evidenceFold = _fold(row.rawPriceText);
      final blobFold = '$foldedLabel $evidenceFold';
      final oneZone = RegExp(
        r'\b1\s*zon|\buna\s*zona|\bperiocular|\bglabel|\bfrontal|\bfrunte\b|'
        r'\bcrow|\bcoada och',
      ).hasMatch(foldedLabel);
      final multiZone = RegExp(
        r'\b[2-4]\s*zon|\bfull face|\b3 zone|\bfull\s*3|'
        r'\bpackage\b|\b3-zone|\bmulti[- ]?zone',
      ).hasMatch(foldedLabel);
      final perUnit =
          row.priceType == PriceType.perUnit ||
          RegExp(
            r'(?:per|/)\s*(?:iu|unit|units|unidad)\b|por\s+unidad',
            caseSensitive: false,
          ).hasMatch('${row.rawPriceText} ${row.rawEvidence}');
      if (oneZone && !multiZone) score += 0.3;
      if (RegExp(r'\b(?:1|one)\s*area\b').hasMatch(foldedLabel)) {
        score += 0.35;
      }
      if (_botoxLooksLikeAddOnOrTargeted(evidenceFold) &&
          !_botoxIsStandardStartingArea(foldedLabel)) {
        rejectLog('[GP PRICE] REJECT · botox_addon_or_targeted');
        continue;
      }
      final specialtyBlob =
          '$foldedLabel $evidenceFold ${_fold(row.rawEvidence)} '
          '${_fold(row.sourceUrl)}';
      if ((_botoxIsSpecialtyStarting(specialtyBlob) ||
              looksLikeBotoxSpecialtyVariantUrl(row.sourceUrl)) &&
          !_botoxIsStandardStartingArea(foldedLabel)) {
        rejectLog('[GP PRICE] REJECT · specialty_botox');
        continue;
      }
      if (row.priceType == PriceType.sale ||
          _looksLikePromoSavingLabel(blobFold)) {
        rejectLog('[GP PRICE] REJECT · botox_promo_not_from');
        continue;
      }
      // Only when the user asked for Botox by name: a Dysport/Xeomin row is a
      // different product at a non-comparable unit price, so demote it past
      // the near-tie window rather than rejecting it. A clinic that lists no
      // Botox at all still quotes its alternative brand, and this stays a
      // preference regardless of which row is scored first.
      if (_mentionsBotoxByName(_fold(procedure)) &&
          _looksLikeAlternativeBotulinumBrand(foldedLabel) &&
          !_mentionsBotoxByName(foldedLabel)) {
        score -= 0.5;
      }
      // Starting price: per-unit and single-area beat packages.
      if (perUnit) score += 0.55;
      if (multiZone && !perUnit) score -= 0.45;
      if (row.priceType == PriceType.from) score += 0.18;
      if (RegExp(
        r'gummy|gingival|zambet gingival|brux|hiperhidroz|hyperhidros|'
        r'platism|masseter|slimming face|cicatrici|mouth corner',
      ).hasMatch(foldedLabel)) {
        score -= 0.45;
      }
      if (_botoxMicroOrBodyArea(foldedLabel) && !perUnit) score -= 0.55;
      if (_botoxIsStandardStartingArea(foldedLabel)) score += 0.4;
      if (_looksLikePromoSavingLabel(foldedLabel)) score -= 0.55;
      // Weekday / special-offer pages are real quotes, but demote them so a
      // Google-AI-style "approximately AED 600" overview is never needed —
      // prefer a normal menu / unit row when the same clinic has one.
      if (RegExp(
        r'special-?offers?|botox-monday|كل يوم إثنين|عرضنا الحصري',
        caseSensitive: false,
      ).hasMatch('${row.sourceUrl} ${row.rawEvidence}')) {
        score -= 0.4;
      }
      if (_botoxAdvertisedStartArea(
        '$foldedLabel ${_fold(row.rawPriceText)} ${_fold(row.rawEvidence)}',
      )) {
        score += 0.24;
      }
    }
    if (requested == 'rhinoplasty') {
      final rhinoBlob =
          '$foldedLabel ${_fold(row.rawPriceText)} ${_fold(row.rawEvidence)}';
      if (looksLikeCityMarketPricingGuideUrl(row.sourceUrl)) {
        rejectLog('[GP PRICE] REJECT · rhino_market_guide');
        continue;
      }
      if (_rhinoplastyLooksNonsurgical(rhinoBlob) && row.priceMin < 2500) {
        rejectLog('[GP PRICE] REJECT · nonsurgical_rhino');
        continue;
      }
      if (looksLikePartialRhinoplastyStarting(foldedLabel) ||
          (looksLikePartialRhinoplastyStarting(rhinoBlob) &&
              !looksLikePrimaryRhinoplastyStarting(foldedLabel) &&
              row.priceMin < 6000)) {
        rejectLog('[GP PRICE] REJECT · rhino_tip_or_partial');
        continue;
      }
      if (looksLikePatientAnecdotePrice(rhinoBlob)) {
        rejectLog('[GP PRICE] REJECT · patient_anecdote');
        continue;
      }
      if (looksLikeOfficialPriceListUrl(row.sourceUrl) &&
          (row.extractionMethod == PriceExtractionMethod.textProximity ||
              row.extractionMethod == PriceExtractionMethod.domBlock) &&
          RegExp(
            r'\bmale\s+(?:nose|rhino)|\ba male nose|\brhinoplasty\s+for\s+men',
            caseSensitive: false,
          ).hasMatch(rhinoBlob)) {
        rejectLog('[GP PRICE] REJECT · rhino_male_landing');
        continue;
      }
      if (looksLikePrimaryRhinoplastyStarting(foldedLabel) ||
          looksLikePrimaryRhinoplastyStarting(row.rawPriceText)) {
        score += 0.48;
      }
      if (RegExp(
        r'\bmale\s+(?:nose|rhino)|\brhinoplasty\s+for\s+men\b|'
        r'\bfor men\b|\ba male nose',
        caseSensitive: false,
      ).hasMatch(rhinoBlob)) {
        score -= 0.4;
      }
      if (RegExp(
            r'\bultrasonic\b|\bpiezo\b|\bpreservation\s+rhino',
            caseSensitive: false,
          ).hasMatch(foldedLabel) &&
          !looksLikePrimaryRhinoplastyStarting(foldedLabel)) {
        score -= 0.35;
      }
      if (looksLikeClinicArticlePriceUrl(row.sourceUrl) ||
          RegExp(
            r'/for-men/|/for-women/',
          ).hasMatch(row.sourceUrl.toLowerCase())) {
        score -= 0.45;
      }
      final year = explorePublishedOrReviewedYear(
        '${row.rawEvidence}\n${row.rawPriceText}',
      );
      if (year >= 2026) score += 0.35;
      if (year > 0 && year <= 2024) score -= 0.25;
      // City “plastic surgery cost” guides are market lists, not clinic menus.
      if (looksLikeCityCostArticleUrl(row.sourceUrl)) {
        score -= 0.85;
      }
      if (row.extractionMethod == PriceExtractionMethod.htmlTable &&
          !looksLikeCityCostArticleUrl(row.sourceUrl) &&
          (row.priceType == PriceType.fixed ||
              row.priceType == PriceType.from)) {
        score += 0.2;
      }
      if (RegExp(
            r'\b(normal|dislocation|c shape|s shape)\b',
          ).hasMatch(foldedLabel) &&
          row.priceMax >= row.priceMin * 1.05) {
        score -= 0.22;
      }
    }
    if (requested == 'breast_augmentation' || requested == 'breast') {
      if (looksLikeFinancingOrPaymentHeading(row.rawProcedureText) ||
          looksLikeFinancingOrPaymentHeading(foldedLabel)) {
        rejectLog('[GP PRICE] REJECT · financing_heading');
        continue;
      }
      if (looksLikeUnilateralBreastStartingRow(foldedLabel) ||
          looksLikeUnilateralBreastStartingRow(row.rawProcedureText)) {
        rejectLog('[GP PRICE] REJECT · breast_unilateral');
        continue;
      }
      if (looksLikeBreastAugmentationAddOnRow(foldedLabel) ||
          looksLikeBreastAugmentationAddOnRow(row.rawProcedureText)) {
        rejectLog('[GP PRICE] REJECT · breast_addon_or_areola');
        continue;
      }
      if (RegExp(
            r'\binverted nipple\b|\bnipple (?:lift|reduction|correction)\b',
          ).hasMatch(foldedLabel) &&
          !RegExp(
            r'augment|enlargement|implant|memorygel|boob job',
          ).hasMatch(foldedLabel)) {
        rejectLog('[GP PRICE] REJECT · breast_nipple_only');
        continue;
      }
      if (RegExp(
            r'\bbreast augmentation\b|\bboob job\b|\benlargement\b|\bmemorygel\b',
          ).hasMatch(foldedLabel) &&
          !RegExp(
            r'unilateral|lift|mastopex|reduction',
          ).hasMatch(foldedLabel)) {
        score += 0.28;
      }
    }
    if (requested == 'peel' || requested == 'filler' || requested == 'laser') {
      if (row.priceType == PriceType.from) score += 0.14;
      if (startsFromListed) score += 0.08;
    }
    if (requested == 'peel') {
      final peelBlob = '$foldedLabel $evidenceBlob';
      if (looksLikeMultiSessionSeriesQuote(peelBlob)) {
        rejectLog('[GP PRICE] REJECT · peel_series_package');
        continue;
      }
      if (looksLikeDepigmentationPeelPackage(peelBlob)) {
        rejectLog('[GP PRICE] REJECT · peel_package');
        continue;
      } else if (RegExp(
        r'chemical peel|skin peel|glycolic|mandelic|salicylic|\btca\b|'
        r'\b(?:1|one|single)\s*session\b',
        caseSensitive: false,
      ).hasMatch(foldedLabel)) {
        score += 0.32;
      }
    }
    if (requested == 'laser') {
      // Prefer a concrete body-area session over a vague “laser treatment”.
      if (RegExp(
        r'bikini|underarm|half\s+leg|full\s+leg|face|back|chest|'
        r'session|/session|per session',
      ).hasMatch(foldedLabel)) {
        score += 0.2;
      }
      if (RegExp(r'tattoo|bleaching|hair bleach').hasMatch(foldedLabel)) {
        score -= 0.5;
      }
    }
    if (requested == 'laser') {
      if (!exploreLaserRowFitsRequest(
        label: row.rawProcedureText,
        procedure: procedure,
      )) {
        rejectLog('[GP PRICE] REJECT · laser_subtype_or_generic');
        continue;
      }
      if (exploreLaserRowSubtype(row.rawProcedureText) != 'generic') {
        score += 0.18;
      }
    }
    if (requested == 'hair') {
      final hairBlob =
          '$foldedLabel ${_fold(row.rawPriceText)} ${_fold(row.rawEvidence)}';
      if (looksLikeGraftOrFollicleQuantity(row.rawPriceText) ||
          looksLikeGraftCountMistakenForPrice(
            priceMin: row.priceMin,
            blob:
                '${row.rawProcedureText} ${row.rawPriceText} ${row.rawEvidence}',
          )) {
        rejectLog('[GP PRICE] REJECT · graft_count');
        continue;
      }
      if (looksLikeEffectivePerGraftMarketing(hairBlob) ||
          looksLikeEffectivePerGraftMarketing(row.rawPriceText) ||
          looksLikeEffectivePerGraftMarketing(row.rawProcedureText)) {
        rejectLog('[GP PRICE] REJECT · effective_per_graft');
        continue;
      }
      if (looksLikeHairMarketPerGraftBlurb(hairBlob) ||
          looksLikeHairMarketPerGraftBlurb(row.rawPriceText)) {
        rejectLog('[GP PRICE] REJECT · hair_market_per_graft');
        continue;
      }
      if (looksLikeHairFutWhenFueRequested(
        procedure: procedure,
        blob: hairBlob,
      )) {
        rejectLog('[GP PRICE] REJECT · hair_fut_not_fue');
        continue;
      }
      if (looksLikeHairDhiWhenFueRequested(
        procedure: procedure,
        blob: hairBlob,
      )) {
        rejectLog('[GP PRICE] REJECT · hair_dhi_not_fue');
        continue;
      }
      if (looksLikeHairMarketComparisonRow(hairBlob) ||
          looksLikeHairMarketComparisonRow(foldedLabel)) {
        rejectLog('[GP PRICE] REJECT · hair_market_comparison');
        continue;
      }
      if (looksLikeHairLargerThanStartingPackage(hairBlob) ||
          looksLikeHairLargerThanStartingPackage(foldedLabel)) {
        rejectLog('[GP PRICE] REJECT · hair_larger_package');
        continue;
      }
      if (looksLikeHairStaleLandingQuote(
        sourceUrl: row.sourceUrl,
        blob: hairBlob,
        priceMin: row.priceMin,
        priceMax: row.priceMax,
      )) {
        rejectLog('[GP PRICE] REJECT · hair_stale_landing');
        continue;
      }
      if (looksLikeCityCostArticleUrl(row.sourceUrl) ||
          looksLikeClinicArticlePriceUrl(row.sourceUrl) ||
          isNonLiteralClinicPriceUrl(row.sourceUrl)) {
        rejectLog('[GP PRICE] REJECT · hair_city_guide');
        continue;
      }
      if (looksLikeHairNonStartingRow(foldedLabel) &&
          !RegExp(r'\bfue\b|\bdhi\b|\bsapphire\b').hasMatch(foldedLabel)) {
        rejectLog('[GP PRICE] REJECT · hair_addon_or_consult');
        continue;
      }
      final perGraft =
          looksLikePerGraftQuotedPrice(hairBlob) ||
          looksLikePerGraftQuotedPrice(row.rawPriceText);
      if (perGraft && row.priceMin > hairPerGraftPlausibleMax(row.currency)) {
        rejectLog('[GP PRICE] REJECT · implausible_per_graft');
        continue;
      }
      if (looksLikeUnshavenHairVariant(foldedLabel)) score -= 0.45;
      if (RegExp(r'\bmin(?:imum)?\s+fee\b').hasMatch(foldedLabel) ||
          RegExp(r'\bmin(?:imum)?\s+fee\b').hasMatch(hairBlob)) {
        score += 0.38;
      }
      if (looksLikeHairStartingPackageRow(foldedLabel) ||
          looksLikeHairStartingPackageRow(hairBlob)) {
        score += 0.5;
      }
      if (looksLikeOfficialPriceListUrl(row.sourceUrl)) score += 0.42;
      if (RegExp(
        r'\bbarb|\bbeard|\bsprancean|\beyebrow',
      ).hasMatch(foldedLabel)) {
        score -= 0.4;
      }
      if (RegExp(
        r'\bscalp|\bcapil|\bfue|\bdhi|\bsapphire|\bgraft|\bfir cu fir|'
        r'\btransplant de par|\btransplant par|\bimplant de par|\bimplant par',
      ).hasMatch(foldedLabel)) {
        score += 0.2;
      }
      if (perGraft) {
        score -= 0.55;
      } else if (row.priceType == PriceType.from ||
          row.priceType == PriceType.fixed) {
        score += 0.42;
      }
    }
    if (RegExp(
      r'\boferta|\bflash\b|\bpromo\b|\bspecial offer\b|\boffer\b|\bdeal\b|'
      r'\bdiscount\b|\bsale\b|%\s*off\b',
    ).hasMatch(foldedLabel)) {
      score -= 0.22;
    }
    // "Laser" / "Botox treatment" as the whole row label means we grabbed a
    // section heading, not a menu line — the card then falls back to a family
    // title instead of "Underarm laser hair removal".
    final labelWords = foldedLabel
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim()
        .split(' ')
        .where((w) => w.isNotEmpty)
        .toList();
    if (labelWords.isNotEmpty &&
        labelWords.every(_kGenericRowLabelWords.contains)) {
      score -= 0.3;
    } else if (RegExp(
      r'\b(?:1|one|single)\s*(?:session|sesion|sedinta)\b|per session|'
      r'\b\d+\s*ml\b|\b\d+\s*units?\b|\bunderarm|\bupper lip|\bfull face|'
      r'\bfull body|\bbikini|\bunder ?arms?\b|\bper area\b',
    ).hasMatch(foldedLabel)) {
      score += 0.12;
    }
    if (row.priceMax >= row.priceMin * 2.5) score -= 0.15;
    // "<treatment> cost in <city>" pages carry the clinic's price table next to
    // market prose. When the table is there, it outranks the prose.
    final proseRow =
        row.extractionMethod == PriceExtractionMethod.textProximity ||
        row.extractionMethod == PriceExtractionMethod.domBlock ||
        row.extractionMethod == PriceExtractionMethod.listItem;
    if (proseRow &&
        (looksLikeCityCostArticleUrl(row.sourceUrl) ||
            looksLikeClinicArticlePriceUrl(row.sourceUrl))) {
      score -= 0.5;
    }
    if (looksLikeCityCostArticleUrl(row.sourceUrl) &&
        looksLikeCityCommonPriceGuideBlurb(evidenceBlob)) {
      score -= 0.9;
    }
    if (looksLikeCityCommonPriceGuideBlurb(evidenceBlob) &&
        clinicOwnPublishedPriceWindow(evidenceBlob) == null) {
      debugPrint('[GP PRICE] REJECT · city_common_price_guide');
      continue;
    }
    try {
      final path = Uri.parse(
        row.sourceUrl.contains('://')
            ? row.sourceUrl
            : 'https://${row.sourceUrl}',
      ).path.toLowerCase();
      if (RegExp(r'(^|/)en(/|$)').hasMatch(path)) score += 0.2;
      if (RegExp(r'(^|/)ar(/|$)').hasMatch(path)) score -= 0.18;
    } catch (_) {}
    final cheaperIsMicroBotox =
        requested == 'botox' &&
        (_botoxMicroOrBodyArea(foldedLabel) ||
            _botoxLooksLikeAddOnOrTargeted(_fold(row.rawPriceText))) &&
        !_botoxIsStandardStartingArea(foldedLabel) &&
        row.priceType != PriceType.perUnit;
    final cheaperIsDepigmentationPeel =
        requested == 'peel' &&
        looksLikeDepigmentationPeelPackage(
          '$foldedLabel ${row.rawPriceText} ${row.rawEvidence}',
        );
    final cheaperIsPromo =
        _looksLikePromoSavingLabel(foldedLabel) ||
        RegExp(
          r'\boferta|\bflash\b|\bpromo\b|\bspecial offer\b|\boffer\b|\bdeal\b|'
          r'\bdiscount\b|\bsale\b|%\s*off\b',
        ).hasMatch(foldedLabel);
    final cheaperIsPartialRhino =
        requested == 'rhinoplasty' &&
        (looksLikePartialRhinoplastyStarting(foldedLabel) ||
            (looksLikePartialRhinoplastyStarting(
                  '${row.rawPriceText} ${row.rawEvidence}',
                ) &&
                row.priceMin < 6000));
    final cheaperIsWeakerRhinoExtract =
        requested == 'rhinoplasty' &&
        best != null &&
        _extractIsMenuStructured(best.extractionMethod) &&
        _extractIsProse(row.extractionMethod);
    final cheaperIsArticleRhino =
        requested == 'rhinoplasty' &&
        looksLikeClinicArticlePriceUrl(row.sourceUrl);
    final cheaperIsUnilateralBreast =
        (requested == 'breast_augmentation' || requested == 'breast') &&
        (looksLikeUnilateralBreastStartingRow(foldedLabel) ||
            looksLikeBreastAugmentationAddOnRow(foldedLabel));
    final cheaperLosesToHairPackage =
        requested == 'hair' &&
        best != null &&
        !looksLikePerGraftQuotedPrice(
          '${best.rawProcedureText} ${best.rawPriceText} ${best.rawEvidence}',
        ) &&
        best.priceMin >= 800 &&
        (looksLikePerGraftQuotedPrice(
              '${row.rawProcedureText} ${row.rawPriceText} ${row.rawEvidence}',
            ) ||
            looksLikeEffectivePerGraftMarketing(
              '${row.rawProcedureText} ${row.rawPriceText}',
            ));
    final cheaperLosesToStandardBotox =
        requested == 'botox' &&
        best != null &&
        _botoxIsStandardStartingArea(_fold(best.rawProcedureText)) &&
        !_botoxIsStandardStartingArea(foldedLabel);
    // Starting price = lowest valid quote among near-tied quality scores.
    // Wider window so an exact "Full Face" cannot beat a cheaper underarm
    // / per-unit / 1-zone variant of the same treatment.
    final nearTie = best != null && (bestScore - score).abs() <= 0.35;
    final betterStarting =
        best != null &&
        nearTie &&
        row.priceMin < best.priceMin &&
        !cheaperIsMicroBotox &&
        !cheaperIsDepigmentationPeel &&
        !cheaperIsPromo &&
        !cheaperIsPartialRhino &&
        !cheaperIsWeakerRhinoExtract &&
        !cheaperIsArticleRhino &&
        !cheaperIsUnilateralBreast &&
        !cheaperLosesToHairPackage &&
        !cheaperLosesToStandardBotox;
    final betterPrice =
        best != null &&
        score == bestScore &&
        row.priceMin < best.priceMin &&
        !cheaperIsMicroBotox &&
        !cheaperIsDepigmentationPeel &&
        !cheaperIsPromo &&
        !cheaperIsPartialRhino &&
        !cheaperIsWeakerRhinoExtract &&
        !cheaperIsArticleRhino &&
        !cheaperIsUnilateralBreast &&
        !cheaperLosesToHairPackage &&
        !cheaperLosesToStandardBotox;
    if (best == null || score > bestScore || betterPrice || betterStarting) {
      best = row.copyWith(
        procedureFamily: family,
        procedureCanonical: canonical,
        evidenceHash: row.evidenceHash.isNotEmpty
            ? row.evidenceHash
            : buildEvidenceHash(
                sourceUrl: row.sourceUrl,
                rawProcedureText: row.rawProcedureText,
                rawPriceText: row.rawPriceText,
              ),
      );
      bestScore = score;
    }
  }
  if (best != null && requested == 'hair') {
    final pageBlob = rows
        .map(
          (r) => '${r.rawProcedureText}\n${r.rawPriceText}\n${r.rawEvidence}',
        )
        .join('\n');
    final fee = exploreMandatoryPackageAddOnFee(pageBlob);
    final already = hairRowIncludesMandatoryAddOnFee(
      '${best.rawProcedureText}\n${best.rawPriceText}\n${best.rawEvidence}',
    );
    if (fee != null &&
        fee > 0 &&
        !already &&
        best.priceMin > fee * 4 &&
        best.priceMin < 20000) {
      best = best.copyWith(priceMin: best.priceMin + fee);
    }
  }
  if (best != null) {
    debugPrint(
      '[GP PRICE] PICK · "${best.rawProcedureText}" · '
      '${best.priceMin.round()} ${best.currency} · '
      '${best.extractionMethod.wire} · ${best.sourceUrl}',
    );
  }
  return best;
}

/// Tiny promo zones and body Botox are not the advertised facial starting price.
bool _botoxMicroOrBodyArea(String folded) {
  return _botoxIsSpecialtyStarting(folded) ||
      RegExp(
        r'small area|small areas|مناطق صغيرة|منطقة صغيرة|'
        r'\bfeet\b|\bfoot\b|القدمين|'
        r'\bshoulders?\b|الأكتاف|'
        r'underarm|under[\s-]?arm|تحت الذراعين|الأبط|'
        r'\bcalves\b|\bcalf\b|\bhands?\b|'
        r'mouth\s*corner|migraine|teeth\s*grind|bruxism|masseter|'
        r'jaw\s*line|jawline|lip[- ]?flip|hyperhidrosis|gummy\s*smile|'
        r'bunny\s*line|platysma|face\s*slimming|coada ochiului',
      ).hasMatch(folded);
}

/// Forehead / frown / 1 area — the Explore Botox starting card.
bool _botoxIsStandardStartingArea(String folded) {
  return RegExp(
    r'\b(?:1|one|single)\s*area\b|'
    r'\b(?:1|una|o)\s*zon|'
    r'одна\s*зон|'
    r'upper[- ]?face|'
    r'forehead lines|frown lines|glabel|'
    r"crow.?s?\s*feet|periocular|laba\s*g|coada och",
  ).hasMatch(folded);
}

/// Add-on / extra targeted zones sold on top of a 1-area treatment.
bool _botoxLooksLikeAddOnOrTargeted(String folded) {
  return RegExp(
    r'when added to another|'
    r'\badd[\s-]?ons?\b|'
    r'targeted areas?|'
    r'higher[- ]dosage supplement|'
    r'each when added|'
    r'smokers?\s*lines?|'
    r'marionette',
  ).hasMatch(folded);
}

/// Chin dimpling / bunny lines / masseter — not the advertised 1-area start.
bool _botoxIsSpecialtyStarting(String folded) {
  return RegExp(
    r'chin\s*dimpl|pebbled\s*chin|mentalis|'
    r'down[- ]?turned|mouth\s*corner|corners?\s+(?:of\s+(?:the\s+)?)?mouth|'
    r'lip[- ]?flip|gummy\s*smile|bunny\s*line|'
    r'jawline\s*lift|masseter|trap[- ]?tox|barbie|trapezius|'
    r'fine\s+under[- ]?eye|'
    r'calf\s*reduction|hyperhidros|migraine|'
    r'excessive\s+sweat(?:ing)?|sweat(?:ing)?\s+(?:botox|toxin)|'
    r'underarm\s+botox|armpit\s+botox|'
    r'chemical\s*brow|neck\s*lift|platism',
  ).hasMatch(folded);
}

bool _botoxAdvertisedStartArea(String folded) {
  return RegExp(
    r'full face|كامل الوجه|'
    r'any area|اي منطقة|أي منطقة|'
    r'\b(?:1|one)\s*area\b|منطقة واحدة|'
    r'starts?\s+from|starting at|start from',
  ).hasMatch(folded);
}

bool _looksLikeGenericBotoxFamilyLabel(String folded) {
  final t = folded.trim();
  if (t.isEmpty) return false;
  if (RegExp(
    r'^(?:botox|anti[- ]?wrinkle)(?:\s+(?:treatment|treatments|'
    r'injections?|injectables?|prices?|cost|costs))?$',
  ).hasMatch(t)) {
    return true;
  }
  final words = t.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  return words.isNotEmpty && words.every(_kGenericRowLabelWords.contains);
}

/// A botulinum brand that is not Botox.
///
/// [_kBotoxPositive] deliberately treats the whole class as one family, which
/// is right for matching but wrong for pricing: the units are not
/// interchangeable, since roughly 2.5-3 Dysport units do the work of one Botox
/// unit. A clinic charging $6/unit for Dysport and $18/unit for Botox is not
/// offering a cheaper Botox, so the two rows must not be compared on price.
bool _looksLikeAlternativeBotulinumBrand(String folded) => RegExp(
  r'\bdysport\b|\bxeomin\b|\bneuronox\b|\bazzalure\b|\bvistabel\b|\bjeuveau\b|'
  r'\bbocouture\b|\bdaxxify\b|\bnuceiva\b|\bletybo\b|\brelfydess\b',
).hasMatch(folded);

bool _mentionsBotoxByName(String folded) => RegExp(
  r'\bbotox\b|\bbotulinum\b|toxina\s*botulin|botulotoxin|'
  r'ботокс|ботулин',
).hasMatch(folded);

bool _looksLikePromoSavingLabel(String folded) {
  return RegExp(
    r'your\s+saving|you\s+save|\bsaving\b|was\s*(?:£|\$|€)|'
    r'strikethrough|before\s+price',
  ).hasMatch(folded);
}

bool _rhinoplastyLooksNonsurgical(String folded) {
  return RegExp(
    r'non[- ]?surgical|nonsurgical|liquid rhino|nose filler|'
    r'rinoplastia no quir|filler nariz|cheaper alternative',
  ).hasMatch(folded);
}

bool _rhinoplastyIsPartialStarting(String folded) {
  return looksLikePartialRhinoplastyStarting(folded);
}

bool _rhinoplastyIsPrimaryStarting(String folded) {
  return looksLikePrimaryRhinoplastyStarting(folded);
}

/// Row labels that name only a treatment family, never a bookable line item.
const _kGenericRowLabelWords = {
  'botox',
  'breast',
  'chemical',
  'dermal',
  'filler',
  'fillers',
  'hair',
  'injection',
  'injections',
  'laser',
  'peel',
  'peels',
  'price',
  'prices',
  'rhinoplasty',
  'surgery',
  'treatment',
  'treatments',
};

/// Cached quote was extracted from the wrong treatment row or a blog/guide.
bool exploreCachedPriceNeedsReselect({
  required String rawProcedureText,
  required String brand,
  required String sourceUrl,
  required String procedure,
  String rawPriceText = '',
  String rawEvidence = '',
  double priceMin = 0,
  double priceMax = 0,
  String priceExtractRevision = '',
  String currency = '',
}) {
  if (isNonLiteralClinicPriceUrl(sourceUrl)) return true;
  if (exploreUrlConflictsWithProcedure(sourceUrl, procedure)) return true;
  if (looksLikeShopifyThemeDummyPrice(
        rawPriceText: rawPriceText,
        priceMin: priceMin,
        currency: currency,
        rawEvidence: rawEvidence,
        procedure: rawProcedureText,
      ) ||
      looksLikeUsdQuotedOnUkHost(
        sourceUrl: sourceUrl,
        currency: currency,
        rawPriceText: rawPriceText,
        rawEvidence: rawEvidence,
      )) {
    return true;
  }
  if (priceMin > 0 &&
      priceExtractRevision.trim() != kExplorePriceExtractRevision) {
    return true;
  }
  final blob = '$rawProcedureText\n$brand\n$rawPriceText\n$rawEvidence';
  final quoteBlob = '$rawPriceText\n$rawEvidence';
  final want = _requestedFamily(procedure);
  final raw = rawProcedureText.trim().isNotEmpty
      ? rawProcedureText.trim()
      : brand.trim();
  if (looksLikeSearchQuickFactsBlob(blob) ||
      looksLikeSeoQuotedPriceHeadline(blob) ||
      looksLikeMixedServiceBundle(blob)) {
    return true;
  }
  if (looksLikeEmergencyOrHelpNumber(rawPriceText, priceMin: priceMin) ||
      looksLikeEmergencyOrHelpNumber(quoteBlob, priceMin: priceMin)) {
    return true;
  }
  if (looksLikeBrandEmbeddedDigitPrice(priceMin, blob) ||
      looksLikeBrandEmbeddedDigitPrice(priceMin, rawPriceText) ||
      looksLikeBrandEmbeddedDigitPrice(priceMin, brand)) {
    return true;
  }
  if (looksLikeMarketAveragePriceBlurb(blob) &&
      pickClinicOwnPublishedPrice(blob, procedure: procedure) == null) {
    return true;
  }
  if (looksLikeCompetitorOrThirdPartyPriceQuote(blob) ||
      looksLikeCompetitorOrThirdPartyPriceQuote(quoteBlob) ||
      looksLikeThirdPartyProviderPriceLabel(raw)) {
    final own = pickClinicOwnPublishedPrice(blob, procedure: procedure);
    if (own == null || !publishedAmountMatchesWindow(own, priceMin)) {
      return true;
    }
  }
  if (want == 'botox' && looksLikeCityCostArticleUrl(sourceUrl)) {
    return true;
  }
  final firstOwn = clinicOwnPublishedPriceWindow(quoteBlob);
  final pickedOwn = pickClinicOwnPublishedPrice(
    quoteBlob,
    procedure: procedure,
  );
  if (firstOwn != null &&
      pickedOwn == null &&
      priceMin > 0 &&
      publishedAmountMatchesWindow(firstOwn, priceMin)) {
    return true;
  }
  if (explorePriceLooksLikeCatalogAggregate(
    rawPriceText: rawPriceText,
    priceMin: priceMin,
    priceMax: priceMax,
  )) {
    return true;
  }
  if (want != 'other' &&
      (competingFamilyRejectReason(raw, want) != null ||
          competingFamilyRejectReason(sourceUrl, want) != null ||
          competingFamilyRejectReason(rawEvidence, want) != null ||
          competingFamilyRejectReason(rawPriceText, want) != null)) {
    return true;
  }
  if ((want == 'botox' || want == 'filler') &&
      (looksLikeEnergyOrDeviceTreatment(raw) ||
          looksLikeEnergyOrDeviceTreatment(sourceUrl) ||
          exploreUrlPathFamilyKey(sourceUrl) == 'energy_device')) {
    return true;
  }
  if (raw.isEmpty) {
    return looksLikePriceMenuUrl(sourceUrl);
  }
  final folded = raw
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim();
  if (_looksLikePromoSavingLabel(_fold(raw))) return true;
  if (want == 'botox' &&
      ((_botoxIsSpecialtyStarting(
                _fold('$raw\n$rawPriceText\n$rawEvidence\n$sourceUrl'),
              ) &&
              !_botoxIsStandardStartingArea(_fold(raw))) ||
          looksLikeBotoxSpecialtyVariantUrl(sourceUrl) &&
              !_botoxIsStandardStartingArea(_fold(raw)) ||
          _botoxLooksLikeAddOnOrTargeted(
            _fold('$raw\n$rawPriceText\n$rawEvidence'),
          ) ||
          _looksLikeGenericBotoxFamilyLabel(_fold(raw)))) {
    return true;
  }
  if (want == 'hair' &&
      (looksLikeGraftOrFollicleQuantity(rawPriceText) ||
          looksLikeGraftCountMistakenForPrice(priceMin: priceMin, blob: blob) ||
          looksLikeEffectivePerGraftMarketing(blob) ||
          looksLikeHairMarketPerGraftBlurb(blob) ||
          looksLikeHairFutWhenFueRequested(procedure: procedure, blob: blob) ||
          looksLikeHairDhiWhenFueRequested(procedure: procedure, blob: blob) ||
          looksLikeHairMarketComparisonRow(blob) ||
          looksLikeHairLargerThanStartingPackage(blob) ||
          looksLikeHairCachedNonStartingPackageFrom(
            sourceUrl: sourceUrl,
            blob: blob,
            priceMin: priceMin,
          ) ||
          looksLikeHairStaleLandingQuote(
            sourceUrl: sourceUrl,
            blob: blob,
            priceMin: priceMin,
            priceMax: priceMax,
          ) ||
          looksLikeCityCostArticleUrl(sourceUrl) ||
          looksLikeClinicArticlePriceUrl(sourceUrl) ||
          isNonLiteralClinicPriceUrl(sourceUrl) ||
          looksLikeHairNonStartingRow(raw) ||
          (looksLikePerGraftQuotedPrice(blob) &&
              priceMin > hairPerGraftPlausibleMax(currency)))) {
    return true;
  }
  if (want == 'peel' &&
      (looksLikeDepigmentationPeelPackage(
            exploreLineOwningAmount(blob, priceMin),
          ) ||
          looksLikeMultiSessionSeriesQuote(
            exploreLineOwningAmount(blob, priceMin),
          ))) {
    return true;
  }
  if (want == 'rhinoplasty') {
    final rhinoBlob = _fold('$raw\n$rawPriceText\n$rawEvidence');
    if (_rhinoplastyLooksNonsurgical(rhinoBlob) &&
        priceMin > 0 &&
        priceMin < 2500) {
      return true;
    }
    if (looksLikePartialRhinoplastyStarting(raw) ||
        (looksLikePartialRhinoplastyStarting('$rawPriceText\n$rawEvidence') &&
            priceMin > 0 &&
            priceMin < 6000)) {
      return true;
    }
    if (looksLikePatientAnecdotePrice('$raw\n$rawPriceText\n$rawEvidence')) {
      return true;
    }
    if (looksLikeCityMarketPricingGuideUrl(sourceUrl) ||
        isNonLiteralClinicPriceUrl(sourceUrl)) {
      return true;
    }
    if (looksLikeClinicArticlePriceUrl(sourceUrl) &&
        priceMin > 0 &&
        priceMin < 7500) {
      return true;
    }
    if (priceMin > 0 &&
        priceMin < 7500 &&
        RegExp(r'rhinoplasty-cost', caseSensitive: false).hasMatch(sourceUrl) &&
        !RegExp(
          r'price-guide|price-list|pricelist',
          caseSensitive: false,
        ).hasMatch(sourceUrl)) {
      return true;
    }
  }
  if ((want == 'breast_augmentation' || want == 'breast') &&
      (looksLikeFinancingOrPaymentHeading(raw) ||
          looksLikeUnilateralBreastStartingRow(raw) ||
          looksLikeSeoCostPageHeading(raw) ||
          looksLikeComplicationOrAftercareHeading(raw))) {
    return true;
  }
  if (looksLikeRoundedMarketPriceSpread(
    priceMin: priceMin,
    priceMax: priceMax > 0 ? priceMax : priceMin,
    currency: currency,
    procedure: procedure,
  )) {
    return true;
  }
  if ((want == 'breast_augmentation' || want == 'breast') &&
      priceMin > 0 &&
      priceMin < 4000) {
    final curr = currency.trim().toUpperCase();
    if (curr == 'GBP' || curr == '£') return true;
  }
  if (want == 'laser' &&
      !exploreLaserRowFitsRequest(label: raw, procedure: procedure)) {
    return true;
  }
  const genericFamilyLabels = {
    'botox',
    'filler',
    'fillers',
    'laser',
    'peel',
    'peels',
    'rhinoplasty',
    'hair',
    'breast',
  };
  if (genericFamilyLabels.contains(folded)) return true;
  final match = matchRawProcedureLabel(raw, requestedProcedure: procedure);
  if (match.rejectReason.isNotEmpty) return true;
  if (want != 'other' &&
      match.family != 'other' &&
      !_familiesCompatible(want, match.family)) {
    return true;
  }
  final relation = classifyProcedureRelation(
    requestedProcedure: procedure,
    label: raw,
    evidence: '$rawPriceText\n$rawEvidence',
    sourceUrl: sourceUrl,
  );
  if (!relation.eligibleForFromPrice) return true;
  if (want != 'other' && match.family == 'other') return true;
  return false;
}

/// Typical-range high/low must use comparable starting prices only.
/// Barbie Botox, add-on zones, and Cosmelan kits stay on cards when that is
/// what the clinic published, but they do not set the topic min–max.
bool explorePriceIsComparableTypicalStart({
  required String procedure,
  String rawProcedureText = '',
  String brand = '',
  String rawPriceText = '',
  String rawEvidence = '',
  String sourceUrl = '',
  double priceMin = 0,
  double priceMax = 0,
  String currency = '',
}) {
  final want = _requestedFamily(procedure);
  final label = rawProcedureText.trim().isNotEmpty ? rawProcedureText : brand;
  final quote = '$rawPriceText\n$rawEvidence';
  if ((want == 'botox' || want == 'filler') &&
      (looksLikeEnergyOrDeviceTreatment(label) ||
          looksLikeEnergyOrDeviceTreatment(sourceUrl) ||
          exploreUrlPathFamilyKey(sourceUrl) == 'energy_device')) {
    return false;
  }
  if (want == 'botox') {
    if (looksLikeSpecialOfferUrl(sourceUrl)) return false;
    if (looksLikeCityCostArticleUrl(sourceUrl)) return false;
    if (looksLikeCompetitorOrThirdPartyPriceQuote(quote) ||
        looksLikeThirdPartyProviderPriceLabel(label)) {
      return false;
    }
    if (_botoxLooksLikeAddOnOrTargeted(_fold('$label\n$quote')) &&
        !_botoxIsStandardStartingArea(_fold(label))) {
      return false;
    }
    if (_botoxIsSpecialtyStarting(_fold('$label\n$quote\n$sourceUrl')) &&
        !_botoxIsStandardStartingArea(_fold(label))) {
      return false;
    }
    if (looksLikeBotoxSpecialtyVariantUrl(sourceUrl) &&
        !_botoxIsStandardStartingArea(_fold(label))) {
      return false;
    }
    if (_looksLikeGenericBotoxFamilyLabel(_fold(label)) &&
        !_botoxIsStandardStartingArea(_fold('$label\n$quote'))) {
      return false;
    }
  }
  if (want == 'hair') {
    if (looksLikeEffectivePerGraftMarketing('$label\n$quote')) return false;
    if (looksLikeHairMarketPerGraftBlurb('$label\n$quote')) return false;
    if (looksLikePerGraftQuotedPrice('$label\n$quote')) return false;
    if (looksLikeGraftOrFollicleQuantity(rawPriceText) ||
        looksLikeGraftCountMistakenForPrice(
          priceMin: priceMin,
          blob: '$label\n$quote',
        )) {
      return false;
    }
    if (looksLikeHairFutWhenFueRequested(
      procedure: procedure,
      blob: '$label\n$quote',
    )) {
      return false;
    }
    if (looksLikeHairDhiWhenFueRequested(
      procedure: procedure,
      blob: '$label\n$quote',
    )) {
      return false;
    }
    if (looksLikeHairMarketComparisonRow('$label\n$quote') ||
        looksLikeHairLargerThanStartingPackage('$label\n$quote') ||
        looksLikeHairCachedNonStartingPackageFrom(
          sourceUrl: sourceUrl,
          blob: '$label\n$quote',
          priceMin: priceMin,
        )) {
      return false;
    }
    if (looksLikeHairStaleLandingQuote(
      sourceUrl: sourceUrl,
      blob: '$label\n$quote',
      priceMin: priceMin,
      priceMax: priceMax,
    )) {
      return false;
    }
    if (looksLikeCityCostArticleUrl(sourceUrl) ||
        looksLikeClinicArticlePriceUrl(sourceUrl) ||
        isNonLiteralClinicPriceUrl(sourceUrl)) {
      return false;
    }
    if (looksLikeHairNonStartingRow(label)) return false;
  }
  if (want == 'peel' &&
      (looksLikeDepigmentationPeelPackage('$label\n$quote') ||
          looksLikeMultiSessionSeriesQuote('$label\n$quote'))) {
    return false;
  }
  if (want == 'rhinoplasty') {
    if (looksLikePartialRhinoplastyStarting(label) ||
        looksLikePartialRhinoplastyStarting(quote)) {
      return false;
    }
    if (looksLikeHospitalFeesOnlyQuote('$label\n$quote') ||
        looksLikeStarredHospitalGuidePrice(
          blob: '$label\n$quote',
          priceMin: priceMin,
          procedure: procedure,
        )) {
      return false;
    }
    if (looksLikeCityMarketPricingGuideUrl(sourceUrl) ||
        isNonLiteralClinicPriceUrl(sourceUrl)) {
      return false;
    }
    if (looksLikePatientAnecdotePrice('$label\n$quote')) return false;
    if (looksLikeRoundedMarketPriceSpread(
      priceMin: priceMin,
      priceMax: priceMax > 0 ? priceMax : priceMin,
      currency: currency,
      procedure: procedure,
    )) {
      return false;
    }
    if (looksLikeClinicArticlePriceUrl(sourceUrl)) return false;
    if (looksLikeCityCostArticleUrl(sourceUrl)) return false;
  }
  return true;
}
