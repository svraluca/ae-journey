import 'explore_city_identity.dart';
import 'explore_search_locale.dart';

/// Configurable multilingual procedure ontology for discovery queries only.
///
/// Aliases are candidate-discovery tools — never verified price evidence.
class ExploreProcedureOntologyEntry {
  const ExploreProcedureOntologyEntry({
    required this.canonicalId,
    required this.aliasesByLanguage,
  });

  final String canonicalId;
  final Map<String, List<String>> aliasesByLanguage;

  List<String> aliasesFor(String lang) {
    final direct = aliasesByLanguage[lang.trim().toLowerCase()];
    if (direct != null && direct.isNotEmpty) return direct;
    return aliasesByLanguage['en'] ?? const [];
  }
}

/// Built-in ontology. Extend via env/JSON later; not a city allowlist.
const kExploreProcedureOntology = <ExploreProcedureOntologyEntry>[
  ExploreProcedureOntologyEntry(
    canonicalId: 'lip_filler',
    aliasesByLanguage: {
      'en': ['lip filler', 'lip augmentation', 'dermal filler lips'],
      'ro': ['acid hialuronic buze', 'marire buze', 'filler buze'],
      'tr': ['dudak dolgusu'],
      'fr': ['injection levres', 'augmentation levres', 'acide hyaluronique levres'],
      'es': ['relleno de labios', 'aumento de labios'],
      'de': ['lippenaufspritzung', 'lippenfiller'],
      'pt': ['preenchimento labial'],
      'it': ['filler labbra', 'aumento labbra'],
      'ar': ['فيلر الشفاه', 'تكبير الشفاه'],
    },
  ),
  ExploreProcedureOntologyEntry(
    canonicalId: 'botox',
    aliasesByLanguage: {
      'en': ['botox', 'anti wrinkle injection', 'botulinum toxin'],
      'ro': ['botox', 'toxina botulinica'],
      'tr': ['botoks'],
      'fr': ['botox', 'injection botox'],
      'es': ['botox', 'toxina botulinica'],
      'de': ['botox', 'faltenbehandlung'],
      'pt': ['botox'],
      'it': ['botox', 'tossina botulinica'],
      'ar': ['بوتوكس'],
    },
  ),
  ExploreProcedureOntologyEntry(
    canonicalId: 'rhinoplasty',
    aliasesByLanguage: {
      'en': ['rhinoplasty', 'nose job'],
      'ro': ['rinoplastie'],
      'tr': ['rinoplasti', 'burun estetigi'],
      'fr': ['rhinoplastie'],
      'es': ['rinoplastia'],
      'de': ['nasenkorrektur', 'rhinoplastik'],
      'pt': ['rinoplastia'],
      'it': ['rinoplastica'],
      'ar': ['تجميل الأنف'],
    },
  ),
];

ExploreProcedureOntologyEntry? exploreOntologyForProcedure(String procedure) {
  final lo = procedure.trim().toLowerCase();
  if (lo.isEmpty) return null;
  for (final e in kExploreProcedureOntology) {
    if (lo.contains(e.canonicalId.replaceAll('_', ' ')) ||
        lo.contains(e.canonicalId.replaceAll('_', ''))) {
      return e;
    }
    for (final aliases in e.aliasesByLanguage.values) {
      for (final a in aliases) {
        if (a.isNotEmpty && lo.contains(a.toLowerCase())) return e;
      }
    }
  }
  if (lo.contains('filler') || lo.contains('lip')) {
    return kExploreProcedureOntology
        .firstWhere((e) => e.canonicalId == 'lip_filler');
  }
  if (lo.contains('botox') || lo.contains('botulin')) {
    return kExploreProcedureOntology.firstWhere((e) => e.canonicalId == 'botox');
  }
  if (lo.contains('rhino') || lo.contains('nose')) {
    return kExploreProcedureOntology
        .firstWhere((e) => e.canonicalId == 'rhinoplasty');
  }
  return null;
}

/// Generate worldwide localized discovery queries (not price evidence).
List<String> exploreLocalizedDiscoveryQueries({
  required String procedure,
  required ExploreCityIdentity city,
  int max = 12,
}) {
  final out = <String>[];
  void add(String q) {
    final t = q.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isNotEmpty && !out.contains(t)) out.add(t);
  }

  final locale = exploreCityPriceSearchTerms(
    city.displayName,
    countryCode: city.countryCode,
  );
  final lang = city.languageCodes.isNotEmpty
      ? city.languageCodes.first
      : locale.lang;
  final ontology = exploreOntologyForProcedure(procedure);
  final localAliases = ontology?.aliasesFor(lang) ?? const <String>[];
  final enAliases = ontology?.aliasesFor('en') ??
      [procedure.trim()].where((e) => e.isNotEmpty).toList();
  final priceWord =
      locale.priceWords.isNotEmpty ? locale.priceWords.first : 'price';
  final clinicWord =
      locale.clinicWord.trim().isNotEmpty ? locale.clinicWord : 'clinic';
  final localCity = city.effectiveLocalName;
  final asciiCity = city.effectiveAsciiName;
  final country = city.countryName.trim().isNotEmpty
      ? city.countryName.trim()
      : city.countryCode;
  final tld = _countryTld(city.countryCode);

  for (final alias in [...localAliases, ...enAliases]) {
    add('$alias $priceWord $localCity');
    if (asciiCity.toLowerCase() != localCity.toLowerCase()) {
      add('$alias $priceWord $asciiCity');
    }
    add('$alias price $localCity $country');
    add('$clinicWord $localCity $alias');
    if (tld.isNotEmpty) {
      add('site:$tld $localCity $alias $priceWord');
    }
  }
  add('$clinicWord $localCity prices');
  add('$procedure $localCity $country');
  return out.take(max).toList(growable: false);
}

String _countryTld(String countryCode) {
  switch (countryCode.trim().toUpperCase()) {
    case 'RO':
      return '.ro';
    case 'MD':
      return '.md';
    case 'FR':
      return '.fr';
    case 'DE':
      return '.de';
    case 'ES':
      return '.es';
    case 'IT':
      return '.it';
    case 'PT':
      return '.pt';
    case 'TR':
      return '.tr';
    case 'GB':
    case 'UK':
      return '.uk';
    case 'AE':
      return '.ae';
    case 'JP':
      return '.jp';
    case 'BR':
      return '.br';
    case 'CA':
      return '.ca';
    case 'US':
      return '.com';
    default:
      return '';
  }
}
