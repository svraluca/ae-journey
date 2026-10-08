import 'explore_clinic_identity.dart';
import 'explore_price_evidence.dart';
import 'explore_search_locale.dart';

/// Directories we mine for *clinic leads* — never shown as the Compare card.
/// Used for every Explore city (not Chișinău-only).
const kExploreMarketplaceDiscoveryHosts = <String>[
  'whatclinic.com',
  'bookimed.com',
  'fresha.com',
  'booksy.com',
];

/// Serper queries that hit WhatClinic / Fresha / Booksy / Bookimed for [city].
///
/// Runs beside the normal city search for any Explore location. WhatClinic and
/// Bookimed hits resolve to clinic websites; Fresha `/a/` and Booksy listing
/// URLs are bookable menus and may be scraped directly (JSON-LD offers).
List<String> exploreMarketplaceDiscoveryQueries({
  required String procedure,
  required String city,
  String pill = '',
  String topic = '',
}) {
  final c = city.trim();
  if (c.isEmpty) return const [];
  final proc = topic.trim().isNotEmpty
      ? topic.trim()
      : (procedure.trim().isNotEmpty ? procedure.trim() : pill.trim());
  if (proc.isEmpty) return const [];
  final loc = exploreCityPriceSearchTerms(c);
  final localCue = _marketplaceLocalProcedureCue(proc, loc.lang);
  // Short English token travels better on directories than long topics.
  final enCue = _marketplaceEnglishProcedureCue(proc);
  final isFiller = enCue.contains('filler') ||
      localCue.toLowerCase().contains('filler') ||
      localCue.toLowerCase().contains('hialuron') ||
      localCue.toLowerCase().contains('buze');
  return [
    '$localCue $c site:whatclinic.com',
    '$enCue $c site:fresha.com/a',
    '$enCue $c site:booksy.com',
    '$enCue $c site:bookimed.com/clinic',
    '$enCue $c site:bookimed.com',
    if (isFiller) 'dermal fillers $c site:fresha.com',
    if (isFiller)
      'juvederm OR restylane OR teosyal $c site:whatclinic.com',
  ];
}

/// Fresha venue profile (`/a/…`) — bookable service menu with JSON-LD offers.
bool exploreIsFreshaVenueUrl(String rawUrl) {
  final u = rawUrl.trim().toLowerCase();
  if (u.isEmpty) return false;
  return RegExp(
    r'fresha\.com/(?:[a-z]{2}(?:-[a-z]{2})?/)?a/[a-z0-9]',
    caseSensitive: false,
  ).hasMatch(u);
}

/// Booksy business listing (numeric id + slug), not a city search hub.
bool exploreIsBooksyListingUrl(String rawUrl) {
  final host = normalizeExploreHost(rawUrl);
  if (host.isEmpty || !host.contains('booksy')) return false;
  return marketplaceListingBusinessNameFromUrl(rawUrl).isNotEmpty;
}

/// Fresha / Booksy venue URL that can be scraped for a bookable menu.
bool exploreIsBookableMarketplaceVenueUrl(String rawUrl) {
  return exploreIsBookingPlatformVenueUrl(rawUrl);
}

/// Hosts that publish bookable clinic menus (Fresha, Booksy) — not directories.
bool isBookingPlatformHost(String rawHostOrUrl) {
  final h = normalizeExploreHost(rawHostOrUrl);
  if (h.isEmpty) return false;
  return h == 'fresha.com' ||
      h.endsWith('.fresha.com') ||
      h == 'booksy.com' ||
      h.endsWith('.booksy.com');
}

/// True for Fresha `/a/…` venue pages and Booksy business listings.
bool exploreIsBookingPlatformVenueUrl(String rawUrl) {
  return exploreIsFreshaVenueUrl(rawUrl) || exploreIsBooksyListingUrl(rawUrl);
}

/// Strip `/booking?…` deep links down to the Fresha venue root.
String exploreBookingPlatformVenueUrl(String rawUrl) {
  final raw = rawUrl.trim();
  if (raw.isEmpty) return '';
  if (exploreIsFreshaVenueUrl(raw)) {
    final m = RegExp(
      r'(https?://(?:www\.)?fresha\.com/(?:[a-z]{2}(?:-[a-z]{2})?/)?a/[a-z0-9][a-z0-9\-_]*)',
      caseSensitive: false,
    ).firstMatch(raw);
    if (m != null) {
      return m.group(1)!.replaceAll(RegExp(r'/$'), '');
    }
  }
  if (exploreIsBooksyListingUrl(raw)) {
    try {
      final uri = Uri.parse(raw.contains('://') ? raw : 'https://$raw');
      return uri.replace(query: '', fragment: '').toString().replaceAll(RegExp(r'/$'), '');
    } catch (_) {
      return raw;
    }
  }
  return '';
}

/// Clinic display name from a Fresha/Booksy SERP or page title.
String exploreBookingPlatformVenueName(String title) {
  var t = decodeExploreHtmlEntities(title).replaceAll('\u00a0', ' ').trim();
  if (t.isEmpty) return '';
  t = t
      .replaceAll(
        RegExp(
          r'^\s*(?:make an appointment at|book at|book with)\s+',
          caseSensitive: false,
        ),
        '',
      )
      .trim();
  t = t
      .replaceAll(
        RegExp(
          r'\s*[|\-–—]\s*(fresha|booksy)\s*$',
          caseSensitive: false,
        ),
        '',
      )
      .trim();
  // Fresha: "Venue - Tirana, Rruga … - Tiranë" — peel geo/address tails.
  for (var i = 0; i < 4; i++) {
    final m = RegExp(r'\s+[|\-–—]\s+.+$').firstMatch(t);
    if (m == null) break;
    final head = t.substring(0, m.start).trim();
    if (head.length < 3) break;
    final tail = m.group(0)!.toLowerCase();
    final looksGeo = RegExp(
      r'tiran|rruga|street|road|avenue|blvd|pallati|near|'
      r'albania|booksy|fresha|\d{3,}|,',
      caseSensitive: false,
    ).hasMatch(tail);
    if (!looksGeo) break;
    t = head;
  }
  if (isMarketplaceBrandName(t)) return '';
  if (t.length < 3) return '';
  return t;
}

/// Injectable volume in ml from a service label. Never invents a volume.
double? exploreInjectableVolumeMl(String raw) {
  final t = raw.replaceAll('\u00a0', ' ').trim();
  if (t.isEmpty) return null;
  final lo = t.toLowerCase();
  final isInjectable = RegExp(
    r'filler|fillers|mbush|hialuron|hyaluron|juvederm|restylane|stylage|'
    r'teosyal|botox|dysport|xeomin|toxin',
    caseSensitive: false,
  ).hasMatch(lo);
  if (!isInjectable) return null;
  final withUnit = RegExp(
    r'(\d+(?:[.,]\d+)?)\s*ml\b',
    caseSensitive: false,
  ).firstMatch(t);
  if (withUnit != null) {
    final q = double.tryParse(withUnit.group(1)!.replaceAll(',', '.'));
    if (q != null && q > 0 && q <= 20) return q;
  }
  // "LIP FILLERS 0.5" / "LIPS FILLER STYLIAGE 0.5" without ml token.
  final bare = RegExp(
    r'(?:filler|fillers|mbush\w*)\b[^0-9]{0,32}(\d+(?:[.,]\d+)?)\s*$',
    caseSensitive: false,
  ).firstMatch(t);
  if (bare != null) {
    final q = double.tryParse(bare.group(1)!.replaceAll(',', '.'));
    if (q != null && q > 0 && q < 5) return q;
  }
  return null;
}

String _marketplaceEnglishProcedureCue(String proc) {
  final p = proc.toLowerCase();
  if (p.contains('botox') || p.contains('anti-wrinkle') || p.contains('dysport')) {
    return 'botox';
  }
  if (p.contains('filler') || p.contains('juvederm') || p.contains('restylane')) {
    return 'dermal filler';
  }
  if (p.contains('peel')) return 'chemical peel';
  if (p.contains('rhino') || p.contains('nose')) return 'rhinoplasty';
  if (p.contains('breast') || p.contains('boob') || p.contains('augmentation')) {
    return 'breast augmentation';
  }
  if (p.contains('liposuction') || p.contains('lipo')) return 'liposuction';
  if (p.contains('laser hair')) return 'laser hair removal';
  return proc.trim();
}

String _marketplaceLocalProcedureCue(String proc, String lang) {
  final p = proc.toLowerCase();
  switch (lang) {
    case 'ro':
      if (p.contains('botox')) return 'botox';
      if (p.contains('filler')) return 'filler';
      if (p.contains('peel')) return 'peeling';
      if (p.contains('rhino') || p.contains('rino')) return 'rinoplastie';
      if (p.contains('breast') || p.contains('boob') || p.contains('san')) {
        return 'marire sani';
      }
      break;
    case 'es':
      if (p.contains('botox')) return 'botox';
      if (p.contains('filler')) return 'relleno';
      if (p.contains('peel')) return 'peeling';
      if (p.contains('rhino') || p.contains('rino')) return 'rinoplastia';
      if (p.contains('breast') || p.contains('boob') || p.contains('aumento')) {
        return 'aumento de pecho';
      }
      break;
    case 'it':
      if (p.contains('botox')) return 'botox';
      if (p.contains('filler')) return 'filler';
      if (p.contains('peel')) return 'peeling';
      if (p.contains('rhino') || p.contains('rino')) return 'rinoplastica';
      if (p.contains('breast') || p.contains('boob') || p.contains('seno')) {
        return 'aumento seno';
      }
      break;
    case 'tr':
      if (p.contains('botox')) return 'botoks';
      if (p.contains('filler')) return 'dolgu';
      if (p.contains('rhino') || p.contains('rino')) return 'rinoplasti';
      if (p.contains('breast') || p.contains('boob')) return 'meme buyutme';
      break;
    case 'pt':
      if (p.contains('botox')) return 'botox';
      if (p.contains('filler')) return 'preenchimento';
      if (p.contains('rhino') || p.contains('rino')) return 'rinoplastia';
      if (p.contains('breast') || p.contains('boob')) return 'aumento de mama';
      break;
    case 'fr':
      if (p.contains('botox')) return 'botox';
      if (p.contains('filler')) return 'acide hyaluronique';
      if (p.contains('rhino') || p.contains('rino')) return 'rhinoplastie';
      if (p.contains('breast') || p.contains('boob')) return 'augmentation mammaire';
      break;
    case 'de':
      if (p.contains('botox')) return 'botox';
      if (p.contains('filler')) return 'filler';
      if (p.contains('rhino') || p.contains('rino')) return 'nasenkorrektur';
      if (p.contains('breast') || p.contains('boob')) return 'brustvergroesserung';
      break;
  }
  return _marketplaceEnglishProcedureCue(proc);
}

bool exploreIsMarketplaceDiscoveryHost(String rawHostOrUrl) {
  final h = normalizeExploreHost(rawHostOrUrl);
  if (h.isEmpty) return false;
  for (final exact in kExploreMarketplaceDiscoveryHosts) {
    if (h == exact || h.endsWith('.$exact')) return true;
  }
  return isMarketplaceOrDirectoryHost(h);
}

/// Clinic display name from a WhatClinic / Bookimed SERP row.
///
/// Empty when the result is a city hub, treatment index, or the marketplace
/// brand itself (those must never become Compare cards).
String exploreClinicNameFromMarketplaceSerp({
  required String title,
  required String snippet,
  required String url,
  String city = '',
}) {
  if (exploreIsBookingPlatformVenueUrl(url) ||
      isBookingPlatformHost(url)) {
    final fromBooking = exploreBookingPlatformVenueName(title);
    if (fromBooking.isNotEmpty &&
        !isMarketplaceBrandName(fromBooking) &&
        clinicIdentityRejectReason(fromBooking) == null) {
      return fromBooking;
    }
  }
  final fromTitle = _cleanMarketplaceSerpTitle(title, city: city);
  if (fromTitle.isNotEmpty &&
      !isMarketplaceBrandName(fromTitle) &&
      clinicIdentityRejectReason(fromTitle) == null &&
      !_looksLikeMarketplaceHubTitle(fromTitle)) {
    return fromTitle;
  }

  final fromUrl = exploreClinicNameFromMarketplaceListingUrl(url, city: city);
  if (fromUrl.isNotEmpty &&
      !isMarketplaceBrandName(fromUrl) &&
      clinicIdentityRejectReason(fromUrl) == null &&
      !_looksLikeMarketplaceHubTitle(fromUrl)) {
    return fromUrl;
  }

  final snip = decodeExploreHtmlEntities(snippet).trim();
  final m = RegExp(
    r'\b((?:Clinica|Clinic|Clínica|Clinique|Klinik|Dr\.?|Doctor)\s+'
    r'[A-ZÁÉÍÓÚĂÂÎȘȚ][\w\.\-]+(?:\s+[A-ZÁÉÍÓÚĂÂÎȘȚ][\w\.\-]+){0,3})',
  ).firstMatch(snip);
  final fromSnip = (m?.group(1) ?? '').trim();
  if (fromSnip.length >= 3 &&
      !isMarketplaceBrandName(fromSnip) &&
      clinicIdentityRejectReason(fromSnip) == null) {
    return fromSnip;
  }
  return '';
}

String _cleanMarketplaceSerpTitle(String title, {String city = ''}) {
  var t = decodeExploreHtmlEntities(title).replaceAll('\u00a0', ' ').trim();
  if (t.isEmpty) return '';
  t = t
      .replaceAll(
        RegExp(
          r'\s*[|\-–—]\s*(whatclinic(?:\.com)?|bookimed(?:\.com)?|'
          r'fresha(?:\.com)?|booksy(?:\.com)?)\s*$',
          caseSensitive: false,
        ),
        '',
      )
      .replaceAll(
        RegExp(
          r'^\s*(whatclinic(?:\.com)?|bookimed(?:\.com)?|'
          r'fresha(?:\.com)?|booksy(?:\.com)?)\s*[|\-–—]\s*',
          caseSensitive: false,
        ),
        '',
      )
      .trim();
  t = t
      .replaceAll(
        RegExp(
          r'\s*[|\-–—:]\s*(prices?|reviews?|doctors?|cost|preturi|recenzii|'
          r'precios|opiniones|prezzi|avis)\b.*$',
          caseSensitive: false,
        ),
        '',
      )
      .trim();
  t = t
      .replaceAll(
        RegExp(
          r'\s+(in|at|din|en|a|à)\s+[A-ZÁÉÍÓÚĂÂÎȘȚ][\w\s\-]{1,40}$',
          caseSensitive: false,
        ),
        '',
      )
      .trim();
  // "Dr X's Clinic in Ankara, Turkey" — city + country leftover.
  t = t
      .replaceAll(
        // `\p{L}` is only a Unicode property in Unicode mode; without the
        // flag Dart reads it as a literal "p{L}" and this stops matching.
        RegExp(
          r'\s+in\s+[\p{L}][\p{L}\d\s\-]{1,40},\s*[\p{L}][\p{L}\d\s\-]{1,40}$',
          caseSensitive: false,
          unicode: true,
        ),
        '',
      )
      .trim();
  t = t
      .replaceAll(
        RegExp(
          r',\s*(?:Turkey|Türkiye|Turkiye|Romania|Moldova|Spain|Italy|'
          r'UAE|UK|USA|United States|United Kingdom)\s*$',
          caseSensitive: false,
        ),
        '',
      )
      .trim();
  // "Clinica SANCOS - Chișinău" / "AMC — Bucharest" / "Miami Plastic - Miami"
  t = t
      .replaceAll(
        // `\p{L}` needs Unicode mode — see above.
        RegExp(
          r'\s*[|\-–—]\s*[\p{L}][\p{L}\d\s\.\-]{1,40}$',
          unicode: true,
        ),
        '',
      )
      .trim();
  if (city.trim().isNotEmpty) {
    final cityRe = RegExp(
      '(?:\\s*[|\\-–—,]\\s*)?(?:\\s+(?:in|at|din|en)\\s+)?'
      '${RegExp.escape(city.trim())}\\s*\$',
      caseSensitive: false,
    );
    t = t.replaceAll(cityRe, '').trim();
  }
  if (t.length < 3 || looksLikePriceQuotedClinicName(t)) return '';
  return t;
}

bool _looksLikeMarketplaceHubTitle(String raw) {
  final t = raw.trim().toLowerCase();
  if (t.isEmpty) return true;
  return RegExp(
    r'^(find|compare|search|best|top|list|directory|clinics?|doctors?|'
    r'treatment|treatments|prices?|cost)\b',
  ).hasMatch(t);
}

/// Last meaningful slug on a marketplace clinic profile URL.
String exploreClinicNameFromMarketplaceListingUrl(
  String sourceUrl, {
  String city = '',
}) {
  final host = normalizeExploreHost(sourceUrl);
  if (host.isEmpty || !exploreIsMarketplaceDiscoveryHost(host)) return '';
  Uri? uri;
  try {
    uri = Uri.parse(
      sourceUrl.contains('://') ? sourceUrl : 'https://$sourceUrl',
    );
  } catch (_) {
    return '';
  }
  final parts = uri.path
      .split('/')
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.isEmpty) return '';

  if (host.contains('bookimed')) {
    final clinicIdx = parts.indexWhere((p) => p.toLowerCase() == 'clinic');
    if (clinicIdx >= 0 && clinicIdx + 1 < parts.length) {
      return _titleCaseMarketplaceSlug(parts[clinicIdx + 1], city: city);
    }
  }

  // Fresha: /a/joys-touch-tirane-rruga-… or /en-GB/a/…
  if (host.contains('fresha')) {
    final aIdx = parts.indexWhere((p) => p.toLowerCase() == 'a');
    if (aIdx >= 0 && aIdx + 1 < parts.length) {
      return _freshaVenueNameFromSlug(parts[aIdx + 1], city: city);
    }
  }

  if (host.contains('booksy')) {
    final fromBooksy = marketplaceListingBusinessNameFromUrl(sourceUrl);
    if (fromBooksy.isNotEmpty) return fromBooksy;
  }

  final citySlugs = _marketplaceCitySlugTokens(city);
  const skip = {
    'cosmetic-plastic-surgery',
    'dentists',
    'cosmetic',
    'plastic',
    'surgery',
    'doctors',
    'reviews',
    'prices',
    'clinics',
    'clinic',
    'en',
    'ro',
    'ru',
    'es',
    'pt',
    'fr',
    'de',
    'it',
    'tr',
    'uk',
    // Country / region path segments on WhatClinic (global).
    'moldova',
    'romania',
    'ukraine',
    'turkey',
    'spain',
    'italy',
    'france',
    'germany',
    'portugal',
    'poland',
    'greece',
    'cyprus',
    'mexico',
    'brazil',
    'argentina',
    'colombia',
    'chile',
    'peru',
    'canada',
    'australia',
    'thailand',
    'india',
    'uae',
    'dubai',
    'united-states',
    'united-kingdom',
    'usa',
    'us',
  };
  for (var i = parts.length - 1; i >= 0; i--) {
    final slug = parts[i].toLowerCase();
    if (skip.contains(slug)) continue;
    if (citySlugs.contains(slug)) continue;
    if (slug.length < 4) continue;
    if (RegExp(r'^\d+$').hasMatch(slug)) continue;
    // Likely a city/country token, not a clinic ("miami", "lisbon").
    if (RegExp(r'^[a-z]{3,20}$').hasMatch(slug) && !slug.contains('-')) {
      continue;
    }
    return _titleCaseMarketplaceSlug(parts[i], city: city);
  }
  return '';
}

Set<String> _marketplaceCitySlugTokens(String city) {
  final c = city.trim().toLowerCase();
  if (c.isEmpty) return const {};
  final folded = _foldMarketplaceAscii(c);
  final out = <String>{
    c,
    folded,
    c.replaceAll(RegExp(r'\s+'), '-'),
    folded.replaceAll(RegExp(r'\s+'), '-'),
    c.replaceAll(RegExp(r'[\s\-]+'), ''),
    folded.replaceAll(RegExp(r'[\s\-]+'), ''),
  };
  // Common aliases.
  if (folded.contains('chisinau') || folded.contains('kishinev')) {
    out.addAll({'chisinau', 'kishinev', 'chiinu'});
  }
  if (folded.contains('bucharest') || folded.contains('bucuresti')) {
    out.addAll({'bucharest', 'bucuresti'});
  }
  if (folded.contains('tiran')) {
    out.addAll({'tirane', 'tirana', 'tiran'});
  }
  return out.where((s) => s.length >= 3).toSet();
}

/// `joys-touch-tirane-rruga-dhimiter-…` → "Joys Touch"
String _freshaVenueNameFromSlug(String rawSlug, {String city = ''}) {
  var slug = rawSlug.trim().toLowerCase();
  if (slug.isEmpty) return '';
  // Drop opaque venue id suffix (last segment often 8+ alnum).
  final parts = slug.split('-').where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '';
  if (parts.last.length >= 6 && RegExp(r'^[a-z0-9]+$').hasMatch(parts.last)) {
    // Keep if it looks like a real word; drop random ids like nzu73yzx.
    if (RegExp(r'\d').hasMatch(parts.last) || parts.last.length >= 8) {
      parts.removeLast();
    }
  }
  final citySlugs = _marketplaceCitySlugTokens(city);
  const geoNoise = {
    'rruga',
    'rr',
    'street',
    'st',
    'avenue',
    'ave',
    'blvd',
    'boulevard',
    'pallati',
    'near',
    'albania',
    'al',
  };
  final kept = <String>[];
  for (final p in parts) {
    if (citySlugs.contains(p)) {
      // Stop before address / city tail once we already have a name.
      if (kept.length >= 2) break;
      continue;
    }
    if (geoNoise.contains(p)) {
      if (kept.length >= 2) break;
      continue;
    }
    // Long address fragments after the business name.
    if (kept.length >= 3 && p.length >= 6) break;
    kept.add(p);
  }
  if (kept.isEmpty) {
    return _titleCaseMarketplaceSlug(parts.take(3).join('-'), city: city);
  }
  return _titleCaseMarketplaceSlug(kept.join('-'), city: city);
}

String _foldMarketplaceAscii(String input) {
  const map = {
    'ă': 'a',
    'â': 'a',
    'á': 'a',
    'à': 'a',
    'ä': 'a',
    'ã': 'a',
    'å': 'a',
    'î': 'i',
    'í': 'i',
    'ì': 'i',
    'ï': 'i',
    'ș': 's',
    'ş': 's',
    'ț': 't',
    'ţ': 't',
    'é': 'e',
    'è': 'e',
    'ê': 'e',
    'ë': 'e',
    'ó': 'o',
    'ò': 'o',
    'ô': 'o',
    'ö': 'o',
    'õ': 'o',
    'ú': 'u',
    'ù': 'u',
    'û': 'u',
    'ü': 'u',
    'ñ': 'n',
    'ç': 'c',
    'ý': 'y',
  };
  final buf = StringBuffer();
  for (final ch in input.toLowerCase().split('')) {
    buf.write(map[ch] ?? ch);
  }
  return buf.toString();
}

String _titleCaseMarketplaceSlug(String slug, {String city = ''}) {
  var s = slug.trim().toLowerCase();
  s = s.replaceAll(RegExp(r'-(in|at|din|en)-[a-z-]{2,}$'), '');
  for (final token in _marketplaceCitySlugTokens(city)) {
    if (token.contains('-') || token.length >= 4) {
      s = s.replaceAll(RegExp('-${RegExp.escape(token)}\$'), '');
      s = s.replaceAll(RegExp('^${RegExp.escape(token)}-'), '');
    }
  }
  return s
      .split(RegExp(r'[-_]+'))
      .where((w) => w.isNotEmpty)
      .map((w) {
        if (w == 'md' || w == 'dr' || w == 'amc' || w == 'nyc') {
          return w.toUpperCase();
        }
        return '${w[0].toUpperCase()}${w.substring(1)}';
      })
      .join(' ');
}

/// Reject marketplace SERP titles before spending another Serper resolve query.
///
/// Valid leads need a plausible clinic/doctor name — not a procedure, city
/// filter, pagination row, or SEO hub headline.
String? exploreMarketplaceLeadRejectReason({
  required String title,
  required String snippet,
  required String url,
  String city = '',
}) {
  final t = decodeExploreHtmlEntities(title).replaceAll('\u00a0', ' ').trim();
  final lo = t.toLowerCase();
  final u = url.trim().toLowerCase();
  if (u.endsWith('.pdf') || u.contains('.pdf?') || u.contains('/pdf/')) {
    return 'pdf';
  }
  if (RegExp(
    r'tourism|medical-tourism|medicaltourism|health-tourism|'
    r'travel.?agency|vacation|holiday.?package',
    caseSensitive: false,
  ).hasMatch(u)) {
    return 'tourism';
  }
  if (t.isEmpty) return 'empty_title';
  if (RegExp(r'^page\s*\d+$', caseSensitive: false).hasMatch(lo)) {
    return 'pagination';
  }
  if (RegExp(
    r'^(?:city|country|direction|procedure|treatment|specialty|filter)\s*[=:]',
    caseSensitive: false,
  ).hasMatch(lo)) {
    return 'filter_param';
  }
  if (RegExp(
    r'^(?:city|country|romania|brasov|bucharest|timisoara)\s*$',
    caseSensitive: false,
  ).hasMatch(lo)) {
    return 'geo_label';
  }
  if (looksLikeProcedureNameAsClinicIdentity(t) ||
      clinicIdentityRejectReason(t) != null) {
    return 'procedure_or_invalid_identity';
  }
  if (_looksLikeMarketplaceHubTitle(t)) return 'hub_title';
  if (RegExp(
    r'\b(?:best|top)\s+clinics?\b|'
    r'\bprices?\s+and\s+reviews?\b|'
    r'\brhinoplasty\s+in\s+\w+\b|'
    r'\bdoctors?\s+abroad\b|'
    r'\bperiodontitis\b|'
    r'\btooth\s+jewell?ery\b|'
    r'\bsmile\s+makeover\b|'
    r'\bfat\s+transfer\b|'
    r'\bareola\s+reduction\b',
    caseSensitive: false,
  ).hasMatch(lo)) {
    return 'seo_or_category';
  }
  if (RegExp(
    r'\b(?:dental|dentist|orthodont|periodont|tooth|teeth)\b',
    caseSensitive: false,
  ).hasMatch(lo)) {
    return 'unrelated_specialty';
  }
  final cityFold = foldExploreCityText(city);
  if (cityFold.isNotEmpty &&
      foldExploreCityText(t) == cityFold &&
      t.split(RegExp(r'\s+')).length <= 2) {
    return 'city_only_title';
  }
  if (RegExp(
    r'^(?:tarife|preturi|prețuri|prices?|pricing|fees?|cost)$',
    caseSensitive: false,
  ).hasMatch(lo)) {
    return 'tariff_only_title';
  }
  // Require some provider-like signal in title or URL slug.
  final fromUrl = exploreClinicNameFromMarketplaceListingUrl(url, city: city);
  final providerish = RegExp(
    r'\b(?:clinic|clinica|clinique|klinik|doctor|dr\.?|centre|center|'
    r'hospital|salon|med)\b',
    caseSensitive: false,
  ).hasMatch(lo);
  if (!providerish && fromUrl.isEmpty) {
    // Short proper names without clinic token still OK if identity passes
    // and is not a single common noun.
    if (t.split(RegExp(r'\s+')).length < 2 &&
        !RegExp(r'[A-ZÁÉÍÓÚĂÂÎȘȚ]').hasMatch(t.substring(0, 1))) {
      return 'weak_provider_identity';
    }
  }
  return null;
}

/// After marketplace→website resolve, reject directories, tourism, PDFs,
/// and unrelated commercial hosts.
bool exploreMarketplaceResolvedWebsiteIsJunk(
  String website, {
  required String city,
}) {
  final u = website.trim().toLowerCase();
  if (u.isEmpty) return true;
  if (u.endsWith('.pdf') || u.contains('.pdf?')) return true;
  if (RegExp(
    r'tourism|medical-tourism|travel|vacation|holiday',
    caseSensitive: false,
  ).hasMatch(u)) {
    return true;
  }
  if (isNonLiteralClinicPriceUrl(u)) return true;
  if (exploreUrlConflictsWithSearchCity(u, city)) return true;
  final host = normalizeExploreHost(u);
  if (host.isEmpty || isMarketplaceOrDirectoryHost(host)) return true;
  if (looksLikeNonClinicContentHost(host)) return true;
  return false;
}

/// Serper query that finds the clinic's own website after a directory hit.
String exploreMarketplaceClinicWebsiteQuery({
  required String clinicName,
  required String city,
}) {
  final c = city.trim();
  if (c.isEmpty) return '';
  // Re-clean so resolve never quotes "… in Ankara, Turkey".
  var name = _cleanMarketplaceSerpTitle(clinicName, city: c);
  name = name
      .replaceAll(RegExp(r"'s\s+Clinic\b", caseSensitive: false), '')
      .replaceAll(RegExp(r'\s+Clinic\s*$', caseSensitive: false), '')
      .trim();
  if (name.length < 3) return '';
  final loc = exploreCityPriceSearchTerms(c);
  final localClinic = switch (loc.lang) {
    'tr' => 'klinik OR doktor OR hastane OR website',
    'ro' => 'clinica OR doctor OR website',
    'es' => 'clinica OR doctor OR website',
    'it' => 'clinica OR dottore OR website',
    'fr' => 'clinique OR docteur OR website',
    'de' => 'klinik OR arzt OR website',
    _ => 'clinic OR doctor OR hospital OR website',
  };
  // Short names stay quoted; longer doctor names search better unquoted.
  final tokenCount = name.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).length;
  final nameQ = tokenCount <= 4 ? '"$name"' : name;
  return '$nameQ $c ($localClinic) '
      '-site:whatclinic.com -site:bookimed.com -site:mediglobus.com '
      '-site:fresha.com -site:booksy.com -site:studio24.bg -site:doctoralia.com';
}
