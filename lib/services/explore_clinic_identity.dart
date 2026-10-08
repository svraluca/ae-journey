import 'package:flutter/foundation.dart';

import 'explore_price_sanity.dart';

/// Shared Explore clinic-identity rules (Dart mirror of functions/explore/identity.js).
///
/// Price parsing / sanity / procedure-family matching stay elsewhere and must
/// not be loosened. This file only answers: "is this a real provider clinic?"

const kExploreMarketplaceExactHosts = <String>{
  'clinicpoint.com',
  'whatclinic.com',
  'bookimed.com',
  'qunomedical.com',
  'treatwell.com',
  'groupon.com',
  'groupon.es',
  'doctoralia.es',
  'doctoralia.com',
  'topdoctors.es',
  'topdoctors.com',
  'saludestetica.com',
  'estheticon.com',
  'fresha.com',
  'booksy.com',
  'hirefrederick.com',
  'studio24.bg',
  'medigence.com',
  'mediglobus.com',
  'injectablesbooking.ae',
  'injectablesbooking.it',
  'clinicsuae.ae',
  'zavis.ai',
  'medifinder.ae',
  'salonsindubai.ae',
  'getclearbeauty.com',
  'trueclinic.com',
  'mymeditravel.com',
  'placidway.com',
  'doktortakvimi.com',
  // Medical-tourism / cost-guide hubs — never clinic cards.
  'turkeymedicals.com',
  'turkeybeautyguide.com',
  'healthyturkiye.com',
  'medicaltravelcost.com',
  'clinicbooking.com',
  'turkeyluxuryclinics.com',
  'medifyr.com',
  'trendyol.com',
  // Delivery / classifieds — breast-pump and "pompa gjiri" SERP noise.
  'wolt.com',
  'merrjep.al',
  'merrjep.com',
  'glovoapp.com',
  'glovo.com',
  'bolt.eu',
  'food.bolt.eu',
  'ubereats.com',
  'olx.al',
  'olx.com',
  'njoftime.com',
};

const kExploreMarketplaceHostNeedles = <String>[
  'clinicpoint.',
  'whatclinic.',
  'bookimed.',
  'qunomedical.',
  'treatwell.',
  'groupon.',
  'doctoralia.',
  'topdoctors.',
  'saludestetica.',
  'estheticon.',
  'fresha.',
  'booksy.',
  'hirefrederick.',
  'studio24.',
  'medigence.',
  'mediglobus.',
  'injectablesbooking.',
  'clinichunter.',
  'zavis.',
  'medifinder.',
  'salonsindubai.',
  'getclearbeauty.',
  'trueclinic.',
  'mymeditravel.',
  'placidway.',
  'doktortakvimi.',
  'turkeymedicals.',
  'turkeybeautyguide.',
  'healthyturkiye.',
  'medicaltravelcost.',
  'clinicbooking.',
  'turkeyluxuryclinics.',
  'medifyr.',
  'trendyol.',
  'wolt.',
  'merrjep.',
  'glovo',
  'ubereats.',
  'olx.',
  'njoftime.',
];

const kExploreMarketplaceBrandTokens = <String>{
  'clinicpoint',
  'clinichunter',
  'whatclinic',
  'bookimed',
  'qunomedical',
  'treatwell',
  'groupon',
  'doctoralia',
  'topdoctors',
  'top doctors',
  'saludestetica',
  'salud estetica',
  'estheticon',
  'fresha',
  'booksy',
  'hirefrederick',
  'studio24',
  'studio 24',
  'medigence',
  'mediglobus',
  'injectablesbooking',
  'medifinder',
  'medi globus',
  'salonsindubai',
  'salons in dubai',
  'getclearbeauty',
  'get clear beauty',
  'trueclinic',
  'mymeditravel',
  'placidway',
  'doktortakvimi',
  'turkeymedicals',
  'turkey beauty guide',
  'turkeybeautyguide',
  'healthyturkiye',
  'healthy turkiye',
  'medicaltravelcost',
  'medical travel cost',
  'clinicbooking',
  'clinic booking',
  'turkeyluxuryclinics',
  'medifyr',
  'trendyol',
};

const _kNonAestheticMarketplaceCategories = <String>{
  'barber-shop',
  'barber',
  'barbershop',
  'hair-salon',
  'nail-salon',
  'nails',
  'makeup-artist',
  'tattoo',
  'tattoo-studio',
  'pet-grooming',
};

const kExploreGenericShopNames = <String>{
  'tienda',
  'shop',
  'store',
  'boutique',
  'outlet',
  'the shop',
  'the store',
  'la tienda',
  'el outlet',
};

const _kGenericNameTokens = <String>{
  'clinic',
  'clinica',
  'clinicas',
  'clinics',
  'aesthetic',
  'esthetic',
  'estetic',
  'estetica',
  'medical',
  'international',
  'barcelona',
  'madrid',
  'valencia',
  'centre',
  'center',
  'centers',
  'centres',
  'hospital',
  'spa',
  'and',
  'the',
};

final _monthCue = RegExp(
  r'\b(enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|'
  r'octubre|noviembre|diciembre|january|february|march|april|june|july|'
  r'august|september|october|november|december)\b',
  caseSensitive: false,
);

/// Arabic FAQ openers ("كم تكلفة…", "ما هو…") scraped as treatment names.
final _kArabicQuestionStart = RegExp(r'^(كم|ما هو|ما هي|لماذا|هل)(\s|$)');

final _procedureKeyword = RegExp(
  r'\b(botox|filler|fillers|labios|lip|laser|peel|peeling|rinoplast|'
  r'rhinoplast|hair|transplant|breast|boob|toxina|hyaluron|juvederm|'
  r'restylane|dysport|chemical|skin\s+booster|buze|hialuron|'
  r'mamar|augmentare)\b|'
  r'(بوتوكس|فيلر|هيالورونيك|ليزر|تقشير|تجميل الانف|تجميل الأنف|'
  r'تكبير الثدي|تكبير الصدر|زراعة الشعر)',
  caseSensitive: false,
);

String normalizeExploreHost(String raw) {
  var h = raw.trim().toLowerCase();
  if (h.isEmpty) return '';
  h = h.replaceFirst(RegExp(r'^https?://'), '');
  h = h.replaceFirst(RegExp(r'^www\.'), '');
  h = h.split('/').first.split(':').first.split('?').first.trim();
  return h;
}

bool isMarketplaceOrDirectoryHost(String rawHost) {
  final h = normalizeExploreHost(rawHost);
  if (h.isEmpty) return false;
  if (kExploreMarketplaceExactHosts.contains(h)) return true;
  for (final exact in kExploreMarketplaceExactHosts) {
    if (h == exact || h.endsWith('.$exact')) return true;
  }
  for (final needle in kExploreMarketplaceHostNeedles) {
    if (h == needle.replaceAll('.', '') ||
        h.contains(needle) ||
        h.endsWith(needle.substring(0, needle.length - 1))) {
      return true;
    }
  }
  return false;
}

/// Compare-the-market / national-average directories. Discovery only —
/// never a clinic-owned verified price.
bool looksLikeMarketEstimateDirectoryUrl(String sourceUrl) {
  final h = normalizeExploreHost(sourceUrl);
  if (h.isEmpty) return false;
  final path = Uri.tryParse(sourceUrl)?.path.toLowerCase() ?? '';
  if ((h == 'booksy.com' || h.endsWith('.booksy.com')) &&
      RegExp(r'/(?:s|l|search|category|categories|explore)/').hasMatch(path)) return true;
  const hosts = {
    'multiestetica.com',
    'gorgeousgetaways.com',
    'getclearbeauty.com',
    'trueclinic.com',
    'mymeditravel.com',
    'turkeymedicals.com',
    'turkeybeautyguide.com',
    'healthyturkiye.com',
    'medicaltravelcost.com',
    'clinicbooking.com',
    'turkeyluxuryclinics.com',
    'medifyr.com',
    'trendyol.com',
    'placidway.com',
  };
  for (final exact in hosts) {
    if (h == exact || h.endsWith('.$exact')) return true;
  }
  if (h.contains('best-clinic') ||
      h.contains('cost-guide') ||
      h.contains('price-guide') ||
      h.contains('fiyat-rehberi') ||
      h.contains('medical-travel') ||
      h.contains('medicaltravel')) {
    return true;
  }
  return false;
}

/// Research / news / content hosts that are never a clinic official site.
bool looksLikeNonClinicContentHost(String rawHostOrUrl) {
  final h = normalizeExploreHost(rawHostOrUrl);
  if (h.isEmpty) return false;
  const needles = <String>[
    'veeva.com',
    'clinicaltrials.gov',
    'clinicaltrial',
    'pubmed.ncbi',
    'nih.gov',
    'wikipedia.org',
    'wikimedia.org',
    'reddit.com',
    'quora.com',
    'medium.com',
    'youtube.com',
    'youtu.be',
    'facebook.com',
    'instagram.com',
    'tiktok.com',
    'linkedin.com',
    'news.',
    'bloomberg.com',
    'reuters.com',
    'trendyol.com',
    'turkeymedicals.',
    'turkeybeautyguide.',
    'healthyturkiye.',
    'medicaltravelcost.',
    'clinicbooking.',
    'medifyr.',
    // Food delivery / classifieds ranked for "zmadhim gjiri" / breast pump.
    'wolt.com',
    'merrjep.al',
    'merrjep.com',
    'glovoapp.com',
    'glovo.com',
    'bolt.eu',
    'food.bolt.eu',
    'ubereats.com',
    'olx.al',
    'olx.com',
    'njoftime.com',
    // Newsrooms and statistics offices that rank for "price" queries.
    'versus.al',
    'cna.al',
    'shqiptarja.com',
    'topalbaniaradio.com',
    'tvklan.al',
    'instat.gov.al',
    'agroalbania.al',
  ];
  for (final n in needles) {
    if (h == n || h.endsWith('.$n') || h.contains(n)) return true;
  }
  return false;
}

/// An investigation or news story is not a clinic price page.
bool exploreSourceIsNewsReport(String rawUrl) {
  final text = rawUrl.trim();
  if (text.isEmpty) return false;
  final withScheme = text.contains('://') ? text : 'https://$text';
  final uri = Uri.tryParse(withScheme);
  if (uri == null) return false;
  const segments = {
    'unpublished',
    'artikull',
    'article',
    'articles',
    'lajme',
    'news',
    'opinion',
  };
  for (final part in uri.pathSegments) {
    final segment = part.toLowerCase();
    if (segment.isEmpty) continue;
    if (segments.contains(segment)) return true;
  }
  return false;
}

/// News articles and content sites cannot stay on a Compare card.
bool exploreListedPriceIsNonClinicContent({
  String sourceUrl = '',
  String website = '',
}) {
  if (exploreSourceIsNewsReport(sourceUrl) ||
      exploreSourceIsNewsReport(website)) {
    return true;
  }
  if (looksLikeNonClinicContentHost(sourceUrl) ||
      looksLikeNonClinicContentHost(website)) {
    return true;
  }
  return false;
}

/// SERP titles that are procedure names, not clinics ("Dermal Fillers").
bool looksLikeProcedureNameAsClinicIdentity(String name) {
  final t = foldExploreIdentityText(name).trim();
  if (t.isEmpty) return false;
  if (RegExp(
    r'^(?:dermal\s+)?fillers?$'
    r'|^(?:lip|cheek|jaw|chin)\s+fillers?$'
    r'|^botox(?:\s+treatment|\s+injection|\s+injections)?$'
    r'|^anti[\s-]?wrinkle(?:\s+injection|\s+injections)?$'
    r'|^toxina\s+botulinica$'
    r'|^chemical\s+peels?$'
    r'|^laser\s+hair\s+removal$'
    r'|^rhinoplasty$'
    r'|^breast\s+augmentation$'
    r'|^breast\s+implants?$'
    r'|^breast\s+prosthesis(?:\b.*)?$'
    r'|^zmadhim\s+gjiri(?:\b.*)?$'
    r'|^mamoplastika(?:\b.*)?$'
    r'|^procedures?\s+in\s+\w+'
    r'|^hair\s+transplant$'
    r'|^fat\s+transfer$'
    r'|^areola\s+reduction$'
    r'|^smile\s+makeover$'
    r'|^tooth\s+jewellery$'
    r'|^tooth\s+jewelry$'
    r'|^periodontitis(?:\s+doctors?(?:\s+abroad)?)?$',
  ).hasMatch(t)) {
    return true;
  }
  // Classified listing chrome / breast-pump product SERP titles.
  if (RegExp(
    r'(ne\s+shitje|kerkohet|me\s+qera|pompe?\s+gjiri|breast\s+pump|'
    r'for\s+sale|wanted\s+ads?)',
  ).hasMatch(t)) {
    return true;
  }
  // Turkish / SEO procedure headlines used as SERP titles:
  // "Ankara Botoks Fiyatları 2026", "Kalıcı Botoks Fiyatları".
  final hasPriceWord = RegExp(
    r'(fiyat|fiyati|fiyatlari|ucret|ucreti|ucretleri|maliyet|'
    r'price|prices|cost|costs|pret|precio|precios|cmim|cmimet)',
  ).hasMatch(t);
  final hasClinicMarker = RegExp(
    r'(clinic|clinica|klinik|hastane|hospital|doctor|dr\.?|doc\.?|'
    r'op\.?\s*dr|centre|center|salon|estetik merkezi|spital)',
  ).hasMatch(t);
  final hasProcedureCue = RegExp(
    r'(botoks|botox|botulinum|kirisiklik|dolgu|filler|rinoplasti|'
    r'rhinoplast|burun estet|meme buyut|gogus buyut|implant|'
    r'sac ekimi|hair transplant|kalici botoks|breast|zmadhim|'
    r'mamoplast|prosthesis)',
  ).hasMatch(t);
  final hasYearOrCityLead = RegExp(
    r'(20\d{2}|ankara|istanbul|izmir|antalya|bursa|london|paris|'
    r'dubai|bucharest|bucuresti|tirane|tirana)',
  ).hasMatch(t);
  if (hasPriceWord && hasProcedureCue && !hasClinicMarker) return true;
  if (hasPriceWord && hasYearOrCityLead && !hasClinicMarker) return true;
  // "Breast prosthesis at Family Hospital partner of Albania Doctor" —
  // procedure lead + partner/directory phrasing, not a clinic brand.
  if (RegExp(
        r'^(?:breast|zmadhim|mamoplast|prosthes)',
      ).hasMatch(t) &&
      RegExp(r'\b(partner|of\s+albania|read\s+\d+\s+review)\b').hasMatch(t)) {
    return true;
  }
  return false;
}

String marketplacePlatformLabel(String rawHostOrName) {
  final host = normalizeExploreHost(rawHostOrName);
  final packed = packedCanonicalClinicName(rawHostOrName);
  const labels = <String, String>{
    'clinicpoint': 'ClinicPoint',
    'whatclinic': 'WhatClinic',
    'bookimed': 'Bookimed',
    'qunomedical': 'Qunomedical',
    'treatwell': 'Treatwell',
    'groupon': 'Groupon',
    'doctoralia': 'Doctoralia',
    'topdoctors': 'TopDoctors',
    'saludestetica': 'SaludEstetica',
    'estheticon': 'Estheticon',
    'fresha': 'Fresha',
    'booksy': 'Booksy',
    'hirefrederick': 'Hirefrederick',
    'studio24': 'Studio24',
    'medigence': 'MediGence',
    'mediglobus': 'MediGlobus',
    'salonsindubai': 'Salons in Dubai',
    'getclearbeauty': 'Get Clear Beauty',
  };
  for (final entry in labels.entries) {
    if (host.contains(entry.key) || packed.contains(entry.key)) {
      return entry.value;
    }
  }
  return host.isEmpty ? rawHostOrName.trim() : host;
}

String foldExploreIdentityText(String raw) {
  final nfd = raw.replaceAll('\u00a0', ' ').trim().toLowerCase();
  const from = 'áàäâãåéèëêíìïîóòöôõúùüûñçýăâîșşțţğı';
  const to = 'aaaaaaeeeeiiiiooooouuuuncyaaissttgi';
  final buf = StringBuffer();
  for (final rune in nfd.runes) {
    final ch = String.fromCharCode(rune);
    final i = from.indexOf(ch);
    buf.write(i >= 0 ? to[i] : ch);
  }
  return buf.toString().replaceAll('ı', 'i').replaceAll('İ', 'i');
}

String packedCanonicalClinicName(String raw) {
  var packed = foldExploreIdentityText(
    raw,
  ).replaceAll(RegExp(r'[^a-z0-9]+'), '');
  if (packed.isEmpty) return '';
  var changed = true;
  while (changed) {
    changed = false;
    for (final token in _kGenericNameTokens) {
      if (packed.length <= token.length + 3) continue;
      if (packed.startsWith(token)) {
        packed = packed.substring(token.length);
        changed = true;
      } else if (packed.endsWith(token)) {
        packed = packed.substring(0, packed.length - token.length);
        changed = true;
      }
    }
  }
  return packed;
}

String spacedCanonicalClinicName(String raw) {
  var name = foldExploreIdentityText(raw)
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final kept = <String>[];
  for (final part in name.split(' ')) {
    if (part.isEmpty) continue;
    if (_kGenericNameTokens.contains(part)) continue;
    kept.add(part);
  }
  final spaced = kept.join(' ').trim();
  return spaced.isEmpty ? name : spaced;
}

bool isMarketplaceBrandName(String name) {
  final spaced = spacedCanonicalClinicName(name);
  final packed = packedCanonicalClinicName(name);
  final folded = foldExploreIdentityText(name).trim();
  if (kExploreMarketplaceBrandTokens.contains(folded) ||
      kExploreMarketplaceBrandTokens.contains(spaced) ||
      kExploreMarketplaceBrandTokens.contains(packed)) {
    return true;
  }
  for (final token in kExploreMarketplaceBrandTokens) {
    final compact = token.replaceAll(' ', '');
    if (packed == compact) return true;
    if (folded == token || folded == '$token.com') return true;
  }
  return false;
}

bool isGenericShopIdentity(String name) {
  final folded = foldExploreIdentityText(name)
      .replaceAll(RegExp(r'[^a-z0-9 ]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (folded.isEmpty) return true;
  if (kExploreGenericShopNames.contains(folded)) return true;
  final tokens = folded.split(' ');
  const trivial = {
    'the',
    'el',
    'la',
    'de',
    'del',
    'online',
    'oficial',
    'official',
    'barcelona',
    'madrid',
    'valencia',
    'shop',
    'store',
    'tienda',
    'boutique',
    'outlet',
  };
  final meaningful = [
    for (final t in tokens)
      if (!trivial.contains(t)) t,
  ];
  if (meaningful.isEmpty) return true;
  if (meaningful.length == 1 &&
      kExploreGenericShopNames.contains(meaningful.first)) {
    return true;
  }
  return false;
}

/// Barber / nail / hair-salon businesses are not aesthetic clinics.
/// A med-spa that happens to mention "barber" plus clinic/aesthetic cues stays.
bool looksLikeNonAestheticVenueName(String name) {
  final n = foldExploreIdentityText(name)
      .replaceAll(RegExp(r'[^a-z0-9 ]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (n.isEmpty) return false;
  const medicalCue = {
    'clinic',
    'clinica',
    'clinique',
    'aesthetic',
    'esthetic',
    'estetic',
    'cosmetic',
    'plastic',
    'dermat',
    'botox',
    'filler',
    'inject',
    'medical',
    'medspa',
    'doctor',
    'surgery',
    'chirurgie',
  };
  final hasMedicalCue = medicalCue.any((cue) => n.contains(cue));
  if (RegExp(r'\b(barber|barbershop|frizer|frizerie)\b').hasMatch(n) &&
      !hasMedicalCue) {
    return true;
  }
  if (RegExp(r'\b(nail salon|lash bar|lash lounge)\b').hasMatch(n) &&
      !hasMedicalCue) {
    return true;
  }
  if (RegExp(r'\bhair salon\b').hasMatch(n) && !hasMedicalCue) {
    return true;
  }
  return false;
}

/// Listing owner from a booking or directory URL. Empty = not a venue page.
String marketplaceListingBusinessNameFromUrl(String sourceUrl) {
  final host = normalizeExploreHost(sourceUrl);
  if (host.isEmpty) return '';
  if (host.contains('hirefrederick')) {
    return _directoryListingBusinessName(sourceUrl);
  }
  if (!host.contains('booksy')) return '';
  Uri? uri;
  try {
    uri = Uri.parse(
      sourceUrl.contains('://') ? sourceUrl : 'https://$sourceUrl',
    );
  } catch (_) {
    return '';
  }
  final path = uri.path;
  final m = RegExp(
    r'/(\d+)_([a-z0-9-]+)_([a-z0-9-]+)(?:_|/|\?|$)',
    caseSensitive: false,
  ).firstMatch(path);
  if (m == null) return '';
  final slug = (m.group(2) ?? '').trim();
  if (slug.isEmpty) return '';
  return _titleCaseHyphenSlug(slug);
}

bool marketplaceListingCategoryIsNonAesthetic(String sourceUrl) {
  final host = normalizeExploreHost(sourceUrl);
  if (host.isEmpty || !host.contains('booksy')) return false;
  Uri? uri;
  try {
    uri = Uri.parse(
      sourceUrl.contains('://') ? sourceUrl : 'https://$sourceUrl',
    );
  } catch (_) {
    return false;
  }
  final m = RegExp(
    r'/(\d+)_([a-z0-9-]+)_([a-z0-9-]+)(?:_|/|\?|$)',
    caseSensitive: false,
  ).firstMatch(uri.path);
  final category = (m?.group(3) ?? '').toLowerCase();
  return _kNonAestheticMarketplaceCategories.contains(category);
}

/// hirefrederick.com/repeat-fitness-and-wellness-club-tirana → the business.
String _directoryListingBusinessName(String sourceUrl) {
  Uri? uri;
  try {
    uri = Uri.parse(
      sourceUrl.contains('://') ? sourceUrl : 'https://$sourceUrl',
    );
  } catch (_) {
    return '';
  }
  final segments = [
    for (final part in uri.pathSegments)
      if (part.trim().isNotEmpty) part.trim(),
  ];
  if (segments.isEmpty) return '';
  var words = segments.first.split('-').where((w) => w.isNotEmpty).toList();
  const place = {
    'tirana',
    'tirane',
    'tiranae',
    'albania',
    'shqiperi',
    'shqiperia',
  };
  if (words.isNotEmpty && place.contains(words.last.toLowerCase())) {
    words = words.sublist(0, words.length - 1);
  }
  if (words.length < 2) return '';
  final titled = _titleCaseHyphenSlug(words.join('-'));
  if (isMarketplaceBrandName(titled) || looksLikeNonAestheticVenueName(titled)) {
    return '';
  }
  return titled;
}

String _titleCaseHyphenSlug(String slug) {
  return slug
      .split('-')
      .where((w) => w.isNotEmpty)
      .map((w) {
        final lo = w.toLowerCase();
        if (lo == 'md' || lo == 'pa' || lo == 'do') return lo.toUpperCase();
        return '${lo[0].toUpperCase()}${lo.substring(1)}';
      })
      .join(' ');
}

/// Scraped menu/SEO copy stored as a clinic name ("Cost $3500",
/// "Starts at $3000"). Never a Google Places business.
bool looksLikePriceQuotedClinicName(String raw) {
  final t = decodeExploreHtmlEntities(raw).replaceAll('\u00a0', ' ').trim();
  if (t.isEmpty) return false;
  if (looksLikeBarePriceLabel(t)) return true;
  final lower = t.toLowerCase();
  if (RegExp(
    r'\b(cl[ií]nica|clinic|doctor|dra?\.?|hospital|centre|center|salon|medspa)\b',
    caseSensitive: false,
  ).hasMatch(lower)) {
    return false;
  }
  final money = RegExp(
    r'[$£€]|aed|usd|eur|gbp|ron|lei|\d',
    caseSensitive: false,
  ).hasMatch(t);
  if (!money) return false;
  if (RegExp(
    r'^(?:cost|costs|price|prices|from|starting(?:\s+(?:at|from))?|'
    r'starts\s+(?:at|from)|desde|de la)\b',
    caseSensitive: false,
  ).hasMatch(t)) {
    return true;
  }
  return t.length <= 48 && RegExp(r'[$£€]\s*[\d.,]+').hasMatch(t);
}

/// Promo titles, marketplace-as-provider, and generic shop names.
String? clinicIdentityRejectReason(
  String name, {
  String websiteHost = '',
  String providerClinic = '',
  String sourceType = '',
}) {
  final t = name.replaceAll('\u00a0', ' ').trim();
  if (t.isEmpty) return 'invalid_identity';
  if (looksLikeProcedureNameAsClinicIdentity(t)) {
    return 'procedure_name_not_clinic';
  }
  if (looksLikeNonClinicContentHost(websiteHost) ||
      looksLikeNonClinicContentHost(t)) {
    return 'non_clinic_content_host';
  }
  final lower = t.toLowerCase();
  if (RegExp(
    r'^\d[\d.,\s]*\s*(?:€|£|\$|%|aed|eur|gbp|ron|lei|درهم|د\.إ)?\s*$',
    caseSensitive: false,
  ).hasMatch(t)) {
    return 'invalid_identity';
  }
  if (looksLikeBarePriceLabel(t) ||
      looksLikeSeoQuotedPriceHeadline(t) ||
      looksLikePriceQuotedClinicName(t)) {
    return 'invalid_identity';
  }
  if (RegExp(r'hasta un\s+\d+\s*%').hasMatch(lower)) return 'invalid_identity';
  // Promo chrome must never become the clinic card title ("56% OFF").
  if (RegExp(r'^\s*\d+[\d.,]*\s*%\s*off\b').hasMatch(lower) ||
      RegExp(
        r'^\s*(?:up\s+to\s+)?\d+[\d.,]*\s*%\s*(?:off|descuento|reducere)\b',
      ).hasMatch(lower) ||
      RegExp(r'^\s*(?:sale|offer|promo|discount)\s*!?\s*$').hasMatch(lower)) {
    return 'invalid_identity';
  }
  if (lower.contains('dto.') ||
      lower.contains('dto ') ||
      lower.endsWith('dto')) {
    if (!RegExp(
      r'\b(cl[ií]nica|clinic|doctor|dr\.?|centre|center)\b',
    ).hasMatch(lower)) {
      return 'invalid_identity';
    }
  }
  if (RegExp(
    r'\b(oferta especial|special offer|best .+ prices?)\b',
  ).hasMatch(lower)) {
    return 'invalid_identity';
  }
  if (RegExp(r'pre[tț]\s*20\d{2}').hasMatch(lower)) {
    return 'invalid_identity';
  }
  if (RegExp(
        r'\b(precio|precios|price|prices|cost|costs|pret|preț|preturi|tarife|'
        r'fiyat|fiyatı|fiyatları|fiyatlari|ücret|ucret|ücretleri|ucretleri)\b',
      ).hasMatch(lower) &&
      !RegExp(
        r'\b(cl[ií]nica|clinic|doctor|hospital|centre|center|salon|klinik|hastane)\b',
      ).hasMatch(lower)) {
    return 'invalid_identity';
  }
  if (RegExp(
        r'\b(botox|filler|labios|buze|peel|laser|rinoplast|hialuronic)\b',
        caseSensitive: false,
      ).hasMatch(lower) &&
      RegExp(r'\b(desde|from|de la)\s*\d').hasMatch(lower)) {
    return 'invalid_identity';
  }
  if (isGenericShopIdentity(t)) return 'generic_business_name';
  if (looksLikeNonAestheticVenueName(t)) return 'wrong_business_type';
  // SERP / menu CTAs — never clinic card titles.
  if (RegExp(
    r'^(?:book\s+now|our\s+pricing|our\s+prices|price\s+list|pricing|'
    r'prices?|tariffs?|book\s+online|learn\s+more|read\s+more|'
    r'view\s+prices?|see\s+prices?|what\s+to\s+pay|how\s+much|'
    r'cost\s+of\b.*|how\s+much\s+does\b.*)$',
    caseSensitive: false,
  ).hasMatch(lower)) {
    return 'invalid_identity';
  }
  // Article / guide H1s scraped as the clinic name (familybeautyal.com).
  if (RegExp(
    r'^(?:what\s+to\s+pay|how\s+much(?:\s+does|\s+is)?|cost\s+guide|'
    r'pricing\s+guide|complete\s+guide)\b',
    caseSensitive: false,
  ).hasMatch(lower)) {
    return 'invalid_identity';
  }
  if (isMarketplaceBrandName(t)) return 'marketplace_without_provider';
  if (looksLikeMarketEstimateDirectoryUrl(websiteHost) ||
      looksLikeMarketEstimateDirectoryUrl(t)) {
    return 'market_estimate';
  }
  final host = normalizeExploreHost(websiteHost);
  final marketplaceHost = host.isNotEmpty && isMarketplaceOrDirectoryHost(host);
  final provider = providerClinic.trim();
  final providerOk =
      provider.isNotEmpty &&
      !isMarketplaceBrandName(provider) &&
      !isGenericShopIdentity(provider) &&
      !looksLikeNonAestheticVenueName(provider);
  if (marketplaceHost && !providerOk) {
    return 'marketplace_without_provider';
  }
  if ((sourceType == 'marketplace' || sourceType == 'aggregator') &&
      !providerOk) {
    return 'marketplace_without_provider';
  }
  return null;
}

bool isInvalidClinicIdentity(String name) =>
    clinicIdentityRejectReason(name) != null;

bool isUsableExploreClinicIdentity({
  required String name,
  String websiteHost = '',
  String providerClinic = '',
  String sourceType = '',
}) {
  return clinicIdentityRejectReason(
        name,
        websiteHost: websiteHost,
        providerClinic: providerClinic,
        sourceType: sourceType,
      ) ==
      null;
}

/// Best-effort clinic label from an official host when the SERP title is a
/// procedure/SEO headline (e.g. "Ankara Botoks Fiyatları" → "Drserkanozturk").
String exploreClinicDisplayNameFromHost(String rawHostOrUrl) {
  final host = normalizeExploreHost(rawHostOrUrl);
  if (host.isEmpty || isMarketplaceOrDirectoryHost(host)) return '';
  if (looksLikeNonClinicContentHost(host)) return '';
  var base = host.split('.').first.trim();
  if (base.startsWith('www')) {
    final parts = host.split('.');
    base = parts.length > 1 ? parts[parts.length - 2] : base;
  }
  // Prefer registrable label: drserkanozturk.com.tr → drserkanozturk
  final labels = host.split('.');
  if (labels.length >= 3 &&
      (labels[labels.length - 1] == 'tr' ||
          labels[labels.length - 1] == 'uk' ||
          labels[labels.length - 1] == 'au')) {
    base = labels[labels.length - 3];
  } else if (labels.length >= 2) {
    base = labels[labels.length - 2];
  }
  base = base.replaceAll(RegExp(r'[^a-zA-Z0-9]+'), ' ').trim();
  if (base.length < 3) return '';
  final titled = base
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .map((w) => '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}')
      .join(' ');
  if (clinicIdentityRejectReason(titled, websiteHost: host) != null) {
    return '';
  }
  return titled;
}

/// Extract a provider clinic name from marketplace HTML. Empty = not reliable.
String extractMarketplaceProviderName(
  String html, {
  String sourceUrl = '',
  String marketplaceName = '',
}) {
  // Booksy URL slug is the listing owner. Nearby businesses in the same
  // HTML must never steal the quote.
  final fromUrl = marketplaceListingBusinessNameFromUrl(sourceUrl);
  if (fromUrl.isNotEmpty) {
    if (marketplaceListingCategoryIsNonAesthetic(sourceUrl) ||
        looksLikeNonAestheticVenueName(fromUrl) ||
        clinicIdentityRejectReason(fromUrl) != null) {
      return '';
    }
    return fromUrl;
  }
  final host = normalizeExploreHost(sourceUrl);
  if (host.contains('fresha')) {
    final fromFresha = _freshaProviderNameFromHtml(html, sourceUrl: sourceUrl);
    if (fromFresha.isNotEmpty) return fromFresha;
  }
  if (html.trim().isEmpty) return '';
  final raw = html.replaceAll(RegExp(r'\s+'), ' ');
  final candidates = <String>[];

  void consider(String value) {
    final t = decodeExploreHtmlEntities(value).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.length < 4 || t.length > 80) return;
    if (isMarketplaceBrandName(t) || isGenericShopIdentity(t)) return;
    if (clinicIdentityRejectReason(t) != null) return;
    if (!RegExp(
      r'\b(cl[ií]nica|clinic|doctor|dra?\.?|centro|centre|center|hospital)\b',
      caseSensitive: false,
    ).hasMatch(t)) {
      // Still allow proper-looking multi-word clinic names.
      if (t.split(' ').length < 2) return;
    }
    candidates.add(t);
  }

  for (final m in RegExp(
    r'"(?:clinicName|clinic_name|providerName|provider_name|businessName)"\s*:\s*"([^"]{4,80})"',
    caseSensitive: false,
  ).allMatches(raw)) {
    consider(m.group(1) ?? '');
  }

  for (final m in RegExp(
    r'itemprop=["'
    "'"
    r']name["'
    "'"
    r'][^>]*>\s*([^<]{4,80})',
    caseSensitive: false,
  ).allMatches(raw)) {
    consider(m.group(1) ?? '');
  }

  for (final m in RegExp(
    r'(?:cl[ií]nica|clinic|doctor(?:a)?|dra?\.?)\s+[A-ZÁÉÍÓÚÑ][\wÁÉÍÓÚÑáéíóúñ'
    "'"
    r'’.\-\s]{2,50}',
  ).allMatches(raw)) {
    consider(m.group(0) ?? '');
  }

  final filtered = <String>[];
  final seen = <String>{};
  for (final c in candidates) {
    final key = packedCanonicalClinicName(c);
    if (key.isEmpty || !seen.add(key)) continue;
    if (marketplaceName.isNotEmpty &&
        packedCanonicalClinicName(c) ==
            packedCanonicalClinicName(marketplaceName)) {
      continue;
    }
    filtered.add(c);
  }
  if (filtered.isEmpty) return '';
  filtered.sort((a, b) => b.length.compareTo(a.length));
  return filtered.first.trim();
}

/// Fresha venue owner from `<title>` / JSON-LD — never the platform brand.
String _freshaProviderNameFromHtml(String html, {String sourceUrl = ''}) {
  String clean(String raw) {
    var t = decodeExploreHtmlEntities(raw).replaceAll('\u00a0', ' ').trim();
    if (t.isEmpty) return '';
    t = t
        .replaceAll(
          RegExp(r'\s*[|\-–—]\s*fresha\s*$', caseSensitive: false),
          '',
        )
        .trim();
    for (var i = 0; i < 4; i++) {
      final m = RegExp(r'\s+[|\-–—]\s+.+$').firstMatch(t);
      if (m == null) break;
      final head = t.substring(0, m.start).trim();
      if (head.length < 3) break;
      final tail = m.group(0)!.toLowerCase();
      if (!RegExp(
        r'tiran|rruga|street|road|avenue|blvd|pallati|near|'
        r'albania|fresha|\d{3,}|,',
        caseSensitive: false,
      ).hasMatch(tail)) {
        break;
      }
      t = head;
    }
    if (isMarketplaceBrandName(t) || clinicIdentityRejectReason(t) != null) {
      return '';
    }
    return t.length >= 3 ? t : '';
  }

  final title = RegExp(
    r'<title[^>]*>([^<]{3,120})</title>',
    caseSensitive: false,
  ).firstMatch(html);
  final fromTitle = clean(title?.group(1) ?? '');
  if (fromTitle.isNotEmpty) return fromTitle;

  final ldName = RegExp(
    r'"@type"\s*:\s*(?:\[[^\]]*HealthAndBeautyBusiness[^\]]*\]|"BeautySalon")'
    r'[\s\S]{0,400}?"name"\s*:\s*"([^"]{3,120})"',
    caseSensitive: false,
  ).firstMatch(html);
  final fromLd = clean(ldName?.group(1) ?? '');
  if (fromLd.isNotEmpty) return fromLd;

  // Last resort: /a/slug tokens before the city/address suffix.
  final m = RegExp(
    r'fresha\.com/(?:[a-z]{2}(?:-[a-z]{2})?/)?a/([a-z0-9][a-z0-9\-]+)',
    caseSensitive: false,
  ).firstMatch(sourceUrl);
  if (m != null) {
    final parts = m.group(1)!.toLowerCase().split('-');
    final kept = <String>[];
    for (final p in parts) {
      if (p.length >= 6 && RegExp(r'\d').hasMatch(p)) break;
      if ({'tirane', 'tirana', 'rruga', 'albania', 'al'}.contains(p)) break;
      kept.add(p);
      if (kept.length >= 3) break;
    }
    if (kept.length >= 2) {
      final titled = kept
          .map((w) => '${w[0].toUpperCase()}${w.substring(1)}')
          .join(' ');
      if (clinicIdentityRejectReason(titled) == null) return titled;
    }
  }
  return '';
}

bool looksLikeRealTreatmentLabel(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').trim();
  if (t.isEmpty) return false;
  if (looksLikeRawScrapedProcedureTitle(t)) return false;
  return _procedureKeyword.hasMatch(t);
}

/// Clinic pages often store `Dr L&#39;Art` in `<title>` — decode before display.
String decodeExploreHtmlEntities(String raw) {
  var t = raw.replaceAll('\u00a0', ' ');
  t = t
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&#39;', "'")
      .replaceAll('&#x27;', "'")
      .replaceAll('&#x2F;', '/');
  t = t.replaceAllMapped(RegExp(r'&#(\d{1,7});'), (m) {
    final n = int.tryParse(m.group(1)!);
    if (n == null || n <= 0 || n > 0x10FFFF) return m.group(0)!;
    return String.fromCharCode(n);
  });
  t = t.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]{1,6});'), (m) {
    final n = int.tryParse(m.group(1)!, radix: 16);
    if (n == null || n <= 0 || n > 0x10FFFF) return m.group(0)!;
    return String.fromCharCode(n);
  });
  return t;
}

bool looksLikeRawScrapedProcedureTitle(String raw) {
  final t = decodeExploreHtmlEntities(raw).replaceAll('\u00a0', ' ').trim();
  if (t.isEmpty) return false;
  if (looksLikeFinancingOrPaymentHeading(t)) return true;
  if (looksLikeComplicationOrAftercareHeading(t)) return true;
  if (looksLikeSeoCostPageHeading(t)) return true;
  if (looksLikePriceMenuHeadingOnly(t)) return true;
  // FAQ / SEO headings scraped as the "treatment" name
  // ("How much does lip augmentation cost?").
  if (t.endsWith('?') || t.endsWith('؟')) return true;
  if (RegExp(
    r'^(how|what|why|when|where|which|is|are|does|do|can|'
    r'c[aâ]t|cu[aá]nto)\b',
    caseSensitive: false,
  ).hasMatch(t)) {
    return true;
  }
  // Arabic letters are not \w, so these need their own anchored check.
  if (_kArabicQuestionStart.hasMatch(t)) return true;
  if (RegExp(
    r'\b(how much|what is the cost|c[aâ]t cost[aă]|'
    r'cu[aá]nto cuesta|cat costa)\b|'
    r'(كم يكلف|كم تكلفة|كم سعر|ما هي تكلفة)',
    caseSensitive: false,
  ).hasMatch(t)) {
    return true;
  }
  // "Cost of 500 FUE grafts" is a menu row, not an SEO question.
  if (RegExp(r'\bcost of\b', caseSensitive: false).hasMatch(t) &&
      !looksLikeHairGraftPackageMenuLabel(t)) {
    return true;
  }
  if (looksLikeSeoQuotedPriceHeadline(t) || looksLikeSearchQuickFactsBlob(t)) {
    return true;
  }
  // Clinic marketing copy leaked as the menu name
  // ("Wrinkle relaxers are priced per unit — Dysport and Xeomin").
  if (looksLikePricingProseProcedureTitle(t)) return true;
  // `<title>` SEO: "Anti-Wrinkle Injections London | Botox | Dr L'Art Clinic"
  if (t.contains('|')) return true;
  if (RegExp(
    r'^(achieve|discover|experience|welcome|enjoy|unlock|reveal)\b',
    caseSensitive: false,
  ).hasMatch(t)) {
    return true;
  }
  if (RegExp(r'\bwith\b.+\btreatments?\b', caseSensitive: false).hasMatch(t)) {
    return true;
  }
  if (t.length > 70) return true;
  if (RegExp(r'\d{1,2}[\/.\-]\d{1,2}[\/.\-]\d{2,4}').hasMatch(t)) return true;
  if (_monthCue.hasMatch(t) && RegExp(r'\d{4}').hasMatch(t)) return true;
  if (RegExp(
    r'\b(opini[oó]n|review|comentario|hace\s+\d+|pinchazos|magia en)\b',
    caseSensitive: false,
  ).hasMatch(t)) {
    return true;
  }
  final words = t.split(RegExp(r'\s+'));
  if (words.length >= 8 && !_procedureKeyword.hasMatch(t)) return true;
  if (words.length >= 4 &&
      !_procedureKeyword.hasMatch(t) &&
      RegExp(r'[.!?…]').hasMatch(t)) {
    return true;
  }
  return false;
}

/// Body copy about how the clinic prices Botox — never a card heading.
bool looksLikePricingProseProcedureTitle(String raw) {
  final t = decodeExploreHtmlEntities(raw).replaceAll('\u00a0', ' ').trim();
  if (t.isEmpty) return false;
  return RegExp(
    r'\b(?:precio|precios|coste|costo|promedio|desde|cu[aá]nto|entre los|'
    r'prix|tarifs?|combien|a partir|prezzo|prezzi|quanto|durchschnitt)\b|'
    r'\bare priced\b|'
    r'\bis priced\b|'
    r'\bpriced per unit\b|'
    r'\bpricing is\b|'
    r'\bour\s+\w[\w\s]{0,24}\s+pricing\b|'
    r'\bcompetitive and transparent\b|'
    r'\btransparent\.?\s*treatments\b|'
    r'\bprices? are competitive\b|'
    r'\bdepending on (?:provider|physician|doctor|practitioner) discretion\b|'
    r'\bevery\s+\d+\s+to\s+\d+\s+weeks\b|'
    // Article / marketing sentences scraped as the menu name.
    r'\bstarts? at roughly\b|'
    r'\bwith only\b|'
    r'\bin albania offers\b|'
    r'\bprice includes\b|'
    r'\bincludes 1 pair of implants\b|'
    r'\ba breast augmentation starts\b|'
    r'\bbreast augmentation in \w+ offers\b',
    caseSensitive: false,
  ).hasMatch(t);
}

bool namesLookLikeSameProvider(String a, String b) {
  final pa = packedCanonicalClinicName(a);
  final pb = packedCanonicalClinicName(b);
  if (pa.isEmpty || pb.isEmpty) return false;
  if (pa == pb) return true;
  if (pa.length >= 8 && pb.length >= 8) {
    if (pa.contains(pb) || pb.contains(pa)) return true;
  }
  return false;
}

void logExploreDiscoveryReject({
  required String reason,
  String placeId = '',
  String name = '',
}) {
  debugPrint('[GP DISCOVERY] reject=$reason · placeId=$placeId · name=$name');
}

void logExploreDiscoverySkip({
  required String reason,
  String placeId = '',
  String name = '',
  String procedure = '',
}) {
  if (name.trim().isNotEmpty && procedure.trim().isNotEmpty) {
    debugPrint(
      '[DISCOVERY SKIP] ${name.trim()} · ${procedure.trim()} · reason=$reason',
    );
    return;
  }
  debugPrint('[GP DISCOVERY] skip=$reason · placeId=$placeId · name=$name');
}

void logExploreMultiProcedureReuse({
  required String name,
  required String existingFamily,
  required String verifyingFamily,
}) {
  debugPrint(
    '[MULTI-PROCEDURE] $name · existing=$existingFamily · verifying=$verifyingFamily',
  );
}

/// Google sometimes types a plastic clinic as gym/lodging. The Maps name
/// is enough to keep it as a Places candidate; website proof still required.
bool placesNameLooksLikeMedicalClinic(String name) {
  final n = name.toLowerCase();
  final aesthetic =
      n.contains('clinic') ||
      n.contains('clinica') ||
      n.contains('clinique') ||
      // `klinik` covers Albanian klinika/klinikë, plus German, Turkish,
      // Polish, Czech, Croatian and Scandinavian spellings. Without it,
      // "Klinika Estetike Dermolife", "Klinika Vivia — Klinikë Dermo
      // Estetike" and "Klinika Dermaplus" were all rejected as
      // wrong_business_type on a Tirana peel search, which is most of the
      // aesthetic clinics in the city.
      n.contains('klinik') ||
      n.contains('клиник') ||
      n.contains('κλινικ') ||
      n.contains('chirurgie') ||
      // Albanian / Turkish surgery.
      n.contains('kirurgji') ||
      n.contains('cerrahi') ||
      n.contains('estetic') ||
      // Albanian / Turkish / Bosnian "estetike", "estetik", "estetika".
      n.contains('estetik') ||
      n.contains('aesthetic') ||
      n.contains('cosmetic') ||
      n.contains('kozmetik') ||
      n.contains('plastic') ||
      n.contains('doctor') ||
      n.contains('cabinet') ||
      n.contains('beauty') ||
      n.contains('botox') ||
      n.contains('filler') ||
      n.contains('injectable') ||
      // `derma` rather than `dermat`: Dermaplus, Dermolife, Dermo Estetike.
      n.contains('derma') ||
      // Albanian "mjekësi" / "mjekësore" (medical).
      n.contains('mjek') ||
      n.contains('laser') ||
      n.contains('medical') ||
      n.contains('med spa') ||
      n.contains('medspa');
  // "SnB Aesthetic Clinic … DENTAL Implants" is still a med-spa.
  if (RegExp(
        r'stomat|dental|dentist|farmac|unghii|manichi|frizer|barber|nail salon',
      ).hasMatch(n) &&
      !aesthetic) {
    return false;
  }
  if (aesthetic) return true;
  return RegExp(r'\bdr\.?\b').hasMatch(n) || RegExp(r'\bmed\b').hasMatch(n);
}

/// Table/H2 section titles glued onto a menu row
/// (`Procedee estetice non-invazive · Fast botox o zonă`).
bool looksLikeCatalogSectionHeading(String left) {
  final lo = left.replaceAll('\u00a0', ' ').trim().toLowerCase();
  if (lo.isEmpty) return true;
  if (looksLikeFinancingOrPaymentHeading(lo)) return true;
  if (looksLikeComplicationOrAftercareHeading(lo)) return true;
  if (looksLikeSeoCostPageHeading(lo)) return true;
  if (looksLikePriceMenuHeadingOnly(lo)) return true;
  if (looksLikeGenericInjectableCategoryHeading(lo)) return true;
  if (RegExp(r'^treatments?$').hasMatch(lo)) return true;
  if (lo.contains('?') || lo.contains('؟')) return true;
  if (_kArabicQuestionStart.hasMatch(lo)) return true;
  if (RegExp(
    r'^(how|what|why|when|where|which|is|are|does|do|can|'
    r'c[aâ]t|cu[aá]nto)\b',
    caseSensitive: false,
  ).hasMatch(lo)) {
    return true;
  }
  // RO menus use "Chirurgia …" (a) as a sticky table section, not a row.
  if (RegExp(
    r'dermatolog|dermatocosmetolog|estetic|chirurgi[ae]|surgery|'
    r'ginecolog|genital|injectabil|'
    r'procedee|proceduri|\bprocedures\b|'
    r'non[\s-]?invaz|non[\s-]?invas|'
    r'lista\s+(de\s+)?pre[tț]|'
    r'\bpre[tț]uri\b|'
    r'\bprecios\b|\bprices\b|\bpricing\b|price list|\btarifas\b|'
    r'\bmenu\b|\bmenú\b|tratamientos|'
    r'quick facts|'
    r'medical[aă]',
  ).hasMatch(lo)) {
    return true;
  }
  final letters = left.replaceAll(RegExp(r'[^A-Za-zĂÂÎȘȚăâîșț]'), '');
  return letters.length >= 10 && left == left.toUpperCase();
}

/// "Filler dermatological injections" is a table section, not a syringe row.
bool looksLikeGenericInjectableCategoryHeading(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').trim().toLowerCase();
  if (t.isEmpty) return false;
  if (RegExp(
    r'^(?:filler\s+)?dermatolog(?:ical|ice)?\s+'
    r'(?:injections?|procedures?|inject[aă]ri)|'
    r'^inject[aă]ri\s+dermatolog|'
    r'^dermatological\s+procedures?$',
    caseSensitive: false,
  ).hasMatch(t)) {
    return true;
  }
  return false;
}

/// "mărire buze, augmentare riduri, corecție volumetrică pomeți" is a bag
/// of treatments, not one menu line.
bool looksLikeLaundryListProcedureTitle(String raw) {
  final parts = raw
      .replaceAll('\u00a0', ' ')
      .split(RegExp(r'\s*,\s*'))
      .map((p) => p.trim())
      .where((p) => p.length >= 3)
      .toList();
  if (parts.length < 3) return false;
  return parts.every((p) => RegExp(r'[A-Za-zĂÂÎȘȚăâîșț]').hasMatch(p));
}

/// Keep the first named treatment from a comma-separated clinic heading.
String firstTreatmentClauseFromLaundryList(String raw) {
  if (!looksLikeLaundryListProcedureTitle(raw)) return raw.trim();
  return raw.replaceAll('\u00a0', ' ').split(RegExp(r'\s*,\s*')).first.trim();
}
