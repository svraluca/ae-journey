import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';

import 'filter_currency.dart';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'explore_seed_catalog.dart';
import 'explore_curated_price_store.dart';
import 'explore_google_price_store.dart';
import 'explore_place_cache_store.dart';
import 'explore_search_locale.dart';
import 'explore_city_identity.dart';
import 'explore_serp_provider.dart';
import 'explore_renderer_client.dart';
import 'explore_firecrawl_client.dart';
import 'explore_zyte_client.dart';
import 'explore_site_url_cache_store.dart';
import 'explore_url_discovery.dart';
import 'explore_procedure_translation.dart';
import 'explore_price_verification.dart';
import 'explore_price_evidence.dart' hide isInvalidClinicIdentity;
import 'explore_price_evidence_lock.dart';
import 'explore_html_price_extractor.dart';
import 'explore_procedure_family.dart';
import 'explore_procedure_relation.dart';
import 'explore_backend_service.dart';
import 'explore_price_sanity.dart';
import 'explore_price_ownership.dart';
import 'explore_currency_tokens.dart';
import 'explore_clinic_identity.dart';
import 'explore_marketplace_discovery.dart';
import 'explore_price_discovery_tool.dart';
import 'explore_price_binding.dart';
import 'explore_compare_mix.dart';
import 'explore_comparison_session.dart';
import 'explore_discovery_state_store.dart';
import 'explore_request_coordinator.dart';
import 'explore_pipeline_config.dart';
import 'google_places_service.dart';
import 'session_prefs.dart';
import 'sanitize_utf16.dart';

/// Cheap JSON classifier for ambiguous clinic-page evidence.
const _kPriceVerifierModel = kExplorePriceVerifierModel;

/// Fallback model when web search is unavailable — cheap JSON/classify calls.
const _kFallbackClinicListModel = 'gpt-5.6-luna';

/// Web-search clinic discovery (Responses API + built-in web_search tool).
const _kWebSearchModel = 'gpt-5.6-terra';

const Duration _kClinicWebsiteProbeTimeout = Duration(seconds: 4);

/// Direct website verification jobs in flight at once.
/// Fill-to-4 needs more than two clinic pages in parallel or Laser / Fillers
/// sit on "Loading more…" while Botox already has cards.
const int _kClinicVerifyConcurrency = 4;

/// Discovery lookup budget. Timeouts skip the candidate instead of stacking
/// waits. A live DataForSEO query answers in ~1.5–3s, and the gate below can
/// add one turn of queue wait on top.
const Duration _kSerpApiTimeout = Duration(seconds: 9);

/// Soft UI deadline — release spinner; background may continue.
const Duration kExploreForegroundGoogleBudget = Duration(seconds: 3);

/// Focused-procedure hard foreground deadline. Background verification may
/// continue detached after this without holding the UI future.
const Duration kExploreForegroundFillBudget = Duration(seconds: 16);

/// Foreground Serper budget — 8–10s so two quality queries can finish
/// instead of five consecutive short timeouts.
const Duration _kForegroundSerpApiTimeout = Duration(seconds: 9);
const Duration _kForegroundPlacesTimeout = Duration(seconds: 4);

/// How this clinic was chosen for the current Compare build.
enum ExploreClinicSource { firestore, googleCache, googleLive, cachedFallback }

/// Wall-clock budget for homepage + a couple of price URLs per clinic.
const Duration _kClinicVerifyBudget = Duration(seconds: 6);

/// After a genuine large-pool miss, wait before spending APIs again.
const Duration _kTopUpRetryCooldown = Duration(minutes: 3);
const Duration _kPartialFillRetryCooldown = Duration(seconds: 20);

/// Cap discovery calls for the visible pill so Fillers is not stuck behind a
/// Botox dermatology sweep.
///
/// How many a pill can afford depends on the provider. Serper answers in ~1.4s
/// for a tenth of a cent, so breadth is cheap and the old ceiling applies. A
/// DataForSEO call costs up to a cent and has taken 30s, so a 20-query sweep
/// there produced no price at all while slowing everything behind it.
const int _kMaxSerpApiPerLiveSearch = 6;
const int _kMaxSlowProviderSerpPerLiveSearch = 4;

/// Headless renders per session, and per host. Blocked or JS-only clinic sites
/// are the only way to read their real price table, but each render costs
/// seconds of Cloud Run time.
const int _kMaxRendersPerSession = 8;
const int _kMaxRendersPerHost = 2;
const Duration _kRenderTimeout = Duration(seconds: 14);

/// User-reported or verified-dead clinic sites (hostname without scheme, no www).
const _kBlockedClinicWebsiteHosts = <String>{
  'trueglow.ro',
  'fiveclinic.ro',
  'elle.com',
  'vogue.es',
  'vogue.com',
  'hola.com',
  'telva.com',
  'cosmopolitan.com',
  'harpersbazaar.com',
  'nytimes.com',
  'theguardian.com',
  'wikipedia.org',
  'elmundo.es',
  'abc.es',
  'lavanguardia.com',
  'elpais.com',
  'timeout.com',
  'timeout.es',
  // Dictionaries and health encyclopedias ranked for "dermal filler" and were
  // verified as Dubai clinics ("DERMAL Definition & Meaning").
  'merriam-webster.com',
  'dictionary.com',
  'britannica.com',
  'clevelandclinic.org',
  'mayoclinic.org',
  'medicalnewstoday.com',
  'verywellhealth.com',
  'healthline.com',
  'webmd.com',
  'drugs.com',
  'nhs.uk',
  'aad.org',
  'plasticsurgery.org',
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

class _SerpSearchResult {
  const _SerpSearchResult({
    required this.title,
    required this.link,
    required this.snippet,
    required this.displayedLink,
  });

  final String title;
  final String link;
  final String snippet;
  final String displayedLink;
}

class _SearchPreviewTask {
  _SearchPreviewTask({
    required this.run,
    required this.completer,
    this.priority = false,
  });
  final Future<String> Function() run;
  final Completer<String> completer;
  final bool priority;
}

/// Quiet status for a discovery job that is not on the interactive request.
class ExploreBackgroundHunt {
  const ExploreBackgroundHunt({
    required this.city,
    required this.pill,
    required this.message,
    this.jobId = '',
    this.isSearching = false,
  });

  final String city;
  final String pill;
  final String message;
  final String jobId;
  final bool isSearching;
}

class OpenAIService {
  /// When true (`.env` `GP_DISABLE_CLINIC_PRELOAD=true`), skip compare-tab
  /// prewarm and trending preload only. Comparison price verification still runs.
  static bool get disableClinicPreload {
    final v = (dotenv.env['GP_DISABLE_CLINIC_PRELOAD'] ?? 'false')
        .trim()
        .toLowerCase();
    return v == 'true' || v == '1';
  }

  /// GPT-5.x / o-series Chat Completions omit sampling params (`temperature`)
  /// and use `max_completion_tokens` instead of `max_tokens`.
  static bool _chatCompletionsUsesGpt5Params(String modelName) {
    return modelName.startsWith('gpt-5') ||
        modelName.startsWith('o1') ||
        modelName.startsWith('o3') ||
        modelName.startsWith('o4');
  }

  /// GPT-5.x models require `max_completion_tokens` in Chat Completions
  /// requests; older gpt-4-family models use `max_tokens`. Centralizing
  /// this avoids silently-failing 400s if the model constant ever changes.
  static Map<String, Object?> _tokenLimitParam(
    String modelName,
    int maxTokens,
  ) {
    return _chatCompletionsUsesGpt5Params(modelName)
        ? {'max_completion_tokens': maxTokens}
        : {'max_tokens': maxTokens};
  }

  /// GPT-5.x / o-series reject `temperature` (only the default is allowed).
  /// Older gpt-4-family models still accept it.
  static Map<String, Object?> _temperatureParam(
    String modelName,
    double temperature,
  ) {
    if (_chatCompletionsUsesGpt5Params(modelName)) return const {};
    return {'temperature': temperature};
  }

  OpenAIService({
    http.Client? client,
    this.model = 'gpt-5.6-luna',
    String? apiKey,
    GooglePlacesService? places,
    String? placesApiKey,
    FirebaseFirestore? firestore,
  }) : _client = client ?? http.Client(),
       _apiKey = apiKey ?? _readKey(),
       _placesApiKey = placesApiKey ?? _readPlacesKey(),
       _places = places ?? GooglePlacesService(),
       _firestore = firestore ?? FirebaseFirestore.instance;

  /// Curated recovery when web search / AI are unavailable.
  static const Map<String, ({int value, String unit})>
  _kCuratedRecoveryByProcedure = {
    'hair transplant': (value: 6, unit: 'months'),
    'fue': (value: 6, unit: 'months'),
    'fut': (value: 6, unit: 'months'),
    'rhinoplasty': (value: 3, unit: 'weeks'),
    'blepharoplasty': (value: 2, unit: 'weeks'),
    'facelift': (value: 4, unit: 'weeks'),
    'mini facelift': (value: 2, unit: 'weeks'),
    'bbl': (value: 2, unit: 'months'),
    'brazilian butt lift': (value: 2, unit: 'months'),
    'abdominoplasty': (value: 2, unit: 'months'),
    'tummy tuck': (value: 2, unit: 'months'),
    'liposuction': (value: 1, unit: 'months'),
    'breast augmentation': (value: 6, unit: 'weeks'),
    'botox': (value: 0, unit: 'days'), // handled below
  };

  static ({int value, String unit})? _curatedRecoveryForProcedure(
    String procedureName,
  ) {
    final key = procedureName.trim().toLowerCase();
    if (key.isEmpty) return null;
    for (final entry in _kCuratedRecoveryByProcedure.entries) {
      if (key == entry.key || key.contains(entry.key)) {
        final rec = entry.value;
        if (rec.value <= 0) return (value: 3, unit: 'days');
        return rec;
      }
    }
    return null;
  }

  static ({int value, String unit}) _parseRecoveryDurationJson(String jsonStr) {
    final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
    final unit = (decoded['unit'] as String? ?? 'days').trim().toLowerCase();
    final value = (decoded['value'] as num?)?.toInt() ?? 3;
    const allowed = {'days', 'weeks', 'months', 'years'};
    return (
      unit: allowed.contains(unit) ? unit : 'days',
      value: value.clamp(1, 60),
    );
  }

  /// Suggest a recovery duration for a custom procedure.
  /// Uses web search first, then GPT, then curated fallbacks.
  /// Returns a normalized unit (`days|weeks|months|years`) and an integer value.
  Future<({int value, String unit})> suggestRecoveryDuration({
    required String procedureName,
    required String category,
  }) async {
    const system = '''
You are a medical recovery research assistant.
SEARCH THE WEB for what doctors and clinics commonly tell patients about recovery time.

Task: suggest the typical "recovery time suggested by doctor" for this aesthetic procedure.
Use the FULL recovery timeline doctors cite — not just the first few days of downtime.
Examples from medical sources:
- Hair transplant / FUE / FUT: 6-12 months until grafts settle and growth is visible (use months, typically 6)
- Rhinoplasty: 2-4 weeks initial, often 3 weeks
- Facelift: 3-6 weeks
- Injectables (Botox, filler): 0-7 days
- Major body surgery (BBL, tummy tuck): 6-12 weeks, often expressed in months

Rules:
- unit must be one of: days, weeks, months, years
- value must be an integer between 1 and 60
- base your answer on what you find from clinics and medical websites, not guesses
- hair transplant must be months (typically 6), never days or a few weeks

Return ONLY valid JSON:
{"unit":"days|weeks|months|years","value":1}
''';

    final user =
        '''
Search the web for doctor-suggested recovery duration for:
Procedure: $procedureName
Category: $category

What recovery period do clinics and surgeons commonly quote to patients?
Return JSON only.
''';

    // 1) Web search (gpt-5.6-terra + web_search) — actually browses medical sources.
    try {
      final jsonStr = await _queueSearchPreview(
        () => _chatCompletionSearchPreviewJson(
          messages: [
            {'role': 'system', 'content': system},
            {'role': 'user', 'content': user},
          ],
          maxTokens: 400,
        ),
      ).timeout(const Duration(seconds: 60));
      return _parseRecoveryDurationJson(jsonStr);
    } catch (e) {
      debugPrint('[GP] Recovery web search failed: $e');
    }

    // 2) GPT without web search.
    try {
      final jsonStr = await _openAiChatJsonCompletion(
        openAiModel: model,
        systemPrompt: system,
        userMessage: user,
        maxTokens: 120,
        temperature: 0.2,
      );
      return _parseRecoveryDurationJson(jsonStr);
    } catch (e) {
      debugPrint('[GP] Recovery GPT fallback failed: $e');
    }

    // 3) Curated procedure-specific default.
    final curated = _curatedRecoveryForProcedure(procedureName);
    if (curated != null) return curated;

    // 4) Category default.
    final c = category.trim().toLowerCase();
    if (c.contains('surgery')) return (value: 3, unit: 'weeks');
    if (c.contains('inject')) return (value: 3, unit: 'days');
    if (c.contains('skin')) return (value: 5, unit: 'days');
    return (value: 3, unit: 'days');
  }

  final http.Client _client;
  final String model;
  final String _apiKey;
  // ignore: unused_field
  final String _placesApiKey;
  final GooglePlacesService _places;
  final FirebaseFirestore _firestore;

  /// Places-resolved Explore locality from the location picker.
  /// Prefer this over bare [city] strings for locale / cache / discovery keys.
  ExploreCityIdentity? _activeCityIdentity;

  void setActiveCityIdentity(ExploreCityIdentity? identity) {
    _activeCityIdentity = identity;
    if (identity != null && kDebugMode) {
      debugPrint(
        '[EXPLORE CITY] display=${identity.displayName} '
        'cityId=${identity.cityId} cc=${identity.countryCode} '
        'lang=${identity.languageCodes.join(",")} '
        'lat=${identity.latitude} lng=${identity.longitude} '
        'placeId=${identity.placeId}',
      );
    }
  }

  ExploreCityIdentity? get activeCityIdentity => _activeCityIdentity;

  /// Country code for search locale: active identity first, then name inference.
  String _countryCodeForCity(String city) {
    final active = _activeCityIdentity;
    if (active != null &&
        active.countryCode.trim().isNotEmpty &&
        (active.displayName.trim().toLowerCase() == city.trim().toLowerCase() ||
            active.canonicalName == foldExploreCityText(city))) {
      return active.countryCode.trim().toUpperCase();
    }
    if (active != null &&
        active.countryCode.trim().isNotEmpty &&
        city.trim().isNotEmpty) {
      // Still prefer active identity when the user just picked this city.
      return active.countryCode.trim().toUpperCase();
    }
    return exploreCountryCodeForCity(city);
  }

  /// Comparison / discovery key locality segment — cityId when resolved.
  String _localityCacheSegment(String city) {
    final active = _activeCityIdentity;
    if (active != null && active.cityId.trim().isNotEmpty) {
      return active.cityId.trim();
    }
    return city.trim();
  }

  /// Coalesces concurrent [ _loadFromFirestore ] calls for the same key.
  final Map<String, Future<OpenAIComparisonResult?>> _firestoreReadCoalesce =
      {};

  /// Session-level misses so empty cities (Paris, …) do not re-read
  /// `ai_cache` + 3 old revisions on every pill preload.
  final Set<String> _firestoreMissKeys = {};

  /// Firestore clinic list cache TTL — results older than this are re-fetched.
  static const Duration _kFirestoreCacheTtl = Duration(hours: 48);

  /// Set to true when OpenAI returns insufficient_quota (hard limit hit).
  /// Prevents hammering the API with calls that will all fail.
  /// Not set for 404 / model_not_found (shut-down or inaccessible models).
  static bool _quotaExhausted = false;

  /// Hostnames whose price pages return JS-shell HTML only (session-only).
  static final Set<String> _jsRenderedDomains = {};

  /// Hosts that returned HTTP 403 this session — skip further probes.
  static final Set<String> _http403Domains = {};

  /// Headless renders in flight/completed this session, keyed by URL.
  static final Map<String, Future<String>> _renderCache = {};

  /// Renders attempted per host — a browser round-trip is 5-25s, so a site
  /// that needs one gets a couple of shots at its price page, not dozens.
  static final Map<String, int> _rendersPerHost = {};

  static int _rendersUsed = 0;
  static bool _loggedRendererMissingConfig = false;

  /// One discovery fallback per clinic+procedure+city+domain this session.
  /// The value is the clinic's own best price URL — never page text.
  static final Map<String, Future<String>> _serpApiFallbackCache = {};

  /// In-flight/completed SerpApi HTTP searches keyed by query.
  static final Map<String, Future<List<_SerpSearchResult>>> _serpApiQueryCache =
      {};

  static int _serpApiCallCount = 0;
  static bool _loggedSerpApiMissingConfig = false;

  /// A provider cannot serve us at all (credentials, verification, balance).
  /// Retrying every query would blank discovery for the whole session, so the
  /// next provider in line takes over. Transient upstream errors never set
  /// these — only answers that no retry can fix.
  static bool _dataForSeoDisabled = false;
  static bool _serperDisabled = false;

  /// DataForSEO serialises live requests per account: with six posts open,
  /// four answered in ~2s while the extras sat unanswered for 18s and 31s.
  /// Anything over the budget times out client-side and is still billed, so
  /// discovery holds a slot instead of piling requests on the account.
  static const int _kDataForSeoMaxInFlight = 2;
  static int _dataForSeoInFlight = 0;
  static final List<Completer<void>> _dataForSeoWaiting = [];

  static void _releaseDataForSeoSlot() {
    while (_dataForSeoWaiting.isNotEmpty) {
      final next = _dataForSeoWaiting.removeAt(0);
      if (next.isCompleted) continue;
      next.complete();
      return;
    }
    if (_dataForSeoInFlight > 0) _dataForSeoInFlight--;
  }

  /// Runs [send] holding a discovery slot. Returns null when the queue wait
  /// alone eats [budget] — the request is never sent, so it is never billed.
  static Future<T?> _withDataForSeoSlot<T>(
    Duration budget,
    Future<T?> Function(Duration remaining) send,
  ) async {
    final sw = Stopwatch()..start();
    final gate = Completer<void>();
    var holding = _dataForSeoInFlight < _kDataForSeoMaxInFlight;
    if (holding) {
      _dataForSeoInFlight++;
    } else {
      _dataForSeoWaiting.add(gate);
      try {
        await gate.future.timeout(budget);
        holding = true;
      } on TimeoutException {
        _dataForSeoWaiting.remove(gate);
        holding = gate.isCompleted;
      }
    }
    try {
      if (!holding) {
        debugPrint('[GP] DataForSEO queue busy — no call sent, not billed');
        return null;
      }
      final remaining = budget - sw.elapsed;
      // Queue wait ate the budget — do not bill, and do not count this as a
      // discovery "timeout" stall (nothing was sent).
      if (remaining < const Duration(milliseconds: 500)) {
        debugPrint('[GP] DataForSEO queue busy — budget gone, not billed');
        return null;
      }
      return await send(remaining);
    } finally {
      if (holding) _releaseDataForSeoSlot();
    }
  }

  /// Must match [buildClinicsList] / [_buildClinicsListFromWeb] Firestore keys.
  static const String _kClinicsListCacheRevision = 'v7';

  // Common short forms and Romanian terms (all other languages via AI fallback).
  static final Map<String, String> _procAliases = {
    'prp': 'PRP therapy',
    'prp terapie': 'PRP therapy',
    'prp therapy': 'PRP therapy',
    'ez gel': 'EZ GEL PRF',
    'ezgel': 'EZ GEL PRF',
    'prf': 'EZ GEL PRF',
    'hifu': 'HIFU face lift',
    'btx': 'Botox',
    'toxina botulinica': 'Botox',
    'acid buze': 'Lip filler',
    'marire buze': 'Lip filler',
    'volumizare buze': 'Lip filler',
    'filler buze': 'Lip filler',
    'filler': 'Hyaluronic acid filler',
    'acid hialuronic': 'Hyaluronic acid filler',
    'polinucleotide': 'Polynucleotides',
    'fire pdo': 'Thread lift',
    'epilare laser': 'Laser hair removal',
    'epilare': 'Laser hair removal',
    'rinoplastie': 'Rhinoplasty',
    'marire sani': 'Breast augmentation',
    'augmentare mamara': 'Breast augmentation',
    'liposuctie': 'Liposuction',
    'lipo': 'Liposuction',
    'peeling chimic': 'Chemical peel',
    'mezoterapie': 'Mesotherapy',
    'transplant par': 'Hair transplant',
    'implant par': 'Hair transplant',
    'fue': 'Hair transplant',
    'dhi': 'Hair transplant',
    'blefaroplastie': 'Eyelid surgery',
    'abdominoplastie': 'Tummy tuck',
    'exozomi': 'Exosome therapy',
    'skinbooster': 'Skin booster',
    'dermapen': 'Microneedling',
    'morpheus': 'Morpheus8',
  };

  // Cache for AI-resolved procedure names (session-only).
  static final Map<String, String> _normalizeCache = {};

  /// Sync version — for cache keys where async not possible.
  static String _normalizeProcSync(String procedure) {
    final key = _cleanKey(procedure);
    // Check static aliases
    if (_procAliases.containsKey(key)) return _procAliases[key]!;
    // Check AI cache from previous calls
    if (_normalizeCache.containsKey(key)) return _normalizeCache[key]!;
    // Try plural stripping
    for (final suffix in ['s', 'es', 'uri', 'uri']) {
      if (key.endsWith(suffix) && key.length > suffix.length + 2) {
        final stem = key.substring(0, key.length - suffix.length);
        if (_procAliases.containsKey(stem)) return _procAliases[stem]!;
        if (_normalizeCache.containsKey(stem)) return _normalizeCache[stem]!;
      }
    }
    // Return original — AI will handle it in buildClinicsList
    return procedure.trim();
  }

  /// Async version — uses AI for unknown languages/terms.
  /// Costs ~$0.0001 per new term, then cached for the session.
  Future<String> _normalizeProcedure(String procedure) async {
    final key = _cleanKey(procedure);

    // 1. Static alias — instant
    if (_procAliases.containsKey(key)) return _procAliases[key]!;

    // 2. Already resolved by AI this session — free
    if (_normalizeCache.containsKey(key)) return _normalizeCache[key]!;

    // 3. Looks like English already — skip AI call
    final isLikelyEnglish = _looksLikeEnglish(key);
    if (isLikelyEnglish) {
      // Capitalize properly and cache
      final canonical = _toTitleCase(procedure.trim());
      _normalizeCache[key] = canonical;
      return canonical;
    }

    // 4. Unknown language — ask AI (gpt-5.6-luna, very cheap)
    try {
      final result = await _openAiChatJsonCompletion(
        openAiModel: model,
        systemPrompt:
            'Translate aesthetic/cosmetic procedure names to canonical '
            'English. Return ONLY: {"name":"English canonical name"}\n'
            'Rules:\n'
            '- Use the most common English clinic term\n'
            '- Keep brand names (Profhilo, Sculptra, Morpheus8)\n'
            '- "acid buze" → Lip filler\n'
            '- "dudak dolgusu" → Lip filler\n'
            '- "увеличение губ" → Lip filler\n'
            '- "注射瘦脸" → Botox jaw slimming\n'
            '- "입술 필러" → Lip filler\n'
            '- Short forms: "prp" → PRP therapy, "hifu" → HIFU face lift\n'
            '- If already English, return as-is with proper capitalization',
        userMessage: 'Procedure: "$procedure"',
        maxTokens: 30,
        temperature: 0,
      );
      final json = jsonDecode(result) as Map<String, dynamic>;
      final name = (json['name'] as String?)?.trim() ?? '';
      if (name.isNotEmpty) {
        _normalizeCache[key] = name;
        debugPrint('[GP] Normalized "$procedure" → "$name"');
        return name;
      }
    } catch (_) {}

    // Fallback — return as-is
    return procedure.trim();
  }

  static String _cleanKey(String s) => s
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(
        RegExp(
          r'[^\w\s\u00C0-\u024F\u0400-\u04FF\u0600-\u06FF\u4E00-\u9FFF\uAC00-\uD7AF]',
        ),
        '',
      )
      .trim();

  /// Returns true if string looks like it's already English.
  static bool _looksLikeEnglish(String s) {
    final isAscii = s.codeUnits.every((c) => c < 128);
    if (!isAscii) return false;
    const englishTerms = {
      'botox',
      'filler',
      'lip',
      'cheek',
      'chin',
      'jawline',
      'rhinoplasty',
      'liposuction',
      'laser',
      'hifu',
      'prp',
      'hydrafacial',
      'microneedling',
      'sculptra',
      'profhilo',
      'morpheus',
      'thread',
      'lift',
      'peel',
      'mesotherapy',
      'polynucleotides',
      'skin',
      'booster',
      'hair',
      'transplant',
      'breast',
      'augmentation',
      'tummy',
      'tuck',
      'eyelid',
      'surgery',
      'treatment',
      'therapy',
      'injection',
      'face',
    };
    return englishTerms.any((t) => s.contains(t));
  }

  static String _toTitleCase(String s) => s
      .split(' ')
      .map(
        (w) =>
            w.isEmpty ? w : w[0].toUpperCase() + w.substring(1).toLowerCase(),
      )
      .join(' ');

  static String _readPlacesKey() =>
      const String.fromEnvironment('GOOGLE_PLACES_API_KEY', defaultValue: '');

  /// Session cache for completed AI responses, keyed by call signature.
  /// Same `(query, city, …)` returns instantly on a second tap during a session.
  /// Stores either the parsed result or the in-flight `Future` so concurrent
  /// callers share one network round-trip.
  static final Map<String, Future<dynamic>> _cache = {};

  /// When each buildComparison cache entry was actually (re)built — NOT
  /// touched on a cache hit. Lets the static _cache entry go stale so a
  /// re-open after a while re-runs pool rotation / AI top-up instead of
  /// replaying the exact same Future for the rest of the app's lifetime.
  static final Map<String, DateTime> _comparisonCacheBuiltAt = {};

  /// Raw fetched page text keyed by URL, shared across all procedures and
  /// refill passes within this app session — avoids re-fetching the same
  /// clinic website (e.g. cronosmed.ro) once per procedure pill.
  static final Map<String, ({String text, DateTime fetchedAt})> _pageTextCache =
      {};
  static const Duration _kPageTextCacheTtl = Duration(minutes: 15);

  /// How long a comparison result is served from the static _cache
  /// before a re-open is treated as stale and rebuilt.
  static const Duration _kComparisonCacheTtl = Duration(minutes: 10);

  /// Full AI batch cache — stores all clinics per search key.
  /// UI pages slice from this instead of calling AI again.
  static final Map<String, List<OpenAIClinic>> _fullBatchCache = {};

  // Queue for gpt-5.6-terra web-search (Responses API) calls
  // Only 1 at a time to avoid rate limits (6000 TPM)
  final _searchPreviewQueue = <_SearchPreviewTask>[];
  int _searchPreviewInFlight = 0;
  static const _kSearchPreviewMaxConcurrent = 2;
  Object? _lastQueueError;

  // Completers that resolve when background price
  // enrichment finishes for a given cache key.
  final Map<String, Completer<OpenAIComparisonResult>> _enrichmentCompleters =
      {};

  /// Last successful [buildComparison] result per memo key (instant UI paint).
  final Map<String, OpenAIComparisonResult> _comparisonMemoryCache = {};
  final Map<String, ({OpenAIComparisonResult source, String revision,
      DateTime validatedAt, OpenAIComparisonResult verified})> _verifiedTabSnapshots = {};
  final Map<String, DateTime> _verifiedTabRefreshAt = {};
  final Map<String, int> _comparisonDisplayEpoch = {};
  final Map<String, DateTime> _placesIdentityMissesRetried = {};

  void reportCompareDisplayCount(String cacheKey, int count) {
    unawaited(ExplorePriceDiscoveryTool.instance.reportDisplayedCount(
      focusKey: cacheKey, count: count,
    ));
  }
  final Map<String, String> _explorePersistFingerprints = {};
  final Map<String, Future<void>> _explorePersistLocks = {};
  final Map<String, Timer?> _explorePersistDebounce = {};
  final Map<String, _ExplorePersistJob> _explorePersistPending = {};

  /// Full Compare pool per cache key (grows toward [kExploreFirestorePoolMax]).
  /// Separate from the 6 on-screen cards so the next visit can shuffle a
  /// different 3 from everything already saved, including the last 3 Google.
  final Map<String, List<OpenAIClinic>> _exploreComparisonPool = {};

  /// Clinics currently shown per city + Explore pill, so Botox / Fillers /
  /// Laser lists do not keep repeating the same names.
  final Map<String, Map<String, List<OpenAIClinic>>> _exploreShownByCityPill =
      {};

  /// Live progress listeners for in-flight [buildComparison] calls (shared by key).
  final Map<String, List<void Function(OpenAIComparisonResult)>>
  _comparisonProgressListeners = {};

  /// Keys where hybrid already exhausted AI refills under the min clinic count.
  /// Prevents wiping memory and refetching forever on every tab revisit.
  final Set<String> _comparisonTopUpExhausted = {};
  final Map<String, DateTime> _comparisonTopUpExhaustedAt = {};
  final Set<String> _ratingBackfillClinicKeys = {};
  bool _serpApiLastTimedOut = false;
  bool _serpApiLastRateLimited = false;

  final Set<String> _comparisonEnrichInFlight = {};
  final Map<String, Completer<OpenAIComparisonResult>>
  _comparisonEnrichCompleters = {};

  /// Tracks the background AI top-up (fetchFresh + refill loop) per cache key
  /// so [buildComparison] can return quickly with the cache pool while the
  /// slower AI web-search runs in the background.
  final Set<String> _comparisonAiTopUpInFlight = {};
  final Map<String, Completer<OpenAIComparisonResult>>
  _comparisonAiTopUpCompleters = {};

  /// Count of tracked fill-session futures (verify, deep backend, waves)
  /// still running for a city+procedure cache key.
  final Map<String, int> _comparisonPendingFillWork = {};

  /// Prevents finishTopUp from launching multiple deep backend fetches.
  final Set<String> _comparisonDeepFillStarted = {};

  /// Interactive Compare is finished for the UI: at least one verified card,
  /// or the live budget ended. A short list is a complete answer.
  final Set<String> _comparisonGoogleMixComplete = {};
  final Set<String> _discoveryToolSettled = {};
  // Join selected-tab and city-warm requests for the same city/procedure.
  final Map<String, Future<OpenAIComparisonResult>> _discoveryToolBuilds = {};

  /// A dropped connection kept the cards already verified. It does not mean
  /// the screen should keep spinning until more cards appear.
  final Set<String> _discoveryToolIncomplete = {};
  final Map<String, Future<void>> _interactiveRefresh = {};

  /// Set when a thin market or "Find more" accepts a background job.
  final ValueNotifier<ExploreBackgroundHunt?> backgroundHuntNote =
      ValueNotifier(null);

  /// Only the on-screen procedure may run Places / SerpApi. Switching pills
  /// bumps [_liveCompareTopUpEpoch] so the previous top-up stops.
  String? _liveCompareTopUpKey;
  int _liveCompareTopUpEpoch = 0;
  int _liveSerpApiBudget = _kMaxSlowProviderSerpPerLiveSearch;

  /// Fast, cheap providers can afford the full sweep; a slow one cannot.
  int _liveSerpApiBudgetCap() =>
      _serpProvider() == ExploreSerpProviderKind.serper
      ? _kMaxSerpApiPerLiveSearch
      : _kMaxSlowProviderSerpPerLiveSearch;

  void _claimLiveCompareTopUp(String cacheKey, {required String label}) {
    if (_liveCompareTopUpKey == cacheKey) return;
    debugPrint('[PILL CANCEL] $label');
    debugPrint('[GP] Live search focus: $label');
    _liveCompareTopUpKey = cacheKey;
    ExplorePriceDiscoveryTool.instance.focusDiscovery(cacheKey);
    _liveCompareTopUpEpoch++;
    // Credits / key may have been topped up since a prior 403 — retry Serper.
    if (_serperDisabled) {
      _serperDisabled = false;
      debugPrint('[GP] Serper re-enabled for this search');
    }
    _liveSerpApiBudget = _liveSerpApiBudgetCap();
    _liveDiscoveryTimeouts = 0;
    _loggedDiscoveryStalled = false;
  }

  /// Cancels the previous pill's UI-blocking search. Late verifies may still
  /// persist to Firestore but must not paint the newly selected pill.
  void focusLiveCompareSearch(String cacheKey, {required String label}) {
    _claimLiveCompareTopUp(cacheKey, label: label);
  }

  /// Drop a joined /discover-hybrid so a pill or city change cannot keep
  /// awaiting the request that [ExplorePriceDiscoveryTool.abortInFlightDiscover]
  /// just closed.
  void abandonInFlightDiscovery() {
    _discoveryToolBuilds.clear();
    ExplorePriceDiscoveryTool.instance.abortInFlightDiscover();
  }

  /// Attach a fill-session future so the UI stays "searching" until it settles.
  void _trackComparisonFillWork(
    String cacheKey,
    Future<void> work, {
    String label = '',
  }) {
    _comparisonPendingFillWork[cacheKey] =
        (_comparisonPendingFillWork[cacheKey] ?? 0) + 1;
    final pending = _comparisonPendingFillWork[cacheKey]!;
    if (label.isNotEmpty) {
      debugPrint(
        '[FILL SESSION] track · $label · pending=$pending · key=$cacheKey',
      );
    }
    unawaited(
      work
          .whenComplete(() {
            final n = (_comparisonPendingFillWork[cacheKey] ?? 1) - 1;
            if (n <= 0) {
              _comparisonPendingFillWork.remove(cacheKey);
            } else {
              _comparisonPendingFillWork[cacheKey] = n;
            }
            if (label.isNotEmpty) {
              debugPrint(
                '[FILL SESSION] settle · $label · pending='
                '${_comparisonPendingFillWork[cacheKey] ?? 0}',
              );
            }
          })
          .catchError((Object _) {}),
    );
  }

  int _comparisonPendingFillCount(String cacheKey) =>
      _comparisonPendingFillWork[cacheKey] ?? 0;

  /// The All preview searches several pills without claiming the live search
  /// slot, so it never passes through [_claimLiveCompareTopUp] — the only
  /// place that clears the stall counter. Without this, three timeouts in the
  /// first wave switched discovery off for every pill that followed.
  void resetLiveDiscoveryBudget({required String label}) {
    if (_serperDisabled) {
      _serperDisabled = false;
      debugPrint('[GP] Serper re-enabled · $label');
    }
    if (_liveDiscoveryTimeouts == 0 &&
        _liveSerpApiBudget == _liveSerpApiBudgetCap()) {
      return;
    }
    debugPrint(
      '[GP] Discovery budget reset · $label · '
      'was $_liveSerpApiBudget left, $_liveDiscoveryTimeouts timeouts',
    );
    _liveSerpApiBudget = _liveSerpApiBudgetCap();
    _liveDiscoveryTimeouts = 0;
    _loggedDiscoveryStalled = false;
    _serpApiLastTimedOut = false;
  }

  void _refundLiveSerpApi() {
    if (_liveSerpApiBudget < _liveSerpApiBudgetCap()) {
      _liveSerpApiBudget++;
    }
  }

  /// An upstream that keeps timing out must not spend the pill's whole budget
  /// one wait at a time: a Botox·Dubai run burned 60s on thirteen queries that
  /// every one of them timed out on. Three in a row ends discovery for this
  /// search, so the verification queue gets the remaining seconds instead.
  static const int _kMaxDiscoveryTimeoutsPerRun = 3;
  int _liveDiscoveryTimeouts = 0;
  bool _loggedDiscoveryStalled = false;

  bool _discoveryStalled() {
    if (_liveDiscoveryTimeouts < _kMaxDiscoveryTimeoutsPerRun) return false;
    if (!_loggedDiscoveryStalled) {
      _loggedDiscoveryStalled = true;
      debugPrint(
        '[GP] Discovery stalled — $_liveDiscoveryTimeouts timeouts in a row, '
        'skipping search for the rest of this pill',
      );
    }
    return true;
  }

  /// Firestore cache key → safe document ID (no slashes, bounded length).
  String _firestoreSafeKey(String key) {
    final encoded = Uri.encodeComponent(key).replaceAll('%', '_');
    const maxLen = 400;
    if (encoded.length <= maxLen) return encoded;
    return encoded.substring(0, maxLen);
  }

  /// Drops clinics that are not procedure-verified on-site (`has_procedure`).
  OpenAIComparisonResult _filterUnverifiedClinics(OpenAIComparisonResult r) {
    final filtered = r.clinics.where((c) => c.hasProcedure).toList();
    if (filtered.isEmpty || filtered.length == r.clinics.length) {
      return r;
    }
    return r.copyWith(clinics: filtered);
  }

  /// Try to load a cached OpenAIComparisonResult from Firestore.
  /// Returns null if missing, expired, or on any error.
  Future<OpenAIComparisonResult?> _loadFromFirestore(String key) {
    if (_firestoreMissKeys.contains(key)) {
      return Future<OpenAIComparisonResult?>.value(null);
    }
    return _firestoreReadCoalesce.putIfAbsent(key, () async {
      try {
        final doc = await _firestore
            .collection('ai_cache')
            .doc(_firestoreSafeKey(key))
            .get();
        if (!doc.exists) {
          _firestoreMissKeys.add(key);
          return null;
        }
        final data = doc.data();
        if (data == null) return null;
        final ts = data['cachedAt'] as Timestamp?;
        if (ts == null) return null;

        final ttlHours =
            (data['ttl_hours'] as num?)?.toInt() ?? _kFirestoreCacheTtl.inHours;
        final ttl = Duration(hours: ttlHours);
        if (DateTime.now().difference(ts.toDate()) > ttl) {
          debugPrint('[GP] Firestore cache expired (TTL: ${ttlHours}h): $key');
          _firestoreMissKeys.add(key);
          return null;
        }

        final json = data['result'] as Map<String, dynamic>?;
        if (json == null) {
          _firestoreMissKeys.add(key);
          return null;
        }
        debugPrint('[GP] Firestore cache HIT (TTL: ${ttlHours}h): $key');
        _firestoreMissKeys.remove(key);
        return OpenAIComparisonResult.fromJson(json.cast<String, Object?>());
      } catch (e) {
        debugPrint('[GP] Firestore cache read error: $e');
        return null;
      } finally {
        scheduleMicrotask(() => _firestoreReadCoalesce.remove(key));
      }
    });
  }

  /// Current comparison doc, or a previous revision if a price-rule bump
  /// left the new key empty (that used to paint 4 Google cards, not 2+2).
  Future<OpenAIComparisonResult?> _loadExploreComparisonPool({
    required String cacheKey,
    required String queryOrSelection,
    required String city,
    required String mode,
  }) async {
    final current = await _loadFromFirestore(cacheKey);
    final currentN = _pricedExploreClinics(
      current?.clinics ?? const [],
      procedure: queryOrSelection,
    ).length;
    if (currentN >= kExploreFirestoreSeedClinics) return current;

    final oldRevs = _kExploreComparisonPreviousRevisions
        .where((rev) => rev != kExploreComparisonCacheRevision)
        .toList();
    if (oldRevs.isEmpty) return current;
    final oldResults = await Future.wait([
      for (final rev in oldRevs)
        _loadFromFirestore('comparison|$rev|$queryOrSelection|$city|$mode'),
    ]);
    for (var i = 0; i < oldResults.length; i++) {
      final old = oldResults[i];
      final n = _pricedExploreClinics(
        old?.clinics ?? const [],
        procedure: queryOrSelection,
      ).length;
      if (n < kExploreFirestoreSeedClinics) continue;
      debugPrint(
        '[GP] Comparison pool fallback ${oldRevs[i]} → '
        '$kExploreComparisonCacheRevision ($n clinics) · '
        '$queryOrSelection · $city',
      );
      return old;
    }
    return current;
  }

  /// Write an OpenAIComparisonResult to Firestore cache.
  Future<void> _saveToFirestore(
    String key,
    OpenAIComparisonResult result,
  ) async {
    final sanitized = _filterUnverifiedClinics(result);
    final unpricedCount = sanitized.clinics
        .where((c) => c.priceMin <= 0)
        .length;

    final ttlHours = unpricedCount > 0 ? 6 : _kFirestoreCacheTtl.inHours;

    try {
      final json = _comparisonResultToJson(sanitized);
      _firestoreMissKeys.remove(key);
      await _firestore.collection('ai_cache').doc(_firestoreSafeKey(key)).set({
        'result': json,
        'cachedAt': FieldValue.serverTimestamp(),
        'key': key,
        'ttl_hours': ttlHours,
        'unpriced_count': unpricedCount,
        'pool_count': sanitized.clinics.length,
      });
      debugPrint(
        '[GP] Firestore cache WRITE: $key '
        '(${sanitized.clinics.length} clinics, TTL: ${ttlHours}h, '
        'unpriced: $unpricedCount)',
      );
    } catch (e) {
      debugPrint('[GP] Firestore cache write error: $e');
    }
  }

  String _batchCacheKey(String procedure, String city) =>
      'batch|${_normalizeProcSync(procedure)}|$city';

  /// Returns the next page of clinics from the cached full batch.
  /// Never calls the AI — slices from what was already fetched.
  /// Returns null if no batch is cached for this procedure+city.
  List<OpenAIClinic>? getNextPageFromCache({
    required String procedure,
    required String city,
    required List<String> alreadyShownNames,
    int pageSize = 10,
  }) {
    final batchCacheKey = _batchCacheKey(procedure, city);
    final fullBatch = _fullBatchCache[batchCacheKey];
    if (fullBatch == null) {
      debugPrint('[GP] No batch cache for $procedure in $city');
      return null;
    }
    final shown = alreadyShownNames.map((n) => n.toLowerCase().trim()).toSet();
    final nextPage = fullBatch
        .where((c) => !shown.contains(c.name.toLowerCase().trim()))
        .take(pageSize)
        .toList();
    debugPrint(
      '[GP] Next page from cache: ${nextPage.length} clinics '
      '(${fullBatch.length} total in batch)',
    );
    return nextPage.isEmpty ? null : nextPage;
  }

  /// How many more clinics are available beyond what's shown.
  int getRemainingCount({
    required String procedure,
    required String city,
    required List<String> alreadyShownNames,
  }) {
    final batchCacheKey = _batchCacheKey(procedure, city);
    final fullBatch = _fullBatchCache[batchCacheKey];
    if (fullBatch == null) return 0;
    final shown = alreadyShownNames.map((n) => n.toLowerCase().trim()).toSet();
    return fullBatch
        .where((c) => !shown.contains(c.name.toLowerCase().trim()))
        .length;
  }

  /// True when every clinic in the session batch is already shown — "Load more"
  /// can request another AI wave (e.g. past the first 30, or past a short
  /// Firestore-only list).
  bool reachedEndOfCachedBatch({
    required String procedure,
    required String city,
    required List<String> alreadyShownNames,
  }) {
    final batchCacheKey = _batchCacheKey(procedure, city);
    final fullBatch = _fullBatchCache[batchCacheKey];
    if (fullBatch == null || fullBatch.isEmpty) return false;
    if (alreadyShownNames.isEmpty) return false;
    final shown = alreadyShownNames.map((n) => n.toLowerCase().trim()).toSet();
    return fullBatch.every((c) => shown.contains(c.name.toLowerCase().trim()));
  }

  Map<String, dynamic> _comparisonResultToJson(OpenAIComparisonResult r) {
    return {
      'city': r.city,
      'topic': r.topic,
      'topic_type': r.topicType == OpenAISearchItemType.clinic
          ? 'clinic'
          : 'procedure',
      'summary': r.summary,
      'range_label': r.rangeLabel,
      'map_center': {'lat': r.mapCenter.lat, 'lng': r.mapCenter.lng},
      'clinics': r.clinics.map((c) => _clinicPersistJson(c)).toList(),
    };
  }

  Map<String, Object?> _clinicPersistJson(OpenAIClinic c) {
    final sourceUrl = c.priceSourceUrl.trim().isNotEmpty
        ? c.priceSourceUrl.trim()
        : (_sourceUrlFromArea(c.area) ?? '');
    return {
      'rank': c.rank,
      'name': c.name,
      'area': _withSourceUrl(c.area, sourceUrl),
      'distance_mi': c.distanceMi,
      'rating': c.rating,
      'reviews': c.reviews,
      'price_gbp': c.priceGbp,
      'price_min': c.priceMin,
      'price_max': c.priceMax,
      'price_label': c.priceLabel,
      'currency': c.currency,
      'currency_confirmed': c.currencyConfirmed,
      'brand': _stripPriceSuffix(c.brand),
      'badge': c.badge,
      'badge_variant': c.badgeVariant,
      'lat': c.coord.lat,
      'lng': c.coord.lng,
      'has_procedure': c.hasProcedure,
      'price_pending': false,
      'price_source_url': sourceUrl,
      'price_evidence_text': sanitizePriceEvidence(c.priceEvidenceText),
      'price_verification_status': c.priceVerificationStatus.wire,
      'price_verification_confidence': c.priceVerificationConfidence,
      if (c.priceVerifiedAt != null)
        'price_verified_at': c.priceVerifiedAt!.toUtc().toIso8601String(),
      if (c.lastCheckedAt != null)
        'last_checked_at': c.lastCheckedAt!.toUtc().toIso8601String(),
      if (c.discoveredAt != null)
        'discovered_at': c.discoveredAt!.toUtc().toIso8601String(),
      if (c.priceRejectionReason.isNotEmpty)
        'price_rejection_reason': c.priceRejectionReason,
      if (c.rawProcedureText.isNotEmpty)
        'raw_procedure_text': c.rawProcedureText,
      if (c.rawPriceText.isNotEmpty) 'raw_price_text': c.rawPriceText,
      if (c.extractionMethod.isNotEmpty)
        'extraction_method': c.extractionMethod,
      if (c.evidenceHash.isNotEmpty) 'evidence_hash': c.evidenceHash,
      if (c.priceType.isNotEmpty) 'price_type': c.priceType,
      if (c.priceUnit.isNotEmpty) 'price_unit': c.priceUnit,
      if (c.priceQuantity != null) 'price_quantity': c.priceQuantity,
      if (c.sourceType.isNotEmpty) 'source_type': c.sourceType,
      if (c.procedureFamily.isNotEmpty) 'procedure_family': c.procedureFamily,
      if (c.procedureCanonical.isNotEmpty)
        'procedure_canonical': c.procedureCanonical,
      if (c.procedureDisplayName.isNotEmpty)
        'procedure_display_name': c.procedureDisplayName,
      if (c.procedureDetail.isNotEmpty) 'procedure_detail': c.procedureDetail,
      if (c.placeId.trim().isNotEmpty) 'place_id': c.placeId.trim(),
      if (c.sourcePlatform.trim().isNotEmpty)
        'source_platform': c.sourcePlatform.trim(),
      if (c.providerClinic.trim().isNotEmpty)
        'provider_clinic': c.providerClinic.trim(),
      if (c.priceExtractRevision.isNotEmpty)
        'price_extract_revision': c.priceExtractRevision,
      if (c.procedureRelation.isNotEmpty)
        'procedure_relation': c.procedureRelation,
    };
  }

  Map<String, Object?> _clinicToGooglePriceJson(OpenAIClinic c) {
    return {
      ..._clinicPersistJson(c),
      'price_source': 'google',
      'price_verified': explorePriceIsVerified(c),
    };
  }

  List<OpenAIClinic> _clinicsFromGooglePriceJson(
    List<Map<String, Object?>> raw,
  ) {
    return [for (final m in raw) OpenAIClinic.fromJson(m)];
  }

  /// Wraps an AI builder with a session-scoped memoization layer.
  Future<T> _memoize<T>(String key, Future<T> Function() build) {
    final hit = _cache[key];
    if (hit != null) return hit as Future<T>;
    final fut = build();
    _cache[key] = fut;
    // Drop failed entries so we retry on next tap.
    fut.then<void>((_) {}, onError: (Object _) => _cache.remove(key));
    return fut;
  }

  Future<String> _queueSearchPreview(
    Future<String> Function() task, {
    bool priority = false,
  }) {
    final completer = Completer<String>();
    final item = _SearchPreviewTask(
      run: task,
      completer: completer,
      priority: priority,
    );
    if (priority) {
      _searchPreviewQueue.insert(0, item);
    } else {
      _searchPreviewQueue.add(item);
    }
    _drainSearchPreviewQueue();
    return completer.future;
  }

  void _drainSearchPreviewQueue() {
    while (_searchPreviewInFlight < _kSearchPreviewMaxConcurrent &&
        _searchPreviewQueue.isNotEmpty) {
      _searchPreviewInFlight++;
      final task = _searchPreviewQueue.removeAt(0);
      task
          .run()
          .then((String result) {
            if (!task.completer.isCompleted) {
              task.completer.complete(result);
            }
          })
          .catchError((Object e, StackTrace st) {
            _lastQueueError = e;
            if (!task.completer.isCompleted) {
              task.completer.completeError(e, st);
            }
          })
          .whenComplete(() {
            _searchPreviewInFlight--;
            final isRateLimit =
                _lastQueueError?.toString().contains('429') ?? false;
            _lastQueueError = null;
            // Do not insert a 3s gap between searches — that made Compare
            // sit on "Loading more clinics…" for a minute. Only back off on 429.
            if (isRateLimit) {
              Future<void>.delayed(
                const Duration(seconds: 8),
                _drainSearchPreviewQueue,
              );
            } else {
              _drainSearchPreviewQueue();
            }
          });
    }
  }

  bool get isConfigured => _apiKey.trim().isNotEmpty;
  bool get canSearch => isConfigured || ExplorePriceDiscoveryTool.instance.enabled;

  Future<List<OpenAISearchItem>> search({
    required String query,
    required String city,
    required String mode,
    required String categoryPill,
  }) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return Future.value(const <OpenAISearchItem>[]);
    // Bump when search semantics / prompts change (invalidates stale suggestions).
    const searchCacheRevision = 'v3-index';
    final key =
        'search|$searchCacheRevision|$trimmed|$city|$mode|$categoryPill';
    final request = _memoize<List<OpenAISearchItem>>(
      key,
      () => _searchUncached(
        trimmed: trimmed,
        city: city,
        mode: mode,
        categoryPill: categoryPill,
      ),
    );
    return request.then((items) {
      // An empty clinic lookup must not stay empty for the entire app session
      // after the backend comes back or the directory gains that clinic.
      if (items.isEmpty && identical(_cache[key], request)) _cache.remove(key);
      return items;
    });
  }

  Future<List<OpenAISearchItem>> _searchUncached({
    required String trimmed,
    required String city,
    required String mode,
    required String categoryPill,
  }) async {
    if (ExplorePriceDiscoveryTool.instance.enabled) {
      final family = exploreTreatmentFamily(trimmed);
      if (_fallbackQueryLooksLikeClinicName(trimmed) || family == ExploreTreatmentFamily.other) {
        final found = await ExplorePriceDiscoveryTool.instance.searchClinics(
          query: trimmed, city: city, countryCode: _countryCodeForCity(city),
        );
        if (found.isNotEmpty) {
          return [for (final row in found) OpenAISearchItem.fromJson(row)];
        }
      }
    }
    if (!isConfigured) {
      if (_fallbackQueryLooksLikeClinicName(trimmed)) return const [];
      return [
        OpenAISearchItem(
          title: _procAliases[_cleanKey(trimmed)] ?? trimmed,
          subtitle: city, type: OpenAISearchItemType.procedure,
          aliases: [trimmed],
          priceHint: null,
        ),
      ];
    }
    final uri = Uri.parse('https://api.openai.com/v1/chat/completions');
    final body = <String, Object?>{
      'model': model,
      ..._temperatureParam(model, 0.2),
      ..._tokenLimitParam(model, 600),
      'response_format': {'type': 'json_object'},
      'messages': [
        {
          'role': 'system',
          'content':
              'You generate compact search results for a beauty/clinic comparison app. '
              'Return ONLY a JSON object of the form '
              '{"results":[{"title":string,"subtitle":string,"type":"procedure"|"clinic",'
              '"price_hint":string?,"aliases":string[]?}, ...]}. '
              'Up to 6 items. No markdown, no code block.\n\n'
              'MULTILINGUAL HANDLING — this is critical:\n'
              '- The query may be in ANY language (English, Romanian, Spanish, French, Italian, '
              'German, Portuguese, Polish, Turkish, Greek, Arabic, Hebrew, etc.).\n'
              '- Detect the language and the underlying procedure/clinic intent.\n'
              '- For procedure queries: ALWAYS include both the canonical English name AND the '
              'original-language synonym so the user discovers more options. '
              'Examples: '
              '"acid buze" (Romanian) → Lip filler / Acid hialuronic buze; '
              '"rellenos de labios" (Spanish) → Lip filler / Rellenos de labios; '
              '"injection lèvres" (French) → Lip filler / Injection des lèvres; '
              '"حقن الشفايف" (Arabic) → Lip filler / حقن الشفايف; '
              '"acido hialuronico" (Spanish/Italian) → Hyaluronic acid filler; '
              '"botoks" (Turkish) → Botox; '
              '"radiofrecvență" (Romanian) → Radiofrequency / RF skin tightening.\n'
              '- Use the title for the most recognizable form (prefer the canonical English name '
              'if the user used a non-English term, or keep the user\'s wording when it is already English). '
              'Put the LOCAL-LANGUAGE synonym inside subtitle: "<local synonym> · <city> · <category>".\n'
              '- Always include both names in "aliases" (e.g. ["Lip filler","Acid hialuronic buze"]) '
              'so downstream search can match either name.\n'
              '- Expand procedure queries into 4–6 related MEDICAL aesthetic options in the same response so the '
              'feed feels rich (e.g. lip query → Lip filler, Lip flip, Russian lips, Tear trough '
              'filler, Smile-line filler, Lip botox).\n\n'
              'DOMAIN — MEDICAL AESTHETICS ONLY (GlowPass):\n'
              '- Suggest ONLY treatments performed in MEDICAL aesthetic / dermatology / plastic surgery '
              'settings — injectables, biostimulators, lasers, RF, clinical skin boosters.\n'
              '- NEVER return brow bars, eyebrow cosmetics, lash studios, nail gel, manicure waxing salons, '
              'or generic beauty-salon interpretations of ambiguous words.\n'
              'DISAMBIGUATION (critical):\n'
              '- "Ez gel", "EZ gel", "easy gel PRF": mean EZ GEL / PRF (Platelet Rich Fibrin) '
              'autologous injectable skin rejuvenation — NOT eyebrow gel, brow tint gel, nail gel.\n'
              '- If the query is just "gel" or sounds like cosmetics, infer MEDICAL aesthetic meaning '
              '(PRF/skin booster/injectables) unless the query explicitly mentions nails/brows/lashes '
              '("eyebrow", "sprâncene/sprancene", "unghii", "nails", ...).\n\n'
              'CLASSIFICATION — overrides mode/category:\n'
              'type = "clinic" when the query is a business/brand/practitioner name. '
              'Signs: starts with "Dr" / "Dr." / "Drs", contains Clinic, Clinica, Clinique, Studio, '
              'Aesthetics, Estetica, Medical, Beauty, Spa, Centre, Center, Salon, Lounge, Skin '
              '(as brand), Hospital, Polyclinic, Kozmetika, or is clearly a proper-noun brand '
              '("DrSkin", "Harley Clinic", "GlowStudio"). Spacing/case is insignificant: '
              '"DrSkin" == "Dr Skin" == "dr skin".\n'
              'type = "procedure" when the query is a cosmetic or medical treatment in ANY language.\n\n'
              'OUTPUT RULES:\n'
              '- Clinic query → ONLY "clinic" items (the clinic itself plus plausible branches/alternative '
              'spellings/similar names in the given city). ALWAYS return ≥ 1 item.\n'
              '- Procedure query → ONLY "procedure" items, expanded across the family as described above.\n'
              '- Never mix types.\n'
              '- "mode" and "category" are soft ranking hints; they MUST NOT override classification.',
        },
        {
          'role': 'user',
          'content':
              'Query: "$trimmed"\nCity: "$city"\nMode hint: "$mode"\nCategory hint: "$categoryPill"\n'
              'GlowPass lists MEDICAL aesthetic procedures only.\n'
              'If the query is "Ez gel" / "EZ gel": treat as EZ GEL PRF (platelet fibrin injectable) — '
              'never suggest eyebrow gel, brow tint / shaping, lash or nail salon services.\n'
              'Classify the query first (any language). '
              'If it is a procedure, return 4–6 RELATED MEDICAL AESTHETIC options '
              '(same family: e.g. PRF vs PRP, skin boosters, collagen stimulators) with canonical '
              'English names AND local synonyms where relevant (subtitle + aliases). '
              'If it is a clinic/brand/doctor name, return clinic items (at least one) regardless of mode.',
        },
      ],
    };

    final res = await _client.post(
      uri,
      headers: {
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(body),
    );

    _throwIfOpenAiHttpFailed(res);

    final decoded = jsonDecode(res.body) as Map<String, Object?>;
    final choices = (decoded['choices'] as List?) ?? const [];
    final first = choices.isNotEmpty ? (choices.first as Map) : const {};
    final msg = (first['message'] as Map?) ?? const {};
    final content = _stripCodeFences((msg['content'] as String?)?.trim() ?? '');
    if (content.isEmpty) return const [];

    try {
      final parsed = jsonDecode(content);
      final arr = _extractResultsArray(parsed);
      var items = arr
          .whereType<Map>()
          .map((m) => OpenAISearchItem.fromJson(m.cast<String, Object?>()))
          .toList(growable: false);
      items = _filterSearchItemsForEzGelPrf(trimmed, items, city, categoryPill);
      return items;
    } catch (_) {
      final lines = content
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .take(6)
          .toList(growable: false);
      final fallbackClinic =
          mode == 'clinic' || _fallbackQueryLooksLikeClinicName(trimmed);
      return [
        for (final l in lines)
          OpenAISearchItem(
            title: l.replaceFirst(RegExp(r'^[\-\*\d\.\)\s]+'), ''),
            subtitle: '$city · $categoryPill',
            type: fallbackClinic
                ? OpenAISearchItemType.clinic
                : OpenAISearchItemType.procedure,
            priceHint: null,
          ),
      ];
    }
  }

  /// Swaps "On request" rows in the compare widget with priced clinics from
  /// [_fullBatchCache] (same procedure + city as [buildClinicsList]).
  List<OpenAIClinic> _replaceUnpricedComparisonFromBatch({
    required List<OpenAIClinic> ranked,
    required List<OpenAIClinic> pool,
    int maxCount = 6,
  }) {
    final take = ranked.length > maxCount
        ? ranked.take(maxCount).toList(growable: false)
        : List<OpenAIClinic>.from(ranked);
    final used = take.map((c) => c.name.toLowerCase().trim()).toSet();

    final replacements =
        pool
            .where(
              (c) =>
                  c.priceMin > 0 &&
                  isJustifiedProcedurePrice(c) &&
                  !used.contains(c.name.toLowerCase().trim()),
            )
            .toList(growable: false)
          ..sort((a, b) {
            final rc = b.reviews.compareTo(a.reviews);
            if (rc != 0) return rc;
            return b.rating.compareTo(a.rating);
          });

    var rj = 0;
    final out = <OpenAIClinic>[];
    for (final c in take) {
      if (c.priceMin > 10) {
        out.add(c);
      } else if (rj < replacements.length) {
        final rep = replacements[rj++];
        out.add(rep);
        used.add(rep.name.toLowerCase().trim());
      }
    }
    while (out.length < maxCount && rj < replacements.length) {
      final next = replacements[rj++];
      final k = next.name.toLowerCase().trim();
      if (!used.contains(k)) {
        out.add(next);
        used.add(k);
      }
    }
    for (var i = 0; i < out.length; i++) {
      out[i] = out[i].copyWith(rank: i + 1);
    }
    return out;
  }

  /// Loads clinics list + fullbatch from Firestore into [_fullBatchCache] so
  /// [buildComparison] can swap unpriced rows without an extra AI call.
  Future<void> _hydrateFullBatchCacheFromFirestore(
    String normalizedProcedure,
    String city,
  ) async {
    final batchKey = _batchCacheKey(normalizedProcedure, city);
    if ((_fullBatchCache[batchKey]?.isNotEmpty ?? false)) {
      return;
    }
    final baseKey =
        'clinicsList|$_kClinicsListCacheRevision|$normalizedProcedure|$city|';
    final firestoreCached = await _loadFromFirestore(baseKey);
    if (firestoreCached == null) return;
    final filtered = _filterUnverifiedClinics(firestoreCached);
    final fullBatchCached = await _loadFromFirestore('$baseKey|fullbatch');
    if (fullBatchCached != null) {
      final fullFiltered = _filterUnverifiedClinics(fullBatchCached);
      _fullBatchCache[batchKey] = List<OpenAIClinic>.from(fullFiltered.clinics);
      debugPrint(
        '[GP] Comparison: Firestore full batch ${fullFiltered.clinics.length} '
        'clinics for swap pool',
      );
    } else {
      _fullBatchCache[batchKey] = List<OpenAIClinic>.from(filtered.clinics);
      debugPrint(
        '[GP] Comparison: Firestore page-only ${filtered.clinics.length} '
        'clinics for swap pool',
      );
    }
  }

  /// The Python server and the app keep verified prices in separate Firestore
  /// collections. Read the app's pools too, without delaying a cold search
  /// indefinitely or trusting a guide price that fails the live card validator.
  Future<List<OpenAIClinic>> _loadDiscoveryToolFirestoreSeeds({
    required String cacheKey,
    required String queryOrSelection,
    required String city,
    required String mode,
    bool forceReload = false,
  }) async {
    final collected = <OpenAIClinic>[];
    Future<void> collect(Future<List<OpenAIClinic>> read) async {
      try {
        collected.addAll(await read);
      } catch (e) {
        debugPrint('[GP TOOL] app Firestore read failed · $e');
      }
    }

    await Future.wait<void>([
      collect(
        ExploreGooglePriceStore.instance
            .load(city: city, procedure: queryOrSelection, forceReload: forceReload)
            .then(_clinicsFromGooglePriceJson),
      ),
      collect(
        ExploreCuratedPriceStore.instance.load(
          city: city,
          procedure: queryOrSelection,
        ),
      ),
      collect(
        _loadExploreComparisonPool(
          cacheKey: cacheKey,
          queryOrSelection: queryOrSelection,
          city: city,
          mode: mode,
        ).then((result) => result?.clinics ?? const <OpenAIClinic>[]),
      ),
    ]).then<void>((_) {}).timeout(const Duration(seconds: 3), onTimeout: () {});

    final verified = <OpenAIClinic>[];
    for (final original in collected) {
      if (!exploreClinicEligibleForVerifiedPool(
        original,
        procedure: queryOrSelection,
        city: city,
      )) {
        continue;
      }
      final candidate = withExploreClinicDisplayName(original);
      if (!explorePriceIsVerified(candidate) ||
          !isJustifiedProcedurePrice(candidate, procedure: queryOrSelection) ||
          candidate.name.trim().isEmpty ||
          isMarketplaceBrandName(candidate.name) ||
          exploreListedPriceIsNonClinicContent(
            sourceUrl: candidate.priceSourceUrl,
            website: candidate.area,
          )) {
        continue;
      }
      if (verified.any((c) => exploreClinicsAreSameProvider(c, candidate))) {
        continue;
      }
      verified.add(candidate);
      if (verified.length >= 40) break;
    }
    final previous =
        _comparisonMemoryCache[cacheKey]?.clinics ?? const <OpenAIClinic>[];
    // City selection can clear the display memo. Shuffle eligible saves too
    // so that a fixed Firestore read order does not lock the first two forever.
    verified.shuffle(math.Random());
    bool recentlyShown(OpenAIClinic c) =>
        previous.any((old) => exploreClinicsAreSameProvider(old, c));
    return [
      ...verified.where((c) => !recentlyShown(c)),
      ...verified.where(recentlyShown),
    ];
  }


  List<OpenAIClinic> _acceptedIndexedClinics(
    List<ExploreDiscoveryToolRow> rows, {
    required String city, required String procedure,
  }) {
    final canonical = ExplorePriceDiscoveryTool.procedureForTool(procedure);
    final accepted = <OpenAIClinic>[];
    for (final row in rows) {
      if (exploreUrlConflictsWithSearchCity(row.sourceUrl, city) ||
          !ExplorePriceDiscoveryTool.rowMatchesRequestedProcedure(row, canonical)) continue;
      final clinic = _clinicFromDiscoveryToolRow(row, city: city, procedure: canonical);
      if (clinic == null || !explorePriceIsVerified(clinic) ||
          !exploreClinicFitsSearchCity(clinic, city) ||
          !exploreClinicFitsCompareProcedure(clinic, procedure)) continue;
      accepted.add(withExploreClinicDisplayName(clinic));
    }
    return mergeExploreClinicIdentities(accepted);
  }

  OpenAIComparisonResult comparisonWithDiscoveryRows({
    required String city, required String procedure,
    required List<ExploreDiscoveryToolRow> rows,
    OpenAIComparisonResult? previous,
  }) {
    final saved = _acceptedIndexedClinics(
      rows.where((r) => r.origin.startsWith('firestore')).toList(),
      city: city, procedure: procedure,
    );
    final fresh = _acceptedIndexedClinics(
      rows.where((r) => !r.origin.startsWith('firestore')).toList(),
      city: city, procedure: procedure,
    );
    final retained = (previous?.clinics ?? const <OpenAIClinic>[])
        .where((c) => explorePriceIsVerified(c) &&
            exploreClinicFitsSearchCity(c, city) &&
            exploreClinicFitsCompareProcedure(c, procedure));
    final candidates = selectExploreCompareRows<OpenAIClinic>(
      saved: mergeExploreAcceptedRows<OpenAIClinic>(retained, saved,
        sameProvider: exploreClinicsAreSameProvider),
      live: fresh, sameProvider: exploreClinicsAreSameProvider,
    );
    final clinics = stabilizeExploreCompareRows<OpenAIClinic>(
      shown: retained, incoming: candidates,
      stillEligible: (c) => explorePriceIsVerified(c) && exploreClinicFitsSearchCity(c, city),
      sameProvider: exploreClinicsAreSameProvider,
    );
    final meta = previous ?? OpenAIComparisonResult(
      city: city, topic: procedure, topicType: OpenAISearchItemType.procedure,
      summary: '', rangeLabel: '', mapCenter: const OpenAICoord(0, 0), clinics: const [],
    );
    return _postprocessPreviewComparison(meta.copyWith(clinics: clinics), preserveOrder: true);
  }

  Stream<OpenAIComparisonResult> _buildIndexedClinicsList({
    required String procedure, required String city, required int count,
    required List<String> excludeNames,
  }) async* {
    final key = 'comparison|$kExploreComparisonCacheRevision|$procedure|'
        '${_localityCacheSegment(city)}|procedure';
    ExplorePriceDiscoveryTool.instance.focusDiscovery(key);
    var pool = await _loadDiscoveryToolFirestoreSeeds(
      cacheKey: key, queryOrSelection: procedure, city: city, mode: 'procedure',
      forceReload: true,
    );
    OpenAIComparisonResult snapshot(String summary) {
      _fullBatchCache[_batchCacheKey(procedure, city)] = List.of(pool);
      final names = excludeNames.map((n) => n.toLowerCase().trim()).toSet();
      return OpenAIComparisonResult(
        city: city, topic: procedure, topicType: OpenAISearchItemType.procedure,
        summary: summary, rangeLabel: '', mapCenter: const OpenAICoord(0, 0),
        clinics: pool.where((c) => !names.contains(c.name.toLowerCase().trim()))
            .take(count).toList(),
      );
    }
    yield snapshot('Checking the price index…');
    final indexed = await ExplorePriceDiscoveryTool.instance.loadIndexedPrices(
      city: city, procedure: procedure, countryCode: _countryCodeForCity(city),
    );
    if (indexed.searchCompleted) {
      pool = mergeExploreAcceptedRows<OpenAIClinic>(
        pool, _acceptedIndexedClinics(indexed.rows, city: city, procedure: procedure),
        sameProvider: exploreClinicsAreSameProvider,
      );
      if (pool.isNotEmpty) {
        unawaited(ExploreGooglePriceStore.instance.upsert(
          city: city, procedure: procedure,
          clinics: [for (final c in pool) _clinicToGooglePriceJson(c)],
        ));
      }
    }
    yield snapshot(pool.isEmpty ? 'Looking for verified public prices…' : '');
    // Pagination may explicitly discover more providers; an empty index must
    // never be treated as a completed, permanently empty result.
    if (pool.length >= count && excludeNames.isEmpty) return;
    final job = await ExplorePriceDiscoveryTool.instance.enqueueDiscoveryJob(
      city: city, procedure: procedure, countryCode: _countryCodeForCity(city),
      reason: excludeNames.isEmpty ? 'thin_market' : 'user',
      foreground: true, focusKey: key,
    );
    if (job == null) {
      yield snapshot('Price search is unavailable. Please try again.');
      return;
    }
    await for (final state in ExplorePriceDiscoveryTool.instance.watchDiscoveryJob(job)) {
      if (state.rows.isNotEmpty) {
        pool = mergeExploreAcceptedRows<OpenAIClinic>(
          pool, _acceptedIndexedClinics(state.rows, city: city, procedure: procedure),
          sameProvider: exploreClinicsAreSameProvider,
        );
        unawaited(ExploreGooglePriceStore.instance.upsert(
          city: city, procedure: procedure,
          clinics: [for (final c in pool) _clinicToGooglePriceJson(c)],
        ));
      }
      yield snapshot(state.isFinished
          ? (state.status == 'failed' ? 'Search could not finish. Please try again.'
          : pool.isEmpty ? 'No verified public prices found yet.' : '')
          : state.message);
    }
  }

  /// Bypass the static process-wide cache even if it hasn't gone stale yet —
  /// wire this to a manual pull-to-refresh / 'find more' action.
  Future<OpenAIComparisonResult> buildComparison({
    required String queryOrSelection,
    required String city,
    required String mode,
    required String categoryPill,
    void Function(OpenAIComparisonResult partial)? onProgress,
    bool awaitEmptyAi = true,
    bool forceRefresh = false,
    bool searchNewGoogle = true,
    int? googleLiveTargetOverride,
    bool claimLiveSearch = true,
    bool joinInFlight = true,
    bool allowDeepFallbacks = true,
    bool discoveryToolPriority = true,
    bool backgroundRefresh = false,
  }) async {
    final compareSw = Stopwatch()..start();
    void logCompareTiming(String source) {
      debugPrint(
        '[GP] Compare timing: $categoryPill · $city · source=$source · '
        '${compareSw.elapsedMilliseconds}ms',
      );
    }

    final localitySeg = _localityCacheSegment(city);
    final cacheKey =
        'comparison|$kExploreComparisonCacheRevision|$queryOrSelection|$localitySeg|$mode';
    final countryCode = _countryCodeForCity(city);
    // A tab return is a read of the displayed snapshot. Collection already has
    // its own durable job; do not rehydrate every Firestore store or await it
    // merely because the comparison memo's ten-minute clock has expired.
    if (!forceRefresh && searchNewGoogle && !backgroundRefresh) {
      final memo = _verifiedTabSnapshots[cacheKey];
      final unchanged = memo != null &&
          memo.revision == kExplorePriceExtractRevision &&
          identical(memo.source, _comparisonMemoryCache[cacheKey]);
      final retained = unchanged ? memo.verified : getCachedComparison(cacheKey);
      if (retained != null &&
          retained.city.trim().toLowerCase() == city.trim().toLowerCase()) {
        final usable = unchanged ? retained.clinics : _pricedExploreClinics(
          retained.clinics, procedure: queryOrSelection,
        ).where((c) => exploreClinicFitsSearchCity(c, city)).toList();
        if (usable.length >= kExploreCompareMaxClinics) {
          if (claimLiveSearch) {
            _claimLiveCompareTopUp(cacheKey, label: '$categoryPill · $city');
          }
          final restored = retained.copyWith(
            clinics: List<OpenAIClinic>.unmodifiable(
              usable.take(kExploreCompareMaxClinics),
            ),
          );
          final now = DateTime.now();
          final validatedAt = unchanged ? memo.validatedAt : now;
          _comparisonMemoryCache[cacheKey] = restored;
          _verifiedTabSnapshots[cacheKey] = (
            source: restored, revision: kExplorePriceExtractRevision,
            validatedAt: validatedAt, verified: restored,
          );
          _comparisonGoogleMixComplete.add(cacheKey);
          onProgress?.call(restored);
          reportCompareDisplayCount(cacheKey, restored.clinics.length);
          final builtAt = _comparisonCacheBuiltAt[cacheKey] ?? validatedAt;
          final sourceNeedsRefresh = restored.clinics.any((c) {
            final checked = c.lastCheckedAt ?? c.priceVerifiedAt;
            final ttl = exploreCuratedPriceIsTrusted(c)
                ? kExploreCuratedStaleAfter : kExploreVerifiedPriceTtl;
            return checked == null || now.difference(checked) > ttl;
          });
          final priorRefresh = _verifiedTabRefreshAt[cacheKey];
          if ((sourceNeedsRefresh || now.difference(builtAt) > _kComparisonCacheTtl ||
              now.difference(validatedAt) > _kComparisonCacheTtl) &&
              (priorRefresh == null || now.difference(priorRefresh) > _kComparisonCacheTtl)) {
            _verifiedTabRefreshAt[cacheKey] = now;
            Timer.run(() {
              unawaited(buildComparison(
                queryOrSelection: queryOrSelection, city: city, mode: mode,
                categoryPill: categoryPill, backgroundRefresh: true,
                claimLiveSearch: false, joinInFlight: false,
                onProgress: onProgress,
              ).catchError((Object error) {
                debugPrint('[GP] Snapshot refresh failed · $error');
                return restored;
              }));
            });
          }
          logCompareTiming('memory-verified');
          return restored;
        }
      }
    }
    if (forceRefresh) {
      _comparisonDisplayEpoch[cacheKey] = (_comparisonDisplayEpoch[cacheKey] ?? 0) + 1;
      _comparisonMemoryCache.remove(cacheKey);
      _cache.remove(cacheKey);
      _interactiveRefresh.remove(cacheKey);
      _discoveryToolBuilds.remove(cacheKey);
    }
    final displayEpoch = _comparisonDisplayEpoch[cacheKey] ?? 0;
    if (kDebugMode) {
      debugPrint(
        '[EXPLORE CITY] compare display=$city cityId=${_activeCityIdentity?.cityId ?? ""} '
        'cc=$countryCode cacheSeg=$localitySeg',
      );
    }

    final builtAt = _comparisonCacheBuiltAt[cacheKey];
    final isStale =
        builtAt != null &&
        DateTime.now().difference(builtAt) > _kComparisonCacheTtl;
    if ((forceRefresh || isStale) &&
        !_comparisonAiTopUpInFlight.contains(cacheKey) &&
        !_discoveryToolBuilds.containsKey(cacheKey)) {
      debugPrint(
        '[GP] Comparison cache ${forceRefresh ? "force-refreshed" : "stale"} — '
        'rebuilding $queryOrSelection · $city',
      );
      _cache.remove(cacheKey);
      // Verified memory rows bridge an index refresh; city/procedure validators
      // below still reject mismatches.
      _comparisonTopUpExhausted.remove(cacheKey);
      _comparisonTopUpExhaustedAt.remove(cacheKey);
      _comparisonGoogleMixComplete.remove(cacheKey);
      _discoveryToolSettled.remove(cacheKey);
      _discoveryToolIncomplete.remove(cacheKey);
      _comparisonDeepFillStarted.remove(cacheKey);
      _comparisonPendingFillWork.remove(cacheKey);
      _comparisonCacheBuiltAt.remove(cacheKey);
    }

    // Keep the existing four-card display while discovery refreshes the pool.

    if (onProgress != null) {
      _comparisonProgressListeners
          .putIfAbsent(
            cacheKey,
            () => <void Function(OpenAIComparisonResult)>[],
          )
          .add(onProgress);
    }

    var rotateKeepVisible = false;

    void emitProgress(OpenAIComparisonResult partial) {
      if ((_comparisonDisplayEpoch[cacheKey] ?? 0) != displayEpoch) return;
      final listeners = _comparisonProgressListeners[cacheKey];
      if (listeners == null || listeners.isEmpty) return;
      for (final cb in List<void Function(OpenAIComparisonResult)>.from(
        listeners,
      )) {
        try {
          cb(partial);
        } catch (e) {
          debugPrint('[GP] Comparison onProgress error: $e');
        }
      }
    }

    try {
      // Reopening keeps the displayed snapshot; collection remains independent.
      final pendingTool = _discoveryToolBuilds[cacheKey];
      if (searchNewGoogle && pendingTool != null) {
        final preview = _comparisonMemoryCache[cacheKey];
        if (preview != null && preview.clinics.isNotEmpty) {
          emitProgress(preview);
        }
        return await pendingTool;
      }

      // Join an in-flight Google top-up. Never await a 2-card memo and
      // start a second builder — that second builder sees inFlight and
      // skips search, so every pill stays at 2.
      if (searchNewGoogle) {
        if (claimLiveSearch) {
          _claimLiveCompareTopUp(cacheKey, label: '$categoryPill · $city');
        }
        if (_comparisonAiTopUpInFlight.contains(cacheKey)) {
          final mem = _comparisonMemoryCache[cacheKey];
          if (mem != null && mem.clinics.isNotEmpty) emitProgress(mem);
          final pending = _comparisonAiTopUpCompleters[cacheKey];
          final pricedOnScreen = mem == null
              ? 0
              : _pricedExploreClinics(
                  mem.clinics,
                  procedure: queryOrSelection,
                ).length;
          final joinPreview = exploreShouldJoinInFlightTopUp(
            joinInFlight: joinInFlight,
            googleLiveTargetOverride: googleLiveTargetOverride,
            pricedOnScreen: pricedOnScreen,
          );
          if (joinPreview && pending != null && !pending.isCompleted) {
            return await pending.future;
          }
          if (!joinInFlight) {
            return mem ??
                OpenAIComparisonResult(
                  city: city,
                  topic: queryOrSelection,
                  topicType: OpenAISearchItemType.procedure,
                  summary: '',
                  rangeLabel: '',
                  mapCenter: const OpenAICoord(0, 0),
                  clinics: const [],
                );
          }
          // Focused pill wants 4 cards. The All-tab preview (target=1) is
          // using this key — wait for it to cancel, then fill to 4.
          if (pending != null && !pending.isCompleted) {
            debugPrint(
              '[GP] Supersede preview top-up · $pricedOnScreen shown · '
              '$categoryPill · $city',
            );
            await pending.future;
          }
        }
        final mem = _comparisonMemoryCache[cacheKey];
        final memN = mem == null
            ? 0
            : _pricedExploreClinics(
                mem.clinics,
                procedure: queryOrSelection,
              ).length;
        if (mem != null &&
            memN > 0 &&
            memN < kExploreCompareMaxClinics &&
            _comparisonTopUpExhausted.contains(cacheKey) &&
            !_comparisonAiTopUpInFlight.contains(cacheKey)) {
          final exhaustedAt = _comparisonTopUpExhaustedAt[cacheKey];
          final cooling =
              exhaustedAt != null &&
              DateTime.now().difference(exhaustedAt) <
                  (memN >= kExploreFirestoreSeedClinics
                      ? _kTopUpRetryCooldown
                      : _kPartialFillRetryCooldown);
          if (cooling) {
            emitProgress(mem);
            _comparisonGoogleMixComplete.add(cacheKey);
            logCompareTiming('top-up-exhausted');
            debugPrint(
              '[GP] Comparison top-up cooldown: '
              '$memN verified · '
              '$categoryPill · $city',
            );
            return mem;
          }
          _comparisonTopUpExhausted.remove(cacheKey);
          _comparisonTopUpExhaustedAt.remove(cacheKey);
        }
        // Keep the session snapshot on an ordinary tab return. A manual
        // refresh clears it above, allowing selection from the growing pool.
        if (mem != null && memN > 0) {
          emitProgress(mem);
          rotateKeepVisible = memN >= kExploreCompareMaxClinics;
          _cache.remove(cacheKey);
          _comparisonGoogleMixComplete.remove(cacheKey);
          // Keep the preview for the tool builder and joined callers.
          debugPrint(
            '[GP] Compare restore · $categoryPill · '
            '$memN cards retained while collecting',
          );
        } else if (mem == null || memN <= 0) {
          _comparisonGoogleMixComplete.remove(cacheKey);
          _cache.remove(cacheKey);
          _comparisonMemoryCache.remove(cacheKey);
        }
      }

      final memoKey = searchNewGoogle ? cacheKey : '$cacheKey|preload';
      final building = _memoize<OpenAIComparisonResult>(memoKey, () async {
        final keepPriorCards = rotateKeepVisible;
        rotateKeepVisible = false;
        _comparisonCacheBuiltAt[cacheKey] = DateTime.now();
        debugPrint('[GP] Compare start · $categoryPill · $city');
        OpenAIComparisonResult wrap(
          List<OpenAIClinic> clinics,
          OpenAIComparisonResult meta,
        ) {
          return _postprocessPreviewComparison(
            meta.copyWith(
              clinics: clinics.take(kExploreCompareMaxClinics).toList(),
            ),
            preserveOrder: true,
          );
        }

        // Python hunter is the first search. It does not need an OpenAI key.
        // Firestore and Google run only when that server cannot be reached.
        // A timeout or a broken response is not saved as a finished search.
        if (searchNewGoogle && ExplorePriceDiscoveryTool.instance.enabled) {
          final requestedProcedure = ExplorePriceDiscoveryTool.procedureForTool(
            queryOrSelection,
            pill: categoryPill,
          );
          final toolMeta = OpenAIComparisonResult(
            city: city,
            topic: queryOrSelection,
            topicType: OpenAISearchItemType.procedure,
            summary: '',
            rangeLabel: '',
            mapCenter: const OpenAICoord(0, 0),
            clinics: const [],
          );
          final appStored = await _loadDiscoveryToolFirestoreSeeds(
            cacheKey: cacheKey,
            queryOrSelection: queryOrSelection,
            city: city,
            mode: mode,
            forceReload: forceRefresh,
          );
          final storedNames = appStored.map((c) => c.name).toList();
          final storedHosts = <String>{
            for (final host in appStored.map(exploreClinicWebsiteHost))
              if (host.isNotEmpty && !isMarketplaceOrDirectoryHost(host)) host,
          };
          for (final entry in _comparisonMemoryCache.entries) {
            if (!entry.key.contains('|$localitySeg|')) continue;
            for (final clinic in entry.value.clinics) {
              if (!explorePriceIsVerified(clinic)) continue;
              if (exploreUrlConflictsWithSearchCity(
                clinic.priceSourceUrl,
                city,
              )) {
                continue;
              }
              if (!exploreClinicFitsSearchCity(clinic, city)) continue;
              final host = exploreClinicWebsiteHost(clinic);
              if (host.isEmpty || isMarketplaceOrDirectoryHost(host)) continue;
              storedHosts.add(host);
            }
          }
          final cityHosts = storedHosts.toList();
          debugPrint(
            '[GP TOOL] app Firestore seeds · $categoryPill · $city · '
            '${appStored.length}',
          );
          final rejectedToolUrls = <String>{};
          final toolOriginsByUrl = <String, String>{
            for (final c in appStored) c.priceSourceUrl: 'firestore_app',
          };
          // Each stream event may contain a different subset. Accumulate
          // accepted providers across events and the bounded continuation.
          var acceptedToolRows = <OpenAIClinic>[];
          List<OpenAIClinic> mapToolRows(List<ExploreDiscoveryToolRow> rows) {
            final saved = <OpenAIClinic>[
              for (final row in appStored)
                if (!rejectedToolUrls.contains(row.priceSourceUrl)) row,
            ];
            final live = <OpenAIClinic>[];
            final acceptedThisEvent = <OpenAIClinic>[];
            for (final row in rows) {
              void dropRow(String reason) {
                if (row.sourceUrl.isNotEmpty) {
                  rejectedToolUrls.add(row.sourceUrl);
                }
                debugPrint(
                  'DROP ${row.clinicName} $reason ${row.sourceUrl}',
                );
              }

              if (exploreUrlConflictsWithSearchCity(row.sourceUrl, city) ||
                  exploreQuotedPriceConflictsWithSearchCity(
                    city: city,
                    url: row.sourceUrl,
                    evidence: row.rawEvidence,
                  )) {
                dropRow('city_url_conflict');
                continue;
              }
              if (isMarketplaceOrDirectoryHost(row.sourceUrl) &&
                  !ExplorePriceDiscoveryTool.canUseMarketplacePrice(row)) {
                dropRow('directory');
                continue;
              }
              final sourcePath = row.sourceUrl.toLowerCase();
              if (sourcePath.contains('price-guide') ||
                  sourcePath.contains('masseter') ||
                  sourcePath.contains('facial-palsy') ||
                  sourcePath.contains('facial_palsy')) {
                dropRow('procedure_mismatch');
                continue;
              }
              if (!ExplorePriceDiscoveryTool.rowMatchesRequestedProcedure(
                row,
                requestedProcedure,
              )) {
                dropRow('procedure_mismatch');
                continue;
              }
              final mapped = _clinicFromDiscoveryToolRow(
                row,
                city: city,
                procedure: requestedProcedure,
              );
              if (mapped == null || !explorePriceIsVerified(mapped) ||
                  !isJustifiedProcedurePrice(mapped, procedure: requestedProcedure)) {
                dropRow('sanity');
                continue;
              }
              final named = withExploreClinicDisplayName(mapped);
              if (named.name.trim().isEmpty) {
                dropRow('sanity');
                continue;
              }
              if (isMarketplaceBrandName(named.name)) {
                dropRow('marketplace');
                continue;
              }
              if (exploreUrlConflictsWithSearchCity(
                named.priceSourceUrl,
                city,
              )) {
                dropRow('city_url_conflict');
                continue;
              }
              if (!exploreClinicFitsSearchCity(named, city)) {
                dropRow('city_fit');
                continue;
              }
              if (!exploreClinicFitsCompareProcedure(named, queryOrSelection)) {
                dropRow('procedure_mismatch');
                continue;
              }
              if (exploreListedPriceIsNonClinicContent(
                sourceUrl: named.priceSourceUrl,
                website: named.area,
              )) {
                dropRow('sanity');
                continue;
              }
              if (acceptedThisEvent.any(
                (c) => exploreClinicsAreSameProvider(c, named),
              )) {
                continue;
              }
              acceptedThisEvent.add(named);
              toolOriginsByUrl[named.priceSourceUrl] = row.origin;
            }
            acceptedToolRows = mergeExploreAcceptedRows<OpenAIClinic>(
              acceptedToolRows,
              acceptedThisEvent,
              sameProvider: exploreClinicsAreSameProvider,
            ).where((c) => !rejectedToolUrls.contains(c.priceSourceUrl)).toList();
            for (final named in acceptedToolRows) {
              final savedIndex = saved.indexWhere(
                (c) => exploreClinicsAreSameProvider(c, named),
              );
              if (savedIndex >= 0) {
                // A freshly checked server amount and method replace the
                // old app price while this provider retains its saved slot.
                // The server row has no Maps score; keep the one already
                // stored for this clinic.
                final kept = saved[savedIndex];
                saved[savedIndex] = named.rating > 0
                    ? named
                    : named.copyWith(
                        rating: kept.rating,
                        reviews: kept.reviews > 0
                            ? kept.reviews
                            : named.reviews,
                        placeId: named.placeId.trim().isNotEmpty
                            ? named.placeId
                            : kept.placeId,
                      );
                toolOriginsByUrl[named.priceSourceUrl] = 'firestore_refreshed';
                continue;
              }
              final origin = toolOriginsByUrl[named.priceSourceUrl] ?? '';
              final destination = origin.startsWith('firestore') ? saved : live;
              destination.add(named);
            }
            return selectExploreCompareRows<OpenAIClinic>(
              saved: saved.where((c) => exploreClinicFitsSearchCity(c, city)),
              live: live,
              sameProvider: exploreClinicsAreSameProvider,
            );
          }

          // Keep the last valid display during refresh; partials cannot shrink it.
          var shown =
              _comparisonMemoryCache[cacheKey]?.clinics
                  .where(
                    (c) =>
                        explorePriceIsVerified(c) &&
                        isJustifiedProcedurePrice(c, procedure: queryOrSelection) &&
                        exploreClinicFitsSearchCity(c, city) &&
                        exploreClinicFitsCompareProcedure(c, queryOrSelection),
                  )
                  .toList() ??
              <OpenAIClinic>[];
          void publishToolRows(
            List<ExploreDiscoveryToolRow> rows, {
            bool replace = false,
          }) {
            if ((_comparisonDisplayEpoch[cacheKey] ?? 0) != displayEpoch) return;
            if (replace) acceptedToolRows = <OpenAIClinic>[];
            final candidates = mapToolRows(rows);
            final retained = _comparisonMemoryCache[cacheKey]?.clinics ?? shown;
            final stable = stabilizeExploreCompareRows<OpenAIClinic>(
              shown: retained,
              incoming: candidates,
              stillEligible: (c) => !rejectedToolUrls.contains(c.priceSourceUrl) &&
                  explorePriceIsVerified(c) &&
                  isJustifiedProcedurePrice(c, procedure: queryOrSelection) &&
                  exploreClinicFitsSearchCity(c, city) &&
                  exploreClinicFitsCompareProcedure(c, queryOrSelection),
              sameProvider: exploreClinicsAreSameProvider,
            );
            final clinics = overlayExploreClinicRatings(
              shown: stable, enriched: candidates,
            );
            final partialResult = wrap(clinics, toolMeta);
            // Count the processed cards actually sent to the screen, rather
            // than an earlier candidate list that postprocessing may prune.
            shown = partialResult.clinics;
            _comparisonMemoryCache[cacheKey] = partialResult;
            emitProgress(partialResult);
            debugPrint(
              '[GP TOOL] cards · $categoryPill · $city · '
              '${shown.length} verified',
            );
          }

          if (appStored.isNotEmpty) publishToolRows(const []);

          OpenAIComparisonResult finishInteractive(String source) {
            if ((_comparisonDisplayEpoch[cacheKey] ?? 0) != displayEpoch) {
              return _comparisonMemoryCache[cacheKey] ?? wrap(const [], toolMeta);
            }
            final toolResult = wrap(shown, toolMeta);
            _comparisonMemoryCache[cacheKey] = toolResult;
            _discoveryToolIncomplete.remove(cacheKey);
            _discoveryToolSettled.add(cacheKey);
            _comparisonGoogleMixComplete.add(cacheKey);
            _comparisonCacheBuiltAt[cacheKey] = DateTime.now();
            emitProgress(toolResult);
            debugPrint(
              '[GP TOOL] done · $categoryPill · $city · '
              '${toolResult.clinics.length} verified',
            );
            logCompareTiming(source);
            return toolResult;
          }


          Future<void> persistAcceptedRows() async {
            if (acceptedToolRows.isEmpty) return;
            await ExploreGooglePriceStore.instance.upsert(
              city: city, procedure: queryOrSelection,
              clinics: [
                for (final c in acceptedToolRows) _clinicToGooglePriceJson(c),
              ],
            );
          }

          Future<void> loadServerIndex({
            Duration deadline = const Duration(seconds: 5),
          }) async {
            final outcome = await ExplorePriceDiscoveryTool.instance.loadIndexedPrices(
              city: city, procedure: queryOrSelection, countryCode: countryCode,
              pill: categoryPill, deadline: deadline,
            );
            if (outcome.searchCompleted) {
              rejectedToolUrls.addAll(outcome.invalidatedSourceUrls);
              publishToolRows(outcome.rows);
              unawaited(persistAcceptedRows());
            }
          }

          Future<void> refreshAndDiscover() async {
            bool canPublishNote() => _liveCompareTopUpKey == cacheKey &&
                (_comparisonDisplayEpoch[cacheKey] ?? 0) == displayEpoch;
            // Start discovery before waiting for known-page refreshes.
            final job = await ExplorePriceDiscoveryTool.instance.enqueueDiscoveryJob(
              city: city, procedure: queryOrSelection, countryCode: countryCode,
              pill: categoryPill, reason: 'thin_market',
              foreground: canPublishNote(), focusKey: cacheKey,
              clientStoredCount: appStored.length,
              knownClinicHosts: cityHosts, knownClinicNames: storedNames,
              excludedSourceUrls: rejectedToolUrls.toList(),
            );
            if (job != null && canPublishNote()) {
              backgroundHuntNote.value = ExploreBackgroundHunt(
                city: city, pill: categoryPill, jobId: job.isFinished ? '' : job.id,
                message: job.message,
              );
            }
            final sw = Stopwatch()..start();
            await loadServerIndex();
            final remaining = ExplorePriceDiscoveryTool.interactiveDeadline - sw.elapsed;
            // Refresh only known evidence pages. This endpoint cannot call
            // Serper, Places, Firecrawl or a browser renderer.
            if (shown.isNotEmpty && remaining > const Duration(seconds: 1)) {
              final fresh = await ExplorePriceDiscoveryTool.instance.refreshKnownPrices(
                city: city, procedure: queryOrSelection, countryCode: countryCode,
                pill: categoryPill, deadline: remaining,
              );
              if (fresh.searchCompleted) {
                rejectedToolUrls.addAll(fresh.invalidatedSourceUrls);
                publishToolRows(fresh.rows);
                unawaited(persistAcceptedRows());
              }
            }
            if (job == null) {
              if (canPublishNote()) {
                backgroundHuntNote.value = ExploreBackgroundHunt(
                  city: city, pill: categoryPill,
                  message: shown.isEmpty
                      ? 'Price search is unavailable. Try Find more clinics again.'
                      : 'Saved prices are available. Price search could not connect.',
                );
              }
              return;
            }
            if (canPublishNote()) {
              backgroundHuntNote.value = ExploreBackgroundHunt(
                city: city, pill: categoryPill, jobId: job.isFinished ? '' : job.id,
                message: job.message,
              );
            }
            var lastPublishedRows = '';
            var completionPublished = false;
            await for (final state in ExplorePriceDiscoveryTool.instance.watchDiscoveryJob(
              job, focusKey: cacheKey,
            )) {
              final changedRows = state.rowsFingerprint != lastPublishedRows;
              final firstCompletion = state.status == 'completed' && !completionPublished;
              if (state.rows.isNotEmpty && (changedRows || firstCompletion)) {
                lastPublishedRows = state.rowsFingerprint;
                completionPublished = completionPublished || firstCompletion;
                publishToolRows(state.rows, replace: state.status == 'completed');
                // Intermediate rows are shown while final identity checks run.
                // Persist only the completed accepted set to the app cache.
                if (state.status == 'completed') unawaited(persistAcceptedRows());
              }
              if (canPublishNote()) reportCompareDisplayCount(cacheKey, shown.length);
              if (canPublishNote() && backgroundHuntNote.value?.jobId == job.id) {
                backgroundHuntNote.value = ExploreBackgroundHunt(
                  city: city, pill: categoryPill,
                  jobId: state.isFinished ? '' : job.id, message: state.message,
                );
              }
              if (state.isFinished) {
                await loadServerIndex();
                if (canPublishNote()) {
                  backgroundHuntNote.value = ExploreBackgroundHunt(
                    city: city, pill: categoryPill,
                    message: state.status == 'failed'
                        ? 'Search could not finish. Try Find more clinics again.'
                        : shown.isEmpty
                        ? 'No verified public prices found yet. Try Find more clinics later.'
                        : shown.length < kExploreCompareMaxClinics
                        ? 'Search finished. No more verified public prices found this time.'
                        : '',
                  );
                }
              }
            }
            if (canPublishNote() && backgroundHuntNote.value?.jobId == job.id) {
              backgroundHuntNote.value = ExploreBackgroundHunt(
                city: city, pill: categoryPill,
                message: 'Discovery is still running. You can check again later.',
              );
            }
          }

          if (backgroundRefresh && !_interactiveRefresh.containsKey(cacheKey)) {
            if (_liveCompareTopUpKey == cacheKey) {
              backgroundHuntNote.value = ExploreBackgroundHunt(
                city: city, pill: categoryPill,
                message: shown.isEmpty
                    ? 'Checking the price index and looking for clinics…'
                    : 'Checking saved prices…',
                isSearching: true,
              );
            }
            final refresh = refreshAndDiscover();
            _interactiveRefresh[cacheKey] = refresh;
            unawaited(refresh.catchError((Object error) {
              debugPrint('[GP INDEX] refresh failed · $error');
            }).whenComplete(() {
              if (identical(_interactiveRefresh[cacheKey], refresh)) {
                _interactiveRefresh.remove(cacheKey);
              }
            }));
          } else if (backgroundRefresh && _liveCompareTopUpKey == cacheKey) {
            // A running watcher must not prevent reselecting a pill from
            // promoting its existing ticket back to the foreground.
            final job = await ExplorePriceDiscoveryTool.instance.enqueueDiscoveryJob(
              city: city, procedure: queryOrSelection, countryCode: countryCode,
              pill: categoryPill, foreground: true, focusKey: cacheKey,
              clientStoredCount: appStored.length,
              knownClinicHosts: cityHosts, knownClinicNames: storedNames,
              excludedSourceUrls: rejectedToolUrls.toList(),
            );
            if (job != null) {
              backgroundHuntNote.value = ExploreBackgroundHunt(
                city: city, pill: categoryPill, jobId: job.isFinished ? '' : job.id,
                message: job.message,
              );
            }
          } else if (!backgroundRefresh) {
            // Read-only reloads must read the worker's collection as well as
            // the app cache. They never start another discovery job.
            await loadServerIndex();
          }
          return finishInteractive(
            shown.isNotEmpty ? 'index-verified' : 'index-empty-background',
          );
        }

        if (!isConfigured) {
          throw StateError('Missing OPENAI_API_KEY.');
        }

        final localSeeds = ExploreSeedCatalog.clinicsFor(
          city: city,
          queryOrSelection: queryOrSelection,
          categoryPill: categoryPill,
        );

        final lastShownFuture = SessionPrefs.exploreLastShownKeys(
          city,
          categoryPill,
        );
        final googleStoreFuture = ExploreGooglePriceStore.instance.load(
          city: city,
          procedure: queryOrSelection,
        );
        // Curated public-site rows load beside the other Firestore reads, so a
        // covered city paints real cards from the pool below without waiting on
        // Places, Serper, OpenAI or a scrape.
        final curatedFuture = ExploreCuratedPriceStore.instance.load(
          city: city,
          procedure: queryOrSelection,
        );
        final poolFuture = _loadExploreComparisonPool(
          cacheKey: cacheKey,
          queryOrSelection: queryOrSelection,
          city: city,
          mode: mode,
        );

        List<OpenAIClinic> pricedIdentity(List<OpenAIClinic> list) => [
          for (final c in list)
            if (c.hasProcedure && c.priceMin > 0 && !c.pricePending) c,
        ];
        final googleStored = _clinicsFromGooglePriceJson(
          await googleStoreFuture,
        );
        final googlePriced = _pricedExploreClinics(
          googleStored,
          procedure: queryOrSelection,
        );
        final firestoreCached = await poolFuture;
        final googleIdentity = pricedIdentity(googleStored);
        final firestoreIdentity = pricedIdentity(
          firestoreCached?.clinics ?? const [],
        );
        final memoryIdentity = pricedIdentity(
          _exploreComparisonPool[cacheKey] ?? const [],
        );
        final curated = await curatedFuture;
        final curatedIdentity = pricedIdentity(curated);
        // New city: skip 7 extra Firestore sibling reads — they are empty too.
        final cacheEmpty =
            googleIdentity.isEmpty &&
            firestoreIdentity.isEmpty &&
            memoryIdentity.isEmpty &&
            curatedIdentity.isEmpty;
        final sibling = await _siblingExploreClinics(
          city: city,
          categoryPill: categoryPill,
          loadRemote: !cacheEmpty,
        );
        // Soft UI rotation only. Never a discovery / verification skip.
        final crossPillRotationAvoidKeys = sibling.keys;
        final siblingFamilyByKey = sibling.familyByKey;
        final persistedLastShown = await lastShownFuture;

        final metaSource = OpenAIComparisonResult(
          city: city,
          topic: queryOrSelection,
          topicType: OpenAISearchItemType.procedure,
          summary: '',
          rangeLabel: '',
          mapCenter: googlePriced.isNotEmpty
              ? googlePriced.first.coord
              : (localSeeds.isNotEmpty
                    ? localSeeds.first.coord
                    : const OpenAICoord(0, 0)),
          clinics: const [],
        );
        // Google-shared prices first, then older cache — never invented seeds.
        // Dedup by domain-aware key so "Dr. Paul Nistor" and "Clinica Dr.
        // Paul Nistor" (same drpaulnistor.ro) don't both make the list.
        // A curated row for a clinic already in the pool does not simply lose:
        // whichever trusted price was confirmed more recently wins.
        final pooled = <OpenAIClinic>[];
        final poolSeen = <String, int>{};
        for (final c in [
          ...googleIdentity,
          ...firestoreIdentity,
          ...memoryIdentity,
          ...curatedIdentity,
        ]) {
          final key = exploreClinicDedupKey(c);
          if (key.isEmpty) continue;
          final fixed = _fixRomanianPublishedCurrency(
            c,
            city: city,
            procedure: queryOrSelection,
          );
          final at = poolSeen[key];
          if (at == null) {
            poolSeen[key] = pooled.length;
            pooled.add(fixed);
            continue;
          }
          pooled[at] = explorePreferFresherTrustedPrice(
            pooled[at],
            fixed,
            procedure: queryOrSelection,
          );
        }
        final rankedPool = sortClinicsByGoogleMapsPopularity(pooled);
        final pool = rankedPool.length <= kExploreFirestorePoolMax
            ? rankedPool
            : rankedPool.take(kExploreFirestorePoolMax).toList();
        final verifiedPool = <OpenAIClinic>[];
        final rejectedCityFit = <OpenAIClinic>[];
        final rejectedMarketplace = <OpenAIClinic>[];
        for (final c in pool) {
          final host = exploreClinicWebsiteHost(c).isNotEmpty
              ? exploreClinicWebsiteHost(c)
              : normalizeExploreHost(c.priceSourceUrl);
          final identityReason = clinicIdentityRejectReason(
            c.name,
            websiteHost: host,
            providerClinic: c.providerClinic,
            sourceType: c.sourceType,
          );
          final marketplaceJunk =
              isMarketplaceOrDirectoryHost(host) ||
              looksLikeMarketEstimateDirectoryUrl(host) ||
              looksLikeNonClinicContentHost(host) ||
              isMarketplaceBrandName(c.name) ||
              identityReason == 'marketplace_without_provider' ||
              identityReason == 'market_estimate' ||
              identityReason == 'non_clinic_content_host';
          if (marketplaceJunk) {
            rejectedMarketplace.add(c);
            debugPrint('[GP] Drop marketplace/guide clinic ${c.name} · $host');
            continue;
          }
          if (exploreClinicEligibleForVerifiedPool(
            c,
            procedure: queryOrSelection,
            city: city,
          )) {
            verifiedPool.add(c);
          } else if (c.priceMin > 0 && !exploreClinicFitsSearchCity(c, city)) {
            rejectedCityFit.add(c);
          }
        }
        if (rejectedCityFit.isNotEmpty) {
          unawaited(
            ExploreGooglePriceStore.instance.purgeRejectedCityClinics(
              city: city,
              procedure: queryOrSelection,
              rejected: [
                for (final c in rejectedCityFit) _clinicToGooglePriceJson(c),
              ],
            ),
          );
        }
        // Exclude cross-city rejects + marketplace/guide hubs so hydrate
        // cannot resurrect Turkeymedicals / Medifyr / Trendyol as clinics.
        final rejectedKeys = <String>{
          for (final c in [...rejectedCityFit, ...rejectedMarketplace])
            exploreClinicDedupKey(c),
        }..removeWhere((k) => k.isEmpty);
        var growingPool = [
          for (final c in pool)
            if (!rejectedKeys.contains(exploreClinicDedupKey(c))) c,
        ];

        Future<void> persistExplorePool(
          List<OpenAIClinic> added, {
          required String reason,
          bool flushNow = false,
        }) async {
          final beforeN = [
            for (final c in growingPool)
              if (exploreClinicEligibleForVerifiedPool(
                c,
                procedure: queryOrSelection,
                city: city,
              ))
                c,
          ].length;
          final worthyAdded = [
            for (final c in added)
              if (exploreClinicEligibleForVerifiedPool(
                c,
                procedure: queryOrSelection,
                city: city,
              ))
                withCanonicalExploreProcedureRelation(
                  c,
                  procedure: queryOrSelection,
                ),
          ];
          // Rejected / bundle / market / ambiguous / unverified never grow
          // the shared pool — even if they arrived from Google.
          if (added.isNotEmpty && worthyAdded.isEmpty) {
            debugPrint(
              '[GP] Pool skip · ${added.length} not exact-verified · $reason',
            );
            return;
          }
          growingPool = mergeExploreClinicIdentities(
            _accumulateExploreComparisonPool(
              existing: growingPool,
              added: worthyAdded,
            ),
          );
          final priced = [
            for (final c in growingPool)
              if (exploreClinicEligibleForVerifiedPool(
                c,
                procedure: queryOrSelection,
                city: city,
              ))
                c,
          ];
          if (priced.isEmpty) return;
          final afterN = priced.length;
          _exploreComparisonPool[cacheKey] = List<OpenAIClinic>.from(priced);
          if (afterN > beforeN) {
            debugPrint('[GP] Firestore pool grew: $beforeN → $afterN');
          }
          _queueExplorePersist(
            cacheKey: cacheKey,
            city: city,
            procedure: queryOrSelection,
            metaSource: metaSource,
            priced: priced,
            reason: reason,
            flushNow: flushNow,
          );
        }

        if (growingPool.isNotEmpty && searchNewGoogle) {
          unawaited(persistExplorePool(const [], reason: 'hydrate pool'));
        }
        final poolKeys = <String>{
          for (final c in verifiedPool) ...exploreClinicIdentityKeys(c),
        }..removeWhere((k) => k.isEmpty);
        final liveVerifiedCount = verifiedPool
            .where((c) => !exploreCuratedPriceIsTrusted(c))
            .length;
        final mixPlan = planExplorePoolMix(
          verifiedPool.length,
          liveVerifiedCount: liveVerifiedCount,
        );
        final cachedTarget = math.min(
          mixPlan.firestoreShow,
          verifiedPool.length,
        );
        final poolEmpty = verifiedPool.isEmpty;
        // Rotate the cached half: prefer clinics not shown last visit / on
        // another tab so swiping pills does not look sponsored.
        final memoryShown =
            _exploreShownByCityPill[city.trim().toLowerCase()]?[categoryPill] ??
            const <OpenAIClinic>[];
        final lastShownKeys = <String>{
          ...persistedLastShown,
          for (final c in memoryShown) ...exploreClinicIdentityKeys(c),
        }..removeWhere((k) => k.isEmpty);
        final rotateAvoid = {...crossPillRotationAvoidKeys, ...lastShownKeys};
        // Random cached half from the full pool — not the popularity top-N.
        // Prefer curated when the audit already covers this pill so live
        // market-average scraps do not take the four visible slots.
        final paintPool = [
          for (final c in explorePaintPool(
            verifiedPool: verifiedPool,
            curated: curatedIdentity,
            want: cachedTarget,
          ))
            if (exploreClinicFitsCompareProcedure(c, queryOrSelection) &&
                (c.priceMin <= 0 ||
                    isJustifiedProcedurePrice(c, procedure: queryOrSelection)))
              c,
        ];
        final instantShow = cachedTarget <= 0
            ? const <OpenAIClinic>[]
            : ExploreSeedCatalog.mixSeedsWithFresh(
                seeds: paintPool,
                fresh: const [],
                maxShow: cachedTarget,
                freshCount: 0,
                seedCount: cachedTarget,
                avoidKeys: rotateAvoid,
              );

        if (instantShow.isNotEmpty) {
          final alreadyN = _pricedExploreClinics(
            _comparisonMemoryCache[cacheKey]?.clinics ?? const [],
            procedure: queryOrSelection,
          ).length;
          // Reopen already painted prior cards — do not flash 4 → 2 seeds.
          if (!keepPriorCards && alreadyN <= instantShow.length) {
            emitProgress(wrap(instantShow, metaSource));
            debugPrint(
              '[GP] Firestore seeds visible: ${instantShow.length} · '
              '${compareSw.elapsedMilliseconds}ms',
            );
            debugPrint(
              '[GP] UI progress: ${instantShow.length} verified · '
              '${compareSw.elapsedMilliseconds}ms',
            );
          } else {
            debugPrint(
              '[GP] Keep ${keepPriorCards ? "prior" : alreadyN} visible · '
              'skip seed replace',
            );
          }
        }

        debugPrint(
          '[GP] Firestore pool: ${verifiedPool.length} verified '
          '(${pool.length} raw) · $categoryPill · $city',
        );
        if (curatedIdentity.isNotEmpty) {
          debugPrint(
            '[CURATED] $city · $categoryPill · ${curatedIdentity.length} rows · '
            '${compareSw.elapsedMilliseconds}ms',
          );
          // A stale curated row keeps painting; the refresh happens behind it.
          if (ExploreCuratedPriceStore.instance.isStale(curated)) {
            debugPrint(
              '[BACKGROUND REFRESH] $city · $categoryPill · '
              'cached=${curatedIdentity.length} · reason=stale',
            );
          }
        }
        if (verifiedPool.length < kExploreCompareMaxClinics) {
          debugPrint(
            '[BACKGROUND FILL] $city · $categoryPill · '
            'cached=${verifiedPool.length} · '
            'need=${kExploreCompareMaxClinics - verifiedPool.length}',
          );
        }
        if (verifiedPool.isEmpty && curatedIdentity.isEmpty) {
          debugPrint(
            '[GP] Live discovery · $categoryPill · $city · '
            'empty curated/cache pool',
          );
        }
        // Bright Data discovery is coordinated after backend quick fetch
        // (see runForegroundGoogle) so we do not fan out Serper + Places +
        // Bright Data + backend for the same city/procedure at once.
        final priorCoverage = ExploreBackendService.instance.lastCoverage(
          city: city,
          procedure: queryOrSelection,
        );
        if (priorCoverage != null &&
            verifiedPool.length >= ExplorePipelineConfig.visibleTarget) {
          // Healthy verified pool — no discovery kick here.
        }
        debugPrint(
          '[GP] Firestore visible: ${instantShow.length} · '
          'mix=fs${mixPlan.firestoreShow}+g${mixPlan.googleLiveTarget}'
          '${mixPlan.skipLiveGoogle ? " · skipLiveGoogle" : ""}'
          '${mixPlan.backgroundDiscoverMax > 0 ? " · bg+${mixPlan.backgroundDiscoverMax}" : ""}',
        );
        debugPrint(
          '[GP] Compare target: ${instantShow.length} Firestore now + '
          '${mixPlan.googleLiveTarget}'
          '${mixPlan.skipLiveGoogle ? " Google (pool-only visible)" : " new Google"}',
        );

        final cityCurrency = _inferCurrencyFromCity(city);

        // City-level, not per-procedure: Istanbul has hair/botox seeds but
        // still has real clinics for fillers — do not treat it like Beirut.
        final cityHasCatalog = ExploreSeedCatalog.hasCityCoverage(city);

        OpenAIClinic prepareClinic(OpenAIClinic c) {
          var next = withExploreClinicDisplayName(c);
          next = repairHighTicketExploreClinicPrice(next, queryOrSelection);
          next = _alignClinicCurrencyToCity(next, city);
          next = _fixRomanianPublishedCurrency(
            next,
            city: city,
            procedure: queryOrSelection,
          );
          _warnCurrencyWithoutPageBacking(next, city: city);
          // Soft-fill only when both currency field and label have no signal.
          if (next.currency.trim().isEmpty && cityCurrency.isNotEmpty) {
            final labelCur = FilterFx.detectCodeFromLabel(
              next.priceLabel,
              fallback: '',
            );
            if (labelCur.isEmpty) {
              next = next.copyWith(
                currency: cityCurrency,
                currencyConfirmed: false,
              );
            }
          }
          // Unknown markets (e.g. Beirut): hold AI guesses. Keep HTML-verified
          // quotes so Abu Dhabi / Sharjah still paint after website confirm.
          if (ExploreSeedCatalog.shouldHoldUnverifiedPrice(
            cityHasCatalog: cityHasCatalog,
            hasPrice: next.priceMin > 0,
            alreadyPending: next.pricePending,
            verified: explorePriceIsVerified(next),
          )) {
            next = next.copyWith(pricePending: true);
          }
          return next;
        }

        bool isUsableClinic(OpenAIClinic c) {
          final ok = exploreClinicEligibleForVerifiedPool(
            c,
            procedure: queryOrSelection,
            city: city,
          );
          if (!ok && c.priceMin > 0) {
            final current = exploreCurrentProcedureRelation(
              c,
              procedure: queryOrSelection,
            );
            debugPrint(
              '[GP] Drop ${c.name} · pending=${c.pricePending} '
              'verified=${explorePriceIsVerified(c)} '
              'match=${exploreClinicMatchesProcedure(c, queryOrSelection)} '
              'justified=${isJustifiedProcedurePrice(c, procedure: queryOrSelection)} '
              'cityFit=${exploreClinicFitsSearchCity(c, city)} '
              'relation=${current.logToken} '
              'relationReason=${current.reason} '
              'relationEligible=${current.eligibleForFromPrice} '
              'storedRelation=${c.procedureRelation} '
              'rawProcedureText=${c.rawProcedureText} '
              'sourceUrl=${c.priceSourceUrl}',
            );
          }
          return ok;
        }

        bool canPaintClinic(OpenAIClinic c) => isUsableClinic(c);

        int pricedCountOf(OpenAIComparisonResult r) => _pricedExploreClinics(
          r.clinics,
          procedure: queryOrSelection,
        ).length;

        OpenAIComparisonResult publishCombined(List<OpenAIClinic> clinics) {
          // Filter to displayable priced clinics BEFORE take(max).
          // Keep caller order (Firestore 2, then Google). Re-ranking by
          // Maps popularity made the first two cards jump to other clinics.
          // Never paint "Price on request" — only verified listed amounts.
          final prepared = clinics.map(prepareClinic).toList();
          final ordered = [
            for (final c in prepared)
              if (isUsableClinic(c)) c,
          ];
          final shown = ordered.length <= kExploreCompareMaxClinics
              ? ordered
              : ordered.take(kExploreCompareMaxClinics).toList();
          final published = _applyJustifiedPriceFilterToComparison(
            wrap(shown, metaSource),
            procedure: queryOrSelection,
            keepNoPublicPrice: false,
          );
          final out = wrap(published.clinics, metaSource);
          _rememberExploreShown(
            city: city,
            categoryPill: categoryPill,
            clinics: out.clinics,
          );
          if (out.clinics.isNotEmpty) {
            _comparisonMemoryCache[cacheKey] = putBestComparison(
              previous: _comparisonMemoryCache[cacheKey],
              incoming: out,
              isStillValid: canPaintClinic,
            );
          }
          emitProgress(out);
          return out;
        }

        // Same cached clinics already painted above — do not shuffle again
        // or the first cards jump to different names after ~2s.
        var combined = List<OpenAIClinic>.of(instantShow);
        final wantCached = cachedTarget;
        if (combined.length < wantCached) {
          combined = ExploreSeedCatalog.mixSeedsWithFresh(
            seeds: paintPool,
            fresh: const <OpenAIClinic>[],
            maxShow: cachedTarget,
            freshCount: 0,
            seedCount: cachedTarget,
          );
        }
        final shownKeys = <String>{
          for (final c in combined) ...exploreClinicIdentityKeys(c),
        }..removeWhere((k) => k.isEmpty);
        late OpenAIComparisonResult published;
        if (combined.isEmpty) {
          published = wrap(const [], metaSource);
        } else if (keepPriorCards) {
          // Seeds are ready for the Google half; UI still shows the prior
          // visit until paintGoogle / finishTopUp emits the rotated mix.
          published = wrap(combined, metaSource);
        } else {
          published = publishCombined(combined);
          _comparisonMemoryCache[cacheKey] = putBestComparison(
            previous: _comparisonMemoryCache[cacheKey],
            incoming: published,
            isStillValid: isUsableClinic,
          );
        }
        final initialResult = published;

        // Preload of other pills: Firestore + Google price store only.
        if (!searchNewGoogle) {
          debugPrint(
            '[GP] CACHE-ONLY comparison · $categoryPill · $city · '
            '${combined.length} Firestore',
          );
          logCompareTiming(poolEmpty ? 'cache-empty' : 'firestore-cache');
          return published;
        }

        // Pool >=20: paint 4 randomized Firestore clinics immediately.
        // Pool >=25: no live Google. Pool 20–24: optional silent +1 grow.
        if (mixPlan.skipLiveGoogle) {
          final poolOnly = publishCombined(
            combined.isNotEmpty ? combined : instantShow,
          );
          _comparisonGoogleMixComplete.add(cacheKey);
          await persistExplorePool(
            poolOnly.clinics,
            reason:
                'pool-only visible '
                '(${verifiedPool.length} verified)',
            flushNow: true,
          );
          logCompareTiming(
            verifiedPool.length >= kExploreFirestorePoolSaturated
                ? 'pool-saturated'
                : 'pool-mature',
          );
          if (mixPlan.backgroundDiscoverMax > 0 &&
              verifiedPool.length < kExploreFirestorePoolSaturated) {
            unawaited(
              _backgroundGrowVerifiedPool(
                cacheKey: cacheKey,
                city: city,
                procedure: queryOrSelection,
                categoryPill: categoryPill,
                excludeKeys: exploreCurrentProcedureExclusionKeys(
                  poolKeys: poolKeys,
                  lastShownKeys: lastShownKeys,
                ),
                maxAdd: mixPlan.backgroundDiscoverMax,
              ),
            );
          }
          return poolOnly;
        }

        // Instant: Firestore seeds. Live: new Google, saved into the pool.
        if (!_comparisonAiTopUpInFlight.contains(cacheKey)) {
          _comparisonAiTopUpInFlight.add(cacheKey);
          _comparisonDeepFillStarted.remove(cacheKey);
          final existingTopUp = _comparisonAiTopUpCompleters[cacheKey];
          if (existingTopUp == null || existingTopUp.isCompleted) {
            _comparisonAiTopUpCompleters[cacheKey] =
                Completer<OpenAIComparisonResult>();
          }
          final aiTopUp = _comparisonAiTopUpCompleters[cacheKey]!;

          Future<OpenAIComparisonResult> runAiTopUp() async {
            var cachedShown = List<OpenAIClinic>.from(combined);
            var googleShown = <OpenAIClinic>[];
            var cachedFallback = <OpenAIClinic>[];
            var bgPublished = published;
            final liveEpoch = _liveCompareTopUpEpoch;
            final fgSw = Stopwatch()..start();
            bool liveCancelled() =>
                _liveCompareTopUpEpoch != liveEpoch ||
                (claimLiveSearch && _liveCompareTopUpKey != cacheKey);
            try {
              // Exclude identities already known for THIS procedure only.
              // A Peels/Fillers card for the same clinic must still be
              // discoverable for Botox.
              final currentProcedureExclusionKeys =
                  exploreCurrentProcedureExclusionKeys(
                    shownKeys: shownKeys,
                    lastShownKeys: lastShownKeys,
                    poolKeys: poolKeys,
                  );
              final discoveryInspectedKeys = <String>{};
              final persistenceKnownKeys = <String>{...poolKeys};
              final needFillUi = mixPlan.googleLiveTarget > 0;
              var liveGoogleTarget =
                  googleLiveTargetOverride ?? mixPlan.googleLiveTarget;
              final isPreviewFill =
                  googleLiveTargetOverride != null &&
                  liveGoogleTarget < kExploreCompareMinClinics;
              final visibleTarget = math.max(
                liveGoogleTarget + mixPlan.firestoreShow,
                ExplorePipelineConfig.visibleTarget,
              );
              // Cap visible target at compare max.
              final uiVisibleTarget = math.min(
                visibleTarget,
                kExploreCompareMaxClinics,
              );

              List<OpenAIClinic> mixedShown() {
                return mixExploreVisibleClinics(
                  cachedShown: cachedShown,
                  googleShown: googleShown,
                  poolForPad: cachedFallback,
                  preferredCachedWithFresh: mixPlan.firestoreShow,
                );
              }

              int pricedShown() => pricedCountOf(bgPublished);
              bool needsMoreVisible() =>
                  !isPreviewFill && pricedShown() < uiVisibleTarget;
              bool needsMoreLiveSlots() =>
                  googleShown.length < liveGoogleTarget;
              bool needsMoreGoogle() =>
                  needsMoreLiveSlots() || needsMoreVisible();
              var uiFrozen = false;
              var googlePoolAdded = 0;
              final visibleTargetReached = Completer<void>();
              void maybeSignalVisibleTarget() {
                if (visibleTargetReached.isCompleted) return;
                if (pricedShown() >= uiVisibleTarget ||
                    (isPreviewFill &&
                        pricedShown() >= math.max(1, liveGoogleTarget))) {
                  visibleTargetReached.complete();
                  ExploreRequestCoordinator.instance.logPerfSnapshot(
                    label: '$categoryPill · $city',
                    targetReachedMs: fgSw.elapsedMilliseconds,
                    backgroundDetached: false,
                  );
                }
              }

              // Cached cards already at target — complete immediately.
              if (pricedShown() >= uiVisibleTarget ||
                  (isPreviewFill && pricedShown() >= 1 && !needFillUi)) {
                maybeSignalVisibleTarget();
              }
              const poolGrowBudget = Duration(seconds: 45);
              // All preview: 7s. Focused: soft 3s / hard 16s. Never 60s UI wait.
              final fgBudget = isPreviewFill
                  ? const Duration(seconds: 7)
                  : ((liveGoogleTarget >= 2 ||
                            verifiedPool.length < kExploreCompareMinClinics)
                        ? kExploreForegroundFillBudget
                        : kExploreForegroundGoogleBudget);
              final softUiBudget = isPreviewFill
                  ? const Duration(seconds: 7)
                  : kExploreForegroundGoogleBudget;

              bool budgetLeft() {
                if (liveCancelled()) return false;
                return fgSw.elapsed < fgBudget;
              }

              void persistGoogleForPool(
                OpenAIClinic c, {
                required String reason,
              }) {
                if (exploreClinicHitsKeys(c, persistenceKnownKeys)) return;
                persistenceKnownKeys.addAll(exploreClinicIdentityKeys(c));
                googlePoolAdded++;
                unawaited(persistExplorePool([c], reason: reason));
                debugPrint(
                  '[GP] Pool grow: ${c.name} · '
                  '$googlePoolAdded/$liveGoogleTarget · $reason',
                );
              }

              /// The pool already knows this clinic, so it is not a new name to
              /// grow the pool with — it is a stored copy whose quote for this
              /// procedure was missing or stale. Overwrite it with the verified
              /// one so the next read serves a priced card straight away.
              void repriceKnownPoolClinic(OpenAIClinic c) {
                unawaited(persistExplorePool([c], reason: 'pool reprice'));
                debugPrint(
                  '[GP] Pool reprice: ${c.name} · '
                  '${c.priceMin.round()} ${c.currency}',
                );
              }

              void rememberInspected(OpenAIClinic c) {
                discoveryInspectedKeys.addAll(exploreClinicIdentityKeys(c));
              }

              void paintGoogle(
                OpenAIClinic c, {
                required ExploreClinicSource source,
              }) {
                final prepared = prepareClinic(c);
                if (exploreClinicIsNoPublicPrice(prepared)) {
                  logExploreDiscoveryReject(
                    reason: 'no_public_price_hidden',
                    placeId: prepared.placeId,
                    name: prepared.name,
                  );
                  return;
                }
                if (!isUsableClinic(prepared)) {
                  logExploreDiscoveryReject(
                    reason: 'invalid_price',
                    placeId: prepared.placeId,
                    name: prepared.name,
                  );
                  return;
                }
                final host = exploreClinicWebsiteHost(prepared).isNotEmpty
                    ? exploreClinicWebsiteHost(prepared)
                    : normalizeExploreHost(prepared.priceSourceUrl);
                var named = prepared;
                // SERP/page titles like "Sofia" / "Цени - София" are not clinics.
                final nameFold = foldExploreIdentityText(named.name);
                final cityFold = foldExploreIdentityText(city);
                final cityOnlyName =
                    cityFold.isNotEmpty &&
                    (nameFold == cityFold ||
                        nameFold == '$cityFold bulgaria' ||
                        nameFold == '$cityFold turkiye' ||
                        nameFold == '$cityFold turkey' ||
                        (RegExp(
                              r'^(?:ceni|цени|prices?|pricing|tarife|preturi)\b',
                              caseSensitive: false,
                            ).hasMatch(nameFold) &&
                            nameFold.contains(cityFold)));
                if (cityOnlyName) {
                  final fromHost = exploreClinicDisplayNameFromHost(host);
                  if (fromHost.isNotEmpty) {
                    named = named.copyWith(name: fromHost);
                  }
                }
                var identityReason = clinicIdentityRejectReason(
                  named.name,
                  websiteHost: host,
                  providerClinic: named.providerClinic,
                  sourceType: named.sourceType,
                );
                if (identityReason != null ||
                    (cityOnlyName &&
                        foldExploreIdentityText(named.name) == cityFold)) {
                  final fromHost = exploreClinicDisplayNameFromHost(host);
                  if (fromHost.isNotEmpty &&
                      clinicIdentityRejectReason(fromHost, websiteHost: host) ==
                          null) {
                    named = named.copyWith(name: fromHost);
                    identityReason = null;
                  }
                }
                if (identityReason != null) {
                  logExploreDiscoveryReject(
                    reason: identityReason,
                    placeId: named.placeId,
                    name: named.name,
                  );
                  if (named.placeId.trim().isNotEmpty) {
                    unawaited(
                      ExploreDiscoveryStateStore.instance.markPermanentReject(
                        city: city,
                        procedure: queryOrSelection,
                        placeId: named.placeId,
                      ),
                    );
                  }
                  return;
                }
                // Already on this pill — keep the stored quote fresh.
                if (exploreClinicHitsKeys(named, shownKeys)) {
                  logExploreDiscoverySkip(
                    reason: 'current_procedure_already_seen',
                    name: named.name,
                    procedure: queryOrSelection,
                    placeId: named.placeId,
                  );
                  if (exploreClinicHitsKeys(named, persistenceKnownKeys)) {
                    repriceKnownPoolClinic(named);
                  }
                  return;
                }
                maybeLogExploreMultiProcedureReuse(
                  clinic: named,
                  procedure: queryOrSelection,
                  siblingFamilyByKey: siblingFamilyByKey,
                  currentProcedureExclusionKeys: currentProcedureExclusionKeys,
                );
                final poolOnly = exploreClinicHitsKeys(
                  named,
                  persistenceKnownKeys,
                );
                final verifiedShownCount = googleShown.length;
                if (verifiedShownCount >= liveGoogleTarget) {
                  if (poolOnly) {
                    repriceKnownPoolClinic(named);
                  } else {
                    persistGoogleForPool(
                      named,
                      reason:
                          'google pool, ${liveGoogleTarget} search slots full',
                    );
                  }
                  return;
                }
                // Pool identity with no showable quote yet (wrong family /
                // stale 999) — a live HTML confirm must still fill a slot.
                // Skipping these left Abu Dhabi Botox stuck on 1 Firestore
                // card while Google "found" 0.
                //
                // But we require a THIS-SESSION witness before we let a pool
                // clinic occupy a fresh Google slot. Verification's 21-day TTL
                // (kExploreVerifiedPriceTtl) means a pool clinic within TTL is
                // returned unchanged — its old price becomes a "Google find".
                // That is how Tajmeels/Enfield/Skin111 showed 999/599/1500 AED
                // for chemical peel in Abu Dhabi with zero fresh scrape.
                final verifiedAt = named.priceVerifiedAt;
                final freshWitness =
                    verifiedAt != null &&
                    DateTime.now().difference(verifiedAt).abs() <
                        const Duration(minutes: 20);
                if (poolOnly && !freshWitness) {
                  debugPrint(
                    '[GP] Skip stale pool clinic on Google slot: '
                    '${named.name} · ${named.priceMin.round()} '
                    '${named.currency} · '
                    'verifiedAt=${verifiedAt?.toIso8601String() ?? "null"}',
                  );
                  rememberInspected(named);
                  currentProcedureExclusionKeys.addAll(
                    exploreClinicIdentityKeys(named),
                  );
                  return;
                }
                if (poolOnly) {
                  repriceKnownPoolClinic(named);
                  googlePoolAdded++;
                } else {
                  persistGoogleForPool(named, reason: 'google ${source.name}');
                }
                currentProcedureExclusionKeys.addAll(
                  exploreClinicIdentityKeys(named),
                );
                rememberInspected(named);
                persistenceKnownKeys.addAll(exploreClinicIdentityKeys(named));
                shownKeys.addAll(exploreClinicIdentityKeys(named));
                googleShown = [...googleShown, named];
                if (named.placeId.trim().isNotEmpty) {
                  unawaited(
                    ExploreDiscoveryStateStore.instance.markAccepted(
                      city: city,
                      procedure: queryOrSelection,
                      placeId: named.placeId,
                    ),
                  );
                }
                final enqueueHost = exploreClinicWebsiteHost(named);
                final enqueueUrl = named.priceSourceUrl.trim().isNotEmpty
                    ? named.priceSourceUrl.trim()
                    : (enqueueHost.isNotEmpty ? 'https://$enqueueHost' : '');
                if (enqueueUrl.isNotEmpty || named.placeId.trim().isNotEmpty) {
                  ExploreBackendService.instance.enqueueDiscoveredCandidates(
                    city: city,
                    procedure: queryOrSelection,
                    candidates: [
                      <String, Object?>{
                        'name': named.name,
                        'officialWebsite': enqueueUrl,
                        'sourceUrl': enqueueUrl,
                        'placeId': named.placeId,
                        'address': named.area,
                        if (named.coord.lat.abs() > 0.01)
                          'lat': named.coord.lat,
                        if (named.coord.lng.abs() > 0.01)
                          'lng': named.coord.lng,
                        'discoveryProvider': 'client_${source.name}',
                      },
                    ],
                  );
                }
                bgPublished = publishCombined(mixedShown());
                debugPrint('[GP] Google candidate: ${named.name}');
                debugPrint(
                  '[GP] Google visible: ${named.name} · '
                  '${googleShown.length}/$liveGoogleTarget · ${source.name}',
                );
                debugPrint(
                  '[GP] UI progress: ${pricedCountOf(bgPublished)}/'
                  '$kExploreCompareMaxClinics · ${fgSw.elapsedMilliseconds}ms',
                );
                debugPrint(
                  '[UI PROGRESS] ${pricedCountOf(bgPublished)}/'
                  '$uiVisibleTarget',
                );
                maybeSignalVisibleTarget();
                if (prepared.rating <= 0 ||
                    exploreClinicNameNeedsMapsRefresh(prepared)) {
                  unawaited(
                    enrichLiveShownClinicRating(
                      cacheKey: cacheKey,
                      clinic: prepared,
                      city: city,
                      procedure: queryOrSelection,
                      pill: categoryPill,
                    ),
                  );
                }
              }

              void hydrateBackendCached(OpenAIClinic prepared) {
                final alreadyShown =
                    exploreClinicHitsKeys(prepared, shownKeys) ||
                    cachedShown.any(
                      (c) => exploreClinicsAreSameProvider(c, prepared),
                    );
                if (alreadyShown) {
                  repriceKnownPoolClinic(prepared);
                  cachedShown = [
                    for (final c in cachedShown)
                      exploreClinicsAreSameProvider(c, prepared) ? prepared : c,
                  ];
                  googleShown = [
                    for (final c in googleShown)
                      exploreClinicsAreSameProvider(c, prepared) ? prepared : c,
                  ];
                  bgPublished = publishCombined(mixedShown());
                  return;
                }
                persistGoogleForPool(prepared, reason: 'backend cached');
                // Keep extras in the pool for pad. Appending them here
                // marked every Firestore clinic "already shown" while the
                // visible mix still reserved 2 slots for live Google.
                if (cachedShown.length >= mixPlan.firestoreShow) {
                  return;
                }
                cachedShown = [...cachedShown, prepared];
                shownKeys.addAll(exploreClinicIdentityKeys(prepared));
                persistenceKnownKeys.addAll(
                  exploreClinicIdentityKeys(prepared),
                );
                bgPublished = publishCombined(mixedShown());
              }

              Future<void> applyBackendResponse({
                required List<Map<String, Object?>> cached,
                required List<Map<String, Object?>> fresh,
                required String reason,
              }) async {
                final consumed = consumeExploreBackendRows(
                  cached: cached,
                  fresh: fresh,
                  procedure: queryOrSelection,
                  city: city,
                );
                final accepted = <OpenAIClinic>[];
                for (final item in consumed) {
                  final prepared = prepareClinic(item.clinic);
                  if (!isUsableClinic(prepared)) continue;
                  if (!explorePriceIsVerified(prepared)) continue;
                  accepted.add(prepared);
                  if (item.source == ExploreClinicSource.googleCache) {
                    hydrateBackendCached(prepared);
                  } else if (!liveCancelled()) {
                    paintGoogle(
                      prepared,
                      source: ExploreClinicSource.googleLive,
                    );
                  }
                }
                if (accepted.isNotEmpty) {
                  await persistExplorePool(
                    accepted,
                    reason: reason,
                    flushNow: true,
                  );
                }
              }

              void finishTopUpIfFull() {
                if (needsMoreGoogle()) return;
                if (!aiTopUp.isCompleted) aiTopUp.complete(bgPublished);
              }

              void padCachedFallback({required String reason}) {
                // Only after live search finishes. Padding during verify
                // filled the 2 Google slots from Firestore and the new
                // websites never appeared on screen.
                //
                // Skip identities that are *on screen*, not every backend-
                // hydrated pool name. Hydrate used to copy all 5 Firestore
                // clinics into shownKeys while mixedShown still painted 2,
                // so pad found 0 extras and the spinner stopped at 2.
                final visibleNow = mixedShown();
                final need = kExploreCompareMaxClinics - visibleNow.length;
                if (need <= 0) return;
                final visibleKeys = <String>{
                  for (final c in visibleNow) ...exploreClinicIdentityKeys(c),
                }..removeWhere((k) => k.isEmpty);
                final padAvoid = <String>{
                  ...visibleKeys,
                  ...lastShownKeys,
                  for (final c in googleShown) ...exploreClinicIdentityKeys(c),
                }..removeWhere((k) => k.isEmpty);
                final poolShuffled = List<OpenAIClinic>.of(growingPool)
                  ..shuffle();
                final preferred = <OpenAIClinic>[];
                final overlap = <OpenAIClinic>[];
                for (final c in poolShuffled) {
                  final prepared = prepareClinic(c);
                  if (!isUsableClinic(prepared)) continue;
                  if (exploreClinicHitsKeys(prepared, visibleKeys)) continue;
                  if (exploreClinicHitsKeys(prepared, padAvoid)) {
                    overlap.add(prepared);
                  } else {
                    preferred.add(prepared);
                  }
                }
                final extras = <OpenAIClinic>[];
                for (final prepared in [...preferred, ...overlap]) {
                  if (extras.length >= need) break;
                  extras.add(prepared);
                  currentProcedureExclusionKeys.addAll(
                    exploreClinicIdentityKeys(prepared),
                  );
                }
                if (extras.isEmpty) {
                  debugPrint(
                    '[GP] Skip Firestore pad ($reason) — mix is '
                    '${cachedShown.length} database + '
                    '${googleShown.length} search',
                  );
                  return;
                }
                cachedFallback = extras;
                bgPublished = publishCombined(mixedShown());
                debugPrint(
                  '[GP] Firestore pad ($reason): +${extras.length} · mix '
                  '${cachedShown.length} database + '
                  '${googleShown.length} search + '
                  '${cachedFallback.length} pool',
                );
              }

              debugPrint('[GP] Google target: $liveGoogleTarget');
              debugPrint(
                '[GP] Google exclusion: ${cachedShown.length} visible clinics',
              );

              // Verify work detached after the UI deadline — keep onProgress
              // alive until these settle so late accepts still paint.
              final detachedVerifyFutures = <Future<void>>[];

              Future<OpenAIComparisonResult> finishTopUp({
                required bool reachedGoogleTarget,
                List<OpenAIClinic> extraPersist = const [],
                bool paused = false,
                bool poolExhausted = false,
              }) async {
                final ready =
                    pricedCountOf(bgPublished) >= kExploreCompareMinClinics;
                if (ready) uiFrozen = true;
                padCachedFallback(
                  reason: googleShown.isEmpty
                      ? 'after Google found 0'
                      : 'after Google, fill leftover slots',
                );
                if (pricedCountOf(bgPublished) == 0 && instantShow.isNotEmpty) {
                  bgPublished = publishCombined(instantShow);
                }
                // Visible target reached, or true exhaustion — never mark
                // complete merely because this is a focused (!preview) tab.
                final pricedNow = pricedCountOf(bgPublished);
                final pendingNow =
                    detachedVerifyFutures.length +
                    _comparisonPendingFillCount(cacheKey);
                final trulyExhaustedNow = poolExhausted && pendingNow == 0;
                if (exploreFillShouldMarkMixComplete(
                  pricedFinal: pricedNow,
                  uiVisibleTarget: uiVisibleTarget,
                  paused: paused,
                  isPreviewFill: isPreviewFill,
                  trulyExhausted: trulyExhaustedNow,
                )) {
                  _comparisonGoogleMixComplete.add(cacheKey);
                  if (pricedNow >= uiVisibleTarget) {
                    debugPrint(
                      '[FILL SESSION COMPLETE] visible=$pricedNow/'
                      '$uiVisibleTarget',
                    );
                  } else {
                    debugPrint(
                      '[FILL SESSION EXHAUSTED] visible=$pricedNow/'
                      '$uiVisibleTarget reason=no_more_viable_candidates',
                    );
                  }
                } else {
                  _comparisonGoogleMixComplete.remove(cacheKey);
                  debugPrint(
                    '[FILL SESSION] visible=$pricedNow/$uiVisibleTarget '
                    'pending=$pendingNow google=${googleShown.length}/'
                    '$liveGoogleTarget',
                  );
                }
                final finalResult = publishCombined(
                  mixedShown().isNotEmpty ? mixedShown() : instantShow,
                );
                await persistExplorePool(
                  [...googleShown, ...extraPersist, ...finalResult.clinics],
                  reason: reachedGoogleTarget
                      ? 'google target reached '
                            '(${googleShown.length}/$liveGoogleTarget)'
                      : 'google deadline '
                            '(${googleShown.length}/$liveGoogleTarget)',
                  flushNow: true,
                );
                final fullPool =
                    _exploreComparisonPool[cacheKey] ?? growingPool;
                final pricedFinal = pricedCountOf(finalResult);
                final pendingBg = List<Future<void>>.of(detachedVerifyFutures);
                detachedVerifyFutures.clear();
                // If still under the visible target, ensure deep backend is
                // part of this fill session (hard-deadline race used to orphan
                // it after the listener detached).
                if (!paused &&
                    !isPreviewFill &&
                    pricedFinal < uiVisibleTarget &&
                    needsMoreGoogle() &&
                    !liveCancelled() &&
                    _comparisonDeepFillStarted.add(cacheKey)) {
                  final deepFuture = () async {
                    debugPrint(
                      '[FILL SESSION] track · backend deep · '
                      '$categoryPill · $city',
                    );
                    final backend = await ExploreBackendService.instance
                        .fetchFresh(
                          city: city,
                          procedure: queryOrSelection,
                          excludeClinicKeys: currentProcedureExclusionKeys
                              .toList(),
                          freshLimit: math.max(
                            liveGoogleTarget,
                            uiVisibleTarget - pricedFinal,
                          ),
                          mode: 'deep',
                        );
                    if (backend == null) return;
                    await applyBackendResponse(
                      cached: backend.cached,
                      fresh: backend.fresh,
                      reason: 'backend deep persist',
                    );
                  }();
                  pendingBg.add(deepFuture);
                }
                for (final f in pendingBg) {
                  _trackComparisonFillWork(
                    cacheKey,
                    f.catchError((Object _) {}),
                    label: 'background verify',
                  );
                }
                final trulyExhaustedFinal =
                    poolExhausted &&
                    pendingBg.isEmpty &&
                    _comparisonPendingFillCount(cacheKey) == 0;
                if (exploreFillShouldMarkMixComplete(
                  pricedFinal: pricedFinal,
                  uiVisibleTarget: uiVisibleTarget,
                  paused: paused,
                  isPreviewFill: isPreviewFill,
                  trulyExhausted: trulyExhaustedFinal,
                )) {
                  _comparisonGoogleMixComplete.add(cacheKey);
                } else {
                  _comparisonGoogleMixComplete.remove(cacheKey);
                }
                if (!paused && !reachedGoogleTarget) {
                  // Under-target is not permanent exhaustion — keep searching
                  // more candidates. Never weaken price validation to fill.
                  if (pricedFinal >= uiVisibleTarget || trulyExhaustedFinal) {
                    if (trulyExhaustedFinal && pricedFinal < uiVisibleTarget) {
                      _comparisonTopUpExhausted.add(cacheKey);
                      _comparisonTopUpExhaustedAt[cacheKey] = DateTime.now();
                    } else if (pricedFinal >= uiVisibleTarget) {
                      _comparisonTopUpExhausted.remove(cacheKey);
                      _comparisonTopUpExhaustedAt.remove(cacheKey);
                    }
                  } else {
                    _comparisonTopUpExhausted.remove(cacheKey);
                    _comparisonTopUpExhaustedAt.remove(cacheKey);
                  }
                } else {
                  _comparisonTopUpExhausted.remove(cacheKey);
                  _comparisonTopUpExhaustedAt.remove(cacheKey);
                }
                if (reachedGoogleTarget) {
                  debugPrint(
                    '[GP] Comparison ready:\n'
                    '${cachedShown.length} Firestore + '
                    '${googleShown.length} Google',
                  );
                } else if (paused) {
                  debugPrint(
                    '[GP] Live search paused: $categoryPill · $city · '
                    '${googleShown.length}/$liveGoogleTarget Google',
                  );
                } else {
                  debugPrint(
                    '[GP] Foreground Google deadline · '
                    '${googleShown.length}/$liveGoogleTarget found · '
                    '${fgSw.elapsedMilliseconds}ms',
                  );
                  if (cachedFallback.isNotEmpty) {
                    debugPrint(
                      '[GP] Comparison ready: ${cachedShown.length} Firestore + '
                      '${googleShown.length} Google + '
                      '${cachedFallback.length} cached fallback',
                    );
                  } else {
                    debugPrint(
                      '[GP] Comparison ready: ${cachedShown.length} Firestore + '
                      '${googleShown.length} Google',
                    );
                  }
                }
                debugPrint(
                  '[GP] Foreground timing: ${fgSw.elapsedMilliseconds}ms',
                );
                debugPrint(
                  '[GP] Comparison hybrid ready — $pricedFinal shown '
                  '(${cachedShown.length} Firestore + '
                  '${googleShown.length} Google), '
                  '${fullPool.length} in Firestore pool · '
                  'persistKeys=${persistenceKnownKeys.length}',
                );
                logCompareTiming(
                  reachedGoogleTarget
                      ? (poolEmpty ? 'google-start' : 'firestore-google')
                      : 'google-deadline',
                );
                if (pricedFinal == 0) {
                  // Do not clobber a late paintGoogle that landed during
                  // persist — empty deadline used to wipe the first accept.
                  final existing = _comparisonMemoryCache[cacheKey];
                  if (existing == null || existing.clinics.isEmpty) {
                    _comparisonMemoryCache[cacheKey] = finalResult;
                  }
                } else {
                  _comparisonMemoryCache[cacheKey] = putBestComparison(
                    previous: _comparisonMemoryCache[cacheKey],
                    incoming: finalResult,
                    isStillValid: isUsableClinic,
                  );
                }
                _scheduleComparisonEnrichment(
                  cacheKey: cacheKey,
                  base: finalResult,
                  queryOrSelection: queryOrSelection,
                  city: city,
                );
                // Under-target with detached verify / deep backend still
                // running: leave the top-up completer open so buildComparison
                // keeps onProgress. Do NOT compare pricedFinal to
                // liveGoogleTarget — those are different units.
                final keepAlive = exploreFillShouldKeepTopUpAlive(
                  pricedFinal: pricedFinal,
                  uiVisibleTarget: uiVisibleTarget,
                  googleShownCount: googleShown.length,
                  liveGoogleTarget: liveGoogleTarget,
                  hasPendingBackgroundWork:
                      pendingBg.isNotEmpty ||
                      _comparisonPendingFillCount(cacheKey) > 0,
                  paused: paused,
                  isPreviewFill: isPreviewFill,
                );
                if (keepAlive && !aiTopUp.isCompleted) {
                  unawaited(() async {
                    try {
                      await Future.wait(
                        pendingBg.map((f) => f.catchError((Object _) {})),
                      );
                      // Also wait for deep backend / later waves tracked on
                      // the fill session (may have started after detach).
                      // Require pending to stay at 0 for several consecutive
                      // polls — Boob job logged EXHAUSTED at 2/4 then still
                      // accepted Dentalandbeauty / Hygeia seconds later.
                      var spins = 0;
                      var idlePolls = 0;
                      while (spins < 160) {
                        await Future<void>.delayed(
                          const Duration(milliseconds: 250),
                        );
                        spins++;
                        final latestCount = pricedCountOf(
                          _comparisonMemoryCache[cacheKey] ?? finalResult,
                        );
                        if (latestCount >= uiVisibleTarget) break;
                        if (_comparisonPendingFillCount(cacheKey) > 0) {
                          idlePolls = 0;
                          continue;
                        }
                        idlePolls++;
                        // ~7s of true idle after the last tracked future —
                        // deep Serper/Firecrawl often lands after the old 4s.
                        if (idlePolls >= 28) break;
                      }
                      if (aiTopUp.isCompleted) return;
                      final latest =
                          _comparisonMemoryCache[cacheKey] ?? finalResult;
                      final settled = pricedCountOf(latest);
                      debugPrint(
                        '[GP] Background verify settled · $categoryPill · '
                        '$city · $settled/$uiVisibleTarget cards',
                      );
                      if (settled >= uiVisibleTarget) {
                        _comparisonGoogleMixComplete.add(cacheKey);
                        debugPrint(
                          '[FILL SESSION COMPLETE] visible=$settled/'
                          '$uiVisibleTarget',
                        );
                      } else if (_comparisonPendingFillCount(cacheKey) == 0) {
                        _comparisonGoogleMixComplete.add(cacheKey);
                        _comparisonTopUpExhausted.add(cacheKey);
                        _comparisonTopUpExhaustedAt[cacheKey] = DateTime.now();
                        debugPrint(
                          '[FILL SESSION EXHAUSTED] visible=$settled/'
                          '$uiVisibleTarget reason=no_more_viable_candidates',
                        );
                      }
                      if (!aiTopUp.isCompleted) aiTopUp.complete(latest);
                    } finally {
                      _comparisonAiTopUpInFlight.remove(cacheKey);
                    }
                  }());
                  return finalResult;
                }
                if (!aiTopUp.isCompleted) aiTopUp.complete(finalResult);
                return finalResult;
              }

              Future<void> verifyCityStubs(
                List<OpenAIClinic> stubs, {
                required String reason,
                required bool wait,
              }) async {
                if (stubs.isEmpty) return;
                debugPrint('[GP] $reason: ${stubs.length} clinics');
                Future<void> run() async {
                  final verified = await _enrichClinicsWithDirectPriceFetch(
                    clinics: [for (final s in stubs) prepareClinic(s)],
                    procedure: queryOrSelection,
                    city: city,
                    requireWebsiteConfirm: true,
                    repriceExisting: true,
                    // Bound the *await* with verifyLeft below — do not also
                    // kill in-flight HTML verify at fgBudget. After soft UI
                    // / BACKGROUND CONTINUE, wait=true runs must keep going
                    // until a card paints or poolGrowBudget, or All never
                    // receives the late Fillers price.
                    stopIf: () =>
                        pricedShown() >= kExploreCompareMaxClinics ||
                        liveCancelled() ||
                        fgSw.elapsed >= poolGrowBudget,
                    // Keep deep discovery until the visible target (4), not
                    // just min clinics (2). With 3 Firestore seeds the old
                    // gate turned deep off and EXHAUSTED at 3/4 while Serper
                    // / Firecrawl still had viable candidates.
                    allowDeepFallbacks:
                        allowDeepFallbacks &&
                        (!wait || pricedShown() < uiVisibleTarget),
                    onClinicDone: (c) {
                      final prepared = prepareClinic(c);
                      if (!canPaintClinic(prepared)) return;
                      paintGoogle(
                        prepared,
                        source: ExploreClinicSource.googleLive,
                      );
                    },
                  );
                  for (final c in verified) {
                    final prepared = prepareClinic(c);
                    if (!canPaintClinic(prepared)) continue;
                    paintGoogle(
                      prepared,
                      source: ExploreClinicSource.googleLive,
                    );
                  }
                }

                Future<void> trackAndRun() {
                  final f = run().catchError((Object _) {});
                  _trackComparisonFillWork(cacheKey, f, label: 'verify stubs');
                  return f;
                }

                if (!wait) {
                  unawaited(trackAndRun());
                  return;
                }
                final verifyLeft = fgBudget - fgSw.elapsed;
                if (verifyLeft <= Duration.zero) {
                  unawaited(trackAndRun());
                  return;
                }
                await trackAndRun().timeout(verifyLeft, onTimeout: () {});
              }

              Future<void> runForegroundGoogle() async {
                if (!needsMoreGoogle() || liveCancelled()) return;

                final discoveryState = await ExploreDiscoveryStateStore.instance
                    .load(city: city, procedure: queryOrSelection);
                discoveryInspectedKeys.addAll({
                  for (final id in discoveryState.permanentRejectedPlaceIds)
                    'id:$id',
                });

                var backendMissing = false;
                final backendFuture = ExploreBackendService.instance.fetchFresh(
                  city: city,
                  procedure: queryOrSelection,
                  excludeClinicKeys: currentProcedureExclusionKeys.toList(),
                  freshLimit: liveGoogleTarget,
                  mode: 'interactive',
                );
                // Prefer backend quick briefly before client Serper / Bright Data.
                // Skip the wait when the visible target is already painted.
                dynamic backendEarly;
                if (!visibleTargetReached.isCompleted && needsMoreGoogle()) {
                  backendEarly = await backendFuture.timeout(
                    const Duration(seconds: 2),
                    onTimeout: () => null,
                  );
                } else {
                  backendEarly = null;
                  unawaited(
                    backendFuture.then((backend) async {
                      if (backend == null) return;
                      await applyBackendResponse(
                        cached: backend.cached,
                        fresh: backend.fresh,
                        reason: 'backend quick detached',
                      );
                      maybeSignalVisibleTarget();
                    }),
                  );
                }
                if (backendEarly != null) {
                  await applyBackendResponse(
                    cached: backendEarly.cached,
                    fresh: backendEarly.fresh,
                    reason: 'backend quick early',
                  );
                  maybeSignalVisibleTarget();
                  final rawCount = backendEarly.coverage['candidateCount'];
                  final candN = rawCount is num ? rawCount.toInt() : null;
                  final disc =
                      '${backendEarly.coverage['discoveryStatus'] ?? ''}';
                  final storedOk =
                      (candN != null && candN > 0) ||
                      backendEarly.cached.isNotEmpty ||
                      backendEarly.fresh.isNotEmpty;
                  if (!storedOk) {
                    ExploreBackendService.instance.requestCityDiscoveryIfNeeded(
                      city: city,
                      procedure: queryOrSelection,
                      verifiedPoolCount: math.max(
                        verifiedPool.length,
                        pricedShown(),
                      ),
                      candidateCount: candN,
                      discoveryStatus: disc,
                      coverageDocumentExists: true,
                    );
                  } else {
                    ExploreBackendService.instance.rememberCoverage(
                      city: city,
                      procedure: queryOrSelection,
                      candidateCount: candN,
                      discoveryStatus: disc.isNotEmpty ? disc : 'partial',
                    );
                  }
                } else {
                  backendMissing = true;
                  unawaited(() async {
                    final backend = await backendFuture;
                    if (backend == null) return;
                    final rawCount = backend.coverage['candidateCount'];
                    final candN = rawCount is num ? rawCount.toInt() : null;
                    final storedOk =
                        (candN != null && candN > 0) ||
                        backend.cached.isNotEmpty ||
                        backend.fresh.isNotEmpty;
                    if (!storedOk) {
                      ExploreBackendService.instance
                          .requestCityDiscoveryIfNeeded(
                            city: city,
                            procedure: queryOrSelection,
                            verifiedPoolCount: math.max(
                              verifiedPool.length,
                              pricedShown(),
                            ),
                            candidateCount: candN,
                            discoveryStatus:
                                '${backend.coverage['discoveryStatus'] ?? ''}',
                            coverageDocumentExists: true,
                          );
                    }
                    await applyBackendResponse(
                      cached: backend.cached,
                      fresh: backend.fresh,
                      reason: 'backend quick late',
                    );
                    maybeSignalVisibleTarget();
                  }());
                }

                if (!backendMissing && !needsMoreGoogle()) {
                  finishTopUpIfFull();
                  return;
                }

                // Callable missing / still short — bounded on-device scrape.

                // Google price store is the database pool — do not paint it
                // as the live-search half. Positions 2–3 always come from
                // this visit's Serp/Places search.

                // Legacy pool rows are hidden until re-verified. Confirm
                // those clinic sites first so Botox/Laser/Peels paint again
                // instead of waiting on a new city search.
                // Re-check pool rows that are unverified or have an
                // impossible quote (Defelipe €1839 = Google review count).
                final reverify = [
                  for (final c in pool)
                    if (c.area.contains('.') &&
                        exploreClinicFitsSearchCity(c, city) &&
                        !exploreDiscoveryShouldSkipPoolVerified(
                          c,
                          procedure: queryOrSelection,
                          city: city,
                        ))
                      prepareClinic(c),
                ];
                final shownByPill =
                    _exploreShownByCityPill[city.trim().toLowerCase()];
                if (shownByPill != null && needFillUi && needsMoreGoogle()) {
                  final reuseSeen = {
                    ...currentProcedureExclusionKeys,
                    ...discoveryInspectedKeys,
                    for (final c in reverify) ...exploreClinicIdentityKeys(c),
                  };
                  for (final entry in shownByPill.entries) {
                    if (entry.key == categoryPill) continue;
                    for (final c in entry.value) {
                      if (c.priceSourceUrl.trim().isEmpty) continue;
                      if (!exploreClinicFitsSearchCity(c, city)) continue;
                      if (exploreClinicHitsKeys(c, reuseSeen)) continue;
                      reuseSeen.addAll(exploreClinicIdentityKeys(c));
                      reverify.add(
                        prepareClinic(
                          c.copyWith(
                            hasProcedure: true,
                            pricePending: true,
                            priceMin: 0,
                            priceMax: 0,
                            priceLabel: '',
                            brand: '',
                            rawProcedureText: '',
                          ),
                        ),
                      );
                    }
                  }
                }
                final reverifyQueue = reverify.take(6).toList();
                Future<void> reverifyFuture = Future.value();
                if (reverifyQueue.isNotEmpty) {
                  debugPrint(
                    '[GP] Re-verify cached pool: ${reverifyQueue.length} · '
                    '$categoryPill · $city',
                  );
                  reverifyFuture = verifyCityStubs(
                    reverifyQueue,
                    reason: 'Re-verify cached pool',
                    wait: needFillUi && budgetLeft(),
                  );
                }

                // Places lookups are slow; start them before SerpApi so a
                // 429 does not leave Hair/Boob job at 0 cards. All preview
                // skips Places so four parallel pills do not exhaust quota.
                Future<List<OpenAIClinic>>? placesFillFuture;
                if (needFillUi &&
                    needsMoreGoogle() &&
                    !liveCancelled() &&
                    exploreLiveSearchUsesPlaces(
                      liveGoogleTarget: liveGoogleTarget,
                      googleLiveTargetOverride: googleLiveTargetOverride,
                    )) {
                  final placesQueries = exploreBilingualPlacesPair(
                    procedure: queryOrSelection,
                    city: city,
                    pill: categoryPill,
                    countryCode: countryCode,
                  );
                  // WAVE 3 — clinic-first Places breadth when still underfilled.
                  final placesExpanded = !isPreviewFill
                      ? exploreLocalizedPlacesQueries(
                          procedure: queryOrSelection,
                          city: city,
                          pill: categoryPill,
                          countryCode: countryCode,
                          maxQueries: pricedShown() < 2 ? 4 : 3,
                        )
                      : placesQueries;
                  final placesQ = <String>[
                    ...placesQueries,
                    for (final q in placesExpanded)
                      if (!placesQueries.any(
                        (e) => e.toLowerCase() == q.toLowerCase(),
                      ))
                        q,
                  ].take(isPreviewFill ? 2 : 4).toList();
                  if (placesQ.isNotEmpty) {
                    debugPrint('[GP] Places search: ${placesQ.join(' · ')}');
                    final placesCap = exploreLiveDiscoveryCandidateCap(
                      liveGoogleTarget,
                    );
                    final placesBudget = fgBudget - fgSw.elapsed;
                    placesFillFuture = _discoverPlacesClinicCandidates(
                      procedure: queryOrSelection,
                      city: city,
                      pill: categoryPill,
                      seenKeys: {
                        ...currentProcedureExclusionKeys,
                        ...discoveryInspectedKeys,
                      },
                      siblingFamilyByKey: siblingFamilyByKey,
                      maxCandidates: placesCap,
                      queriesOverride: placesQ,
                      skipPlaceIds: {
                        ...discoveryState.permanentRejectedPlaceIds,
                        for (final e
                            in discoveryState.temporaryRejectedUntil.entries)
                          if (e.value.isAfter(DateTime.now())) e.key,
                      },
                      lookupDeadline: DateTime.now().add(
                        placesBudget <= Duration.zero
                            ? const Duration(seconds: 2)
                            : (placesBudget < const Duration(seconds: 12)
                                  ? placesBudget
                                  : const Duration(seconds: 12)),
                      ),
                    );
                  }
                }

                // 2. City-wide priced web search — native + English in parallel
                // (same timeout window, not a second sequential wait).
                Future<void> cityVerifyFuture = Future.value();
                if (needsMoreGoogle() && (needFillUi || budgetLeft())) {
                  final remaining = fgBudget - fgSw.elapsed;
                  // Leave room for HTML verify after Serp within the fill budget.
                  // Prefer 8–10s Serper windows; never chain many 4s timeouts.
                  final serpTimeout = needFillUi
                      ? (remaining <= Duration.zero
                            ? const Duration(seconds: 3)
                            : (remaining < _kForegroundSerpApiTimeout
                                  ? remaining
                                  : _kForegroundSerpApiTimeout))
                      : (remaining < _kForegroundSerpApiTimeout
                            ? remaining
                            : _kForegroundSerpApiTimeout);
                  // WAVE 1 — broad web discovery (no site:) + bilingual pair.
                  debugPrint('[SEARCH WAVE] 1 start · $categoryPill · $city');
                  final broad = buildBroadProcedureDiscoveryQueries(
                    city: city,
                    procedure: queryOrSelection,
                    pill: categoryPill,
                    countryCode: countryCode,
                    maxQueries: isPreviewFill ? 2 : 4,
                  );
                  final bilingual = exploreBilingualSearchPair(
                    procedure: queryOrSelection,
                    city: city,
                    pill: categoryPill,
                    maxPair: 2,
                    countryCode: countryCode,
                  );
                  final queries = <String>[
                    ...broad,
                    for (final q in bilingual)
                      if (!broad.any((b) => b.toLowerCase() == q.toLowerCase()))
                        q,
                  ].take(isPreviewFill ? 2 : 5).toList();
                  if (queries.isNotEmpty) {
                    debugPrint(
                      '[GP] Google city search: ${queries.join(' · ')}',
                    );
                  }
                  final cityCap = exploreLiveDiscoveryCandidateCap(
                    liveGoogleTarget,
                  );
                  // Broad discovery queries in parallel (bounded), not a
                  // long sequential query chain that burns the fill budget.
                  final cityFuture = _discoverSerpApiCityPricedClinics(
                    procedure: queryOrSelection,
                    city: city,
                    pill: categoryPill,
                    seenKeys: shownKeys,
                    siblingFamilyByKey: siblingFamilyByKey,
                    maxClinics: needFillUi
                        ? cityCap
                        : liveGoogleTarget - googleShown.length,
                    poolForHostMatch: pool,
                    resolvePlaces: false,
                    timeout: serpTimeout,
                    maxQueries: queries.length.clamp(1, isPreviewFill ? 2 : 5),
                    mode: ExploreRequestMode.foreground,
                    allPreview: isPreviewFill,
                    uiDeadlinePassed: fgSw.elapsed >= softUiBudget,
                    queriesOverride: queries,
                  );
                  // Official discovery first. Never await marketplace before
                  // verifying official clinic websites — marketplace junk
                  // resolution must not block good candidates.
                  final cityStubs = await cityFuture;
                  debugPrint(
                    '[SEARCH WAVE] 1 complete · stubs=${cityStubs.length}',
                  );
                  debugPrint(
                    '[PIPELINE] procedure=$categoryPill '
                    'officialFound=${cityStubs.length} '
                    'officialVerifyStarted=${cityStubs.isEmpty ? 0 : math.min(cityStubs.length, cityCap)}',
                  );
                  for (final stub in cityStubs) {
                    logExplorePrice(
                      clinicName: stub.name,
                      procedure: queryOrSelection,
                      amount: stub.priceMin,
                      currency: stub.currency,
                      sourceUrl: stub.priceSourceUrl.isNotEmpty
                          ? stub.priceSourceUrl
                          : (_sourceUrlFromArea(stub.area) ?? ''),
                      verdict: 'candidate · official search',
                    );
                  }
                  Future<void> officialVerifyFuture = Future.value();
                  if (cityStubs.isNotEmpty) {
                    officialVerifyFuture = verifyCityStubs(
                      cityStubs.take(cityCap).toList(),
                      reason: needFillUi
                          ? 'Fill-to-$liveGoogleTarget website verify'
                          : 'Background verification started',
                      wait: needFillUi && budgetLeft(),
                    );
                  }

                  Future<void> marketplaceVerifyFuture = Future.value();
                  // All preview used to skip marketplace entirely (isPreviewFill
                  // + allowDeepFallbacks:false). Cold cities then only scraped
                  // official SERP pages and never mined WhatClinic/Bookimed.
                  final mayMarket =
                      (allowDeepFallbacks || isPreviewFill) &&
                      needsMoreGoogle() &&
                      !visibleTargetReached.isCompleted &&
                      !liveCancelled();
                  // Marketplace only when official discovery found nothing, or
                  // after official verify still needs cards.
                  if (mayMarket && cityStubs.isEmpty && budgetLeft()) {
                    marketplaceVerifyFuture = () async {
                      if (visibleTargetReached.isCompleted ||
                          !needsMoreGoogle()) {
                        return;
                      }
                      final marketStubs = await _discoverMarketplaceDirectoryLeads(
                        procedure: queryOrSelection,
                        city: city,
                        pill: categoryPill,
                        seenKeys: shownKeys,
                        maxClinics: needFillUi ? (isPreviewFill ? 2 : 4) : 2,
                        timeout: serpTimeout,
                        mode: ExploreRequestMode.background,
                        // Use focused Serper budget — All's shared pool of 4
                        // is for official discovery; marketplace is fallback.
                        allPreview: false,
                        uiDeadlinePassed: fgSw.elapsed >= softUiBudget,
                      );
                      debugPrint(
                        '[PIPELINE] procedure=$categoryPill '
                        'marketplaceDiscovered=${marketStubs.length}',
                      );
                      if (marketStubs.isEmpty ||
                          visibleTargetReached.isCompleted ||
                          !needsMoreGoogle()) {
                        return;
                      }
                      await verifyCityStubs(
                        marketStubs.take(cityCap).toList(),
                        reason: 'Marketplace fallback website verify',
                        wait: needFillUi && budgetLeft(),
                      );
                    }();
                  } else if (mayMarket && cityStubs.isNotEmpty) {
                    // Start only after official verify finishes without enough
                    // accepted cards — never block official on marketplace.
                    // Do not require budgetLeft(): official HTML often outlives
                    // the UI deadline; gating on it skipped WhatClinic entirely
                    // for Ankara while stubs were still verifying.
                    marketplaceVerifyFuture = () async {
                      await officialVerifyFuture;
                      if (visibleTargetReached.isCompleted ||
                          !needsMoreGoogle() ||
                          liveCancelled()) {
                        return;
                      }
                      final marketStubs =
                          await _discoverMarketplaceDirectoryLeads(
                            procedure: queryOrSelection,
                            city: city,
                            pill: categoryPill,
                            seenKeys: {
                              ...shownKeys,
                              for (final c in cityStubs)
                                ...exploreClinicIdentityKeys(c),
                            },
                            maxClinics: 2,
                            timeout: serpTimeout,
                            mode: ExploreRequestMode.background,
                            allPreview: false,
                            uiDeadlinePassed: true,
                          );
                      debugPrint(
                        '[PIPELINE] procedure=$categoryPill '
                        'marketplaceDiscovered=${marketStubs.length}',
                      );
                      if (marketStubs.isEmpty ||
                          visibleTargetReached.isCompleted ||
                          !needsMoreGoogle()) {
                        return;
                      }
                      await verifyCityStubs(
                        marketStubs.take(2).toList(),
                        reason: 'Marketplace post-official fallback verify',
                        wait: false,
                      );
                    }();
                  } else if (!mayMarket) {
                    debugPrint(
                      '[PIPELINE] procedure=$categoryPill '
                      'marketplaceSkipped '
                      'preview=$isPreviewFill deep=$allowDeepFallbacks '
                      'needMore=${needsMoreGoogle()}',
                    );
                  }

                  cityVerifyFuture = Future.wait([
                    officialVerifyFuture,
                    marketplaceVerifyFuture,
                  ]);

                  // WAVE 2 — brand / alias discovery when wave 1 underfilled.
                  if (!isPreviewFill &&
                      needFillUi &&
                      needsMoreGoogle() &&
                      !liveCancelled() &&
                      !_serpApiLastRateLimited &&
                      budgetLeft() &&
                      !visibleTargetReached.isCompleted) {
                    debugPrint(
                      '[SEARCH WAVE] 2 start · brand/alias · $categoryPill',
                    );
                    final wave2All = exploreLocalizedSearchQueries(
                      procedure: queryOrSelection,
                      city: city,
                      pill: categoryPill,
                      countryCode: countryCode,
                      maxQueries: 8,
                    );
                    final wave2Queries = <String>[];
                    for (final q in wave2All) {
                      if (queries.any(
                        (e) => e.toLowerCase() == q.toLowerCase(),
                      )) {
                        continue;
                      }
                      wave2Queries.add(q);
                      if (wave2Queries.length >= 3) break;
                    }
                    debugPrint(
                      '[GP] Fill-to-$liveGoogleTarget Serp wave-2 · '
                      '$categoryPill · $city · ${wave2Queries.join(' · ')}',
                    );
                    final more = await _discoverSerpApiCityPricedClinics(
                      procedure: queryOrSelection,
                      city: city,
                      pill: categoryPill,
                      seenKeys: {...shownKeys},
                      siblingFamilyByKey: siblingFamilyByKey,
                      maxClinics: cityCap,
                      poolForHostMatch: pool,
                      resolvePlaces: false,
                      timeout: _kSerpApiTimeout,
                      maxQueries: isPreviewFill
                          ? 1
                          : (wave2Queries.isEmpty ? 2 : wave2Queries.length),
                      mode: ExploreRequestMode.foreground,
                      allPreview: isPreviewFill,
                      uiDeadlinePassed: fgSw.elapsed >= softUiBudget,
                      queriesOverride: wave2Queries.isEmpty
                          ? null
                          : wave2Queries,
                    );
                    debugPrint(
                      '[SEARCH WAVE] 2 complete · stubs=${more.length}',
                    );
                    debugPrint(
                      '[PIPELINE] procedure=$categoryPill '
                      'officialFound=${more.length} '
                      'officialVerifyStarted=${more.isEmpty ? 0 : math.min(more.length, cityCap)}',
                    );
                    if (more.isNotEmpty) {
                      cityVerifyFuture = Future.wait([
                        cityVerifyFuture,
                        verifyCityStubs(
                          more.take(cityCap).toList(),
                          reason:
                              'Fill-to-$liveGoogleTarget Serp wave-2 verify',
                          wait: budgetLeft(),
                        ),
                      ]);
                    }
                  }
                }

                Future<void> consumePlacesStubs(
                  List<OpenAIClinic> stubs,
                ) async {
                  for (final stub in stubs) {
                    if (!needsMoreGoogle()) break;
                    if (!needFillUi && !budgetLeft()) break;
                    final stubHost = _extractDomain(stub.area);
                    if (stubHost.isNotEmpty &&
                        _isSessionBlockedHost(stubHost) &&
                        _rendererHostBudgetSpent(stubHost)) {
                      continue;
                    }
                    rememberInspected(stub);
                    final pooled =
                        _matchExploreClinicByHost(pool, stubHost) ??
                        _matchExploreClinicByKeys(pool, stub);
                    if (pooled != null && isUsableClinic(pooled)) {
                      paintGoogle(
                        prepareClinic(pooled),
                        source: ExploreClinicSource.googleLive,
                      );
                    }
                  }
                  if (needsMoreGoogle() && needFillUi && stubs.isNotEmpty) {
                    final need = liveGoogleTarget - googleShown.length;
                    final placesVerifyCap = math.min(
                      stubs.length,
                      math.max(need * 2, liveGoogleTarget + 1),
                    );
                    final toVerify = [
                      for (final s in stubs)
                        if (!exploreClinicHitsKeys(s, shownKeys))
                          if (!(_isSessionBlockedHost(_extractDomain(s.area)) &&
                              _rendererHostBudgetSpent(_extractDomain(s.area))))
                            s,
                    ].take(placesVerifyCap).toList();
                    await verifyCityStubs(
                      toVerify,
                      reason: 'Fill-to-$liveGoogleTarget Places website verify',
                      wait: budgetLeft(),
                    );
                  }
                }

                // Places discovery is already running. Verify those sites in
                // parallel with the city-search stubs so Cloudflare mills do
                // not sit on both verification slots for 20s.
                Future<void> placesVerifyFuture = Future.value();
                if (needsMoreGoogle() && placesFillFuture != null) {
                  placesVerifyFuture = placesFillFuture.then(
                    consumePlacesStubs,
                  );
                } else if (needsMoreGoogle() &&
                    budgetLeft() &&
                    exploreLiveSearchUsesPlaces(
                      liveGoogleTarget: liveGoogleTarget,
                      googleLiveTargetOverride: googleLiveTargetOverride,
                    )) {
                  final remaining = fgBudget - fgSw.elapsed;
                  if (remaining >= const Duration(milliseconds: 600)) {
                    final placesQueries = exploreBilingualPlacesPair(
                      procedure: queryOrSelection,
                      city: city,
                      pill: categoryPill,
                      countryCode: countryCode,
                    );
                    if (placesQueries.isNotEmpty) {
                      debugPrint(
                        '[GP] Places search: ${placesQueries.join(' · ')}',
                      );
                      placesVerifyFuture = _discoverPlacesClinicCandidates(
                        procedure: queryOrSelection,
                        city: city,
                        pill: categoryPill,
                        seenKeys: {
                          ...currentProcedureExclusionKeys,
                          ...discoveryInspectedKeys,
                        },
                        siblingFamilyByKey: siblingFamilyByKey,
                        maxCandidates: 8,
                        queriesOverride: placesQueries,
                        skipPlaceIds: {
                          ...discoveryState.permanentRejectedPlaceIds,
                          for (final e
                              in discoveryState.temporaryRejectedUntil.entries)
                            if (e.value.isAfter(DateTime.now())) e.key,
                        },
                        lookupDeadline: DateTime.now().add(
                          remaining < _kForegroundPlacesTimeout
                              ? remaining
                              : _kForegroundPlacesTimeout,
                        ),
                      ).then(consumePlacesStubs);
                    }
                  }
                }
                void detachVerifyToBackground() {
                  detachedVerifyFutures
                    ..add(reverifyFuture)
                    ..add(cityVerifyFuture)
                    ..add(placesVerifyFuture);
                  unawaited(reverifyFuture);
                  unawaited(cityVerifyFuture);
                  unawaited(placesVerifyFuture);
                }

                // Soft UI / visible target / hard fill — do not block UI on
                // leftover verify futures once cards are ready.
                final waitBudget = fgBudget - fgSw.elapsed;
                if (waitBudget <= Duration.zero ||
                    liveCancelled() ||
                    visibleTargetReached.isCompleted) {
                  debugPrint(
                    '[BACKGROUND CONTINUE] $categoryPill · $city · '
                    '${fgSw.elapsedMilliseconds}ms'
                    '${visibleTargetReached.isCompleted ? " · targetReached" : ""}',
                  );
                  detachVerifyToBackground();
                } else {
                  await Future.any([
                    visibleTargetReached.future,
                    Future.wait([
                      reverifyFuture,
                      cityVerifyFuture,
                      placesVerifyFuture,
                    ]),
                    Future<void>.delayed(waitBudget),
                  ]);
                  if (visibleTargetReached.isCompleted ||
                      fgSw.elapsed >= fgBudget ||
                      liveCancelled()) {
                    debugPrint(
                      '[BACKGROUND CONTINUE] $categoryPill · $city · '
                      '${fgSw.elapsedMilliseconds}ms'
                      '${visibleTargetReached.isCompleted ? " · targetReached" : ""}',
                    );
                    detachVerifyToBackground();
                  }
                }
                // Only spin briefly if still under target; never hold 60s.
                while (needsMoreGoogle() &&
                    !liveCancelled() &&
                    !visibleTargetReached.isCompleted &&
                    fgSw.elapsed < fgBudget) {
                  final left = fgBudget - fgSw.elapsed;
                  await Future.any([
                    visibleTargetReached.future,
                    Future<void>.delayed(
                      left < const Duration(milliseconds: 250)
                          ? left
                          : const Duration(milliseconds: 250),
                    ),
                  ]);
                  if (visibleTargetReached.isCompleted) break;
                }
                finishTopUpIfFull();
              }

              void releaseUiDeadline({required bool hard}) {
                if (liveCancelled()) return;
                if (_comparisonGoogleMixComplete.contains(cacheKey) &&
                    aiTopUp.isCompleted) {
                  return;
                }
                final underMinBefore =
                    pricedCountOf(bgPublished) < kExploreCompareMinClinics;
                // Soft UI: if Google is slow/429'd, fill empty slots from the
                // verified pool immediately so users are not stuck at 2 cards
                // for ~60s waiting on Places/Serper.
                if (underMinBefore && needsMoreGoogle()) {
                  padCachedFallback(
                    reason: hard
                        ? 'hard deadline pool pad'
                        : 'soft deadline pool pad',
                  );
                }
                final priced = pricedCountOf(bgPublished);
                final underMin = priced < kExploreCompareMinClinics;
                bgPublished = publishCombined(
                  mixedShown().isNotEmpty ? mixedShown() : cachedShown,
                );
                _comparisonMemoryCache[cacheKey] = putBestComparison(
                  previous: _comparisonMemoryCache[cacheKey],
                  incoming: bgPublished,
                  isStillValid: isUsableClinic,
                );
                // Never complete the top-up here — that detaches onProgress
                // and later verified clinics never appear on screen.
                if (!hard || (underMin && needsMoreGoogle())) {
                  debugPrint(
                    '[UI ${hard ? 'HARD' : 'SOFT'} DEADLINE] $categoryPill · '
                    '$city · $priced cards · keep filling · '
                    '${fgSw.elapsedMilliseconds}ms',
                  );
                } else {
                  debugPrint(
                    '[UI DEADLINE] $categoryPill · $city · '
                    '$priced cards · '
                    '${googleShown.length}/$liveGoogleTarget Google · '
                    '${fgSw.elapsedMilliseconds}ms',
                  );
                }
                // Deep backend is started from finishTopUp so it stays inside
                // the fill-session pending set (not an orphaned UI deadline
                // future that outlives the progress listener).
              }

              unawaited(
                Future<void>.delayed(
                  softUiBudget,
                  () => releaseUiDeadline(hard: false),
                ),
              );
              unawaited(
                Future<void>.delayed(
                  fgBudget,
                  () => releaseUiDeadline(hard: true),
                ),
              );

              await runForegroundGoogle().timeout(
                fgBudget + const Duration(milliseconds: 400),
                onTimeout: () {
                  releaseUiDeadline(hard: true);
                  debugPrint(
                    '[UI DEADLINE] $categoryPill · $city · '
                    'runForegroundGoogle cut',
                  );
                },
              );

              if (liveCancelled()) {
                return finishTopUp(
                  reachedGoogleTarget: !needsMoreGoogle(),
                  extraPersist: googleShown,
                  paused: true,
                );
              }

              return finishTopUp(
                reachedGoogleTarget:
                    googlePoolAdded >= liveGoogleTarget || !needsMoreGoogle(),
                extraPersist: googleShown,
                poolExhausted:
                    uiFrozen &&
                    pricedCountOf(bgPublished) >= kExploreCompareMinClinics,
              );
            } catch (e) {
              debugPrint('[GP] Comparison AI top-up error: $e');
              await persistExplorePool(
                googleShown,
                reason: 'top-up error, keep ${googleShown.length} new',
                flushNow: true,
              );
              if (pricedCountOf(bgPublished) > 0) {
                debugPrint(
                  '[GP] Top-up error with ${pricedCountOf(bgPublished)} shown '
                  '— not marking exhausted',
                );
              }
              if (!aiTopUp.isCompleted) aiTopUp.complete(bgPublished);
              return bgPublished;
            } finally {
              // Keep in-flight while deferred background verify still owns
              // the top-up completer (late onProgress for All / cold cities).
              if (aiTopUp.isCompleted) {
                _comparisonAiTopUpInFlight.remove(cacheKey);
              }
            }
          }

          final topUpFuture = runAiTopUp();
          _cache[cacheKey] = topUpFuture;
          // Never block the UI on the full 4-clinic scrape. First verified
          // cards emit via onProgress; remaining discovery stays in background.
          unawaited(topUpFuture);
          logCompareTiming(
            poolEmpty ? 'google-start' : 'firestore-2-google-pending',
          );
          return initialResult;
        }

        final pending = _comparisonAiTopUpCompleters[cacheKey];
        if (pending != null && !pending.isCompleted) {
          return await pending.future;
        }
        return _comparisonMemoryCache[cacheKey] ?? initialResult;
      });
      final toolBuild =
          searchNewGoogle && ExplorePriceDiscoveryTool.instance.enabled;
      if (toolBuild) _discoveryToolBuilds[cacheKey] = building;
      try {
        return await building;
      } finally {
        if (identical(_discoveryToolBuilds[cacheKey], building)) {
          _discoveryToolBuilds.remove(cacheKey);
        }
      }
    } finally {
      if (onProgress != null) {
        // Detach the caller's listener only after the background AI top-up
        // has emitted its final result (or is not running). Detaching earlier
        // would drop the "Loading more clinics…" updates the caller expects.
        void detach() {
          _comparisonProgressListeners[cacheKey]?.remove(onProgress);
          if (_comparisonProgressListeners[cacheKey]?.isEmpty ?? false) {
            _comparisonProgressListeners.remove(cacheKey);
          }
        }

        final indexRefresh = _interactiveRefresh[cacheKey];
        final topUp = _comparisonAiTopUpCompleters[cacheKey];
        if (indexRefresh != null) {
          // The initial index snapshot returns before this job finishes.
          // Keep the screen subscribed to partials and final worker results.
          unawaited(indexRefresh.then<void>(
            (_) => detach(), onError: (Object error, StackTrace stack) => detach(),
          ));
        } else if (topUp != null && !topUp.isCompleted) {
          unawaited(
            topUp.future
                .timeout(
                  const Duration(seconds: 300),
                  onTimeout: () =>
                      _comparisonMemoryCache[cacheKey] ??
                      OpenAIComparisonResult(
                        city: city,
                        topic: queryOrSelection,
                        topicType: OpenAISearchItemType.procedure,
                        summary: '',
                        rangeLabel: '',
                        mapCenter: const OpenAICoord(0, 0),
                        clinics: const [],
                      ),
                )
                .whenComplete(detach)
                .catchError(
                  (Object _) =>
                      _comparisonMemoryCache[cacheKey] ??
                      OpenAIComparisonResult(
                        city: city,
                        topic: queryOrSelection,
                        topicType: OpenAISearchItemType.procedure,
                        summary: '',
                        rangeLabel: '',
                        mapCenter: const OpenAICoord(0, 0),
                        clinics: const [],
                      ),
                ),
          );
        } else {
          detach();
        }
      }
    }
  }

  /// Waits for background Places + price enrichment after [buildComparison].
  Future<OpenAIComparisonResult?> awaitComparisonEnrichment(
    String cacheKey, {
    Duration timeout = const Duration(seconds: 50),
  }) async {
    final pending = _comparisonEnrichCompleters[cacheKey];
    if (pending != null && !pending.isCompleted) {
      try {
        return await pending.future.timeout(timeout);
      } on TimeoutException {
        return _comparisonMemoryCache[cacheKey];
      }
    }
    return _comparisonMemoryCache[cacheKey];
  }

  /// Waits for the background AI fetch + refill loop kicked by
  /// [buildComparison] to finish. Returns the latest in-memory result when
  /// the timeout hits so the UI can still finish loading gracefully.
  Future<OpenAIComparisonResult?> awaitComparisonAiTopUp(
    String cacheKey, {
    Duration timeout = const Duration(seconds: 180),
  }) async {
    final pending = _comparisonAiTopUpCompleters[cacheKey];
    if (pending != null && !pending.isCompleted) {
      try {
        return await pending.future.timeout(timeout);
      } on TimeoutException {
        return _comparisonMemoryCache[cacheKey];
      }
    }
    return _comparisonMemoryCache[cacheKey];
  }

  bool isComparisonAiTopUpInFlight(String cacheKey) =>
      _comparisonAiTopUpInFlight.contains(cacheKey);

  /// Authoritative focused-pill search activity: top-up in flight OR any
  /// tracked fill-session work (verify, deep backend, query waves).
  /// Does not treat [_comparisonGoogleMixComplete] as "done searching" when
  /// set incorrectly — mix complete is only set at visible target or true
  /// exhaustion.
  bool isComparisonSearchActive(String cacheKey) {
    if (_interactiveRefresh.containsKey(cacheKey)) return true;
    if (_discoveryToolBuilds.containsKey(cacheKey)) return true;
    if (_comparisonGoogleMixComplete.contains(cacheKey) &&
        _comparisonPendingFillCount(cacheKey) == 0 &&
        !_comparisonAiTopUpInFlight.contains(cacheKey)) {
      return false;
    }
    return _comparisonAiTopUpInFlight.contains(cacheKey) ||
        _comparisonPendingFillCount(cacheKey) > 0;
  }

  bool isExploreGoogleMixComplete(String cacheKey) =>
      _comparisonGoogleMixComplete.contains(cacheKey);

  bool isDiscoveryToolSettled(String cacheKey) =>
      _discoveryToolSettled.contains(cacheKey);

  bool isDiscoveryToolIncomplete(String cacheKey) =>
      _discoveryToolIncomplete.contains(cacheKey);

  bool isComparisonTopUpExhausted(String cacheKey) =>
      _comparisonTopUpExhausted.contains(cacheKey);

  /// Re-attempt Google Places ratings for clinics that still have `rating <= 0`.
  /// Skips confirmed in-memory misses (`matched: false` within miss TTL).
  /// Does not touch prices.
  Future<OpenAIComparisonResult> backfillMissingClinicRatings({
    required OpenAIComparisonResult base,
    required String city,
    required String procedure,
    required String pill,
  }) async {
    // This operation only supplies ratings. Without a Places key there is
    // nothing to recover; probing clinic websites cannot produce a rating.
    if (!_places.isConfigured) return base;
    final unrated = [
      for (final c in base.clinics)
        if (c.rating <= 0) c,
    ];
    if (unrated.isEmpty) return base;

    final toRetry = List<OpenAIClinic>.from(unrated);
    debugPrint(
      '[GP] Rating backfill: ${unrated.length} unrated, '
      '${toRetry.length} retried · $pill · $city',
    );
    if (toRetry.isEmpty) return base;

    final uniqueRetry = <OpenAIClinic>[];
    final lockedKeys = <String>[];
    for (final c in toRetry) {
      final k = '${city.trim().toLowerCase()}|${c.name.trim().toLowerCase()}';
      if (!_ratingBackfillClinicKeys.add(k)) continue;
      lockedKeys.add(k);
      uniqueRetry.add(c);
    }
    if (uniqueRetry.isEmpty) return base;

    try {
      final withPlaces = await _enrichClinicsWithPlaces(
        clinics: uniqueRetry,
        city: city,
        dropUnmatched: false,
      );
      final merged = <OpenAIClinic>[];
      for (final prev in base.clinics) {
        final match = _matchExploreClinicByKeys(withPlaces, prev);
        if (match == null || match.rating <= 0) {
          merged.add(withExploreClinicDisplayName(prev));
          continue;
        }
        merged.add(
          prev.copyWith(
            name: exploreClinicDisplayName(match).isNotEmpty
                ? exploreClinicDisplayName(match)
                : exploreClinicDisplayName(prev),
            rating: match.rating,
            reviews: match.reviews > 0 ? match.reviews : prev.reviews,
          ),
        );
      }
      final rated = [
        for (final c in merged)
          if (c.rating > 0 || c.reviews > 0) c,
      ];
      if (rated.isNotEmpty && procedure.trim().isNotEmpty) {
        unawaited(
          ExploreGooglePriceStore.instance.upsert(
            city: city,
            procedure: procedure,
            clinics: [for (final c in rated) _clinicToGooglePriceJson(c)],
          ),
        );
      }
      return base.copyWith(clinics: merged);
    } finally {
      _ratingBackfillClinicKeys.removeAll(lockedKeys);
    }
  }

  bool hasRetryableUnratedClinics({
    required List<OpenAIClinic> clinics,
    required String city,
  }) {
    if (!_places.isConfigured) return false;
    for (final c in clinics) {
      if (c.rating > 0) continue;
      final k = '${city.trim().toLowerCase()}|${c.name.trim().toLowerCase()}';
      if (_ratingBackfillClinicKeys.contains(k)) continue;
      final miss = ExplorePlaceCacheStore.instance.peekMemory(
        city: city, clinicName: c.name,
      );
      if (miss != null && !miss.matched) continue;
      return true;
    }
    return false;
  }

  /// Places lookup for one clinic just appended to the visible list.
  /// Merges the rating into the in-memory comparison and notifies listeners.
  Future<void> enrichLiveShownClinicRating({
    required String cacheKey,
    required OpenAIClinic clinic,
    required String city,
    required String procedure,
    required String pill,
  }) async {
    if (clinic.rating > 0 && !exploreClinicNameNeedsMapsRefresh(clinic)) {
      return;
    }
    final stub = OpenAIComparisonResult(
      city: city,
      topic: procedure,
      topicType: OpenAISearchItemType.procedure,
      summary: '',
      rangeLabel: '',
      mapCenter: clinic.coord,
      clinics: [clinic],
    );
    final rated = await backfillMissingClinicRatings(
      base: stub,
      city: city,
      procedure: procedure,
      pill: pill,
    );
    OpenAIClinic? updated;
    for (final c in rated.clinics) {
      if (exploreClinicHitsKeys(c, exploreClinicIdentityKeys(clinic)) &&
          c.rating > 0) {
        updated = c;
        break;
      }
    }
    if (updated == null) return;
    final current = _comparisonMemoryCache[cacheKey];
    if (current == null) return;
    var changed = false;
    final mergedClinics = <OpenAIClinic>[];
    for (final prev in current.clinics) {
      if (!exploreClinicHitsKeys(prev, exploreClinicIdentityKeys(clinic))) {
        mergedClinics.add(prev);
        continue;
      }
      final nextName = exploreClinicDisplayName(updated);
      if (prev.rating == updated.rating &&
          prev.reviews == updated.reviews &&
          prev.name == nextName) {
        mergedClinics.add(prev);
        continue;
      }
      changed = true;
      mergedClinics.add(
        prev.copyWith(
          name: nextName.isNotEmpty ? nextName : prev.name,
          rating: updated.rating,
          reviews: updated.reviews > 0 ? updated.reviews : prev.reviews,
        ),
      );
    }
    if (!changed) return;
    final merged = current.copyWith(clinics: mergedClinics);
    _comparisonMemoryCache[cacheKey] = merged;
    final listeners = _comparisonProgressListeners[cacheKey];
    if (listeners == null || listeners.isEmpty) return;
    for (final cb in List<void Function(OpenAIComparisonResult)>.from(
      listeners,
    )) {
      try {
        cb(merged);
      } catch (e) {
        debugPrint('[GP] Live rating onProgress error: $e');
      }
    }
  }

  void kickComparisonEnrichmentIfNeeded({
    required String cacheKey,
    required OpenAIComparisonResult base,
    required String queryOrSelection,
    required String city,
  }) {
    _scheduleComparisonEnrichment(
      cacheKey: cacheKey,
      base: base,
      queryOrSelection: queryOrSelection,
      city: city,
    );
  }

  void _scheduleComparisonEnrichment({
    required String cacheKey,
    required OpenAIComparisonResult base,
    required String queryOrSelection,
    required String city,
  }) {
    if (_comparisonEnrichInFlight.contains(cacheKey)) return;
    _comparisonEnrichInFlight.add(cacheKey);
    _comparisonEnrichCompleters.putIfAbsent(
      cacheKey,
      () => Completer<OpenAIComparisonResult>(),
    );

    unawaited(() async {
      try {
        final enriched = await _enrichComparisonResult(
          base: base,
          queryOrSelection: queryOrSelection,
          city: city,
        );
        // Overlay confirmed scrape prices onto the list the user already
        // saw. Never replace 4 cards with 2 just because a later HTTP
        // probe timed out or missed the procedure line.
        final onScreen = _comparisonMemoryCache[cacheKey];
        final shownFloor =
            (onScreen != null && onScreen.clinics.length > base.clinics.length)
            ? onScreen
            : base;
        final toStore = _keepShownClinicsAfterEnrichment(
          shown: shownFloor,
          enriched: enriched,
          procedure: queryOrSelection,
        );
        final rejected = [
          for (final c in enriched.clinics)
            if (exploreRevalidationRemovesCard(c)) c,
        ];
        if (rejected.isNotEmpty) {
          _dropRejectedComparisonClinics(cacheKey, rejected);
        }
        _comparisonMemoryCache[cacheKey] = toStore;
        final listeners = _comparisonProgressListeners[cacheKey];
        if (listeners != null) {
          for (final cb in List<void Function(OpenAIComparisonResult)>.from(
            listeners,
          )) {
            try {
              cb(toStore);
            } catch (e) {
              debugPrint('[GP] Comparison enrichment onProgress error: $e');
            }
          }
        }
        final poolForStore = _exploreComparisonPool[cacheKey];
        unawaited(
          ExploreGooglePriceStore.instance.upsert(
            city: city,
            procedure: queryOrSelection,
            dropKeys: {
              for (final c in rejected)
                ExploreGooglePriceStore.mergeKey({
                  'name': c.name,
                  'place_id': c.placeId,
                  'price_source_url': c.priceSourceUrl,
                  'area': c.area,
                }),
            },
            clinics: [
              for (final c in poolForStore ?? toStore.clinics)
                if (c.hasProcedure &&
                    c.priceMin > 0 &&
                    !c.pricePending &&
                    explorePriceIsVerified(c) &&
                    exploreClinicFitsSearchCity(c, city) &&
                    exploreClinicEligibleForVerifiedPool(
                      c,
                      procedure: queryOrSelection,
                      city: city,
                    ))
                  _clinicToGooglePriceJson(c),
            ],
          ),
        );
        final c = _comparisonEnrichCompleters[cacheKey];
        if (c != null && !c.isCompleted) c.complete(toStore);
        debugPrint('[GP] Comparison background enrichment done');
      } catch (e) {
        debugPrint('[GP] Comparison background enrichment error: $e');
        final c = _comparisonEnrichCompleters[cacheKey];
        if (c != null && !c.isCompleted) c.complete(base);
      } finally {
        _comparisonEnrichInFlight.remove(cacheKey);
      }
    }());
  }

  OpenAIComparisonResult _applyJustifiedPriceFilterToComparison(
    OpenAIComparisonResult resultFiltered, {
    required String procedure,
    bool keepNoPublicPrice = false,
  }) {
    var clinics = resultFiltered.clinics;
    final justifiedClinics =
        filterComparisonClinicsWithJustifiedPrices(
              clinics: clinics,
              procedure: procedure,
            )
            // Explore cards hide unpriced rows — except identity-verified
            // "Price on request" clinics when cold cities hide list prices.
            .where(
              (c) =>
                  c.priceMin > 0 ||
                  (keepNoPublicPrice && exploreClinicIsNoPublicPrice(c)),
            )
            .toList();
    if (justifiedClinics.length < clinics.length) {
      final keptKeys = {
        for (final c in justifiedClinics) exploreClinicDedupKey(c),
      };
      for (final c in clinics) {
        if (keptKeys.contains(exploreClinicDedupKey(c))) continue;
        debugPrint(
          '[GP] Drop unjustified ${c.name} · '
          'curated=${exploreCuratedPriceIsTrusted(c)} '
          'justified=${isJustifiedProcedurePrice(c, procedure: procedure)} '
          'fit=${exploreClinicFitsCompareProcedure(c, procedure)} '
          'price=${c.priceMin} ${c.currency}',
        );
      }
      debugPrint(
        '[GP] Comparison: removed '
        '${clinics.length - justifiedClinics.length} '
        'clinics with unjustified/unpriced quotes',
      );
      clinics = justifiedClinics;
      resultFiltered = _postprocessPreviewComparison(
        resultFiltered.copyWith(clinics: clinics),
      );
    }

    final pricedClinics = clinics
        .where(
          (c) =>
              c.priceMin > 0 &&
              explorePriceIsVerified(c) &&
              isJustifiedProcedurePrice(c, procedure: procedure),
        )
        .toList();

    if (pricedClinics.length < 2) {
      return resultFiltered.copyWith(rangeLabel: '');
    }

    final minP = pricedClinics
        .map((c) => c.priceMin)
        .reduce((a, b) => a < b ? a : b);
    final maxP = pricedClinics
        .map((c) => c.priceMax > 0 ? c.priceMax : c.priceMin)
        .reduce((a, b) => a > b ? a : b);
    final curr = pricedClinics.first.currency;
    final correctedRange = curr == 'RON'
        ? '${minP.toInt()}–${maxP.toInt()} RON'
        : curr == '£'
        ? '£${minP.toInt()}–${maxP.toInt()}'
        : curr == '€'
        ? '€${minP.toInt()}–${maxP.toInt()}'
        : '${minP.toInt()}–${maxP.toInt()} $curr';
    return resultFiltered.copyWith(rangeLabel: correctedRange);
  }

  Future<OpenAIComparisonResult> _enrichComparisonResult({
    required OpenAIComparisonResult base,
    required String queryOrSelection,
    required String city,
  }) async {
    var working = List<OpenAIClinic>.from(base.clinics);

    final needsPlaces = working.any(
      (c) =>
          c.reviews <= 0 ||
          c.rating <= 0 ||
          exploreClinicNameNeedsMapsRefresh(c),
    );
    if (needsPlaces) {
      final placesSw = Stopwatch()..start();
      final withPlaces =
          await _enrichClinicsWithPlaces(
            clinics: working,
            city: city,
            dropUnmatched: false,
          ).timeout(
            const Duration(seconds: 12),
            onTimeout: () {
              debugPrint(
                '[GP] Comparison Places timeout — using AI review counts',
              );
              return working;
            },
          );
      // Keep the on-screen set. Places may fail for bundled seed names
      // (no Maps website) — dropping them is what made 4 cards collapse to 1.
      if (withPlaces.length >= working.length) {
        working = withPlaces;
      } else if (withPlaces.isNotEmpty) {
        final byName = {
          for (final c in withPlaces) c.name.toLowerCase().trim(): c,
        };
        working = [
          for (final c in working) byName[c.name.toLowerCase().trim()] ?? c,
        ];
      }
      final rated = [
        for (final c in working)
          if (c.rating > 0 || c.reviews > 0) c,
      ];
      if (rated.isNotEmpty) {
        unawaited(
          ExploreGooglePriceStore.instance.upsert(
            city: city,
            procedure: queryOrSelection,
            clinics: [
              for (final c in rated)
                if (exploreClinicFitsSearchCity(c, city))
                  _clinicToGooglePriceJson(c),
            ],
          ),
        );
        debugPrint(
          '[GP] Compare timing: $queryOrSelection · $city · '
          'source=places-enriched · ${placesSw.elapsedMilliseconds}ms',
        );
      }
    }

    var resultFiltered = _postprocessPreviewComparison(
      base.copyWith(clinics: working),
    );

    final unpricedCount = resultFiltered.clinics
        .where((c) => c.priceMin <= 0)
        .length;
    final needsVerify = resultFiltered.clinics.any(
      (c) =>
          c.priceMin > 0 &&
          (c.pricePending ||
              c.priceVerificationStatus == PriceVerificationStatus.unverified ||
              c.priceVerificationStatus ==
                  PriceVerificationStatus.legacyUnverified),
    );
    final needsRescrape = resultFiltered.clinics.any(
      (c) =>
          (c.area.contains('.') &&
              c.priceMin > 0 &&
              (!explorePriceIsVerified(c) ||
                  !isJustifiedProcedurePrice(
                    c,
                    procedure: queryOrSelection,
                  ))) ||
          exploreCachedPriceNeedsReselect(
            rawProcedureText: c.rawProcedureText,
            brand: c.brand,
            sourceUrl: c.priceSourceUrl.isNotEmpty ? c.priceSourceUrl : c.area,
            procedure: queryOrSelection,
            rawPriceText: c.rawPriceText,
            rawEvidence: c.priceEvidenceText,
            priceMin: c.priceMin,
            priceMax: c.priceMax,
            priceExtractRevision: c.priceExtractRevision,
            currency: c.currency,
          ),
    );
    if (unpricedCount <= 0 && !needsVerify && !needsRescrape) {
      debugPrint(
        resultFiltered.clinics.isEmpty
            ? '[GP] Comparison: no known price pages to refresh; discovery is handled by its job'
            : '[GP] Comparison: all priced & verified — skip HTTP re-scrape',
      );
      return _applyJustifiedPriceFilterToComparison(
        resultFiltered,
        procedure: queryOrSelection,
      );
    }

    debugPrint(
      '[GP] Comparison: $unpricedCount unpriced, '
      '${needsVerify ? "pending verification" : "no verify"}, '
      'rescrape=$needsRescrape — enriching via HTTP',
    );
    var clinicsOut = await _enrichClinicsWithDirectPriceFetch(
      clinics: resultFiltered.clinics,
      procedure: queryOrSelection,
      city: city,
      repriceExisting: needsRescrape,
      requireWebsiteConfirm: needsVerify,
    );
    clinicsOut = [
      for (final c in clinicsOut)
        if (c.hasProcedure) c,
    ];
    if (clinicsOut.any((c) => c.priceMin <= 10)) {
      final norm = await _normalizeProcedure(queryOrSelection);
      var batch = _fullBatchCache[_batchCacheKey(norm, city)];
      if (batch == null || batch.isEmpty) {
        await _hydrateFullBatchCacheFromFirestore(norm, city);
        batch = _fullBatchCache[_batchCacheKey(norm, city)];
      }
      if (batch != null && batch.isNotEmpty) {
        final beforePriced = clinicsOut.where((c) => c.priceMin > 10).length;
        final swapped = _replaceUnpricedComparisonFromBatch(
          ranked: clinicsOut,
          pool: batch,
        );
        final afterPriced = swapped.where((c) => c.priceMin > 10).length;
        if (afterPriced > beforePriced) {
          clinicsOut = swapped;
        }
      }
    }

    clinicsOut = filterComparisonClinicsWithJustifiedPrices(
      clinics: clinicsOut,
      procedure: queryOrSelection,
    );

    final enrichedPriced = clinicsOut.where((c) => c.priceMin > 10).toList();
    if (enrichedPriced.isNotEmpty) {
      final minP = enrichedPriced
          .map((c) => c.priceMin)
          .reduce((a, b) => a < b ? a : b);
      final maxP = enrichedPriced
          .map((c) => c.priceMax > 0 ? c.priceMax : c.priceMin)
          .reduce((a, b) => a > b ? a : b);
      final curr = enrichedPriced.first.currency;
      final newRange = curr == 'RON'
          ? '${minP.toInt()}–${maxP.toInt()} RON'
          : curr == '£'
          ? '£${minP.toInt()}–${maxP.toInt()}'
          : curr == '€'
          ? '€${minP.toInt()}–${maxP.toInt()}'
          : '${minP.toInt()}–${maxP.toInt()} $curr';
      return _postprocessPreviewComparison(
        resultFiltered.copyWith(clinics: clinicsOut, rangeLabel: newRange),
      );
    }

    return _postprocessPreviewComparison(
      resultFiltered.copyWith(clinics: clinicsOut),
    );
  }

  /// Returns a cached comparison result from memory if available.
  /// Synchronous snapshot from [_comparisonMemoryCache] only (not [_cache] futures).
  OpenAIComparisonResult? getCachedComparison(String cacheKey) {
    final hit = _comparisonMemoryCache[cacheKey];
    if (hit == null) return null;
    return hit.copyWith(
      clinics: [for (final c in hit.clinics) stripStaleExtractedClinicPrice(c)],
    );
  }

  /// Stores a comparison in the in-memory cache (e.g. Explore All-mixed).
  void putCachedComparison(String cacheKey, OpenAIComparisonResult result) {
    final prev = _comparisonMemoryCache[cacheKey];
    _comparisonMemoryCache[cacheKey] = putBestComparison(
      previous: prev,
      incoming: result,
    );
  }

  void _queueExplorePersist({
    required String cacheKey,
    required String city,
    required String procedure,
    required OpenAIComparisonResult metaSource,
    required List<OpenAIClinic> priced,
    required String reason,
    bool flushNow = false,
  }) {
    debugPrint('[GP] Firestore write queued · $cacheKey');
    _explorePersistPending[cacheKey] = _ExplorePersistJob(
      city: city,
      procedure: procedure,
      metaSource: metaSource,
      priced: priced,
      reason: reason,
    );
    _explorePersistDebounce[cacheKey]?.cancel();
    if (flushNow) {
      unawaited(_flushExplorePersist(cacheKey));
      return;
    }
    _explorePersistDebounce[cacheKey] = Timer(
      const Duration(milliseconds: 450),
      () => unawaited(_flushExplorePersist(cacheKey)),
    );
  }

  Future<void> _flushExplorePersist(String cacheKey) async {
    _explorePersistDebounce[cacheKey]?.cancel();
    _explorePersistDebounce[cacheKey] = null;
    final job = _explorePersistPending.remove(cacheKey);
    if (job == null) return;
    final prevLock = _explorePersistLocks[cacheKey] ?? Future<void>.value();
    final gate = Completer<void>();
    _explorePersistLocks[cacheKey] = gate.future;
    try {
      await prevLock;
      final fingerprint = explorePersistFingerprint(job.priced);
      if (explorePersistPayloadUnchanged(
        _explorePersistFingerprints[cacheKey] ?? '',
        fingerprint,
      )) {
        debugPrint('[GP] Firestore write skipped · unchanged');
        return;
      }
      debugPrint('[GP] Firestore flush · ${job.priced.length} clinics');
      await _saveToFirestore(
        cacheKey,
        job.metaSource.copyWith(clinics: job.priced),
      );
      await ExploreGooglePriceStore.instance.upsert(
        city: job.city,
        procedure: job.procedure,
        clinics: [
          for (final c in job.priced)
            if (!exploreCuratedPriceIsTrusted(c) &&
                exploreClinicEligibleForVerifiedPool(
                  c,
                  procedure: job.procedure,
                  city: job.city,
                ))
              _clinicToGooglePriceJson(c),
        ],
      );
      _explorePersistFingerprints[cacheKey] = fingerprint;
      debugPrint(
        '[GP] Comparison Firestore SAVE (${job.reason}): '
        '${job.priced.length} clinics in pool · ${job.procedure} · ${job.city}',
      );
    } catch (e) {
      debugPrint('[GP] Firestore flush error: $e');
    } finally {
      gate.complete();
      if (_explorePersistLocks[cacheKey] == gate.future) {
        _explorePersistLocks.remove(cacheKey);
      }
    }
  }

  /// Firestore-backed comparison pool (shared across users for a city + procedure).
  /// Tries previous cache revisions so every Compare pill (Botox, Fillers, …)
  /// can still paint 2 cached cards after a price-rule bump.
  Future<OpenAIComparisonResult?> loadComparisonFromFirestore(
    String cacheKey, {
    String? queryOrSelection,
    String? city,
    String? mode,
  }) {
    if (queryOrSelection != null && city != null && mode != null) {
      return _loadExploreComparisonPool(
        cacheKey: cacheKey,
        queryOrSelection: queryOrSelection,
        city: city,
        mode: mode,
      );
    }
    return _loadFromFirestore(cacheKey);
  }

  /// Cheap city enter: hydrate Firestore pool + Google price store for every
  /// procedure pill. No Places, scrape, SerpApi, or OpenAI.
  Future<void> prewarmExploreCachesForCity({
    required String city,
    required String mode,
  }) async {
    final c = city.trim();
    if (c.isEmpty) return;
    debugPrint('[GP] Cache prewarm · $c');
    await Future.wait([
      for (final pill in kExploreComparePills) ...[
        ExploreGooglePriceStore.instance.load(
          city: c,
          procedure: explorePillAiSearchQuery(pill),
        ),
        _loadExploreComparisonPool(
          cacheKey:
              'comparison|$kExploreComparisonCacheRevision|${explorePillAiSearchQuery(pill)}|$c|$mode',
          queryOrSelection: explorePillAiSearchQuery(pill),
          city: c,
          mode: mode,
        ),
      ],
    ]);
  }

  void _dropRejectedComparisonClinics(
    String cacheKey,
    List<OpenAIClinic> rejected,
  ) {
    final keys = {
      for (final c in rejected)
        if (exploreClinicDedupKey(c).isNotEmpty) exploreClinicDedupKey(c),
    };
    final names = {for (final c in rejected) c.name.toLowerCase().trim()};
    final pool = _exploreComparisonPool[cacheKey];
    if (pool == null) return;
    _exploreComparisonPool[cacheKey] = [
      for (final c in pool)
        if (!keys.contains(exploreClinicDedupKey(c)) &&
            !names.contains(c.name.toLowerCase().trim()))
          c,
    ];
  }

  /// Keep every clinic already on screen. Use the scrape only to update a
  /// card when it still has a displayable price; inconclusive probes must
  /// not delete cards after the user has been looking at them.
  OpenAIComparisonResult _keepShownClinicsAfterEnrichment({
    required OpenAIComparisonResult shown,
    required OpenAIComparisonResult enriched,
    required String procedure,
  }) {
    bool usable(OpenAIClinic c) =>
        c.hasProcedure &&
        c.priceMin > 0 &&
        !c.pricePending &&
        explorePriceIsVerified(c) &&
        exploreClinicMatchesProcedure(c, procedure) &&
        isJustifiedProcedurePrice(c, procedure: procedure) &&
        !exploreListedPriceIsNonClinicContent(
          sourceUrl: c.priceSourceUrl,
          website: c.area,
        );

    final enrichedByKey = <String, OpenAIClinic>{
      for (final c in enriched.clinics)
        if (exploreClinicDedupKey(c).isNotEmpty) exploreClinicDedupKey(c): c,
    };
    final enrichedByName = <String, OpenAIClinic>{
      for (final c in enriched.clinics)
        if (c.name.trim().isNotEmpty) c.name.toLowerCase().trim(): c,
    };
    final out = <OpenAIClinic>[];
    final used = <String>{};
    for (final prev in shown.clinics) {
      final key = exploreClinicDedupKey(prev);
      if (key.isEmpty || !used.add(key)) continue;
      final next =
          enrichedByKey[key] ?? enrichedByName[prev.name.toLowerCase().trim()];
      if (next == null) {
        if (usable(prev)) out.add(prev);
        continue;
      }
      if (exploreRevalidationRemovesCard(next)) {
        debugPrint(
          '[GP] Dropped revalidated card ${prev.name} · '
          '${next.priceRejectionReason}',
        );
        continue;
      }
      if (!usable(next) && !usable(prev)) continue;
      var merged = usable(next) ? next : prev;
      final displayName = exploreClinicDisplayName(next);
      if (next.rating > 0 || next.reviews > 0 || displayName != merged.name) {
        merged = merged.copyWith(
          name: displayName.isNotEmpty ? displayName : merged.name,
          rating: next.rating > 0 ? next.rating : merged.rating,
          reviews: next.reviews > 0 ? next.reviews : merged.reviews,
        );
      }
      out.add(merged);
    }
    // Do not splice extra Firestore clinics onto a 3-cached + 3-new mix.
    final shownN = shown.clinics.length;
    final scrapeN = enriched.clinics.length;
    if (scrapeN < shownN) {
      debugPrint(
        '[GP] Enrichment kept $shownN on-screen clinics '
        '(scrape returned $scrapeN) · $procedure',
      );
    }
    return _postprocessPreviewComparison(
      shown.copyWith(
        clinics: out.length <= kExploreCompareMaxClinics
            ? out
            : out.take(kExploreCompareMaxClinics).toList(),
        rangeLabel: enriched.rangeLabel.isNotEmpty
            ? enriched.rangeLabel
            : shown.rangeLabel,
      ),
    );
  }

  List<OpenAIClinic> _pricedExploreClinics(
    List<OpenAIClinic> clinics, {
    String? procedure,
  }) {
    return clinics
        .where(
          (c) =>
              c.hasProcedure &&
              c.priceMin > 0 &&
              !c.pricePending &&
              exploreClinicFitsCompareProcedure(c, procedure ?? '') &&
              explorePriceIsVerified(c) &&
              isJustifiedProcedurePrice(c, procedure: procedure),
        )
        .toList(growable: false);
  }

  void _rememberExploreShown({
    required String city,
    required String categoryPill,
    required List<OpenAIClinic> clinics,
  }) {
    final pill = categoryPill.trim();
    if (pill.isEmpty || pill == 'All') return;
    final cityKey = city.trim().toLowerCase();
    if (cityKey.isEmpty) return;
    _exploreShownByCityPill.putIfAbsent(cityKey, () => {});
    _exploreShownByCityPill[cityKey]![pill] = List<OpenAIClinic>.of(clinics);
    unawaited(
      SessionPrefs.setExploreLastShownKeys(
        city: city,
        pill: pill,
        keys: [for (final c in clinics) ...exploreClinicIdentityKeys(c)],
      ),
    );
  }

  /// Clinics shown (or recently cached) on OTHER Compare pills.
  ///
  /// Returned identity keys are a **soft UI rotation preference** only
  /// (`crossPillRotationAvoidKeys`). They must never be mixed into Places,
  /// SERP, stored-candidate, website, or backend discovery exclusion.
  Future<
    ({Set<String> keys, List<String> names, Map<String, String> familyByKey})
  >
  _siblingExploreClinics({
    required String city,
    required String categoryPill,
    bool loadRemote = true,
  }) async {
    final keys = <String>{};
    final names = <String>[];
    final familyByKey = <String, String>{};

    void addClinic(OpenAIClinic c, String pill) {
      final idKeys = exploreClinicIdentityKeys(c);
      if (idKeys.isEmpty) return;
      var added = false;
      for (final key in idKeys) {
        if (key.isEmpty) continue;
        if (keys.add(key)) added = true;
      }
      final family = exploreCanonicalProcedureFamilyKey(
        explorePillAiSearchQuery(pill),
      );
      if (family.isNotEmpty) {
        for (final key in idKeys) {
          if (key.isEmpty) continue;
          familyByKey[key] = family;
        }
      }
      if (!added) return;
      final n = c.name.trim();
      if (n.isNotEmpty) names.add(n);
    }

    final cityKey = city.trim().toLowerCase();
    final shown = _exploreShownByCityPill[cityKey];
    if (shown != null) {
      for (final entry in shown.entries) {
        if (entry.key == categoryPill) continue;
        for (final c in entry.value) {
          addClinic(c, entry.key);
        }
      }
    }

    final otherPills = kExploreComparePills
        .where((p) => p != categoryPill)
        .toList();
    if (!loadRemote || otherPills.isEmpty) {
      return (keys: keys, names: names, familyByKey: familyByKey);
    }

    try {
      final rows = await Future.wait([
        for (final pill in otherPills)
          ExploreGooglePriceStore.instance.load(
            city: city,
            procedure: explorePillAiSearchQuery(pill),
          ),
      ]);
      for (var i = 0; i < rows.length; i++) {
        final pill = otherPills[i];
        final clinics = _clinicsFromGooglePriceJson(
          rows[i],
        ).where((c) => c.hasProcedure && c.priceMin > 0).toList();
        final visible = sortClinicsByGoogleMapsPopularity(
          clinics,
        ).take(kExploreCompareMaxClinics);
        for (final c in visible) {
          addClinic(c, pill);
        }
      }
    } catch (e) {
      debugPrint('[GP] Sibling clinic load error: $e');
    }

    return (keys: keys, names: names, familyByKey: familyByKey);
  }

  List<OpenAIClinic> _accumulateExploreComparisonPool({
    required List<OpenAIClinic> existing,
    required List<OpenAIClinic> added,
  }) {
    final byKey = <String, OpenAIClinic>{};
    void put(OpenAIClinic c, {required bool requireVerified}) {
      if (!c.hasProcedure || c.priceMin <= 0 || c.pricePending) return;
      if (requireVerified && !explorePriceIsVerified(c)) return;
      final key = exploreClinicDedupKey(c);
      if (key.isEmpty) return;
      byKey[key] = c;
    }

    for (final c in existing) {
      put(c, requireVerified: false);
    }
    for (final c in added) {
      put(c, requireVerified: true);
    }
    final addedKeys = <String>{for (final c in added) exploreClinicDedupKey(c)}
      ..removeWhere((k) => k.isEmpty);
    final pool = byKey.values.toList();
    if (pool.length <= kExploreFirestorePoolMax) {
      pool.sort(compareClinicsByGoogleMapsPopularity);
      return pool;
    }
    // Keep newly discovered clinics even if they have fewer reviews, so
    // the next visit can shuffle them into the cached 3 instead of always
    // keeping the same popular 30.
    final keepNew = <OpenAIClinic>[];
    final rest = <OpenAIClinic>[];
    for (final c in pool) {
      if (addedKeys.contains(exploreClinicDedupKey(c))) {
        keepNew.add(c);
      } else {
        rest.add(c);
      }
    }
    rest.sort(compareClinicsByGoogleMapsPopularity);
    final room = math.max(0, kExploreFirestorePoolMax - keepNew.length);
    final out = [...keepNew, ...rest.take(room)];
    out.sort(compareClinicsByGoogleMapsPopularity);
    return out;
  }

  Future<OpenAIComparisonResult> _fetchExploreComparisonFromAi({
    required String queryOrSelection,
    required String city,
    required String categoryPill,
    required int targetCount,
    required List<String> excludeNames,
    List<String> rejectedUnpricedNames = const [],
    int refillPass = 0,
    String? extraGoogleQuery,
    List<OpenAIClinic> knownPriced = const [],
    bool prioritizeSearch = false,
    void Function(OpenAIClinic clinic)? onClinicDone,
  }) async {
    final pill = categoryPill.trim();
    final brandExamples = exploreCategoryBrandExamples(pill);
    final excludeNote = excludeNames.isEmpty
        ? ''
        : 'Do not extract these clinics again (already saved or on screen): '
              '${excludeNames.join(", ")}.\n'
              'Find $targetCount OTHER clinics in $city with a published '
              'price for this treatment — not the names above.\n';
    final rejectedNote = rejectedUnpricedNames.isEmpty
        ? ''
        : 'These names had no published number — skip them: '
              '${rejectedUnpricedNames.join(", ")}.\n';
    final refillNote = refillPass >= 1
        ? 'REFILL: open more clinic price-list pages. Search English "prices" '
              'AND the local price word for this city. Extract a starting price '
              'from each page.\n'
        : '';
    final queryLower = queryOrSelection.toLowerCase();
    final topic = exploreProcedurePriceTopic(queryOrSelection, pill);
    final rhinoplastyNote =
        pill == 'Rhinoplasty' ||
            queryLower.contains('rhinoplasty') ||
            queryLower.contains('nose job') ||
            queryLower.contains('rinoplastica') ||
            queryLower.contains('chirurgia naso')
        ? '\n- For rhinoplasty, extract the surgery starting price from the '
              'page (typically thousands), not a consultation fee.\n'
        : '';
    final localized = await buildLocalizedComparisonQueries(
      procedure: queryOrSelection,
      city: city,
      pill: pill,
    );
    final googleQueries = <String>[];
    void addQuery(String raw) {
      final q = raw.trim();
      if (q.isEmpty) return;
      if (googleQueries.any((e) => e.toLowerCase() == q.toLowerCase())) {
        return;
      }
      googleQueries.add(q);
    }

    for (final q in localized.take(4)) {
      addQuery(q);
    }
    if (extraGoogleQuery != null) addQuery(extraGoogleQuery);
    debugPrint(
      '[GP] Comparison Google queries ($city · $queryOrSelection): '
      '${googleQueries.join(" · ")}',
    );
    final priceLocale = exploreCityPriceSearchTerms(
      city,
      countryCode: _countryCodeForCity(city),
    );
    final localSearchNames = exploreProcedureNamesForLang(
      exploreTreatmentFamily(queryOrSelection).name,
      priceLocale.lang,
    );
    final hairNote = pill == 'Hair' || isHairExploreProcedure(queryOrSelection)
        ? '\n- For hair transplant, extract per-graft OR package starting '
              'price, whichever the page publishes.\n'
        : '';
    final systemPrompt =
        'Find pages relevant to $topic prices in $city and extract structured facts.\n'
        'You are a page reader, not a clinic directory. Do not ask whether a '
        'clinic "exists". Open Google results and clinic price pages, then '
        'copy facts that are already written there.\n\n'
        '══ SEARCH ══\n'
        'Search at most the queries below (do not invent extra searches). '
        'Do not stop early if you have only 1–3 clinics — keep going through '
        'the listed queries until you have $targetCount clinics with a '
        'published starting price, or the queries are exhausted. '
        'Always include English "prices" and the local '
        'price word for this city when both are listed.\n'
        '${googleQueries.map((q) => '  • $q').join('\n')}\n\n'
        'Prefer organic pages whose title or body already shows a number + '
        'currency (lei, RON, €, £, AED, \$).\n\n'
        '══ EXTRACT FROM EACH PAGE ══\n'
        '- clinic name as written\n'
        '- starting price + currency as written (lei, RON, €, £, AED, \$).\n'
        '- treatment line as written (brand) — no price or currency in this field\n'
        '- page URL (source_url)\n'
        '- city/area if shown\n'
        '- Google Maps rating and review count when they appear '
        '(do not invent; use 0 if not shown)\n\n'
        '══ COPY RULES ══\n'
        '- Do not invent clinics, prices, or currencies.\n'
        '- price_min = the STARTING published price (1 zone / de la / from).\n'
        '- currency = the symbol/word next to that number. NEVER write € for a lei price.\n'
        '- NEVER convert currencies.\n'
        '- price_label MUST use RON when the source is lei.\n'
        '- has_procedure=true when the page is about this treatment.\n'
        '- brand: treatment/product name only — NEVER a "| <price>" suffix.\n'
        '- rating/reviews: copy Google Maps stars + review count when shown; else 0.\n'
        '$rhinoplastyNote'
        '$hairNote'
        '- Return up to $targetCount clinics. If you found fewer, still '
        'return every verified one.\n\n'
        '══ OUTPUT ══\n'
        'Return ONLY valid JSON:\n'
        '{"city":string,"topic":string,"topic_type":"procedure",'
        '"currency":string,"range_label":string,'
        '"map_center":{"lat":number,"lng":number},'
        '"clinics":[{"rank":number,"name":string,"area":string,'
        '"distance_mi":number,"rating":number,"reviews":number,'
        '"price_min":number,"price_max":number,"price_label":string,'
        '"currency":string,"price_gbp":number,"brand":string,'
        '"badge":string,"badge_variant":"best"|"mid"|"hi",'
        '"has_procedure":boolean,"source_url":string,'
        '"snippet":string,"lat":number,"lng":number}]}';

    final userMsg =
        'Find pages relevant to $topic prices in $city and extract structured facts.\n\n'
        '$excludeNote'
        '$rejectedNote'
        '$refillNote'
        'Local language: ${priceLocale.lang}. '
        'You MUST search both English "price/prices" AND these local words: '
        '${priceLocale.priceWords.join(", ")}. '
        'Local treatment names: ${localSearchNames.isEmpty ? topic : localSearchNames.join(", ")}.\n'
        '${pill.isNotEmpty && pill != 'All' ? 'Treatment name examples: $brandExamples.\n' : ''}'
        'Copy lei as RON. Copy the treatment name into brand — never the price.';

    final json = await _queueSearchPreview(
      () => _chatCompletionSearchPreviewJson(
        messages: [
          {'role': 'system', 'content': systemPrompt},
          {'role': 'user', 'content': userMsg},
        ],
        maxTokens: 2200,
      ),
      priority: prioritizeSearch,
    );

    try {
      final parsed = _decodeAiComparisonJson(json);
      final result = OpenAIComparisonResult.fromJson(
        parsed.cast<String, Object?>(),
      );
      final knownKeys = <String>{
        for (final c in knownPriced) ...exploreClinicIdentityKeys(c),
      }..removeWhere((k) => k.isEmpty);
      OpenAIClinic reuseIfKnown(OpenAIClinic c) {
        if (!exploreClinicHitsKeys(c, knownKeys)) return c;
        for (final p in knownPriced) {
          if (exploreClinicHitsKeys(c, exploreClinicIdentityKeys(p)) &&
              p.priceMin > 0 &&
              p.hasProcedure) {
            return p;
          }
        }
        return c;
      }

      final reused = [for (final c in result.clinics) reuseIfKnown(c)];
      for (final c in reused) {
        if (onClinicDone == null) continue;
        if (c.priceMin > 0 &&
            c.hasProcedure &&
            !c.pricePending &&
            exploreClinicHitsKeys(c, knownKeys)) {
          onClinicDone(c);
        }
      }
      final confirmed = await _enrichClinicsWithDirectPriceFetch(
        clinics: reused,
        procedure: queryOrSelection,
        city: city,
        requireWebsiteConfirm: true,
        skipWebsiteConfirmKeys: knownKeys,
        onClinicDone: onClinicDone,
      );
      // Keep unpriced / !hasProcedure rows so fetchFresh can add those
      // clinic names to the rejected list and not ask GPT for them again.
      return result.copyWith(clinics: confirmed);
    } catch (e) {
      debugPrint('[GP] Comparison AI JSON parse failed: $e');
      return OpenAIComparisonResult(
        city: city,
        topic: queryOrSelection,
        topicType: OpenAISearchItemType.procedure,
        summary: '',
        rangeLabel: '',
        mapCenter: const OpenAICoord(0, 0),
        clinics: const [],
      );
    }
  }

  /// Keeps clinics with enough Google-style review volume when possible.
  List<OpenAIClinic> _filterClinicsByMinReviews(
    List<OpenAIClinic> clinics, {
    int minKeep = 4,
  }) {
    if (clinics.isEmpty) return clinics;
    for (final threshold in [50, 30, 15, 5, 0]) {
      final filtered = clinics
          .where((c) => c.reviews >= threshold)
          .toList(growable: false);
      if (filtered.length >= minKeep) return filtered;
    }
    return clinics;
  }

  bool _placesHitLooksLikeClinic(
    GooglePlacesSearchHit hit, {
    required bool hairProcedure,
  }) {
    if (placesNameLooksLikeMedicalClinic(hit.name)) return true;
    if (looksLikeNonAestheticVenueName(hit.name)) return false;
    final types = {for (final t in hit.types) t.toLowerCase()};
    const reject = {
      'nail_salon',
      'barber_shop',
      'meal_takeaway',
      'restaurant',
      'cafe',
      'bar',
      'gym',
      'clothing_store',
      'supermarket',
      'lodging',
      'travel_agency',
      'real_estate_agency',
    };
    // Dubai med-spas are often typed hair_care because they also do laser
    // hair removal. The name already said clinic / cosmetic / botox.
    if (!hairProcedure &&
        types.contains('hair_care') &&
        !placesNameLooksLikeMedicalClinic(hit.name)) {
      return false;
    }
    final hasClinicType =
        types.contains('doctor') ||
        types.contains('spa') ||
        types.contains('beauty_salon') ||
        types.contains('health') ||
        types.contains('hospital') ||
        types.contains('physiotherapist');
    if (types.any(reject.contains) && !hasClinicType) return false;
    return true;
  }

  OpenAIClinic _clinicStubFromPlaceResult(
    GooglePlacesResult place, {
    required String city,
  }) {
    final host = _stripWww(_normalizeProbeHost(place.website));
    final district = place.area.trim().isNotEmpty
        ? place.area.trim()
        : city.trim();
    final area = host.isEmpty ? district : '$district · $host';
    return OpenAIClinic(
      rank: 0,
      name: place.name,
      area: _withSourceUrl(area, place.website),
      distanceMi: 0,
      rating: place.rating,
      reviews: place.reviewsTotal,
      priceGbp: 0,
      priceMin: 0,
      priceMax: 0,
      priceLabel: '',
      currency: '',
      currencyConfirmed: false,
      brand: '',
      badge: '',
      badgeVariant: 'mid',
      coord: OpenAICoord(place.lat, place.lng),
      hasProcedure: true,
      pricePending: true,
      placeId: place.placeId,
    );
  }

  OpenAIClinic? _matchExploreClinicByHost(
    List<OpenAIClinic> clinics,
    String urlOrHost,
  ) {
    final host = _stripWww(_normalizeProbeHost(urlOrHost));
    if (host.isEmpty) return null;
    for (final c in clinics) {
      final ch = _stripWww(_normalizeProbeHost(_extractDomain(c.area)));
      if (ch.isEmpty) continue;
      if (_hostsSameDomainOrSubdomain(host, ch) ||
          _hostsSameDomainOrSubdomain(ch, host)) {
        return c;
      }
    }
    return null;
  }

  OpenAIClinic? _matchExploreClinicByKeys(
    List<OpenAIClinic> clinics,
    OpenAIClinic candidate,
  ) {
    final keys = exploreClinicIdentityKeys(candidate);
    if (keys.isEmpty) return null;
    for (final c in clinics) {
      if (exploreClinicHitsKeys(c, keys)) return c;
    }
    return null;
  }

  String _clinicNameFromHost(String host) => exploreClinicBrandFromHost(host);

  /// Names Google Maps is likely to resolve. [lookupClinic] already appends
  /// the city — do not include it here.
  List<String> _placesClinicLookupQueries(OpenAIClinic clinic) {
    final aiHost = _normalizeProbeHost(_extractDomain(clinic.area));
    final hostBrand = _clinicNameFromHost(aiHost);
    final out = <String>[];
    void add(String raw) {
      final t = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
      if (t.length < 3) return;
      final key = t.toLowerCase();
      if (out.any((e) => e.toLowerCase() == key)) return;
      out.add(t);
    }

    if (aiHost.isNotEmpty && !isMarketplaceOrDirectoryHost(aiHost)) add(aiHost);
    if (!isMarketplaceOrDirectoryHost(aiHost)) add(hostBrand);
    add(_splitPackedClinicBrand(clinic.name));
    if (!_serpTitleLooksLikeSeoHeadline(clinic.name)) add(clinic.name);
    add(_normalizeClinicNameForPlaces(_splitPackedClinicBrand(clinic.name)));
    return out;
  }

  bool _serpTitleLooksLikeSeoHeadline(String title) =>
      exploreClinicNameLooksLikeSeoHeadline(title);

  String _clinicNameFromSerpTitle(String title, String host) =>
      exploreClinicNameFromSerpTitle(title, host);

  /// Silent pool growth when the verified set is 20–24. Never paints cards
  /// or toggles Compare loading — only persists one new exact-verified clinic.
  Future<void> _backgroundGrowVerifiedPool({
    required String cacheKey,
    required String city,
    required String procedure,
    required String categoryPill,
    required Set<String> excludeKeys,
    int maxAdd = 1,
  }) async {
    if (maxAdd <= 0) return;
    final current = [
      for (final c
          in _exploreComparisonPool[cacheKey] ?? const <OpenAIClinic>[])
        if (exploreClinicEligibleForVerifiedPool(
          c,
          procedure: procedure,
          city: city,
        ))
          c,
    ];
    if (current.length >= kExploreFirestorePoolSaturated) {
      debugPrint(
        '[GP] Background pool grow skip · already '
        '${current.length}/$kExploreFirestorePoolSaturated · $categoryPill · $city',
      );
      return;
    }
    debugPrint(
      '[GP] Background pool grow · want +$maxAdd · '
      'have ${current.length} · $categoryPill · $city',
    );
    try {
      final seen = <String>{...excludeKeys};
      for (final c in current) {
        seen.addAll(exploreClinicIdentityKeys(c));
      }
      seen.removeWhere((k) => k.isEmpty);
      final stubs = await _discoverPlacesClinicCandidates(
        procedure: procedure,
        city: city,
        pill: categoryPill,
        seenKeys: seen,
        maxCandidates: math.max(6, maxAdd * 4),
      );
      var candidateStubs = [
        for (final s in stubs)
          if (!exploreClinicHitsKeys(s, seen)) s,
      ];
      // Places daily quota (429) must not freeze pool growth — Serper city
      // discovery still finds clinic websites to scrape.
      if (candidateStubs.isEmpty) {
        debugPrint(
          '[GP] Background pool grow · Places empty · Serper fallback · '
          '$categoryPill · $city',
        );
        final serp = await _discoverSerpApiCityPricedClinics(
          procedure: procedure,
          city: city,
          pill: categoryPill,
          seenKeys: seen,
          maxClinics: math.max(6, maxAdd * 4),
          resolvePlaces: false,
          timeout: _kSerpApiTimeout,
          maxQueries: 2,
          mode: ExploreRequestMode.background,
        );
        candidateStubs = [...serp];
        // Marketplace only if official Serper found nothing — never block
        // official stubs behind marketplace resolution.
        if (candidateStubs.isEmpty) {
          final market = await _discoverMarketplaceDirectoryLeads(
            procedure: procedure,
            city: city,
            pill: categoryPill,
            seenKeys: seen,
            maxClinics: 4,
            timeout: _kSerpApiTimeout,
            mode: ExploreRequestMode.background,
          );
          candidateStubs = [...market];
        }
      }
      final fresh = candidateStubs.take(maxAdd * 3).toList();
      if (fresh.isEmpty) {
        debugPrint('[GP] Background pool grow · no new clinic stubs');
        return;
      }
      final verified = await _enrichClinicsWithDirectPriceFetch(
        clinics: fresh,
        procedure: procedure,
        city: city,
        requireWebsiteConfirm: true,
        repriceExisting: true,
        stopIf: () => false,
      );
      final added = <OpenAIClinic>[];
      for (final c in verified) {
        if (added.length >= maxAdd) break;
        if (!exploreClinicEligibleForVerifiedPool(
          c,
          procedure: procedure,
          city: city,
        )) {
          continue;
        }
        if (exploreClinicHitsKeys(c, seen)) continue;
        added.add(c);
        seen.addAll(exploreClinicIdentityKeys(c));
      }
      if (added.isEmpty) {
        debugPrint('[GP] Background pool grow · 0 exact-verified');
        return;
      }
      final merged = mergeExploreClinicIdentities(
        _accumulateExploreComparisonPool(existing: current, added: added),
      );
      final priced = [
        for (final c in merged)
          if (exploreClinicEligibleForVerifiedPool(
            c,
            procedure: procedure,
            city: city,
          ))
            c,
      ];
      _exploreComparisonPool[cacheKey] = priced;
      _queueExplorePersist(
        cacheKey: cacheKey,
        city: city,
        procedure: procedure,
        metaSource: OpenAIComparisonResult(
          city: city,
          topic: procedure,
          topicType: OpenAISearchItemType.procedure,
          summary: '',
          rangeLabel: '',
          mapCenter: priced.isNotEmpty
              ? priced.first.coord
              : const OpenAICoord(0, 0),
          clinics: const [],
        ),
        priced: priced,
        reason: 'background pool grow +${added.length}',
        flushNow: true,
      );
      debugPrint(
        '[GP] Background pool grow · +${added.length} · '
        'pool ${priced.length} · $categoryPill · $city',
      );
    } catch (e) {
      debugPrint('[GP] Background pool grow error: $e');
    }
  }

  /// Extra Google Places candidates when Compare is still under 4 verified
  /// clinics. Identity only — procedure + price still need website proof.
  Future<List<OpenAIClinic>> _discoverPlacesClinicCandidates({
    required String procedure,
    required String city,
    required String pill,
    required Set<String> seenKeys,
    int maxCandidates = 8,
    String? translatedFallback,
    List<String>? queriesOverride,
    Set<String> skipPlaceIds = const {},
    DateTime? lookupDeadline,
    Map<String, String> siblingFamilyByKey = const {},
  }) async {
    if (!_places.isConfigured) return const [];
    final queries =
        queriesOverride ??
        exploreBilingualPlacesPair(
          procedure: procedure,
          city: city,
          pill: pill,
          countryCode: _countryCodeForCity(city),
        );
    if (queries.isEmpty) return const [];
    debugPrint(
      '[GP] Places candidate search ($city · $procedure): '
      '${queries.join(" · ")}',
    );
    final hair = isHairExploreProcedure(procedure);
    final hits = <GooglePlacesSearchHit>[];
    final seenPlace = <String>{...skipPlaceIds};
    final loggedKnownSkip = <String>{};
    for (final q in queries) {
      final rows = await _places.searchText(
        query: q,
        city: city,
        maxResults: 8,
      );
      for (final hit in rows) {
        if (!seenPlace.add(hit.placeId)) {
          // Second query, or already in the pool / previously rejected.
          // Not a quality reject — do not log as DISCOVERY reject.
          if (skipPlaceIds.contains(hit.placeId) &&
              loggedKnownSkip.add(hit.placeId)) {
            logExploreDiscoverySkip(
              reason: 'current_procedure_already_seen',
              placeId: hit.placeId,
              name: hit.name,
              procedure: procedure,
            );
          }
          continue;
        }
        final identityReason = clinicIdentityRejectReason(hit.name);
        if (identityReason != null) {
          logExploreDiscoveryReject(
            reason: identityReason,
            placeId: hit.placeId,
            name: hit.name,
          );
          continue;
        }
        if (!_placesHitLooksLikeClinic(hit, hairProcedure: hair)) {
          logExploreDiscoveryReject(
            reason: 'wrong_business_type',
            placeId: hit.placeId,
            name: hit.name,
          );
          continue;
        }
        final nameKey = exploreClinicNameDedupKey(hit.name);
        if (nameKey.isNotEmpty && seenKeys.contains(nameKey)) {
          logExploreDiscoverySkip(
            reason: 'current_procedure_already_seen',
            placeId: hit.placeId,
            name: hit.name,
            procedure: procedure,
          );
          continue;
        }
        final siblingFam = siblingFamilyByKey[nameKey];
        if (siblingFam != null && siblingFam.isNotEmpty) {
          final verifying = exploreCanonicalProcedureFamilyKey(procedure);
          if (verifying.isNotEmpty && siblingFam != verifying) {
            logExploreMultiProcedureReuse(
              name: hit.name,
              existingFamily: siblingFam,
              verifyingFamily: verifying,
            );
          }
        }
        hits.add(hit);
      }
    }
    hits.sort(
      (a, b) => _placesSearchHitPriorityScore(
        b,
        procedure,
      ).compareTo(_placesSearchHitPriorityScore(a, procedure)),
    );
    debugPrint('[GP] Places candidates: ${hits.length}');
    final stubs = <OpenAIClinic>[];
    for (final hit in hits) {
      if (stubs.length >= maxCandidates) break;
      if (lookupDeadline != null && DateTime.now().isAfter(lookupDeadline)) {
        debugPrint('[GP] Places lookup deadline · ${stubs.length} stubs kept');
        break;
      }
      final details = await _places.lookupPlaceId(
        placeId: hit.placeId,
        city: city,
      );
      if (details == null) continue;
      if (!_looksLikeAestheticMedicalBusiness(
        clinicName: details.name,
        place: details,
        hairProcedure: hair,
      )) {
        logExploreDiscoveryReject(
          reason: 'wrong_business_type',
          placeId: hit.placeId,
          name: details.name,
        );
        continue;
      }
      final website = details.website.trim();
      if (website.isEmpty) continue;
      final host = _stripWww(_normalizeProbeHost(website));
      if (host.isEmpty || _denylistedWebsiteHost(host)) continue;
      if (!exploreHostFitsSearchCity(host, city)) {
        debugPrint('[GP] Skip foreign-market Places host: $host · $city');
        continue;
      }
      if (isMarketplaceOrDirectoryHost(host)) {
        logExploreDiscoveryReject(
          reason: 'marketplace_without_provider',
          placeId: hit.placeId,
          name: details.name,
        );
        continue;
      }
      if (exploreUrlConflictsWithSearchCity(website, city)) {
        debugPrint('[GP] Skip other-city Places website: $website · $city');
        continue;
      }
      final placeAddress = details.address.trim().isNotEmpty
          ? details.address
          : hit.address;
      if (explorePlacesAddressConflictsWithSearchCity(placeAddress, city)) {
        debugPrint(
          '[GP] Skip other-city Places listing: ${details.name} · '
          '$placeAddress · $city',
        );
        continue;
      }
      final stub = _clinicStubFromPlaceResult(details, city: city);
      if (exploreClinicHitsKeys(stub, seenKeys)) {
        logExploreDiscoverySkip(
          reason: 'current_procedure_already_seen',
          name: stub.name,
          procedure: procedure,
          placeId: stub.placeId,
        );
        continue;
      }
      maybeLogExploreMultiProcedureReuse(
        clinic: stub,
        procedure: procedure,
        siblingFamilyByKey: siblingFamilyByKey,
        currentProcedureExclusionKeys: seenKeys,
      );
      stubs.add(stub);
    }
    stubs.sort((a, b) {
      final sb = _placesCandidatePriorityScore(b, procedure: procedure);
      final sa = _placesCandidatePriorityScore(a, procedure: procedure);
      return sb.compareTo(sa);
    });
    debugPrint('[GP] Places candidates with website: ${stubs.length}');
    return stubs;
  }

  /// One Google search for "{procedure} prices in {city}" — finds clinics
  /// that actually publish a number. Host-matches the Firestore pool so a
  /// pool clinic C can fill a Google slot. Places lookup is optional.
  Future<List<OpenAIClinic>> _discoverSerpApiCityPricedClinics({
    required String procedure,
    required String city,
    required String pill,
    required Set<String> seenKeys,
    int maxClinics = 2,
    List<OpenAIClinic> poolForHostMatch = const [],
    bool resolvePlaces = true,
    Duration? timeout,
    int maxQueries = 2,
    Map<String, String> siblingFamilyByKey = const {},
    ExploreRequestMode mode = ExploreRequestMode.foreground,
    bool allPreview = false,
    bool uiDeadlinePassed = false,
    List<String>? queriesOverride,
  }) async {
    if (!_webDiscoveryConfigured()) return const [];
    if (resolvePlaces && !_places.isConfigured) return const [];
    final queries = (queriesOverride != null && queriesOverride.isNotEmpty)
        ? queriesOverride.take(maxQueries < 1 ? 1 : maxQueries).toList()
        : exploreBilingualSearchPair(
            procedure: procedure,
            city: city,
            pill: pill,
            maxPair: maxQueries,
            countryCode: _countryCodeForCity(city),
          );
    if (queries.isEmpty) return const [];
    debugPrint('[GP] Discovery city query: ${queries.join(' · ')}');
    final wait = timeout ?? _kSerpApiTimeout;
    final results = await _searchSerpApiBilingual(
      queries: queries,
      city: city,
      timeout: wait,
      mode: mode,
      procedureKey: procedure,
      allPreview: allPreview,
      uiDeadlinePassed: uiDeadlinePassed,
    );
    if (results.isEmpty) {
      debugPrint('[GP] Discovery city search empty');
      return const [];
    }
    debugPrint('[GP] Discovery city results: ${results.length}');
    final rankedHits =
        [for (var i = 0; i < results.length; i++) (r: results[i], i: i)]
          ..sort((a, b) {
            final d =
                _serpCityDiscoveryScore(b.r, procedure: procedure, city: city) -
                _serpCityDiscoveryScore(a.r, procedure: procedure, city: city);
            if (d != 0) return d;
            return a.i.compareTo(b.i);
          });
    final localSeen = {...seenKeys};
    final stubs = <OpenAIClinic>[];
    final topic = exploreProcedurePriceTopic(procedure, pill);
    for (final hit in rankedHits) {
      final r = hit.r;
      if (stubs.length >= maxClinics) break;
      if (_serpApiUrlIsJunk(r.link, procedure)) continue;
      var pageUrl = r.link.trim();
      if (isNonLiteralClinicPriceUrl(pageUrl)) {
        debugPrint('[GP] Discovery skip blog/guide URL: $pageUrl');
        continue;
      }
      final host = _stripWww(_normalizeProbeHost(pageUrl));
      if (host.isEmpty ||
          _isGenericSocialOrDirectoryHost(host) ||
          _denylistedWebsiteHost(host) ||
          _isSessionBlockedHost(host)) {
        continue;
      }
      if (exploreUrlConflictsWithSearchCity(pageUrl, city)) {
        debugPrint('[GP] Skip other-city URL: $pageUrl · $city');
        continue;
      }
      if (!exploreListingFitsSearchCity(
        city: city,
        host: host,
        currency: '',
        procedureText: '${r.title} ${r.snippet}',
      )) {
        debugPrint('[GP] Skip foreign-market host: $host · $city');
        continue;
      }
      const directories = {
        'realself.com',
        'groupon.com',
        'yelp.com',
        'newbeauty.com',
        'whatclinic.com',
        'bookimed.com',
        'mediglobus.com',
        'zwivel.com',
        'booksy.com',
        'studio24.bg',
        'fresha.com',
        'healthline.com',
        'webmd.com',
      };
      if (directories.any((d) => host == d || host.endsWith('.$d'))) {
        continue;
      }
      if (isMarketplaceOrDirectoryHost(host)) {
        continue;
      }
      // Do not require the snippet to quote 499 / 1,500 / etc. Google is
      // only a clinic+page pointer; the card amount comes from HTML.
      if (!_serpResultLooksLikeClinicSite(r, procedure: procedure)) {
        continue;
      }
      if (exploreTextConflictsWithSearchCity('${r.title} ${r.snippet}', city)) {
        debugPrint('[GP] Skip other-city snippet: ${r.title} · $city');
        continue;
      }
      const amount = 0.0;
      const currency = '';
      const label = '';

      final pooled = _matchExploreClinicByHost(poolForHostMatch, pageUrl);
      if (pooled != null) {
        if (exploreClinicHitsKeys(pooled, localSeen)) {
          logExploreDiscoverySkip(
            reason: 'current_procedure_already_seen',
            name: pooled.name,
            procedure: procedure,
            placeId: pooled.placeId,
          );
          continue;
        }
        // Already a verified *showable* card in the pool — spend the slot
        // on a new name. Wrong-family or help-number 999 must re-verify.
        if (exploreDiscoveryShouldSkipPoolVerified(
          pooled,
          procedure: procedure,
          city: city,
        )) {
          logExploreDiscoverySkip(
            reason: 'current_procedure_already_seen',
            name: pooled.name,
            procedure: procedure,
            placeId: pooled.placeId,
          );
          continue;
        }
        maybeLogExploreMultiProcedureReuse(
          clinic: pooled,
          procedure: procedure,
          siblingFamilyByKey: siblingFamilyByKey,
          currentProcedureExclusionKeys: localSeen,
        );
        final priced = pooled.copyWith(
          hasProcedure: true,
          pricePending: true,
          priceSourceUrl: pageUrl.isNotEmpty ? pageUrl : pooled.priceSourceUrl,
          priceVerificationStatus: PriceVerificationStatus.unverified,
        );
        final withSrc = priced.copyWith(
          area: _withSourceUrl(priced.area, pageUrl),
          priceSourceUrl: pageUrl,
          hasProcedure: true,
          pricePending: true,
          priceVerificationStatus: PriceVerificationStatus.unverified,
        );
        debugPrint(
          '[GP] Discovery hit: ${withSrc.name} · verify page · '
          '${r.link} (pool host match)',
        );
        stubs.add(withSrc);
        localSeen.addAll(exploreClinicIdentityKeys(withSrc));
        continue;
      }

      OpenAIClinic? withSrc;
      if (resolvePlaces && _places.isConfigured) {
        final brand = host.split('.').first.replaceAll(RegExp(r'[-_]+'), ' ');
        if (brand.trim().length < 3) continue;
        final hits = await _places.searchText(
          query: '$brand $city',
          city: city,
          maxResults: 5,
        );
        GooglePlacesResult? details;
        for (final hit in hits) {
          final d = await _places.lookupPlaceId(
            placeId: hit.placeId,
            city: city,
          );
          if (d == null || d.website.trim().isEmpty) continue;
          if (!_hostsSameDomainOrSubdomain(d.website, host) &&
              !_hostsSameDomainOrSubdomain(pageUrl, d.website)) {
            continue;
          }
          if (!_looksLikeAestheticMedicalBusiness(
            clinicName: d.name,
            place: d,
          )) {
            continue;
          }
          details = d;
          break;
        }
        if (details != null) {
          final stub = _clinicStubFromPlaceResult(details, city: city);
          if (exploreClinicHitsKeys(stub, localSeen)) continue;
          withSrc = stub.copyWith(
            area: _withSourceUrl(stub.area, pageUrl),
            priceGbp: amount.round(),
            priceMin: amount,
            priceMax: amount,
            priceLabel: label,
            currency: currency,
            currencyConfirmed: false,
            brand: topic,
            hasProcedure: true,
            pricePending: true,
            priceSourceUrl: pageUrl,
            priceVerificationStatus: PriceVerificationStatus.unverified,
            discoveredAt: DateTime.now().toUtc(),
          );
        }
      }

      withSrc ??= OpenAIClinic(
        rank: 0,
        name: resolveBroadSerpClinicCandidateName(r.title, host),
        area: _withSourceUrl(host, pageUrl),
        distanceMi: 0,
        rating: 0,
        reviews: 0,
        priceGbp: amount.round(),
        priceMin: amount,
        priceMax: amount,
        priceLabel: label,
        currency: currency,
        currencyConfirmed: false,
        brand: topic,
        badge: '',
        badgeVariant: 'mid',
        coord: const OpenAICoord(0, 0),
        hasProcedure: true,
        pricePending: true,
        priceSourceUrl: pageUrl,
        priceVerificationStatus: PriceVerificationStatus.unverified,
        discoveredAt: DateTime.now().toUtc(),
      );
      if (exploreClinicHitsKeys(withSrc, localSeen)) {
        logExploreDiscoverySkip(
          reason: 'current_procedure_already_seen',
          name: withSrc.name,
          procedure: procedure,
          placeId: withSrc.placeId,
        );
        continue;
      }
      maybeLogExploreMultiProcedureReuse(
        clinic: withSrc,
        procedure: procedure,
        siblingFamilyByKey: siblingFamilyByKey,
        currentProcedureExclusionKeys: localSeen,
      );
      if (isInvalidClinicIdentity(withSrc.name) ||
          exploreClinicNameLooksLikeSeoHeadline(withSrc.name)) {
        final hostName = _clinicNameFromHost(host);
        if (hostName.isNotEmpty && !isInvalidClinicIdentity(hostName)) {
          withSrc = withSrc.copyWith(name: hostName);
        }
      }
      if (isInvalidClinicIdentity(withSrc.name)) {
        debugPrint('[GP IDENTITY] REJECT "${withSrc.name}"');
        continue;
      }
      debugPrint(
        '[GP] Discovery hit: ${withSrc.name} · verify page · $pageUrl',
      );
      stubs.add(withSrc);
      localSeen.addAll(exploreClinicIdentityKeys(withSrc));
    }
    debugPrint('[GP] Discovery clinic candidates: ${stubs.length}');
    return stubs;
  }

  /// Second discovery pass: WhatClinic / Bookimed listings → real clinic sites.
  ///
  /// Marketplace hosts are never painted. Each hit must resolve to a clinic
  /// name + non-directory website before it enters website verify.
  Future<List<OpenAIClinic>> _discoverMarketplaceDirectoryLeads({
    required String procedure,
    required String city,
    required String pill,
    required Set<String> seenKeys,
    int maxClinics = 4,
    Duration? timeout,
    ExploreRequestMode mode = ExploreRequestMode.background,
    bool allPreview = false,
    bool uiDeadlinePassed = false,
  }) async {
    if (!_webDiscoveryConfigured()) return const [];
    final topic = exploreProcedurePriceTopic(procedure, pill);
    final queries = exploreMarketplaceDiscoveryQueries(
      procedure: procedure,
      city: city,
      pill: pill,
      topic: topic,
    );
    if (queries.isEmpty) return const [];
    debugPrint('[GP] Marketplace discovery query: ${queries.join(' · ')}');
    final wait = timeout ?? _kSerpApiTimeout;
    final results = await _searchSerpApiBilingual(
      queries: queries,
      city: city,
      timeout: wait,
      mode: mode,
      procedureKey: procedure,
      allPreview: allPreview,
      uiDeadlinePassed: uiDeadlinePassed,
    );
    if (results.isEmpty) {
      debugPrint('[GP] Marketplace discovery empty');
      return const [];
    }
    debugPrint('[GP] Marketplace discovery results: ${results.length}');
    final localSeen = {...seenKeys};
    final stubs = <OpenAIClinic>[];
    var marketplaceResolved = 0;
    for (final r in results) {
      if (stubs.length >= maxClinics) break;
      final pageUrl = r.link.trim();
      if (pageUrl.isEmpty || !exploreIsMarketplaceDiscoveryHost(pageUrl)) {
        continue;
      }
      final junkReason = exploreMarketplaceLeadRejectReason(
        title: r.title,
        snippet: r.snippet,
        url: pageUrl,
        city: city,
      );
      if (junkReason != null) {
        debugPrint('[GP] Marketplace lead reject · $junkReason · ${r.title}');
        continue;
      }
      if (exploreUrlConflictsWithSearchCity(pageUrl, city) ||
          exploreTextConflictsWithSearchCity('${r.title} ${r.snippet}', city)) {
        continue;
      }
      final clinicName = exploreClinicNameFromMarketplaceSerp(
        title: r.title,
        snippet: r.snippet,
        url: pageUrl,
        city: city,
      );
      if (clinicName.isEmpty ||
          isMarketplaceBrandName(clinicName) ||
          clinicIdentityRejectReason(clinicName) != null ||
          exploreMarketplaceLeadRejectReason(
                title: clinicName,
                snippet: '',
                url: pageUrl,
                city: city,
              ) !=
              null) {
        debugPrint(
          '[GP] Marketplace lead skip · no clinic identity · ${r.title}',
        );
        continue;
      }
      final bookableVenue = exploreIsBookingPlatformVenueUrl(pageUrl);
      String? website;
      if (bookableVenue) {
        // Fresha / Booksy menus publish bookable prices (JSON-LD). Scrape the
        // venue page directly — do not wait on an official-site resolve.
        website = exploreBookingPlatformVenueUrl(pageUrl);
        if (website.isEmpty) {
          website = pageUrl.contains('://') ? pageUrl : 'https://$pageUrl';
        }
      } else {
        website = await _resolveClinicWebsiteFromMarketplaceLead(
          clinicName: clinicName,
          city: city,
          timeout: wait,
          mode: mode,
          procedureKey: procedure,
          uiDeadlinePassed: uiDeadlinePassed,
        );
      }
      if (website == null || website.isEmpty) {
        debugPrint(
          '[GP] Marketplace lead skip · no clinic website · $clinicName',
        );
        continue;
      }
      marketplaceResolved++;
      final host = _stripWww(_normalizeProbeHost(website));
      if (host.isEmpty ||
          _denylistedWebsiteHost(host) ||
          _isGenericSocialOrDirectoryHost(host) ||
          _isSessionBlockedHost(host)) {
        debugPrint(
          '[GP] Marketplace lead reject junk host · $clinicName · $host',
        );
        continue;
      }
      // WhatClinic/Bookimed must resolve off-directory. Fresha/Booksy venues
      // are allowed as the scrape target.
      if (!bookableVenue &&
          (exploreIsMarketplaceDiscoveryHost(host) ||
              isMarketplaceOrDirectoryHost(host) ||
              exploreMarketplaceResolvedWebsiteIsJunk(website, city: city))) {
        debugPrint(
          '[GP] Marketplace lead reject marketplace/social host · '
          '$clinicName · $host',
        );
        continue;
      }
      final stub = OpenAIClinic(
        rank: 0,
        name: clinicName,
        area: _withSourceUrl('$city · $host', website),
        distanceMi: 0,
        rating: 0,
        reviews: 0,
        priceGbp: 0,
        priceMin: 0,
        priceMax: 0,
        priceLabel: '',
        currency: '',
        currencyConfirmed: false,
        brand: topic,
        badge: '',
        badgeVariant: 'mid',
        coord: const OpenAICoord(0, 0),
        hasProcedure: true,
        pricePending: true,
        priceSourceUrl: website,
        priceVerificationStatus: PriceVerificationStatus.unverified,
        discoveredAt: DateTime.now().toUtc(),
        sourceType: bookableVenue ? 'marketplace' : 'marketplace_lead',
        sourcePlatform: marketplacePlatformLabel(pageUrl),
        providerClinic: clinicName,
      );
      if (!isUsableExploreClinicIdentity(
        name: stub.name,
        websiteHost: website,
        providerClinic: clinicName,
        sourceType: bookableVenue ? 'marketplace' : 'marketplace_lead',
      )) {
        continue;
      }
      if (exploreClinicHitsKeys(stub, localSeen)) {
        logExploreDiscoverySkip(
          reason: 'current_procedure_already_seen',
          name: stub.name,
          procedure: procedure,
        );
        continue;
      }
      debugPrint(
        bookableVenue
            ? '[GP] Marketplace lead: ${stub.name} · verify venue menu · '
                  '$website'
            : '[GP] Marketplace lead: ${stub.name} · verify clinic site · '
                  '$website (from $pageUrl)',
      );
      stubs.add(stub);
      localSeen.addAll(exploreClinicIdentityKeys(stub));
    }
    debugPrint(
      '[GP] Marketplace clinic candidates: ${stubs.length} · '
      'resolved=$marketplaceResolved',
    );
    return stubs;
  }

  /// Resolve a directory listing to the clinic's own website via Serper.
  Future<String?> _resolveClinicWebsiteFromMarketplaceLead({
    required String clinicName,
    required String city,
    Duration? timeout,
    ExploreRequestMode mode = ExploreRequestMode.background,
    String procedureKey = '',
    bool uiDeadlinePassed = false,
  }) async {
    final q = exploreMarketplaceClinicWebsiteQuery(
      clinicName: clinicName,
      city: city,
    );
    if (q.isEmpty) return null;
    final wait = timeout ?? _kSerpApiTimeout;
    final results = await _searchSerpApi(
      q,
      timeout: wait,
      hl: 'en',
      gl: exploreGoogleGl(
        exploreCityPriceSearchTerms(
          city,
          countryCode: _countryCodeForCity(city),
        ).lang,
        city,
        countryCode: _countryCodeForCity(city),
      ),
      mode: mode,
      procedureKey: procedureKey.isNotEmpty ? procedureKey : clinicName,
      uiDeadlinePassed: uiDeadlinePassed,
    );
    for (final r in results) {
      final link = r.link.trim();
      if (link.isEmpty) continue;
      final host = _stripWww(_normalizeProbeHost(link));
      if (host.isEmpty) continue;
      if (exploreIsMarketplaceDiscoveryHost(host) ||
          isMarketplaceOrDirectoryHost(host) ||
          _denylistedWebsiteHost(host) ||
          _isGenericSocialOrDirectoryHost(host)) {
        continue;
      }
      if (isNonLiteralClinicPriceUrl(link)) continue;
      if (exploreUrlConflictsWithSearchCity(link, city)) continue;
      if (exploreMarketplaceResolvedWebsiteIsJunk(link, city: city)) continue;
      return link.contains('://') ? link : 'https://$link';
    }
    return null;
  }

  /// Prefer clinic price/procedure pages over SEO city-average blogs.
  /// Snippet amounts are a weak "this page lists prices" hint — never a
  /// required exact number such as 499 or 1,500.
  int _serpCityDiscoveryScore(
    _SerpSearchResult r, {
    required String procedure,
    String city = '',
  }) {
    var score = 0;
    if (isNonLiteralClinicPriceUrl(r.link)) score -= 80;
    if (looksLikeClinicArticlePriceUrl(r.link)) score -= 25;
    if (looksLikePriceMenuUrl(r.link) ||
        r.link.toLowerCase().contains('package') ||
        r.link.toLowerCase().contains('offer') ||
        RegExp(
          r'/(?:preturi|prețuri|tarife|prices|pricing)(?:/|$)',
          caseSensitive: false,
        ).hasMatch(r.link)) {
      score += 30;
    }
    if (_priceLinkScore(r.link) >= 3) score += 20;
    if (city.trim().isNotEmpty &&
        exploreUrlStronglyMatchesSearchCity(r.link, city)) {
      // Branch page for the searched city (e.g. /preturi/brasov/) — verify first.
      score += 55;
    }
    if (exploreSerpHitWorthFetching(
      url: r.link,
      title: r.title,
      snippet: r.snippet,
      procedure: procedure,
    )) {
      score += 40;
    }
    final titleFold = _foldExploreMatchText(r.title);
    final cityFold = foldExploreCityText(city);
    if (cityFold.isNotEmpty &&
        titleFold.contains(cityFold) &&
        !exploreClinicNameLooksLikeSeoHeadline(r.title) &&
        !isInvalidClinicIdentity(r.title)) {
      score += 20;
    }
    // Bare city / tariff / procedure titles are not clinic identities.
    if (exploreSerpTitleLooksLikeNonClinicIdentity(r.title, city: city)) {
      score -= 35;
    }
    if (exploreSerpProcedureMatchTokens(procedure).any(
      (t) => t.length >= 4 && titleFold.contains(_foldExploreMatchText(t)),
    )) {
      score += 25;
    }
    if (_pageHasPricedAmounts('${r.title} ${r.snippet}')) {
      score += 15;
    }
    if (isMarketplaceOrDirectoryHost(_stripWww(_normalizeProbeHost(r.link)))) {
      score -= 100;
    }
    return score;
  }

  /// Cheap ranking so verification hits likely public-price clinics first.
  int _placesSearchHitPriorityScore(
    GooglePlacesSearchHit hit,
    String procedure,
  ) {
    var score = 0;
    final name = hit.name;
    final lo = name.toLowerCase();
    if (placesNameLooksLikeMedicalClinic(name)) score += 18;
    if (RegExp(r'\bdr\.?\b', caseSensitive: false).hasMatch(name)) {
      score += 28;
    }
    if (name.length > 55) score -= 30;
    if (RegExp(r',').allMatches(name).length >= 2) score -= 25;
    if (exploreClinicNameLooksLikeSeoHeadline(name)) score -= 20;
    if (hit.rating >= 4.0) score += 6;
    if (hit.reviewsTotal >= 30) score += 8;
    final fam = exploreTreatmentFamily(procedure);
    if (fam == ExploreTreatmentFamily.breast &&
        name.length < 55 &&
        RegExp(r'mamar|breast|sani').hasMatch(lo)) {
      score += 8;
    }
    if (fam == ExploreTreatmentFamily.rhinoplasty &&
        name.length < 55 &&
        RegExp(r'rino|rhino|nas').hasMatch(lo)) {
      score += 8;
    }
    if (fam == ExploreTreatmentFamily.hair &&
        RegExp(r'hair|par|fue|capilar').hasMatch(lo)) {
      score += 8;
    }
    return score;
  }

  int _placesCandidatePriorityScore(
    OpenAIClinic stub, {
    required String procedure,
  }) {
    var score = 0;
    final name = stub.name.toLowerCase();
    final area = stub.area.toLowerCase();
    final website = _sourceUrlFromArea(stub.area) ?? '';
    final host = _stripWww(_normalizeProbeHost(website));
    if (website.isNotEmpty) score += 20;
    if (host.isNotEmpty && _denylistedWebsiteHost(host)) return -100;
    final keys = _procedureConfirmKeywords(procedure, '');
    if (keys.any(
      (k) =>
          k.length >= 3 &&
          (name.contains(k) || area.contains(k) || website.contains(k)),
    )) {
      score += 30;
    }
    if (name.contains('clinic') ||
        name.contains('clinica') ||
        name.contains('plastic') ||
        name.contains('aesthetic') ||
        name.contains('estetic') ||
        name.contains('dermatolog') ||
        name.contains('surgeon') ||
        name.contains('med spa') ||
        name.contains('medspa')) {
      score += 15;
    }
    if (RegExp(r'\bdr\.?\b').hasMatch(name)) score += 22;
    if (stub.name.length > 55) score -= 30;
    if (RegExp(r',').allMatches(stub.name).length >= 2) score -= 25;
    if (exploreClinicNameLooksLikeSeoHeadline(stub.name)) score -= 20;
    if (_priceLinkScore(website) >= 2) score += 12;
    if (stub.reviews >= 50) score += 5;
    final fam = exploreTreatmentFamily(procedure);
    if (fam == ExploreTreatmentFamily.hair) {
      final blob = '$name $area $website';
      if (RegExp(
        r'hair implant|hair transplant|transplant de par|implant de par|'
        r'implant par|fue|dhi|barbatilor',
      ).hasMatch(blob)) {
        score += 40;
      }
    }
    if (fam == ExploreTreatmentFamily.breast) {
      final blob = '$name $area $website';
      if (RegExp(
        r'marire sani|breast|mamar|implant mamar|boob',
      ).hasMatch(blob)) {
        score += 25;
      }
    }
    final generic =
        name.contains('salon') ||
        name.contains('spa') ||
        name.contains('wellness');
    final surgical =
        fam == ExploreTreatmentFamily.rhinoplasty ||
        fam == ExploreTreatmentFamily.breast ||
        fam == ExploreTreatmentFamily.hair;
    if (surgical &&
        generic &&
        !name.contains('plastic') &&
        !name.contains('surgeon') &&
        !name.contains('clinic')) {
      score -= 20;
    }
    return score;
  }

  /// Preview map + compare card: order by Google-Maps-style popularity (reviews,
  /// then rating), and normalize badges. Keeps model prices but fixes ordering.
  OpenAIComparisonResult _postprocessPreviewComparison(
    OpenAIComparisonResult r, {
    bool preserveOrder = false,
  }) {
    if (r.clinics.isEmpty) return r;
    final sorted = preserveOrder ? r.clinics : sortClinicsByGoogleMapsPopularity(r.clinics);
    final n = sorted.length;
    final out = <OpenAIClinic>[];
    for (var i = 0; i < n; i++) {
      final named = withExploreClinicDisplayName(sorted[i]);
      if (named.name.trim().isEmpty || isMarketplaceBrandName(named.name)) {
        debugPrint('[GP IDENTITY] drop platform card "${sorted[i].name}"');
        continue;
      }
      if (exploreListedPriceIsNonClinicContent(
        sourceUrl: named.priceSourceUrl,
        website: named.area,
      )) {
        debugPrint(
          '[GP IDENTITY] drop news/content card "${named.name}" · '
          '${named.priceSourceUrl.isNotEmpty ? named.priceSourceUrl : named.area}',
        );
        continue;
      }
      final c = named;
      final rank = i + 1;
      final (badge, bv) = switch (rank) {
        1 => ('Top rated', 'best'),
        _ when rank == n && n >= 3 => ('Premium', 'hi'),
        _ => ('Highly rated', 'mid'),
      };
      out.add(
        _fixRomanianPublishedCurrency(
          _alignClinicCurrencyToCity(
            c.copyWith(rank: rank,
              badge: preserveOrder ? 'Verified price' : badge,
              badgeVariant: preserveOrder ? 'mid' : bv),
            r.city,
          ),
          city: r.city,
          procedure: r.topic,
        ),
      );
    }
    final rl = _previewRangeLabelFromClinics(out, procedure: r.topic);
    return OpenAIComparisonResult(
      city: r.city,
      topic: r.topic,
      topicType: r.topicType,
      summary: r.summary,
      rangeLabel: rl.isEmpty ? r.rangeLabel : rl,
      mapCenter: r.mapCenter,
      clinics: out,
    );
  }

  String _previewRangeLabelFromClinics(
    List<OpenAIClinic> list, {
    String procedure = '',
  }) {
    var priced = list
        .where(
          (c) =>
              c.priceMin > 0 &&
              !_isPriceOnRequestLabel(c.priceLabel) &&
              explorePriceIsVerified(c) &&
              isJustifiedProcedurePrice(c, procedure: procedure) &&
              explorePriceIsComparableTypicalStart(
                procedure: procedure,
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
    if (priced.length < 2) return '';
    final wantSub = exploreLaserRequestedSubtype(procedure);
    if (wantSub == 'hair' || wantSub == 'skin') {
      final same = priced.where((c) {
        final label = '${c.rawProcedureText} ${c.brand}';
        return exploreLaserRowSubtype(label) == wantSub;
      }).toList();
      if (same.length >= 2) priced = same;
    } else if (procedure.toLowerCase().contains('laser')) {
      final hair = priced
          .where(
            (c) =>
                exploreLaserRowSubtype('${c.rawProcedureText} ${c.brand}') ==
                'hair',
          )
          .toList();
      final skin = priced
          .where(
            (c) =>
                exploreLaserRowSubtype('${c.rawProcedureText} ${c.brand}') ==
                'skin',
          )
          .toList();
      if (hair.length >= 2 && hair.length >= skin.length) {
        priced = hair;
      } else if (skin.length >= 2) {
        priced = skin;
      }
    }
    if (priced.length < 2) return '';
    // Typical range only within one currency — never mix $ with € amounts.
    final sameCurrency = clinicsSharingDominantCurrency(priced);
    var lo = sameCurrency.map((e) => e.priceMin).reduce(math.min);
    var hi = sameCurrency.map((e) => e.priceMin).reduce(math.max);
    // Drop absurd outliers (e.g. AI price_max = 10_000_000).
    final median = (() {
      final mins = sameCurrency.map((e) => e.priceMin).toList()..sort();
      return mins[mins.length ~/ 2];
    })();
    final cap = math.max(median * 20, lo * 20);
    if (hi > cap && cap > 0) {
      hi = sameCurrency
          .map((e) {
            final v = e.priceMax > e.priceMin ? e.priceMax : e.priceMin;
            return v <= cap ? v : e.priceMin;
          })
          .reduce(math.max);
    }
    if (hi < lo) hi = lo;
    final loI = lo.round();
    final hiI = hi.round();
    final sym = sameCurrency.first.currency.trim();
    if (sym == 'RON' || sym.toUpperCase() == 'LEI') return '$loI–$hiI RON';
    if (sym == '€' || sym == 'EUR') return '€$loI–$hiI';
    if (sym == '£' || sym == 'GBP') return '£$loI–$hiI';
    if (sym == r'$' || sym == 'USD')
      return '\$'
          '$loI'
          '–\$'
          '$hiI';
    if (sym == 'TRY') return '$loI–$hiI TRY';
    if (sym == 'AED') return '$loI–$hiI AED';
    if (sym == '₩' || sym.toUpperCase() == 'KRW') return '$loI–$hiI ₩';
    if (sym.toUpperCase() == 'HKD') return '$loI–$hiI HKD';
    if (sym.toUpperCase() == 'SGD') return '$loI–$hiI SGD';
    if (sym.toUpperCase() == 'THB') return '$loI–$hiI THB';
    return '$loI–$hiI $sym';
  }

  /// Returns a batch of clinics offering [procedure] in [city].
  /// Pass [excludeNames] to get a fresh batch that doesn't repeat already-shown clinics.
  /// Pass [aliases] to give the AI multilingual synonyms (e.g.
  /// ["Lip filler", "Acid hialuronic buze"]) so it can match clinics under
  /// any name.
  ///
  /// Emits twice when applicable: fast initial list, then an update after
  /// background price enrichment refreshes the session cache.
  Stream<OpenAIComparisonResult> buildClinicsList({
    required String procedure,
    required String city,
    int count = 10,
    List<String> excludeNames = const [],
    List<String> aliases = const [],
  }) async* {
    if (ExplorePriceDiscoveryTool.instance.enabled) {
      yield* _buildIndexedClinicsList(
        procedure: procedure, city: city, count: count, excludeNames: excludeNames,
      );
      return;
    }
    if (!isConfigured) {
      throw StateError(
        'Missing OPENAI_API_KEY. Add it to .env or --dart-define.',
      );
    }
    final normalized = await _normalizeProcedure(procedure);
    final baseKey =
        'clinicsList|$_kClinicsListCacheRevision|$normalized|$city'
        '|${aliases.join(",")}';

    // Check Firestore cache first — avoids paying for AI on repeat searches
    final firestoreCached = await _loadFromFirestore(baseKey);
    if (firestoreCached != null) {
      _cache[baseKey] = Future<OpenAIComparisonResult>.value(firestoreCached);
      debugPrint('[GP] Serving from Firestore cache (free): $baseKey');
      final filtered = _filterUnverifiedClinics(firestoreCached);

      // Try to load the full 30-clinic batch from Firestore
      final fullBatchCached = await _loadFromFirestore('$baseKey|fullbatch');
      if (fullBatchCached != null) {
        final fullFiltered = _filterUnverifiedClinics(fullBatchCached);
        _fullBatchCache[_batchCacheKey(normalized, city)] =
            List<OpenAIClinic>.from(fullFiltered.clinics);
        debugPrint(
          '[GP] Loaded full batch from Firestore: '
          '${fullFiltered.clinics.length} clinics',
        );
      } else {
        // Fallback: use visible page clinics only
        _fullBatchCache[_batchCacheKey(normalized, city)] =
            List<OpenAIClinic>.from(filtered.clinics);
      }
      final alreadyShownFs = excludeNames.toSet();
      final pageItemsFs = filtered.clinics
          .where((c) => !alreadyShownFs.contains(c.name))
          .take(count)
          .toList();

      // Pagination: more clinics may exist only after a fresh AI wave.
      if (pageItemsFs.isNotEmpty || excludeNames.isEmpty) {
        final pageResult = filtered.copyWith(clinics: pageItemsFs);
        yield pageResult;

        if (excludeNames.isEmpty) {
          final unpricedCount = filtered.clinics
              .where((c) => c.priceMin <= 0)
              .length;
          if (unpricedCount > 0) {
            debugPrint(
              '[GP] Cache has $unpricedCount unpriced clinics — '
              're-enriching in background',
            );
            _enrichmentCompleters[baseKey] =
                Completer<OpenAIComparisonResult>();
            final cacheReEnrichCompleter = _enrichmentCompleters[baseKey]!;

            _enrichPricesInBackgroundThenRefreshCache(
              resultSnapshot: pageResult,
              fullBatch: filtered.clinics,
              visibleCount: pageResult.clinics.length,
              procedure: normalized,
              city: city,
              cacheKey: baseKey,
            );

            try {
              final updated = await cacheReEnrichCompleter.future.timeout(
                const Duration(seconds: 15),
              );
              final updatedFiltered = _filterUnverifiedClinics(updated);
              final pageItemsUpdated = updatedFiltered.clinics
                  .where((c) => !alreadyShownFs.contains(c.name))
                  .take(count)
                  .toList();
              final updatedPage = updatedFiltered.copyWith(
                clinics: pageItemsUpdated,
              );
              final updPriced = updatedPage.clinics
                  .where((c) => c.priceMin > 0)
                  .length;
              final initPriced = pageResult.clinics
                  .where((c) => c.priceMin > 0)
                  .length;
              if (updPriced > initPriced) {
                debugPrint(
                  '[GP] Cache re-enrichment improved prices: '
                  '$initPriced→$updPriced',
                );
                yield updatedPage;
              }
            } on TimeoutException {
              debugPrint('[GP] Cache re-enrichment timed out — checking cache');
              final cached = _cache[baseKey];
              if (cached != null) {
                try {
                  final late = await (cached as Future<OpenAIComparisonResult>)
                      .timeout(const Duration(seconds: 5));
                  final lateFiltered = _filterUnverifiedClinics(late);
                  final pageLate = lateFiltered.clinics
                      .where((c) => !alreadyShownFs.contains(c.name))
                      .take(count)
                      .toList();
                  final latePage = lateFiltered.copyWith(clinics: pageLate);
                  final updPriced = latePage.clinics
                      .where((c) => c.priceMin > 0)
                      .length;
                  final initPriced = pageResult.clinics
                      .where((c) => c.priceMin > 0)
                      .length;
                  if (updPriced > initPriced) {
                    debugPrint(
                      '[GP] Late cache result has more prices: '
                      '$initPriced→$updPriced — emitting',
                    );
                    yield latePage;
                  }
                } catch (_) {}
              }
            } catch (e) {
              debugPrint('[GP] Cache re-enrichment error: $e');
            } finally {
              _enrichmentCompleters.remove(baseKey);
            }
          }
        }
        return;
      }
      debugPrint(
        '[GP] Firestore list exhausted (${filtered.clinics.length} clinics) — '
        'fetching more via AI',
      );
    }

    // Second+ AI waves need their own memo key so we do not return the first
    // cached batch forever when the user taps "Load more" past 30 clinics.
    final aiMemoKey = excludeNames.isEmpty
        ? baseKey
        : '$baseKey|more|v7|${excludeNames.length}|'
              '${Object.hashAll(excludeNames.map((s) => s.toLowerCase().trim()))}';

    Completer<OpenAIComparisonResult>? enrichmentCompleter;
    if (excludeNames.isEmpty) {
      _enrichmentCompleters[baseKey] = Completer<OpenAIComparisonResult>();
      enrichmentCompleter = _enrichmentCompleters[baseKey]!;
    }

    final fullResult = await _memoize<OpenAIComparisonResult>(
      aiMemoKey,
      () => _buildClinicsListFromWeb(
        procedure: normalized,
        city: city,
        count: 30,
        excludeNames: excludeNames,
        aliases: aliases,
        enrichmentCacheKey: baseKey,
      ),
    );

    // Slice the full result for this page
    final alreadyShown = excludeNames.toSet();
    final pageItems = fullResult.clinics
        .where((c) => !alreadyShown.contains(c.name))
        .take(count)
        .toList();
    final initial = fullResult.copyWith(clinics: pageItems);
    yield initial;

    // Further waves: price work is kicked off inside _buildClinicsListFromWeb.
    if (excludeNames.isNotEmpty) {
      return;
    }

    // Emission 2 — after background price enrichment completes (first wave only)
    final hasZero = initial.clinics.any((c) => c.priceMin <= 0);
    if (!hasZero) {
      _enrichmentCompleters.remove(baseKey);
      return;
    }

    try {
      final updated = await enrichmentCompleter!.future.timeout(
        const Duration(seconds: 15),
      );

      final updatedFiltered = _filterUnverifiedClinics(updated);
      final pageItemsUpdated = updatedFiltered.clinics
          .where((c) => !alreadyShown.contains(c.name))
          .take(count)
          .toList();
      final updatedSliced = updatedFiltered.copyWith(clinics: pageItemsUpdated);

      final initPriced = initial.clinics.where((c) => c.priceMin > 0).length;
      final updPriced = updatedSliced.clinics
          .where((c) => c.priceMin > 0)
          .length;

      if (updPriced > initPriced) {
        debugPrint(
          '[GP] Stream emission 2 (instant): '
          '$initPriced→$updPriced prices',
        );
        yield updatedSliced;
      }
    } on TimeoutException {
      debugPrint('[GP] Enrichment timed out — checking cache');
      final cached = _cache[baseKey];
      if (cached != null) {
        try {
          final fullUpdated = await (cached as Future<OpenAIComparisonResult>)
              .timeout(const Duration(seconds: 5));
          final fullFiltered = _filterUnverifiedClinics(fullUpdated);
          final pageItemsUpdated = fullFiltered.clinics
              .where((c) => !alreadyShown.contains(c.name))
              .take(count)
              .toList();
          final updatedSliced = fullFiltered.copyWith(
            clinics: pageItemsUpdated,
          );
          final initPriced = initial.clinics
              .where((c) => c.priceMin > 0)
              .length;
          final updPriced = updatedSliced.clinics
              .where((c) => c.priceMin > 0)
              .length;
          if (updPriced > initPriced) {
            debugPrint(
              '[GP] Late enrichment found: '
              '$initPriced→$updPriced prices',
            );
            yield updatedSliced;
          }
        } catch (_) {
          debugPrint('[GP] No enriched data in cache');
        }
      }
    } catch (e) {
      debugPrint('[GP] Enrichment await error: $e');
    } finally {
      _enrichmentCompleters.remove(baseKey);
    }
  }

  /// TLD substring guard for clinic rows (used before Places verification).
  List<OpenAIClinic> _filterClinicsAreaHasRecognizedTld(
    List<OpenAIClinic> clinics,
  ) {
    return clinics.where((c) {
      final extracted = _extractDomain(c.area);
      if (_denylistedWebsiteHost(extracted)) {
        debugPrint('[GP] Filtered denylisted domain in area: ${c.name}');
        return false;
      }
      final area = c.area.toLowerCase();
      final hasDomain =
          area.contains('.ro') ||
          area.contains('.com') ||
          area.contains('.co.uk') ||
          area.contains('.eu') ||
          area.contains('.de') ||
          area.contains('.fr') ||
          area.contains('.es') ||
          area.contains('.it') ||
          area.contains('.tr') ||
          area.contains('.net') ||
          area.contains('.org');
      if (!hasDomain) {
        debugPrint('[GP] Filtered clinic without domain: ${c.name}');
        return false;
      }
      return true;
    }).toList();
  }

  /// Strips trailing procedure qualifiers for broader web search (e.g. "PRP therapy" → "PRP").
  String _stripProcedureQualifiers(String procedure) {
    var s = procedure.trim();
    if (s.isEmpty) return s;
    final lower = s.toLowerCase();
    const suffixes = <String>[
      ' face lift',
      ' facelift',
      ' therapy',
      ' treatment',
      ' facial',
    ];
    for (final suf in suffixes) {
      if (lower.endsWith(suf) && s.length > suf.length) {
        s = s.substring(0, s.length - suf.length).trim();
        break;
      }
    }
    return s.isEmpty ? procedure.trim() : s;
  }

  /// Attempts to recover a truncated JSON response from the AI.
  /// Finds complete clinic objects inside `"clinics":[...]` and closes the array/root.
  Map<String, dynamic>? _recoverTruncatedJson(String raw) {
    try {
      final s = raw.trim();
      final keyIdx = s.indexOf('"clinics"');
      if (keyIdx < 0) return null;
      final openBracket = s.indexOf('[', keyIdx);
      if (openBracket < 0) return null;

      final head = s.substring(0, openBracket + 1);
      final tail = s.substring(openBracket + 1);

      final objects = <String>[];
      var i = 0;
      while (i < tail.length) {
        while (i < tail.length && ' \n\r\t'.contains(tail[i])) {
          i++;
        }
        if (i >= tail.length) break;
        if (tail[i] == ']') break;
        if (tail[i] != '{') break;

        final startObj = i;
        var depth = 0;
        var inStr = false;
        var esc = false;
        var strQuote = '';
        var closed = false;
        for (; i < tail.length; i++) {
          final c = tail[i];
          if (inStr) {
            if (esc) {
              esc = false;
            } else if (c == r'\') {
              esc = true;
            } else if (c == strQuote) {
              inStr = false;
            }
            continue;
          }
          if (c == '"' || c == "'") {
            inStr = true;
            strQuote = c;
            continue;
          }
          if (c == '{') depth++;
          if (c == '}') {
            depth--;
            if (depth == 0) {
              objects.add(tail.substring(startObj, i + 1));
              closed = true;
              i++;
              break;
            }
          }
        }
        if (!closed) break;

        while (i < tail.length && ' \n\r\t'.contains(tail[i])) {
          i++;
        }
        if (i < tail.length && tail[i] == ',') {
          i++;
          continue;
        }
        break;
      }

      if (objects.isEmpty) return null;

      final repaired = '$head${objects.join(',')}]}';
      final parsed = jsonDecode(repaired) as Map<String, dynamic>;
      if (parsed.containsKey('clinics') || parsed.containsKey('city')) {
        debugPrint(
          '[GP] Recovered JSON with ${repaired.length} chars '
          '(original: ${raw.length})',
        );
        return parsed;
      }
      return null;
    } catch (e) {
      debugPrint('[GP] JSON recovery failed: $e');
      return null;
    }
  }

  /// Pre-warms the Firestore + in-memory cache for a list of
  /// procedures in a given city. Runs sequentially with a short
  /// gap between calls to avoid rate limiting.
  /// Fire-and-forget — call without awaiting.
  Future<void> prewarmClinicCache({
    required List<String> procedures,
    required String city,
    int delayBetweenMs = 3000,
  }) async {
    if (disableClinicPreload) return;
    for (final procedure in procedures) {
      if (procedure.trim().isEmpty) continue;
      // Skip if already cached in memory
      final normalized = _normalizeProcSync(procedure);
      final baseKey =
          'clinicsList|$_kClinicsListCacheRevision|$normalized|$city|';

      if (_cache.containsKey(baseKey)) {
        debugPrint('[GP] Prewarm skip (already cached): $procedure');
        continue;
      }

      // Check Firestore first — if cached there, just warm memory
      final firestoreCached = await _loadFromFirestore(baseKey);
      if (firestoreCached != null) {
        _cache[baseKey] = Future<OpenAIComparisonResult>.value(firestoreCached);
        final filtered = _filterUnverifiedClinics(firestoreCached);
        _fullBatchCache[_batchCacheKey(normalized, city)] =
            List<OpenAIClinic>.from(filtered.clinics);
        debugPrint(
          '[GP] Prewarm from Firestore: $procedure '
          '(${filtered.clinics.length} clinics)',
        );

        // If unpriced clinics exist, enrich in background
        final unpricedCount = filtered.clinics
            .where((c) => c.priceMin <= 0)
            .length;
        if (unpricedCount > 0) {
          _enrichPricesInBackgroundThenRefreshCache(
            resultSnapshot: filtered,
            fullBatch: filtered.clinics,
            visibleCount: filtered.clinics.length,
            procedure: normalized,
            city: city,
            cacheKey: baseKey,
          );
        }
        continue;
      }

      // Not cached anywhere — fetch from AI
      debugPrint('[GP] Prewarm fetching: $procedure in $city');
      try {
        await for (final _ in buildClinicsList(
          procedure: procedure,
          city: city,
          count: 10,
          aliases: const [],
        )) {
          // Just consume the stream to trigger caching
          break; // First emission is enough — enrichment runs in background
        }
        debugPrint('[GP] Prewarm done: $procedure');
      } catch (e) {
        debugPrint('[GP] Prewarm failed for $procedure: $e');
      }

      // Gap between calls to avoid hammering the API
      await Future<void>.delayed(Duration(milliseconds: delayBetweenMs));
    }
    debugPrint('[GP] Prewarm complete for ${procedures.length} procedures');
  }

  /// Pre-warms cache for ONE procedure — checks memory + Firestore
  /// first, only calls AI if truly not cached.
  /// Safe to call on every scroll event — debounced by cache checks.
  Future<void> prewarmSingle({
    required String procedure,
    required String city,
  }) async {
    if (disableClinicPreload || _quotaExhausted) return;

    final normalized = _normalizeProcSync(procedure);
    final baseKey =
        'clinicsList|$_kClinicsListCacheRevision|$normalized|$city|';

    // Already in memory — nothing to do
    if (_cache.containsKey(baseKey)) return;

    // Already in Firestore — warm memory only (free)
    final firestoreCached = await _loadFromFirestore(baseKey);
    if (firestoreCached != null) {
      _cache[baseKey] = Future<OpenAIComparisonResult>.value(firestoreCached);
      final filtered = _filterUnverifiedClinics(firestoreCached);
      _fullBatchCache[_batchCacheKey(normalized, city)] =
          List<OpenAIClinic>.from(filtered.clinics);
      debugPrint('[GP] Lazy prewarm (Firestore hit — free): $procedure');

      // Re-enrich prices if needed
      final unpriced = filtered.clinics.where((c) => c.priceMin <= 0).length;
      if (unpriced > 0) {
        _enrichPricesInBackgroundThenRefreshCache(
          resultSnapshot: filtered,
          fullBatch: filtered.clinics,
          visibleCount: filtered.clinics.length,
          procedure: normalized,
          city: city,
          cacheKey: baseKey,
        );
      }
      return;
    }

    // Not cached anywhere — fetch from AI (costs money)
    debugPrint('[GP] Lazy prewarm (AI call): $procedure in $city');
    try {
      await for (final _ in buildClinicsList(
        procedure: procedure,
        city: city,
        count: 10,
        aliases: const [],
      )) {
        break; // First emission triggers caching — enough
      }
      debugPrint('[GP] Lazy prewarm done: $procedure');
    } catch (e) {
      debugPrint('[GP] Lazy prewarm failed for $procedure: $e');
    }
  }

  Future<OpenAIComparisonResult> _buildClinicsListFromWeb({
    required String procedure,
    required String city,
    required int count,
    required List<String> excludeNames,
    required List<String> aliases,
    String? enrichmentCacheKey,
  }) async {
    if (_quotaExhausted) {
      debugPrint('[GP] Skipping AI call — quota exhausted');
      throw StateError(
        'OpenAI quota exhausted — top up at platform.openai.com/billing',
      );
    }
    final excludeNote = excludeNames.isEmpty
        ? ''
        : 'Do NOT include: ${excludeNames.join(", ")}.';

    final aliasNote = aliases.isEmpty
        ? ''
        : 'Also known as: ${aliases.join(", ")}.';

    // Always fetch 30 from AI — enough for 3 pages
    // UI slicing handles pagination, not separate AI calls
    final targetCount = 30;
    // Session cache key must match [buildClinicsList] for background price refresh.

    final systemPrompt =
        'You are a research tool for a global BEAUTY & '
        'AESTHETIC MEDICINE comparison app.\n\n'
        'YOUR ONLY JOB: Find aesthetic clinics that offer '
        'a specific cosmetic procedure AND have it listed '
        'on their website.\n\n'
        '══ STEP 1 — SEARCH GOOGLE MAPS (MANDATORY) ══\n'
        'You MUST run these exact Google searches first:\n\n'
        'Search 1: "$procedure $city"\n'
        'Search 2: "$procedure $city recenzii"\n'
        'Search 3: "$procedure clinica $city"\n\n'
        'Then open Google Maps and search: "$procedure $city"\n\n'
        'Take the TOP results that appear — these are real verified '
        'businesses with real reviews. Do NOT invent clinics.\n'
        'Do NOT add clinics that do not appear in these search results.\n'
        'Copy the EXACT clinic name, rating, review count, and website '
        'URL as shown in Google Maps — do not guess or modify them.\n\n'
        'Order results by Google Maps ranking (most reviews + highest '
        'rating first) — this is already the correct order from the '
        'search results.\n\n'
        '══ OUTPUT JSON ══\n'
        'Return ONLY valid JSON — no markdown:\n'
        '{"city":string,"topic":string,"topic_type":"procedure",'
        '"summary":string,"currency":string,"range_label":string,'
        '"map_center":{"lat":number,"lng":number},'
        '"clinics":[{"rank":number,"name":string,"area":string,'
        '"distance_mi":number,"rating":number,"reviews":number,'
        '"price_min":number,"price_max":number,"price_label":string,'
        '"price_gbp":number,"currency":string,"brand":string,'
        '"badge":string,"badge_variant":"best"|"mid"|"hi",'
        '"has_procedure":boolean,"lat":number,"lng":number}]}\n\n'
        '══ OUTPUT RULES ══\n'
        'ANTI-HALLUCINATION RULES (critical):\n'
        '- Only include clinics you found in the Google search results above\n'
        '- If you found fewer than $targetCount real clinics, return fewer — '
        'never pad with invented ones\n'
        '- The clinic name must exactly match Google Maps\n'
        '- The domain must exactly match the "Website" button on Google Maps\n'
        '- The rating and review count must exactly match Google Maps\n'
        '- If Google Maps shows 4.9 ★ (474 reviews) for Illuma Clinique, '
        'return exactly rating=4.9 reviews=474\n\n'
        '- has_procedure: true ONLY when you visited the clinic website and confirmed '
        'this procedure appears in their services or price list.\n'
        '  false when the clinic is real but you could not verify the procedure on '
        'their site.\n'
        '  NEVER set true without visiting the website.\n'
        '- name: EXACT clinic name from Google Maps / their website\n'
        '- area: "District · hostname.tld" ONLY when hostname.tld is the Maps '
        'Website URL\'s host for this business. If there is no Maps website, '
        'omit the clinic (never fabricate a domain).\n'
        '- rating: real Google Maps rating (0 if not found)\n'
        '- currency: use the EXACT currency from clinic website\n'
        '  Romania: RON or Lei → use "RON"\n'
        '           Some RO clinics use EUR → use "€"\n'
        '  UK/Ireland: pound → use "£"\n'
        '  Eurozone (FR/DE/ES/IT/NL/BE/AT/PT): → use "€"\n'
        '  Turkey: lira → use "TRY"\n'
        '  USA/Canada/Australia: dollar → use "\$" or "AUD"\n'
        '  UAE/Dubai: dirham → use "AED" or "\$"\n'
        '  Russia: ruble → use "RUB"\n'
        '  Poland: złoty → use "PLN"\n'
        '  South Korea: won → use "KRW"\n'
        '  Japan: yen → use "JPY"\n'
        '  Brazil: real → use "BRL"\n'
        '  India: rupee → use "INR"\n'
        '- CRITICAL: NEVER convert prices between currencies\n'
        '  If clinic website shows "250 €" → return price_min=250, currency="€"\n'
        '  If clinic website shows "750 RON" → return price_min=750, currency="RON"\n'
        '  If clinic shows BOTH (e.g. "200€ / 1000 RON") → use EUR\n'
        '  Romanian clinics often price surgery in EUR and\n'
        '  non-surgical treatments also in EUR — use what the site shows\n'
        '  DO NOT default everything to RON for Romanian cities\n'
        '- price_min/price_max: INTEGER in local currency\n'
        '  "1.000 RON" → 1000 (dot=thousand separator in RO)\n'
        '  "1,000 RON" → 1000 (comma=thousand separator in US)\n'
        '  "£350" → 350\n'
        '  "€750" → 750\n'
        '  "1.500 TRY" → 1500\n'
        '  "₩150,000" → 150000\n'
        '  "¥15,000" → 15000\n'
        '  NEVER return 0 when a price is visible\n'
        '- price_label: formatted price with symbol\n'
        '  RON: "1,000 RON" or "800–1,200 RON"\n'
        '  EUR: "€350" or "€200–400"\n'
        '  GBP: "£150" or "£80–120"\n'
        '  TRY: "1,500 TRY"\n'
        '  USD: "\$200"\n'
        '- rank: 1 = most reviews + best rating combined\n'
        '  Clinics with 200+ reviews rank above those with 10\n'
        '  A 4.8★ with 500 reviews beats 5.0★ with 5 reviews\n'
        '  Clinics with price on request rank lower than priced\n'
        '- badge_variant: best=most reviewed+rated, mid=average, hi=premium\n'
        '- brand: actual product brand used (if known). NEVER include the '
        'price, currency, or a "| <price>" suffix here — price goes ONLY in '
        'price_min/price_max/price_label.\n'
        '- Return EXACTLY $targetCount clinics or as close as possible\n'
        '- Search multiple query variations to find enough clinics:\n'
        '  "$procedure $city"\n'
        '  "$procedure clinica $city"\n'
        '  "$procedure tratament $city"\n'
        '- If one search returns 10, try another variation to find more\n'
        '- Prioritize clinics WITH a real price on their website\n'
        '- Include clinics where you found a price BEFORE those without\n'
        '- Clinics with no price go at the END of the list\n'
        '- If fewer than $targetCount pass all checks,\n'
        '  return only verified ones — never add wrong clinics';

    final userMsg =
        'Search Google Maps for: "$procedure $city"\n\n'
        'Return the TOP clinics that appear in these real search results.\n'
        'These are the verified, most-reviewed clinics for this procedure '
        'in $city according to Google.\n\n'
        'For each clinic in the results:\n'
        '1. Copy exact name from Google Maps\n'
        '2. Copy exact rating and review count from Google Maps\n'
        '3. Click the Website button and copy the exact domain\n'
        '4. Visit their website and find the price for "$procedure"\n'
        '5. Set has_procedure=true only if procedure is listed on their site\n\n'
        'IMPORTANT: After finding each clinic on Google Maps, you MUST:\n'
        '- Visit their website price page (e.g. /preturi/ /prices/ /tarife/)\n'
        '- Find the exact price for "$procedure"\n'
        '- Return price_min as an integer in local currency\n'
        '- If price not found on website, set price_min=0 and '
        'price_label="Price on request"\n'
        'Never skip the price lookup step.\n\n'
        '${aliasNote.isNotEmpty ? "Also known as: $aliasNote\n" : ""}'
        '${excludeNote.isNotEmpty ? "Skip (already shown): $excludeNote\n" : ""}'
        '\n'
        'Step 0: For every candidate clinic, open Google Maps in $city, confirm '
        'the business, and read the official "Website" field. If missing, drop '
        'the candidate. Never invent a domain in "area".\n'
        'Step 1: Detect country and language from "$city".\n'
        'Step 2: Search Google with MULTIPLE QUERY VARIANTS:\n'
        '  You MUST run ALL of these searches:\n'
        '  Search 1: "$procedure clinic $city"\n'
        '  Search 2: "${_stripProcedureQualifiers(procedure)} clinic $city"\n'
        '  Search 3: "$procedure aesthetic $city prices"\n'
        '  Search 4: "$procedure $city pret OR price OR preturi"\n'
        '\n'
        '  IMPORTANT — search for SHORT FORM too:\n'
        '  If procedure is "PRP therapy" also search:\n'
        '    "PRP clinic $city" (without "therapy")\n'
        '    "PRP facial $city"\n'
        '    "PRP tratament $city"\n'
        '    "PRP plasmă $city"\n'
        '  If procedure is "Laser CO2" also search:\n'
        '    "laser CO2 $city" AND "laser fractional $city"\n'
        '  If procedure is "Lip filler" also search:\n'
        '    "acid hialuronic buze $city" (for Romania)\n'
        '    "filler buze $city"\n'
        '    "marire buze $city"\n'
        '  If procedure is "HIFU face lift" also search:\n'
        '    "HIFU $city" AND "Ultraformer $city" AND "Ultherapy $city"\n'
        '  If procedure is "Thread lift" also search:\n'
        '    "fire PDO $city" AND "lifting fire $city"\n'
        '  RULE: Always search the ROOT WORD without qualifiers.\n'
        '  "PRP therapy" → root = "PRP"\n'
        '  "Laser CO2" → root = "Laser CO2" AND "laser"\n'
        '  "HIFU face lift" → root = "HIFU"\n'
        '  "Hydrafacial" → root = "Hydrafacial"\n'
        '  "Morpheus8" → root = "Morpheus8" AND "Morpheus 8"\n'
        '  "Polynucleotides" → also search "PDRN" AND "Nucleofill"\n'
        '  "EZ GEL PRF" → also search "EZ gel" AND "PRF"\n'
        '  "Skin booster" → also search "skinbooster" AND "Volite"\n'
        '  "Exosome therapy" → also search "exozomi" AND "exosome"\n'
        'Step 3: For each clinic found, visit their website.\n'
        '  Look for pages named:\n'
        '  STANDARD: /preturi/ /tarife/ /prices/ /price-list/\n'
        '    /tarife-servicii/ /lista-preturi/ /costuri/ /services/\n'
        '  SHOPIFY STORES: /collections/ /collections/all\n'
        '    /collections/injectabile /collections/filler\n'
        '    /collections/marire-buze /collections/botox\n'
        '    /products/ /shop/\n'
        '  WOOCOMMERCE: /shop/ /produse/ /servicii/\n'
        '    /?post_type=product\n'
        '  If the site uses Shopify (/collections/ URLs exist),\n'
        '  visit the collection page for the procedure.\n'
        '  Each product on the page = one procedure variant.\n'
        '  Use the lowest product price as price_min.\n'
        'Step 4: Get the EXACT price for "$procedure":\n'
        '  Method A: Visit their price page directly\n'
        '  Method B: Search Google: "[clinic name] [procedure] pret RON"\n'
        '  Method C: Search Google: "[clinic name] [procedure] price"\n'
        '  Method D: Check their Google Maps listing — prices\n'
        '    sometimes appear in reviews or Q&A section\n'
        '  Method E: Search: site:[domain] "[procedure]"\n'
        '    to find any page on their site mentioning the price\n'
        '  IMPORTANT: Many Romanian clinic sites use Elementor/\n'
        '  WordPress and prices only show in JavaScript — if the\n'
        '  price page shows no prices, try Google search instead:\n'
        '  "[clinic name] PRP pret" or "[clinic name] PRP price"\n'
        '  Use Google snippets/cached pages to find prices.\n'
        '  If price truly not found: price_min=0,\n'
        '  price_label="Price on request".\n'
        'Step 5: Reject clinics that:\n'
        '  - Are not aesthetic/beauty clinics\n'
        '  - Do not list "$procedure" in their services\n'
        '  - Are hospitals, dental, pharmacy, general medicine\n'
        'Step 6: Return $targetCount verified clinics with\n'
        '  REAL prices from their websites. JSON only.\n\n'
        'CRITICAL: Never use estimated or average market prices.\n'
        'If you cannot find the real price from their website,\n'
        'set price_min=0 and price_label="Price on request".\n'
        'Better to show "Price on request" than a wrong price.';

    // ── PRIMARY: gpt-5.6-terra + web_search (Responses API) ─
    // Real web search, visits clinic websites, gets real prices.
    // This is the ONLY path that actually browses the internet.
    try {
      String rawJson =
          await _queueSearchPreview(
            () => _chatCompletionSearchPreviewJson(
              messages: [
                {'role': 'system', 'content': systemPrompt},
                {'role': 'user', 'content': userMsg},
              ],
              maxTokens: 16000,
            ),
          ).timeout(
            const Duration(seconds: 120),
            onTimeout: () =>
                throw TimeoutException('Search preview queue timed out'),
          );

      final trimmed = rawJson.trim();
      if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) {
        debugPrint('[GP] AI returned prose — retrying with JSON-only prompt');
        try {
          rawJson =
              await _queueSearchPreview(
                () => _chatCompletionSearchPreviewJson(
                  messages: [
                    {
                      'role': 'system',
                      'content':
                          'Return ONLY a valid JSON object starting with {. '
                          'No prose. No explanation. No markdown. Just JSON.',
                    },
                    {
                      'role': 'user',
                      'content':
                          'Search Google Maps for "$procedure clinics $city" '
                          'and return top 10 results as this JSON:\n'
                          '{"city":"$city","topic":"$procedure",'
                          '"topic_type":"procedure","currency":"RON",'
                          '"range_label":"","map_center":{"lat":0,"lng":0},'
                          '"clinics":[{"rank":1,"name":"clinic name",'
                          '"area":"district · domain.ro","distance_mi":0,'
                          '"rating":4.8,"reviews":100,"price_min":0,'
                          '"price_max":0,"price_label":"","price_gbp":0,'
                          '"currency":"RON","brand":"","badge":"Recommended",'
                          '"badge_variant":"mid","has_procedure":true,'
                          '"lat":0,"lng":0}]}\n'
                          'Start your response with { immediately.',
                    },
                  ],
                  maxTokens: 16000,
                ),
              ).timeout(
                const Duration(seconds: 120),
                onTimeout: () =>
                    throw TimeoutException('Search preview queue timed out'),
              );
        } catch (e) {
          debugPrint('[GP] JSON-only retry failed: $e');
          rethrow;
        }
      }

      Map<String, dynamic> jsonObj;
      try {
        jsonObj = jsonDecode(rawJson) as Map<String, dynamic>;
      } on FormatException catch (e) {
        debugPrint('[GP] JSON truncated — attempting recovery: $e');
        final recovered = _recoverTruncatedJson(rawJson);
        if (recovered != null) {
          debugPrint('[GP] JSON recovery succeeded');
          jsonObj = recovered;
        } else {
          debugPrint(
            '[GP] JSON recovery failed — retrying with maxTokens: 16000',
          );
          try {
            final retryJson =
                await _queueSearchPreview(
                  () => _chatCompletionSearchPreviewJson(
                    messages: [
                      {'role': 'system', 'content': systemPrompt},
                      {'role': 'user', 'content': userMsg},
                    ],
                    maxTokens: 16000,
                  ),
                ).timeout(
                  const Duration(seconds: 120),
                  onTimeout: () =>
                      throw TimeoutException('Search preview queue timed out'),
                );
            jsonObj = jsonDecode(retryJson) as Map<String, dynamic>;
            debugPrint('[GP] Retry succeeded');
          } catch (retryErr) {
            debugPrint('[GP] Retry also failed: $retryErr');
            rethrow;
          }
        }
      }
      final result = OpenAIComparisonResult.fromJson(
        jsonObj.cast<String, Object?>(),
      );
      if (result.clinics.isNotEmpty) {
        final verified = _filterClinicsAreaHasRecognizedTld(result.clinics);

        if (verified.isEmpty)
          return _buildClinicsListUncached(
            procedure: procedure,
            city: city,
            count: count,
            excludeNames: excludeNames,
            aliases: aliases,
            openAiCompletionModelOverride: _kFallbackClinicListModel,
          );

        // Step 1: enrich ratings from Google Places
        final withRatings =
            await _enrichClinicsWithPlaces(
              clinics: verified,
              city: city,
            ).timeout(
              const Duration(seconds: 10),
              onTimeout: () {
                debugPrint('[GP] Places timeout — using unrated list');
                return verified;
              },
            );
        if (withRatings.isEmpty) {
          debugPrint(
            '[GP] Places filtered all clinics — returning web-search verified list '
            'without enrichment',
          );
          final procedureVerifiedFallback = verified
              .where((c) => c.hasProcedure)
              .toList();
          return result.copyWith(
            clinics: procedureVerifiedFallback.isNotEmpty
                ? procedureVerifiedFallback
                : verified,
          );
        }

        // Show list immediately after Places (ratings + aesthetic filter).
        // Direct HTTP price scrapes run in background — they were blocking 15–20s.
        final procedureVerified = withRatings
            .where((c) => c.hasProcedure)
            .toList();
        if (procedureVerified.isEmpty) {
          debugPrint(
            '[GP] All clinics failed has_procedure check — falling back',
          );
          return _buildClinicsListUncached(
            procedure: procedure,
            city: city,
            count: count,
            excludeNames: excludeNames,
            aliases: aliases,
            openAiCompletionModelOverride: _kFallbackClinicListModel,
          );
        }
        final filtered = _filterUnverifiedClinics(
          result.copyWith(clinics: procedureVerified),
        );
        final fullSorted = _sortClinics(filtered.clinics);

        final batchCacheKey = _batchCacheKey(procedure, city);
        if (excludeNames.isEmpty) {
          _fullBatchCache[batchCacheKey] = fullSorted;
        } else {
          final prev = _fullBatchCache[batchCacheKey] ?? const <OpenAIClinic>[];
          final seen = prev.map((c) => c.name.toLowerCase().trim()).toSet();
          final additions = fullSorted
              .where((c) => !seen.contains(c.name.toLowerCase().trim()))
              .toList();
          _fullBatchCache[batchCacheKey] = [...prev, ...additions];
          debugPrint(
            '[GP] Merged AI wave into batch cache: '
            '${prev.length}+${additions.length}='
            '${_fullBatchCache[batchCacheKey]!.length} ($batchCacheKey)',
          );
        }
        debugPrint(
          '[GP] Stored full batch of ${_fullBatchCache[batchCacheKey]!.length} '
          'clinics ($batchCacheKey)',
        );

        final persistListKey =
            enrichmentCacheKey ??
            'clinicsList|$_kClinicsListCacheRevision'
                '|$procedure|$city|$count'
                '|${excludeNames.join(",")}|${aliases.join(",")}';
        _saveToFirestore(
          '$persistListKey|fullbatch',
          result.copyWith(clinics: _fullBatchCache[batchCacheKey]!),
        );

        final pageSlice = fullSorted.take(count).toList();
        final withPending = pageSlice
            .map((c) => c.priceMin <= 0 ? c.copyWith(pricePending: true) : c)
            .toList();
        final quickResult = result.copyWith(clinics: withPending);
        _enrichPricesInBackgroundThenRefreshCache(
          resultSnapshot: quickResult,
          fullBatch: fullSorted,
          visibleCount: pageSlice.length,
          procedure: procedure,
          city: city,
          cacheKey:
              enrichmentCacheKey ??
              'clinicsList|$_kClinicsListCacheRevision'
                  '|$procedure|$city|$count'
                  '|${excludeNames.join(",")}|${aliases.join(",")}',
        );
        return quickResult;
      }
    } catch (e, st) {
      debugPrint('[GP] _buildClinicsListFromWeb error: $e');
      debugPrint('[GP] Stack: $st');
    }

    // ── FALLBACK 2: gpt-5.6-luna no web search ──────────────
    // Last resort — no internet access, uses training data.
    // Returns "Price on request" for unknown prices.
    return _buildClinicsListUncached(
      procedure: procedure,
      city: city,
      count: count,
      excludeNames: excludeNames,
      aliases: aliases,
      openAiCompletionModelOverride: _kFallbackClinicListModel,
    );
  }

  Future<List<OpenAIClinic>> _enrichClinicsWithPlaces({
    required List<OpenAIClinic> clinics,
    required String city,
    bool dropUnmatched = true,
  }) async {
    if (clinics.isEmpty) return clinics;
    final entered = clinics.length;
    final enteredUnrated = clinics.where((c) => c.rating <= 0).length;

    late final List<OpenAIClinic> result;
    if (!_places.isConfigured) {
      // Same website-match/verification path as Places: probe the clinic
      // domain. Never trust AI web-search URLs without a fetch.
      final kept = await Future.wait(
        clinics.map((c) async {
          final d = _extractDomain(c.area);
          if (d.isEmpty) {
            debugPrint('[GP] Filtered clinic (no website domain): ${c.name}');
            return dropUnmatched ? null : _clearedUnverifiedPrice(c);
          }
          if (_denylistedWebsiteHost(d)) {
            debugPrint('[GP] Filtered denylisted: ${c.name}');
            return dropUnmatched ? null : c;
          }
          if (!await _probeWebsiteHost(d)) {
            debugPrint('[GP] Filtered unreachable website: ${c.name} → $d');
            return dropUnmatched ? null : _clearedUnverifiedPrice(c);
          }
          return c;
        }),
      );
      result = kept.whereType<OpenAIClinic>().toList();
    } else {
      // One Places lookup per clinic: enrich ratings + drop rows where the AI
      // domain disagrees with Google's official website or the site does not respond.
      // Same clinic across Botox/Fillers/Laser reuses city|name cache.
      var cacheHits = 0;
      var liveCalls = 0;
      final futures = clinics.map((c) async {
        final cached = await ExplorePlaceCacheStore.instance.lookupAny(
          city: city,
          clinicNames: ExplorePlaceCacheStore.aliasNames(
            clinicName: c.name, websiteHost: exploreClinicWebsiteHost(c),
          ),
        );
        if (cached != null && cached.matched && cached.rating > 0) {
          final nameNeedsMaps =
              exploreClinicNameNeedsMapsRefresh(c) &&
              cached.mapsName.trim().isEmpty;
          if (!nameNeedsMaps) {
            cacheHits++;
            final applied = _clinicFromCachedPlace(c, cached);
            if (applied != null && applied.rating > 0) return applied;
          }
        }
        if (cached != null && !cached.matched) {
          // A timeout must not suppress ratings for the entire app session.
          // Limit genuine identity misses briefly, then allow recovery.
          final retryKey = '${city.toLowerCase()}|${c.name.toLowerCase()}|${c.priceSourceUrl}';
          final previous = _placesIdentityMissesRetried[retryKey];
          if (previous != null && DateTime.now().difference(previous) < const Duration(minutes: 2)) {
            cacheHits++;
            return dropUnmatched ? null : c;
          }
          _placesIdentityMissesRetried[retryKey] = DateTime.now();
        }
        liveCalls++;
        return _enrichOrFilterClinicWithPlaces(c, city);
      }).toList();
      final out = await Future.wait(futures);
      result = !dropUnmatched
          ? [for (var i = 0; i < clinics.length; i++) out[i] ?? clinics[i]]
          : out.whereType<OpenAIClinic>().toList();
      debugPrint(
        '[GP] Places cache: $cacheHits hits, $liveCalls live calls · $city',
      );
    }
    final stillUnrated = result.where((c) => c.rating <= 0).length;
    debugPrint(
      '[GP] Places enrich: $entered in ($enteredUnrated unrated) → '
      '${result.length} out ($stillUnrated still rating=0) · $city',
    );
    return result;
  }

  /// HTTP price scraping for "Price on request" rows — too slow to await on first paint.
  /// Updates session cache when done so the same search returns scraped prices immediately.
  void _enrichPricesInBackgroundThenRefreshCache({
    required OpenAIComparisonResult resultSnapshot,
    required List<OpenAIClinic> fullBatch,
    required String procedure,
    required String city,
    required String cacheKey,
    required int visibleCount,
    void Function(OpenAIComparisonResult)? onEnriched,
  }) {
    final hasZeroPrices = fullBatch.any((c) => c.priceMin <= 0);
    if (!hasZeroPrices) return;

    Future<void>.microtask(() async {
      try {
        final enriched = await _enrichClinicsWithDirectPriceFetch(
          clinics: fullBatch,
          procedure: procedure,
          city: city,
        );
        final sorted = _sortClinics(enriched);
        final cleared = sorted
            .map((c) => c.copyWith(pricePending: false))
            .toList();

        final unpriced = cleared.where((c) => c.priceMin <= 0).toList();

        List<OpenAIClinic> finalClinics;
        if (unpriced.isEmpty) {
          finalClinics = cleared;
        } else {
          final batchKey = _batchCacheKey(procedure, city);
          final fullBatchAll = _fullBatchCache[batchKey] ?? cleared;

          final allPriced = fullBatchAll.where((c) => c.priceMin > 0).toList();

          final shownNames = cleared
              .take(visibleCount)
              .where((c) => c.priceMin > 0)
              .map((c) => c.name.toLowerCase())
              .toSet();

          final replacements = allPriced
              .where((c) => !shownNames.contains(c.name.toLowerCase()))
              .toList();

          debugPrint(
            '[GP] ${unpriced.length} unpriced — '
            '${replacements.length} replacements available',
          );

          final filled = <OpenAIClinic>[];
          var replIdx = 0;
          for (final c in cleared.take(visibleCount)) {
            if (c.priceMin > 0) {
              filled.add(c);
            } else if (replIdx < replacements.length) {
              debugPrint(
                '[GP] Replacing unpriced "${c.name}" '
                'with "${replacements[replIdx].name}"',
              );
              filled.add(replacements[replIdx]);
              replIdx++;
            }
          }
          finalClinics = _sortClinics(filled);
        }

        final enrichedResult = resultSnapshot.copyWith(clinics: finalClinics);
        _fullBatchCache[_batchCacheKey(procedure, city)] = cleared;
        _cache[cacheKey] = Future<OpenAIComparisonResult>.value(enrichedResult);
        _saveToFirestore(cacheKey, enrichedResult);
        final fullBatchResult = resultSnapshot.copyWith(clinics: cleared);
        _saveToFirestore('$cacheKey|fullbatch', fullBatchResult);
        debugPrint(
          '[GP] Background price scrape done — '
          '${enriched.where((c) => c.priceMin > 0).length}/${enriched.length} with prices',
        );
        final c = _enrichmentCompleters[cacheKey];
        if (c != null && !c.isCompleted) {
          c.complete(enrichedResult);
        }
        _enrichmentCompleters.remove(cacheKey);
        onEnriched?.call(enrichedResult);
      } catch (e) {
        debugPrint('[GP] Background enrichment error: $e');
      }
    });
  }

  /// Scores a URL by how likely it is to contain prices.
  /// Higher = more likely to have prices. Locale tokens come from [city].
  int _priceLinkScore(String url, {String city = '', String procedure = ''}) {
    return exploreScoreClinicPriceUrl(url, city: city, procedure: procedure);
  }

  /// True when the path is clearly another treatment (Thermage, EZ-GEL, PRP)
  /// than the one Compare is verifying.
  bool _urlConflictsWithSearchedProcedure(String url, String procedure) {
    final u = url.toLowerCase();
    if (u.trim().isEmpty) return false;
    if (exploreUrlConflictsWithProcedure(url, procedure)) return true;
    final want = exploreTreatmentFamily(procedure);
    if (want == ExploreTreatmentFamily.other) return false;
    final pathFam = exploreTreatmentFamily(
      u.replaceAll(RegExp(r'[/_\-?=&]+'), ' '),
    );
    if (u.contains('aftercare') ||
        u.contains('how-long') ||
        u.contains('second-opinion') ||
        u.contains('glutathione') ||
        u.contains('salmon-dna') ||
        u.contains('iv-drip') ||
        u.contains('migraine') ||
        u.contains('neurology')) {
      return true;
    }
    if (want != ExploreTreatmentFamily.laser && u.contains('tattoo-removal')) {
      return true;
    }
    if (want == ExploreTreatmentFamily.botox &&
        (u.contains('botox') ||
            u.contains('dysport') ||
            u.contains('xeomin') ||
            u.contains('jeuveau') ||
            u.contains('neuromodul'))) {
      return false;
    }
    if (want == ExploreTreatmentFamily.filler &&
        (u.contains('filler') ||
            u.contains('juvederm') ||
            u.contains('restylane') ||
            u.contains('hyaluron') ||
            u.contains('lip-filler'))) {
      return false;
    }
    if (want == ExploreTreatmentFamily.laser &&
        (u.contains('laser') ||
            u.contains('hair-removal') ||
            u.contains('epilare') ||
            u.contains('depilacion'))) {
      return false;
    }
    if (want == ExploreTreatmentFamily.peel &&
        (u.contains('peel') || u.contains('peeling'))) {
      return false;
    }
    if (want == ExploreTreatmentFamily.rhinoplasty &&
        (u.contains('rhino') ||
            u.contains('rinoplast') ||
            u.contains('nose-job'))) {
      return false;
    }
    if (want == ExploreTreatmentFamily.breast &&
        (u.contains('breast') ||
            u.contains('mamar') ||
            u.contains('pecho') ||
            u.contains('boob'))) {
      return false;
    }
    if (want == ExploreTreatmentFamily.hair &&
        (u.contains('hair-transplant') ||
            u.contains('fue') ||
            u.contains('injerto') ||
            u.contains('transplant'))) {
      return false;
    }
    if (pathFam != ExploreTreatmentFamily.other && pathFam != want) {
      return true;
    }
    if (want == ExploreTreatmentFamily.botox &&
        (u.contains('thermage') ||
            u.contains('ez-gel') ||
            u.contains('ezgel') ||
            u.contains('/prp') ||
            u.contains('platelet'))) {
      return true;
    }
    return false;
  }

  /// Review pagination, skincare SKUs, and shop junk — not a filler price page.
  bool _serpApiUrlIsJunk(String url, String procedure) {
    final u = url.toLowerCase();
    if (u.isEmpty) return true;
    if (u.contains('/reviews') ||
        u.contains('/review/') ||
        u.contains('/testimonial')) {
      return true;
    }
    if (RegExp(r'/page/\d+').hasMatch(u)) return true;
    if (u.contains('serum') ||
        u.contains('moisturizer') ||
        u.contains('anti-blemish') ||
        u.contains('cleanser') ||
        u.contains('sunscreen') ||
        u.contains('retinol')) {
      return true;
    }
    if (u.contains('/cart') ||
        u.contains('/checkout') ||
        u.contains('/account')) {
      return true;
    }
    if (looksLikeTreatmentFinanceUrl(url)) return true;
    if (u.contains('aftercare') ||
        u.contains('glutathione') ||
        u.contains('salmon-dna') ||
        u.contains('iv-drip') ||
        u.contains('migraine') ||
        u.contains('complete-guide') ||
        u.contains('how-to-') ||
        u.contains('how-long') ||
        u.contains('second-opinion')) {
      return true;
    }
    final keys = _procedureConfirmKeywords(procedure, '');
    final namesProcedure =
        keys.any((k) => k.length >= 4 && u.contains(k)) ||
        u.contains('injectable') ||
        u.contains('juvederm') ||
        u.contains('restylane');
    if ((u.contains('/product/') || u.contains('/shop/')) && !namesProcedure) {
      return true;
    }
    return false;
  }

  /// Accent-insensitive match so "depilación láser" hits "depilacion laser".
  String _foldExploreMatchText(String raw) {
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

  bool _serpResultLooksLikeClinicSite(
    _SerpSearchResult r, {
    required String procedure,
  }) {
    final host = _stripWww(_normalizeProbeHost(r.link));
    if (host.isEmpty) return false;
    if (_denylistedWebsiteHost(host) || _isGenericSocialOrDirectoryHost(host)) {
      return false;
    }
    return exploreSerpHitWorthFetching(
      url: r.link,
      title: r.title,
      snippet: r.snippet,
      procedure: procedure,
    );
  }

  bool _urlIsClinicHomepage(String url, String host) {
    final parsed = Uri.tryParse(url.trim());
    if (parsed == null || parsed.host.isEmpty) return false;
    if (!_hostsSameDomainOrSubdomain(url, host)) return false;
    final path = parsed.path.replaceAll(RegExp(r'/+$'), '');
    return path.isEmpty || path == '/';
  }

  /// Locale-aware price-page probes. Keep this short — Compare waits on
  /// every URL. Same slugs in every city; never a per-clinic allowlist.
  List<String> _clinicPriceProbeUrls(String domain) {
    return explorePriceMenuProbeUrls(domain);
  }

  List<String> _procedurePricePathHints(String procedure) {
    switch (exploreTreatmentFamily(procedure)) {
      case ExploreTreatmentFamily.botox:
        return const [
          '/upper-face-botox',
          '/pages/upper-face-botox',
          '/anti-wrinkle-injections',
          '/botox',
          '/pages/botox',
          '/anti-wrinkle',
          '/toxina-botulinica',
          '/toxina-botulinica/',
          '/arrugas',
          '/estompare-riduri',
          '/eliminare-riduri-neuromodulator',
          '/injectari',
          '/neuromodulator',
        ];
      case ExploreTreatmentFamily.filler:
        return const [
          '/aumento-de-labios',
          '/rellenos',
          '/filler',
          '/fillers',
          '/lip-fillers',
          '/dermal-fillers',
          '/marire-buze',
          '/acid-hialuronic',
          '/pages/preturi-injectari',
        ];
      case ExploreTreatmentFamily.laser:
        return const [
          '/depilacion-laser',
          '/depilacion',
          '/epilare-laser',
          '/laser-hair-removal',
          '/laser',
        ];
      case ExploreTreatmentFamily.peel:
        return const [
          '/peeling',
          '/peeling-quimico',
          '/peeling-chimic',
          '/peeling-kimik',
          '/chemical-peel',
          '/peels',
          '/biorepeel',
          '/prx',
          '/cosmelan',
          '/sq/',
        ];
      case ExploreTreatmentFamily.rhinoplasty:
        return const [
          '/nose-job-cost',
          '/rhinoplasty-cost',
          '/rhinoplasty',
          '/nose-job',
          '/nose-reshaping',
          '/rinoplastia',
          '/rinoplastie',
        ];
      case ExploreTreatmentFamily.breast:
        return const [
          '/aumento-de-pecho',
          '/mamoplastia',
          '/marire-sani',
          '/augmentare-mamara',
          '/breast-augmentation',
          '/breast-implants',
          '/augmentation-mammaire',
          '/breast-enlargement',
          '/breast-enlargement-surgery',
          '/boob-job-cost',
          '/our-fees',
          '/fees',
        ];
      case ExploreTreatmentFamily.hair:
        return const [
          '/injerto-capilar',
          '/fue',
          '/transplant-de-par',
          '/implant-de-par',
          '/hair-transplant',
          '/hair-restoration',
          '/greffe-de-cheveux',
          '/fees',
          '/our-fees',
        ];
      case ExploreTreatmentFamily.skin:
      case ExploreTreatmentFamily.other:
        return const [];
    }
  }

  List<String> _clinicProcedureProbeUrls(String domain, String procedure) {
    final base = 'https://$domain';
    return [
      for (final path in _procedurePricePathHints(procedure)) '$base$path',
    ];
  }

  /// Treatment words UAE / Gulf clinics use in their "cost in <city>" pages.
  List<String> _procedureCostPageSlugs(String procedure) {
    switch (exploreTreatmentFamily(procedure)) {
      case ExploreTreatmentFamily.botox:
        return const ['botox', 'botox-injections'];
      case ExploreTreatmentFamily.filler:
        return const ['lip-fillers', 'dermal-fillers', 'fillers'];
      case ExploreTreatmentFamily.laser:
        return const ['laser-treatments', 'laser-hair-removal'];
      case ExploreTreatmentFamily.peel:
        return const ['chemical-peel', 'chemical-peels'];
      case ExploreTreatmentFamily.rhinoplasty:
        return const ['rhinoplasty', 'nose-job'];
      case ExploreTreatmentFamily.breast:
        return const ['breast-surgery', 'breast-augmentation'];
      case ExploreTreatmentFamily.hair:
        return const ['hair-transplant'];
      case ExploreTreatmentFamily.skin:
      case ExploreTreatmentFamily.other:
        return const [];
    }
  }

  /// Prefer published `{procedure}-cost-in-{city}` / `-price-in-` pages when
  /// clinics publish the menu there instead of a generic `/prices` path.
  List<String> _clinicCostPageProbeUrls(
    String domain,
    String procedure,
    String city,
  ) {
    final slugs = _procedureCostPageSlugs(procedure);
    if (slugs.isEmpty) return const [];
    final citySlug = city
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final base = 'https://$domain';
    final out = <String>[];
    for (final slug in slugs) {
      out
        ..add('$base/$slug-cost')
        ..add('$base/$slug-cost/')
        ..add('$base/$slug-price');
      if (citySlug.isEmpty) continue;
      for (final prefix in const ['/en', '']) {
        out
          ..add('$base$prefix/$slug-cost-in-$citySlug/')
          ..add('$base$prefix/$slug-price-in-$citySlug/');
      }
    }
    return out;
  }

  /// For clinics returned with price_min=0 by the AI search,
  /// attempt to fetch their price page directly and extract
  /// the real price for the given procedure.
  ///
  /// When [requireWebsiteConfirm] is true (fresh Explore AI rows), every
  /// claimed price_min must appear on the fetched clinic website. Fetch
  /// failure or no match clears the price and sets [OpenAIClinic.pricePending].
  Future<List<OpenAIClinic>> _enrichClinicsWithDirectPriceFetch({
    required List<OpenAIClinic> clinics,
    required String procedure,
    required String city,
    bool repriceExisting = false,
    bool requireWebsiteConfirm = false,
    Set<String> skipWebsiteConfirmKeys = const {},
    void Function(OpenAIClinic clinic)? onClinicDone,
    bool Function()? stopIf,
    bool allowDeepFallbacks = true,
  }) async {
    // Enrich clinics with no price, pending verification, a website we
    // can use to replace a placeholder seed quote, or (Explore AI) any
    // claimed price that must be confirmed on the live page.
    final needsPrice = clinics.where((c) {
      if (!c.area.contains('.')) return false;
      if (exploreCachedPriceNeedsReselect(
        rawProcedureText: c.rawProcedureText,
        brand: c.brand,
        sourceUrl: c.priceSourceUrl.isNotEmpty ? c.priceSourceUrl : c.area,
        procedure: procedure,
        rawPriceText: c.rawPriceText,
        rawEvidence: c.priceEvidenceText,
        priceMin: c.priceMin,
        priceMax: c.priceMax,
        priceExtractRevision: c.priceExtractRevision,
        currency: c.currency,
      )) {
        return true;
      }
      if (skipWebsiteConfirmKeys.isNotEmpty &&
          c.priceMin > 0 &&
          !c.pricePending &&
          explorePriceIsVerified(c) &&
          exploreClinicHitsKeys(c, skipWebsiteConfirmKeys)) {
        return false;
      }
      if (c.priceMin == 0 || c.pricePending) return true;
      if (!explorePriceIsVerified(c)) return true;
      final checked = c.priceVerifiedAt ?? c.lastCheckedAt;
      if (checked != null &&
          DateTime.now().difference(checked) < kExploreVerifiedPriceTtl &&
          exploreClinicMatchesProcedure(c, procedure) &&
          isJustifiedProcedurePrice(c, procedure: procedure)) {
        return false;
      }
      // Fresh Google rows: every claimed price must appear on the live page.
      if (requireWebsiteConfirm) return true;
      // Background re-scrape: only quotes that are still wrong / too cheap.
      if (repriceExisting &&
          !isJustifiedProcedurePrice(c, procedure: procedure)) {
        return true;
      }
      return false;
    }).toList();
    if (needsPrice.isEmpty) {
      if (!requireWebsiteConfirm) return clinics;
      // No verifiable website — inconclusive, not disproved. Keep AI price
      // so the compare list is not permanently stuck at 1 card.
      return [
        for (final c in clinics)
          if (c.priceMin > 0 && !c.area.contains('.'))
            c.copyWith(pricePending: false)
          else
            c,
      ];
    }

    final urlCache = <String, Future<String>>{};

    Future<String> cachedFetch(String url, {bool allowRender = false}) {
      if (_isSessionBlockedHost(url) && !allowRender) {
        return Future.value('');
      }
      final cached = _pageTextCache[url];
      if (cached != null &&
          DateTime.now().difference(cached.fetchedAt) < _kPageTextCacheTtl) {
        return Future.value(cached.text);
      }
      return urlCache.putIfAbsent('$url|render=$allowRender', () async {
        try {
          final r = await _fetchPageTextEx(
            url,
            timeout: requireWebsiteConfirm ? _kClinicWebsiteProbeTimeout : null,
            allowRender: allowDeepFallbacks && allowRender,
          );
          if (r.text.isNotEmpty) {
            _pageTextCache[url] = (text: r.text, fetchedAt: DateTime.now());
          }
          return r.text;
        } catch (_) {
          return '';
        }
      });
    }

    // Fetch prices with a bounded queue so SerpApi / website probes
    // cannot stampede (max 2 verification jobs at once).
    Future<OpenAIClinic> verifyClinic(OpenAIClinic clinic) async {
      // Never keep an unverified GPT number. Wrong prices (750 RON for
      // 3-area Botox) and clinics that do not offer the treatment (Bellezza)
      // came from "keep AI if the scrape is inconclusive".
      OpenAIClinic rejectUnverified(
        String reason, {
        bool offersProcedure = true,
      }) {
        debugPrint(
          '[GP] price decision for ${clinic.name}: drop '
          'ai=${clinic.priceMin} ${clinic.currency} reason=$reason '
          'offers=$offersProcedure',
        );
        if (!offersProcedure) {
          return clinic.copyWith(
            hasProcedure: false,
            priceMin: 0,
            priceMax: 0,
            priceGbp: 0,
            priceLabel: '',
            pricePending: false,
            priceRejectionReason: reason,
          );
        }
        // Procedure offered but no literal amount — do not paint as
        // "Price on request"; Explore only shows verified listed prices.
        return _clearedUnverifiedPrice(clinic, reason: reason);
      }

      try {
        final domain = _extractDomain(clinic.area);
        if (domain.isEmpty) {
          if (requireWebsiteConfirm && clinic.priceMin > 0) {
            return rejectUnverified('no_website');
          }
          return clinic;
        }

        final domainKey = _normalizeProbeHost(domain);
        final base = 'https://$domain';
        final bookableMarketplaceVenue =
            exploreIsBookingPlatformVenueUrl(clinic.priceSourceUrl) ||
            exploreIsBookingPlatformVenueUrl(clinic.area) ||
            (clinic.sourceType == 'marketplace' &&
                isBookingPlatformHost(domainKey));
        if (_isGenericSocialOrDirectoryHost(domainKey) ||
            looksLikeMarketEstimateDirectoryUrl(domainKey) ||
            looksLikeNonClinicContentHost(domainKey) ||
            isMarketplaceBrandName(clinic.name) ||
            (isMarketplaceOrDirectoryHost(domainKey) &&
                !bookableMarketplaceVenue)) {
          debugPrint(
            '[GP] Skip marketplace/directory host $domainKey '
            '(${clinic.name})',
          );
          return rejectUnverified(
            'marketplace_or_directory_host',
            offersProcedure: false,
          );
        }
        if (_isSessionBlockedHost(domainKey)) {
          debugPrint('[GP] Skip blocked domain $domainKey (${clinic.name})');
          return requireWebsiteConfirm
              ? rejectUnverified('page_blocked_or_empty')
              : clinic;
        } else if (_jsRenderedDomains.contains(domainKey)) {
          debugPrint('[GP] JS-rendered site: ${clinic.name}');
          final home = await cachedFetch(base, allowRender: allowDeepFallbacks);
          if (home.length >= 400 &&
              !_pageOffersProcedure(
                home,
                procedure: procedure,
                brand: clinic.brand,
              )) {
            return rejectUnverified(
              'js_site_no_procedure',
              offersProcedure: false,
            );
          }
          if (!requireWebsiteConfirm) {
            return clinic;
          }
          // Fall through so SerpApi can recover a scrapeable URL / snippet.
        }

        String bestText = '';
        String? bestSourceUrl;

        // Bodies already seen on this host, keyed by content, so a catch-all
        // route cannot be mistaken for a dozen different pages.
        //
        // perlaskinclinic.com answered /prices, /price-list, /pricing,
        // /peeling, /chemical-peel-cost and nine more guessed paths with the
        // same 8462-char SPA shell. Each one was fetched and parsed, and
        // `/prices` was then *preferred* as the price source at "score 5" —
        // a soft 404 outranking the real page.
        final seenBodyByHash = <String, String>{};
        bool isSoftDuplicateBody(String url, String text) {
          if (text.length < 200) return false;
          final hash =
              '${text.length}:'
              '${text.hashCode}:'
              '${text.substring(0, 120).hashCode}';
          final firstUrl = seenBodyByHash[hash];
          if (firstUrl == null) {
            seenBodyByHash[hash] = url;
            return false;
          }
          if (firstUrl == url) return false;
          debugPrint(
            '[GP] Same body as $firstUrl — treating as soft 404: $url',
          );
          return true;
        }

        final googleResultUrl = _sourceUrlFromArea(clinic.area);
        final probes = _clinicPriceProbeUrls(domain);
        final procedureProbes = _clinicProcedureProbeUrls(domain, procedure);
        final costPageProbes = _clinicCostPageProbeUrls(
          domain,
          procedure,
          city,
        );
        final menuProbes = [
          for (final u in probes)
            if (looksLikePriceMenuUrl(u)) u,
        ].take(3).toList();
        final rankedGoogleUrl =
            googleResultUrl != null &&
                googleResultUrl.trim().isNotEmpty &&
                !isNonLiteralClinicPriceUrl(googleResultUrl) &&
                !_serpApiUrlIsJunk(googleResultUrl, procedure)
            ? googleResultUrl.trim()
            : '';
        final englishGoogleUrl = rankedGoogleUrl.isEmpty
            ? ''
            : exploreEnglishLocaleUrl(rankedGoogleUrl);
        final locLang = exploreCityPriceSearchTerms(
          city,
        ).lang.trim().toLowerCase();
        final localHomeUrl =
            domain.isEmpty || locLang.isEmpty || locLang == 'en'
            ? ''
            : exploreLocalLocaleHomepageUrl('https://$domain/', lang: locLang);
        final venueMenuUrl = () {
          final src = clinic.priceSourceUrl.trim();
          final fromSrc = exploreBookingPlatformVenueUrl(src);
          if (fromSrc.isNotEmpty) return fromSrc;
          final fromArea = _sourceUrlFromArea(clinic.area)?.trim() ?? '';
          return exploreBookingPlatformVenueUrl(fromArea);
        }();
        final priorityUrls = [
          if (venueMenuUrl.isNotEmpty) venueMenuUrl,
          if (localHomeUrl.isNotEmpty) localHomeUrl,
          if (englishGoogleUrl.isNotEmpty &&
              englishGoogleUrl != rankedGoogleUrl)
            englishGoogleUrl,
          if (rankedGoogleUrl.isNotEmpty) rankedGoogleUrl,
          ...menuProbes,
          ...costPageProbes.take(4),
          ...procedureProbes.take(4),
          if (probes.isNotEmpty) probes.first,
          ...probes.skip(1).take(2),
        ];

        bool isBotoxSpecialtyLanding(String url) {
          return exploreTreatmentFamily(procedure) ==
                  ExploreTreatmentFamily.botox &&
              looksLikeBotoxSpecialtyVariantUrl(url);
        }

        bool isSolidPublishedPricePage(String url, String text) {
          if (text.length < 800 || !_pageHasPricedAmounts(text)) return false;
          if (isBotoxSpecialtyLanding(url)) return false;
          if (looksLikeOfficialPriceListUrl(url)) return true;
          if (exploreTreatmentFamily(procedure) ==
                  ExploreTreatmentFamily.botox &&
              looksLikeBotoxStandardStartingUrl(url)) {
            return true;
          }
          return _priceLinkScore(url, city: city, procedure: procedure) >= 5;
        }

        if (rankedGoogleUrl.isNotEmpty) {
          if (englishGoogleUrl.isNotEmpty &&
              englishGoogleUrl != rankedGoogleUrl) {
            await _fetchRawHtml(englishGoogleUrl);
          }
          await _fetchRawHtml(rankedGoogleUrl);
          if (_isSessionBlockedHost(domainKey)) {
            return rejectUnverified('page_blocked_or_empty');
          }
          final fromGoogle = _clinicFromDeterministicEvidence(
            clinic: clinic,
            procedure: procedure,
            preferredUrl: englishGoogleUrl.isNotEmpty
                ? englishGoogleUrl
                : rankedGoogleUrl,
            extraUrls: [
              if (englishGoogleUrl.isNotEmpty &&
                  englishGoogleUrl != rankedGoogleUrl)
                rankedGoogleUrl,
            ],
            city: city,
          );
          if (fromGoogle != null &&
              !isBotoxSpecialtyLanding(
                fromGoogle.priceSourceUrl.isNotEmpty
                    ? fromGoogle.priceSourceUrl
                    : rankedGoogleUrl,
              )) {
            debugPrint(
              '[GP] Google-result HTML for ${clinic.name}: '
              '${fromGoogle.priceLabel}',
            );
            return fromGoogle;
          }
          if (fromGoogle != null) {
            debugPrint('[GP] Ignore specialty Botox landing: $rankedGoogleUrl');
          }
        }

        if (menuProbes.isNotEmpty) {
          await Future.wait([for (final u in menuProbes) _fetchRawHtml(u)]);
          final fromMenu = _clinicFromDeterministicEvidence(
            clinic: clinic,
            procedure: procedure,
            preferredUrl: menuProbes.first,
            extraUrls: menuProbes,
            city: city,
          );
          if (fromMenu != null &&
              !isBotoxSpecialtyLanding(fromMenu.priceSourceUrl)) {
            debugPrint(
              '[GP] Price menu HTML for ${clinic.name}: '
              '${fromMenu.priceLabel}',
            );
            return fromMenu;
          }
        }

        // Extended fallback URLs — only tried if priority returns thin content
        final fallbackUrls = [
          '$base/servicii',
          '$base/servicii/',
          '$base/tratamientos',
          '$base/tratamientos/',
          '$base/services/',
          '$base/costuri/',
          '$base/tratamente',
          '$base/tratamente/',
        ];

        bool urlLooksLikeThisProcedure(String url) {
          final u = url.toLowerCase();
          if (u.isEmpty) return false;
          final keys = _procedureConfirmKeywords(procedure, clinic.brand);
          if (keys.any((k) => k.length >= 3 && u.contains(k))) return true;
          for (final path in _procedurePricePathHints(procedure)) {
            final slug = path.replaceAll(RegExp(r'^/+|/+$'), '').toLowerCase();
            if (slug.length >= 3 && u.contains(slug)) return true;
          }
          final fam = exploreTreatmentFamily(procedure);
          if (fam == ExploreTreatmentFamily.filler &&
              (u.contains('injectable') ||
                  u.contains('juvederm') ||
                  u.contains('restylane') ||
                  u.contains('hyaluron') ||
                  u.contains('volbella') ||
                  u.contains('voluma') ||
                  u.contains('lip-filler') ||
                  u.contains('dermal-filler'))) {
            return true;
          }
          if (fam == ExploreTreatmentFamily.botox &&
              (u.contains('dysport') ||
                  u.contains('xeomin') ||
                  u.contains('jeuveau') ||
                  u.contains('anti-wrinkle'))) {
            return true;
          }
          if (fam == ExploreTreatmentFamily.laser &&
              (u.contains('hair-removal') ||
                  u.contains('epilare') ||
                  u.contains('depilacion') ||
                  u.contains('ipl'))) {
            return true;
          }
          if (fam == ExploreTreatmentFamily.peel && u.contains('peel')) {
            return true;
          }
          if (fam == ExploreTreatmentFamily.rhinoplasty &&
              (u.contains('rinoplast') ||
                  u.contains('rhinoplast') ||
                  u.contains('nose-job') ||
                  u.contains('nose-reshaping'))) {
            return true;
          }
          if (fam == ExploreTreatmentFamily.breast &&
              (u.contains('breast') ||
                  u.contains('mamar') ||
                  u.contains('mamoplast') ||
                  u.contains('pecho'))) {
            return true;
          }
          if (fam == ExploreTreatmentFamily.hair &&
              (u.contains('hair-transplant') ||
                  u.contains('injerto') ||
                  u.contains('/fue'))) {
            return true;
          }
          return false;
        }

        bool pageOffersThis(String text) => _pageOffersProcedure(
          text,
          procedure: procedure,
          brand: clinic.brand,
        );

        bool considerPage(String url, String text) {
          if (isNonLiteralClinicPriceUrl(url)) {
            debugPrint('[GP] Ignore blog/guide URL: $url');
            return false;
          }
          if (text.isEmpty) return false;
          // A guessed path that returns the page we already have is not a
          // price page, whatever its slug promises.
          if (isSoftDuplicateBody(url, text)) return false;
          if (exploreTreatmentFamily(procedure) ==
              ExploreTreatmentFamily.botox) {
            if (isBotoxSpecialtyLanding(url) &&
                (looksLikeOfficialPriceListUrl(bestSourceUrl ?? '') ||
                    looksLikeBotoxStandardStartingUrl(bestSourceUrl ?? '')) &&
                bestText.length >= 400 &&
                _pageHasPricedAmounts(bestText)) {
              debugPrint(
                '[GP] Keep standard Botox menu over specialty landing: '
                '$bestSourceUrl',
              );
              return false;
            }
            if (!isBotoxSpecialtyLanding(url) &&
                (looksLikeOfficialPriceListUrl(url) ||
                    looksLikeBotoxStandardStartingUrl(url)) &&
                isBotoxSpecialtyLanding(bestSourceUrl ?? '') &&
                text.length >= 400 &&
                _pageHasPricedAmounts(text)) {
              bestText = text;
              bestSourceUrl = url;
              debugPrint(
                '[GP] Prefer standard Botox menu over specialty landing: $url',
              );
              return true;
            }
          }
          if (exploreTreatmentFamily(procedure) ==
              ExploreTreatmentFamily.hair) {
            if (looksLikeOfficialPriceListUrl(bestSourceUrl ?? '') &&
                looksLikeHairProcedureLandingUrl(url) &&
                bestText.length >= 400 &&
                _pageHasPricedAmounts(bestText)) {
              debugPrint(
                '[GP] Keep hair fees menu over procedure landing: '
                '$bestSourceUrl',
              );
              return false;
            }
            if (looksLikeOfficialPriceListUrl(url) &&
                looksLikeHairProcedureLandingUrl(bestSourceUrl ?? '') &&
                text.length >= 400 &&
                _pageHasPricedAmounts(text)) {
              bestText = text;
              bestSourceUrl = url;
              debugPrint('[GP] Prefer hair fees menu over landing: $url');
              return true;
            }
          }
          if (bestText.length >= 400 &&
              looksLikeOfficialPriceListUrl(bestSourceUrl ?? '') &&
              looksLikeCityCostArticleUrl(url)) {
            debugPrint(
              '[GP] Keep official price list over cost-guide: '
              '$bestSourceUrl',
            );
            return false;
          }
          if (_serpApiUrlIsJunk(url, procedure) && bestText.length >= 400) {
            debugPrint('[GP] Ignore junk URL: $url');
            return false;
          }
          final newProcUrl = urlLooksLikeThisProcedure(url);
          final oldProcUrl = urlLooksLikeThisProcedure(bestSourceUrl ?? '');
          // Nav on every page mentions Botox. Do not keep /marire-sani/.
          if (!newProcUrl &&
              _urlConflictsWithSearchedProcedure(url, procedure)) {
            debugPrint('[GP] Ignore off-procedure URL: $url');
            return false;
          }
          // Keep /botox/ or /product/botox-… over a generic /preturi that
          // only lists laser (SkinMedica) or other treatments.
          // Official /prices/ still outranks a treatment landing whose path
          // happens to contain the procedure slug (/cosmelan-peel/, /barbie-botox/).
          if (oldProcUrl && !newProcUrl && bestText.length >= 400) {
            final newIsOfficialMenu =
                looksLikeOfficialPriceListUrl(url) &&
                _pageHasPricedAmounts(text);
            if (!newIsOfficialMenu) {
              return false;
            }
          }
          if (newProcUrl && !oldProcUrl && text.length >= 400) {
            final oldScore = _priceLinkScore(bestSourceUrl ?? '');
            final newScore = _priceLinkScore(url);
            final oldIsPricedMenu =
                oldScore >= 3 && _pageHasPricedAmounts(bestText);
            final newHasPrices = _pageHasPricedAmounts(text);
            // /botox landing pages often inherit footer euros. Keep /preturi.
            if (oldIsPricedMenu && newScore < 3) {
              debugPrint(
                '[GP] Keep priced menu over procedure landing: '
                '$bestSourceUrl',
              );
              return false;
            }
            if (oldIsPricedMenu &&
                looksLikeOfficialPriceListUrl(bestSourceUrl ?? '') &&
                (looksLikeCityCostArticleUrl(url) || newScore < 5)) {
              debugPrint(
                '[GP] Keep official /prices over cost-guide: '
                '$bestSourceUrl',
              );
              return false;
            }
            if (oldIsPricedMenu && !newHasPrices) {
              debugPrint(
                '[GP] Keep priced menu over thin procedure URL: '
                '$bestSourceUrl',
              );
              return false;
            }
            bestText = text;
            bestSourceUrl = url;
            debugPrint(
              '[GP] Prefer procedure URL: $url (${text.length} chars)',
            );
            return true;
          }
          final newOffers = pageOffersThis(text);
          final oldOffers = bestText.isNotEmpty && pageOffersThis(bestText);
          if (oldOffers && !newOffers && bestText.length >= 400) {
            return false;
          }
          if (oldOffers &&
              !newProcUrl &&
              _urlConflictsWithSearchedProcedure(url, procedure)) {
            debugPrint('[GP] Ignore off-procedure URL: $url');
            return false;
          }
          if (newOffers && !oldOffers && text.length >= 400) {
            bestText = text;
            bestSourceUrl = url;
            debugPrint(
              '[GP] Prefer page that lists this treatment: $url '
              '(${text.length} chars)',
            );
            return true;
          }
          final newScore = _priceLinkScore(url);
          final oldScore = _priceLinkScore(bestSourceUrl ?? '');
          final betterPricePath = newScore > oldScore && text.length >= 600;
          final longerSameOrBetter =
              newScore >= oldScore && text.length > bestText.length;
          if (bestText.isEmpty || betterPricePath || longerSameOrBetter) {
            bestText = text;
            bestSourceUrl = url;
            debugPrint(
              '[GP] Better price page found: $url (${text.length} chars'
              '${newScore > 0 ? ", score $newScore" : ""})',
            );
            return true;
          }
          return false;
        }

        /// [considerPage] rejects these on the URL alone, so fetching them
        /// only burned the verify budget: a Dubai hair search spent it on
        /// /nose-fillers and /filler-injection-cost-dubai, then parsed eight
        /// filler rows out of them just to reject every one. The clinic's own
        /// homepage is never off-procedure — it anchors the scrape.
        bool isOffProcedureUrl(String url) {
          if (_urlIsClinicHomepage(url, domainKey)) return false;
          return !urlLooksLikeThisProcedure(url) &&
              _urlConflictsWithSearchedProcedure(url, procedure);
        }

        // Phase 1: home + locale price URLs in parallel (not one-by-one).
        Future<void> fetchUrls(List<String> urls) async {
          if (_isSessionBlockedHost(domainKey)) {
            debugPrint('[GP] Skip blocked domain $domainKey');
            return;
          }
          final unique = <String>[];
          final seenUrl = <String>{};
          for (final url in urls) {
            final u = url.trim();
            if (u.isEmpty || !seenUrl.add(u)) continue;
            if (isOffProcedureUrl(u)) {
              debugPrint('[GP] Skip off-procedure URL before fetch: $u');
              continue;
            }
            unique.add(u);
          }
          if (unique.isEmpty) return;
          final rows = await Future.wait([
            for (final url in unique)
              () async {
                if (!isNonLiteralClinicPriceUrl(url)) {
                  await _fetchRawHtml(url);
                }
                final text = await cachedFetch(
                  url,
                  allowRender: _looksLikePricePageUrl(url),
                );
                return (url: url, text: text);
              }(),
          ]);
          for (final row in rows) {
            considerPage(row.url, row.text);
          }
        }

        Future<void> trySerpApi(String reason) async {
          if (_serpApiLastRateLimited) {
            debugPrint(
              '[GP] Discovery fallback skipped · already 429 (${clinic.name})',
            );
            return;
          }
          debugPrint('[GP] Direct scrape inconclusive');
          debugPrint('[GP] Discovery fallback: ${clinic.name}');
          final bestUrl = await _serpApiPriceFallback(
            clinic: clinic,
            procedure: procedure,
            city: city,
            host: domainKey,
          );
          final junkUrl =
              bestUrl.isNotEmpty && _serpApiUrlIsJunk(bestUrl, procedure);
          final homeOnly =
              bestUrl.isNotEmpty && _urlIsClinicHomepage(bestUrl, domainKey);
          if (homeOnly) {
            debugPrint(
              '[GP] Discovery homepage only — skip re-fetch (${clinic.name})',
            );
            _refundLiveSerpApi();
          }
          if (junkUrl) {
            debugPrint(
              '[GP] Discovery junk URL — skipped (${clinic.name}): $bestUrl',
            );
          }
          // Discovery picked the clinic's own price page: fetch it, and let a
          // 403 or JS shell go through the headless renderer. Search snippets
          // are never used as price text — only this page is.
          if (bestUrl.isNotEmpty &&
              !homeOnly &&
              !junkUrl &&
              !_urlConflictsWithSearchedProcedure(bestUrl, procedure)) {
            final page = await cachedFetch(bestUrl, allowRender: true);
            if (page.isNotEmpty) {
              considerPage(bestUrl, page);
            }
          }
        }

        await fetchUrls(priorityUrls);

        // Any listed procedure price on the fetched HTML is enough.
        // Do not wait for a Google snippet amount such as 499 or 1,500.
        if (requireWebsiteConfirm &&
            bestText.isNotEmpty &&
            !isBotoxSpecialtyLanding(bestSourceUrl ?? '')) {
          final fromHtml = _clinicFromDeterministicEvidence(
            clinic: clinic,
            procedure: procedure,
            preferredUrl: bestSourceUrl ?? '',
            city: city,
          );
          if (fromHtml != null &&
              !isBotoxSpecialtyLanding(fromHtml.priceSourceUrl)) {
            debugPrint(
              '[GP] HTML evidence for ${clinic.name}: '
              '${fromHtml.priceLabel}',
            );
            return fromHtml;
          }
        }

        if (bestText.isNotEmpty && bestText.length < 600) {
          debugPrint(
            '[GP] Thin/JS home page: $domainKey '
            '(${bestText.length} chars) — more URLs before SerpApi',
          );
        }

        final verifyDeadline = DateTime.now().add(_kClinicVerifyBudget);

        // Phase 2: only if phase 1 returned thin/no content, try fallbacks
        final hasSolidPriceList = isSolidPublishedPricePage(
          bestSourceUrl ?? '',
          bestText,
        );
        if (!hasSolidPriceList &&
            bestText.length < 400 &&
            DateTime.now().isBefore(verifyDeadline)) {
          await fetchUrls(fallbackUrls.take(2).toList());
        }

        // Phase 3: sitemap.xml + internal links, scored with locale price words.
        final alreadyHasPriceList = isSolidPublishedPricePage(
          bestSourceUrl ?? '',
          bestText,
        );
        if (!alreadyHasPriceList &&
            DateTime.now().isBefore(verifyDeadline) &&
            (bestText.length < 400 || pageOffersThis(bestText))) {
          debugPrint(
            '[GP] ${bestText.length < 3000 ? "Thin content" : "Confirm scrape"} '
            '— discovering price links for ${clinic.name}',
          );
          try {
            final sitemapUrls = await exploreDiscoverSitemapUrls(
              hostOrBase: domainKey,
            );
            final homeHtml = await cachedFetch(base);
            final internal = homeHtml.isEmpty
                ? const <String>[]
                : _discoverInternalLinks(
                    html: homeHtml,
                    baseUrl: base,
                    addGuessedPriceFallbacks: false,
                  );
            debugPrint(
              '[GP] Discovered sitemap=${sitemapUrls.length} '
              'internal=${internal.length} for ${clinic.name}',
            );
            final ranked = exploreRankClinicPriceUrls(
              [...sitemapUrls, ...internal],
              city: city,
              procedure: procedure,
              host: domainKey,
              // Ranked wider than the 3 we fetch so dropping off-procedure
              // links still leaves 3 real candidates behind them.
              max: 8,
            );
            // Filter before the take, or an off-procedure link still costs
            // one of the three slots it is about to be dropped from.
            final usable = [
              for (final u in ranked)
                if (!isOffProcedureUrl(u)) u,
            ];
            debugPrint(
              '[GP] Scored links for ${clinic.name}: '
              '${usable.take(5).join(", ")}'
              '${usable.length < ranked.length ? " (${ranked.length - usable.length} off-procedure)" : ""}',
            );
            await fetchUrls(usable.take(3).toList());
          } catch (_) {}
        }

        // SerpApi when we still need a dedicated price/procedure URL.
        // Do not skip just because the homepage omits the keyword — many
        // ES clinics only name Botox/laser on inner pages.
        final pageHasPrices = _pageHasPricedAmounts(bestText);
        final hasDedicatedPricePage =
            urlLooksLikeThisProcedure(bestSourceUrl ?? '') ||
            (_priceLinkScore(
                      bestSourceUrl ?? '',
                      city: city,
                      procedure: procedure,
                    ) >=
                    3 &&
                bestText.length >= 800);
        if (!hasDedicatedPricePage &&
            (_isSessionBlockedHost(domainKey) ||
                bestText.length < 400 ||
                !pageHasPrices ||
                !pageOffersThis(bestText))) {
          if (bestText.isNotEmpty && bestText.length < 600) {
            _jsRenderedDomains.add(domainKey);
          }
          if (_isSessionBlockedHost(domainKey)) {
            debugPrint(
              '[GP] Discovery fallback skipped — host blocked '
              '(${clinic.name})',
            );
          } else {
            final reason = !pageOffersThis(bestText)
                ? 'homepage_no_procedure'
                : (pageHasPrices ? 'thin/empty page' : 'no_price_amounts');
            await trySerpApi(reason);
          }
        }

        // Firecrawl fallback only when HTTP + internal links + Serper still
        // have no procedure-matched evidence. Map returns URLs; scrape/PDF
        // bodies go through extractPriceEvidence — never a Firecrawl price.
        {
          final already = await _clinicFromDeterministicEvidenceAsync(
            clinic: clinic,
            procedure: procedure,
            preferredUrl: bestSourceUrl ?? '',
            city: city,
          );
          if (already != null) {
            debugPrint(
              '[GP] HTML evidence for ${clinic.name}: '
              '${already.priceLabel} (pre-firecrawl)',
            );
            return already;
          }
          if (!allowDeepFallbacks) {
            debugPrint(
              '[GP] Skip deep fallbacks (interactive) · ${clinic.name}',
            );
          } else {
            final fromFirecrawl = await _tryFirecrawlClinicPriceFallback(
              clinic: clinic,
              procedure: procedure,
              city: city,
              domainKey: domainKey,
              baseUrl: base,
              considerPage: considerPage,
              cachedFetch: cachedFetch,
            );
            if (fromFirecrawl != null) return fromFirecrawl;

            final fromZyte = await _tryZyteClinicPriceFallback(
              clinic: clinic,
              procedure: procedure,
              city: city,
              domainKey: domainKey,
              preferredUrl: bestSourceUrl ?? base,
              considerPage: considerPage,
              pageLooksBlocked:
                  _isSessionBlockedHost(domainKey) ||
                  bestText.length < 400 ||
                  !pageHasPrices,
            );
            if (fromZyte != null) return fromZyte;
          }
        }

        if (bestText.isNotEmpty) {
          final htmlEvidence = _clinicFromDeterministicEvidence(
            clinic: clinic,
            procedure: procedure,
            preferredUrl: bestSourceUrl ?? '',
            city: city,
          );
          if (htmlEvidence != null) {
            debugPrint(
              '[GP] HTML evidence for ${clinic.name}: '
              '${htmlEvidence.priceLabel} (skip GPT extract)',
            );
            return htmlEvidence;
          }

          if (requireWebsiteConfirm &&
              bestText.length >= 400 &&
              !pageOffersThis(bestText)) {
            return rejectUnverified(
              'site_does_not_offer_procedure',
              offersProcedure: false,
            );
          }

          if (!isHighTicketExploreProcedure(procedure) &&
              _pageHasPricedAmounts(bestText)) {
            final fromHtml = _clinicFromDeterministicEvidence(
              clinic: clinic,
              procedure: procedure,
              preferredUrl: bestSourceUrl ?? '',
              city: city,
            );
            if (fromHtml != null) {
              debugPrint(
                '[GP] Early HTML evidence for ${clinic.name}: '
                '${fromHtml.priceLabel} (skip GPT extract)',
              );
              return fromHtml;
            }
            final earlyProse = _findProcedurePriceInProse(
              pageText: bestText,
              procedure: procedure,
              brand: clinic.brand,
            );
            if (earlyProse != null &&
                isJustifiedProcedurePriceValue(
                  priceMin: earlyProse.priceMin,
                  currency: earlyProse.currency,
                  procedure: procedure,
                )) {
              final verified = await _verifyClinicPriceFromPage(
                clinic: clinic,
                procedure: procedure,
                pageText: bestText,
                sourceUrl: bestSourceUrl ?? '',
                candidateAmount: earlyProse.priceMin,
                candidateCurrency: earlyProse.currency,
                city: city,
              );
              if (verified != null) {
                debugPrint(
                  '[GP] Early prose price for ${clinic.name}: '
                  '${verified.priceLabel} (skip GPT extract)',
                );
                return verified;
              }
            }
          }

          debugPrint(
            '[GP] Skip legacy GPT procedure-list extraction '
            '(${clinic.name})',
          );
          final extracted = const <OpenAIProfileProcedureRow>[];
          final normalizedProc = _normalizeProcSync(procedure).toLowerCase();
          // Extract the single most identifying keyword from the procedure
          // Used for loose matching against composite procedure names
          // e.g. "PRP therapy" → "prp", "Lip filler" → "filler",
          //      "HIFU face lift" → "hifu", "Laser CO2" → "laser"
          final _coreKeywordMap = <String, String>{
            'hair transplant': 'hair transplant',
            'transplant de par': 'hair transplant',
            'implant capilar': 'hair transplant',
            'injerto capilar': 'hair transplant',
            'fue': 'hair transplant',
            'dhi': 'hair transplant',
            'lip filler': 'filler',
            'acid hialuronic': 'filler',
            'acid buze': 'filler',
            'filler buze': 'filler',
            'marire buze': 'filler',
            'mărire buze': 'filler',
            'volumizare buze': 'filler',
            'contur buze': 'filler',
            'prp': 'prp',
            'botox': 'botox',
            'filler': 'filler',
            'hifu': 'hifu',
            'laser': 'laser',
            'epilare': 'laser',
            'microneedling': 'microneedling',
            'dermapen': 'dermapen',
            'mesotherapy': 'mesotherapy',
            'morpheus': 'morpheus',
            'thread': 'thread',
            'polynucleotide': 'polynucleotide',
            'polinucleotide': 'polynucleotide',
            'exosome': 'exosome',
            'skinbooster': 'skinbooster',
            'profhilo': 'profhilo',
            'sculptra': 'sculptra',
            'chemical peel': 'peel',
            'chemical': 'peel',
            'peeling': 'peel',
            'peel': 'peel',
            'rhinoplasty': 'rhinoplasty',
            'rinoplast': 'rhinoplasty',
            'nose job': 'rhinoplasty',
            'breast augmentation': 'breast',
            'boob job': 'breast',
            'marire sani': 'breast',
            'mărire sâni': 'breast',
            'implant mamar': 'breast',
            'implanturi mamare': 'breast',
            'augmentare mamară': 'breast',
            'aumento de pecho': 'breast',
            'aumento pecho': 'breast',
            'aumento mamario': 'breast',
          };

          String? coreKeyword;
          for (final entry in _coreKeywordMap.entries) {
            if (normalizedProc.contains(entry.key)) {
              coreKeyword = entry.value;
              break;
            }
          }
          if (coreKeyword == null) {
            coreKeyword = exploreCoreKeywordForProcedure(procedure);
          }
          if (coreKeyword == null) {
            final meaningful = normalizedProc
                .split(RegExp(r'[\s\+\-\/]+'))
                .where((t) => t.length > 2)
                .toList();
            if (meaningful.isNotEmpty) {
              coreKeyword = meaningful.first;
            }
          }

          debugPrint('[GP] Core keyword for "$procedure": "$coreKeyword"');
          debugPrint(
            '[GP] Matching procedure: "$procedure" → normalized: "$normalizedProc"',
          );
          debugPrint(
            '[GP] Extracted procedure names: '
            '${extracted.map((p) => "${p.name}(${p.priceMin})").take(10).join(", ")}',
          );

          OpenAIProfileProcedureRow? match;

          if (coreKeyword != null) {
            final ck = coreKeyword;
            final synonymMap = {
              'hair transplant': [
                'fue',
                'dhi',
                'graft',
                'grafts',
                'follicle',
                'capilar',
                'capilary',
                'transplant de par',
                'transplant păr',
                'implant de par',
                'implant par',
                'implant capilar',
                'injerto capilar',
                'trapianto',
                'greffe',
                'saç ekimi',
                'hair implant',
                'scalp',
                'per graft',
                '/graft',
              ],
              'prp': [
                'plasma',
                'plasmă',
                'trombocite',
                'platelet',
                'vampire',
                'vampir',
                'bogată',
                'prfm',
                'prf',
              ],
              'botox': [
                'toxină',
                'toxina',
                'botulinică',
                'botulinum',
                'dysport',
                'vistabel',
                'xeomin',
                'anti-rid',
                'neuromodul',
                'neuromodulator',
                'neuromodulador',
                'arruga',
                'arrugas',
                'antiarrugas',
                'wrinkle',
              ],
              'filler': [
                'filler',
                'relleno',
                'rellenos',
                'acid hialuronic',
                'hialuronic',
                'hyaluronic',
                'acid buze',
                'filler buze',
                'marire buze',
                'mărire buze',
                'volumizare buze',
                'contur buze',
                'labio',
                'labios',
                'lips',
                'aumento de labios',
                'perfilado de labios',
                'juvederm',
                'restylane',
                'belotero',
                'teosyal',
                'volbella',
                'volift',
                'voluma',
                'revolax',
              ],
              'hifu': [
                'hifu',
                'ultraformer',
                'ultherapy',
                'ulthera',
                'focused ultrasound',
                'ultrasound lifting',
                'lifting ultrasound',
                'smas lifting',
                'smas',
                'ultrason',
                'ultrasônico',
                'ultrasonik',
                'fus ',
              ],
              'microneedling': ['dermapen', 'skinpen', 'microac'],
              'mesotherapy': ['mezoterapie', 'mezo'],
              'laser': ['co2', 'fractional', 'fraxel', 'fractionat'],
              'peel': [
                'peel',
                'peeling',
                'químico',
                'quimico',
                'chimic',
                'glycolic',
                'glicolico',
                'tca',
                'jessner',
                'chemical peel',
              ],
              'rhinoplasty': [
                'rinoplast',
                'rinoplastia',
                'rinoplastie',
                'nose job',
                'nasal surgery',
                'septoplast',
              ],
              'polynucleotide': [
                'polinucleotid',
                'polynucleotid',
                'pdrn',
                'nucleofill',
                'newest',
                'rejuran',
                ' pn ',
                'juvelook',
                'lenisna',
                'vitaran',
                'ameela',
              ],
              'thread': [
                'fire pdo',
                'fir tensor',
                'lifting fire',
                'fire tensoare',
              ],
              'morpheus': [
                'rf microneedling',
                'radiofrequency',
                'radiofrecvență',
              ],
              'exosome': ['exozomi', 'exosomes', 'exosom'],
              'skinbooster': [
                'skin booster',
                'volite',
                'aquagold',
                'juvederm volite',
              ],
              'breast': [
                'breast augmentation',
                'breast implant',
                'breast implants',
                'implant mamar',
                'implanturi mamare',
                'marire sani',
                'mărire sâni',
                'marire san',
                'augmentare mamara',
                'augmentare mamară',
                'protesi al seno',
                'mastoplastica additiva',
                'aumento de pecho',
                'aumento pecho',
                'aumento mamario',
                'aumento de mamas',
                'augmentation mammaire',
                'prothèse mammaire',
                'prothese mammaire',
                'prothèses mammaires',
                'implant mammaire',
                'implants mammaires',
                'mammaire',
                'mammaires',
                'lipofilling mammaire',
              ],
              'skin': [
                'profhilo',
                'skin booster',
                'skinbooster',
                'polynucleotide',
                'polinucleotide',
                'pdrn',
                'hydrafacial',
                'biostimulator',
                'mesotherapy',
                'mezoterapie',
                'exosome',
                'volite',
                'sunekos',
                'hifu',
                'microneedling',
                'dermapen',
              ],
            };
            final synonyms = exploreSynonymsForCoreKeyword(
              ck,
              extra: synonymMap,
            );

            bool rowMatchesName(OpenAIProfileProcedureRow p) {
              if (_extractedRowIsWrongCategory(
                rowName: p.name,
                procedure: procedure,
              )) {
                return false;
              }
              final wantFam = exploreTreatmentFamily(procedure);
              final gotFam = exploreTreatmentFamily('${p.name} ${p.detail}');
              if (wantFam != ExploreTreatmentFamily.other &&
                  wantFam == gotFam) {
                return true;
              }
              if (_extractedRowMatchesProcedure(
                rowName: p.name,
                procedure: procedure,
                brand: clinic.brand,
              )) {
                return true;
              }
              final pLo = p.name.toLowerCase();
              if (pLo == normalizedProc || pLo == ck) return true;
              if (_windowHasKeyword(pLo, ck)) return true;
              if (pLo.startsWith(ck) && ck.length >= 4) return true;
              return synonyms.any((s) => _textHasSynonym(pLo, s));
            }

            final pricedMatches = extracted
                .where(
                  (p) =>
                      p.priceMin > 0 &&
                      rowMatchesName(p) &&
                      !_extractedRowLooksLikePromo(p),
                )
                .toList();
            if (pricedMatches.isNotEmpty) {
              final anatomyMatches = pricedMatches
                  .where(
                    (p) => _extractedRowMatchesProcedure(
                      rowName: p.name,
                      procedure: procedure,
                      brand: clinic.brand,
                    ),
                  )
                  .toList();
              final justifiedPool =
                  (anatomyMatches.isNotEmpty ? anatomyMatches : pricedMatches)
                      .where(
                        (p) => isJustifiedProcedurePriceValue(
                          priceMin: p.priceMin,
                          currency: _currencyForScrapedRow(
                            priceLabel: p.priceLabel,
                            pageText: bestText,
                            city: city,
                            procedure: procedure,
                            amount: p.priceMin,
                            claimedCurrency: clinic.currency,
                          ),
                          procedure: procedure,
                          evidence: '${p.name} ${p.priceLabel} ${p.detail}',
                        ),
                      )
                      .toList();
              var pickFrom = justifiedPool.isNotEmpty
                  ? justifiedPool
                  : (anatomyMatches.isNotEmpty
                        ? anatomyMatches
                        : pricedMatches);
              // Prefer the standard / base treatment over a 1-zone or
              // single-area line item when the search did not ask for a
              // zone count.
              final wantedZones = _zoneCountHint(procedure);
              if (wantedZones != null) {
                final zoned = pickFrom
                    .where((p) => _zoneCountHint(p.name) == wantedZones)
                    .toList();
                if (zoned.isNotEmpty) pickFrom = zoned;
              }
              final wantFam = exploreTreatmentFamily(procedure);
              if (wantFam != ExploreTreatmentFamily.other) {
                final familyRows = pickFrom
                    .where((p) => exploreTreatmentFamily(p.name) == wantFam)
                    .toList();
                if (familyRows.isNotEmpty) pickFrom = familyRows;
              }
              final brandLo = clinic.brand.toLowerCase();
              if (brandLo.contains('chimic') || brandLo.contains('chemical')) {
                final chimic = pickFrom.where((p) {
                  final n = p.name.toLowerCase();
                  return n.contains('chimic') || n.contains('chemical');
                }).toList();
                if (chimic.isNotEmpty) pickFrom = chimic;
              }
              if (wantFam == ExploreTreatmentFamily.laser) {
                pickFrom = _preferLaserHairRemovalStartingRows(pickFrom);
              }
              final procLo = procedure.toLowerCase();
              if (isHairExploreProcedure(procedure) && procLo.contains('fue')) {
                final fueRows = pickFrom
                    .where((p) => p.name.toLowerCase().contains('fue'))
                    .toList();
                if (fueRows.isNotEmpty) pickFrom = fueRows;
              }
              pickFrom.sort(
                (a, b) => _compareExtractedProcedureRows(a, b, procedure),
              );
              match = pickFrom.first;
              debugPrint(
                '[GP] Priced row match: "${match.name}" = ${match.priceMin} '
                '(${pricedMatches.length} candidates)',
              );
            } else {
              // Keep a name-only match for logs; price stays unused.
              for (final p in extracted) {
                if (rowMatchesName(p)) {
                  match = p;
                  debugPrint('[GP] Name match without price: "${p.name}"');
                  break;
                }
              }
            }

            // De-prefer combo/package treatments — user wants
            // standalone procedure price
            if (match != null && match.priceMin > 0) {
              final chosenMatch = match;
              final comboPatterns = RegExp(
                r'\+|\bsi\b|\band\b|\bpackage\b|\bcombo\b|\bset\b'
                r'|\bpachet\b|\bsedinta\b|\bprotocol\b|\bsesiune\b'
                r'|\bsession\b',
                caseSensitive: false,
              );

              final isMenuAlternatives = chosenMatch.name.contains('/');
              if (comboPatterns.hasMatch(chosenMatch.name) &&
                  !isMenuAlternatives) {
                final standalone = pricedMatches.where((p) {
                  return !comboPatterns.hasMatch(p.name) &&
                      p.priceMin > 0 &&
                      p.priceMin <= chosenMatch.priceMin;
                }).toList();

                if (standalone.isNotEmpty) {
                  standalone.sort(
                    (a, b) => _compareExtractedProcedureRows(a, b, procedure),
                  );
                  debugPrint(
                    '[GP] Replaced combo "${chosenMatch.name}" '
                    '(${chosenMatch.priceMin}) with standalone '
                    '"${standalone.first.name}" '
                    '(${standalone.first.priceMin})',
                  );
                  match = standalone.first;
                }
              }
            }
          }

          if (match == null) {
            debugPrint(
              '[GP] No price match found for "$procedure" '
              '(core: "$coreKeyword") in ${extracted.length} procedures',
            );
          }
          if (match != null &&
              match.priceMin > 0 &&
              isJustifiedProcedurePriceValue(
                priceMin: match.priceMin,
                currency: _currencyForScrapedRow(
                  priceLabel: match.priceLabel,
                  pageText: bestText,
                  city: city,
                  procedure: procedure,
                  amount: match.priceMin,
                  claimedCurrency: clinic.currency,
                ),
                procedure: procedure,
                evidence: '${match.name} ${match.priceLabel} ${match.detail}',
              )) {
            final scrapedCur = _scrapedCurrencyDecision(
              priceLabel: match.priceLabel,
              pageText: bestText,
              city: city,
              procedure: procedure,
              amount: match.priceMin,
              claimedCurrency: clinic.currency,
            );
            _logScrapedCurrencySource(clinic.name, scrapedCur);
            final currency = scrapedCur.code;
            final label = _formatScrapedPriceLabel(
              match.priceMin,
              match.priceMax,
              currency,
            );
            debugPrint(
              '[GP] Price match found on page for ${clinic.name} '
              '(${bestSourceUrl ?? "?"}) "${match.name}" = ${match.priceMin}',
            );
            debugPrint('[GP] HTTP price found for ${clinic.name}: $label');
            final confirmedRow = await _verifyClinicPriceFromPage(
              clinic: clinic.copyWith(
                priceMin: match.priceMin,
                priceMax: match.priceMax > 0 ? match.priceMax : match.priceMin,
                priceLabel: label,
                currency: currency,
                brand:
                    match.name.trim().isNotEmpty &&
                        !isBroadExploreCategoryName(match.name)
                    ? match.name.trim()
                    : clinic.brand,
              ),
              procedure: procedure,
              pageText: bestText,
              sourceUrl: bestSourceUrl ?? '',
              candidateAmount: match.priceMin,
              candidateCurrency: currency,
              city: city,
            );
            if (confirmedRow != null) {
              debugPrint('[GP] Direct price verified: ${clinic.name}');
              return confirmedRow;
            }
          }

          // Only try AI search if the page was truly blank/unreachable.
          // If we fetched real content but found no price match,
          // a search-preview AI call won't help and costs ~$0.04 per clinic.
          final pageWasBlank = bestText.length < 500;
          if (!pageWasBlank) {
            final anyPricedRow = extracted.any((p) => p.priceMin > 0);
            // Sōma listed 24 other treatments and no rhinoplasty; prose still
            // grabbed a 2000 € number near "nose". If the price list exists
            // without this surgery, do not invent it from nearby text.
            final skipProse =
                isHighTicketExploreProcedure(procedure) && anyPricedRow;
            if (!skipProse) {
              final prose = _findProcedurePriceInProse(
                pageText: bestText,
                procedure: procedure,
                brand: clinic.brand,
              );
              if (prose != null &&
                  isJustifiedProcedurePriceValue(
                    priceMin: prose.priceMin,
                    currency: prose.currency,
                    procedure: procedure,
                  )) {
                final verified = await _verifyClinicPriceFromPage(
                  clinic: clinic,
                  procedure: procedure,
                  pageText: bestText,
                  sourceUrl: bestSourceUrl ?? '',
                  candidateAmount: prose.priceMin,
                  candidateCurrency: prose.currency,
                  city: city,
                );
                if (verified != null) {
                  debugPrint(
                    '[GP] price decision for ${clinic.name}: replace '
                    'ai=${clinic.priceMin} ${clinic.currency} → '
                    'page=${verified.priceMin} ${verified.currency} '
                    'reason=prose_match',
                  );
                  return verified;
                }
              }
            }

            // Site was readable. If it never mentions this treatment,
            // the AI invented the clinic↔procedure pairing (Bellezza + Botox).
            final offers = _pageOffersProcedure(
              bestText,
              procedure: procedure,
              brand: clinic.brand,
            );
            // LLM prose fallback. Deterministic tabular extraction fails on
            // sites that price treatments in narrative form
            // (Novomed: "The cost of chemical peel in Abu Dhabi starts from
            // AED 700"). Only fire if the page actually offers this
            // treatment, is not high-ticket surgery, and there was no
            // stronger row-level price already.
            if (offers &&
                !anyPricedRow &&
                !isHighTicketExploreProcedure(procedure) &&
                bestText.length >= 500) {
              final llm = await _extractProcedurePriceWithLlm(
                pageText: bestText,
                procedure: procedure,
                clinicName: clinic.name,
                sourceUrl: bestSourceUrl ?? '',
              );
              if (llm != null &&
                  isJustifiedProcedurePriceValue(
                    priceMin: llm.priceMin,
                    currency: llm.currency,
                    procedure: procedure,
                  )) {
                final verified = await _verifyClinicPriceFromPage(
                  clinic: clinic,
                  procedure: procedure,
                  pageText: bestText,
                  sourceUrl: bestSourceUrl ?? '',
                  candidateAmount: llm.priceMin,
                  candidateCurrency: llm.currency,
                  city: city,
                );
                if (verified != null) {
                  debugPrint(
                    '[GP] LLM narrative semantic extraction for ${clinic.name}: '
                    '${llm.priceMin} ${llm.currency} · "${llm.sourceQuote}"',
                  );
                  return verified;
                }
              }
            }
            debugPrint(
              '[GP] HTTP found content but no price match for '
              '${clinic.name} — skipping AI fallback '
              '(any_priced_rows=$anyPricedRow offers=$offers)',
            );
            if (!offers && bestText.length >= 400) {
              return rejectUnverified(
                'site_does_not_offer_procedure',
                offersProcedure: false,
              );
            }
            // This treatment is listed without a number — even if laser
            // or another row already has a price (Zeugma + Botox).
            final thisProcUnpriced = match == null || match.priceMin <= 0;
            if (offers && thisProcUnpriced) {
              final beforeUrl = bestSourceUrl ?? '';
              final beforeLen = bestText.length;
              await trySerpApi('offers_no_listed_price');
              final improved =
                  (bestSourceUrl ?? '') != beforeUrl ||
                  bestText.length != beforeLen;
              if (improved) {
                final retryHtml = _clinicFromDeterministicEvidence(
                  clinic: clinic,
                  procedure: procedure,
                  preferredUrl: bestSourceUrl ?? '',
                  city: city,
                );
                if (retryHtml != null) return retryHtml;
                final prose2 = _findProcedurePriceInProse(
                  pageText: bestText,
                  procedure: procedure,
                  brand: clinic.brand,
                );
                if (prose2 != null &&
                    isJustifiedProcedurePriceValue(
                      priceMin: prose2.priceMin,
                      currency: prose2.currency,
                      procedure: procedure,
                    )) {
                  final verified2 = await _verifyClinicPriceFromPage(
                    clinic: clinic,
                    procedure: procedure,
                    pageText: bestText,
                    sourceUrl: bestSourceUrl ?? '',
                    candidateAmount: prose2.priceMin,
                    candidateCurrency: prose2.currency,
                    city: city,
                  );
                  if (verified2 != null) return verified2;
                }
              }
            }
            if (_pageSaysContactForPrice(bestText) && !anyPricedRow) {
              return rejectUnverified('contact_for_price');
            }
            if (clinic.priceMin > 0) {
              return rejectUnverified(
                anyPricedRow
                    ? 'site_lists_other_prices_not_this_one'
                    : 'no_prices_on_page',
              );
            }
            if (clinic.pricePending) {
              return clinic.copyWith(
                priceMin: 0,
                priceMax: 0,
                priceLabel: '',
                pricePending: false,
              );
            }
            return clinic;
          }
        }

        if (requireWebsiteConfirm) {
          return rejectUnverified(
            bestText.length >= 400
                ? 'page_unreadable_or_no_price'
                : 'page_blocked_or_empty',
          );
        }

        // Do not ask GPT to "find" a price we already claimed — that is
        // how invented numbers get a second chance. Only search when the
        // clinic arrived with no price at all.
        if (clinic.priceMin > 0) {
          return rejectUnverified('unconfirmed_claimed_price');
        }

        // HTTP failed (JS-rendered site) — do not ask an LLM for a number.
        debugPrint(
          '[GP] HTTP found no prices for ${clinic.name} '
          '— not using AI price search',
        );
        debugPrint('[GP EXTRACT] rendering_required ${clinic.name}');

        if (clinic.pricePending) {
          return clinic.copyWith(
            priceMin: 0,
            priceMax: 0,
            priceLabel: '',
            pricePending: false,
          );
        }
        return clinic;
      } catch (_) {
        if (requireWebsiteConfirm && clinic.priceMin > 0) {
          return rejectUnverified('fetch_exception');
        }
        return clinic;
      }
    }

    final results = List<OpenAIClinic?>.filled(needsPrice.length, null);
    var nextIndex = 0;
    var active = 0;
    Future<void> runWorker() async {
      while (true) {
        if (stopIf?.call() == true) return;
        final i = nextIndex;
        if (i >= needsPrice.length) return;
        nextIndex++;
        active++;
        final waiting = needsPrice.length - nextIndex;
        debugPrint(
          '[GP] Verification queue: $active active / '
          '${waiting < 0 ? 0 : waiting} waiting',
        );
        debugPrint('[GP] Verify candidate: ${needsPrice[i].name}');
        try {
          final c = await ExploreRequestCoordinator.instance.runClinicVerify(
            clinicKey:
                '${exploreClinicDedupKey(needsPrice[i])}|'
                '${procedure.trim().toLowerCase()}',
            // Re-checked *inside* the gate, which is where a queued candidate
            // finally gets its slot. Switching pills used to abandon only the
            // dispatch loop, so candidates already waiting still ran a full
            // scrape for a tab nobody was looking at — and starved the pill
            // the user had just opened.
            run: () async {
              if (stopIf?.call() == true) return needsPrice[i];
              return verifyClinic(needsPrice[i]);
            },
          );
          results[i] = c;
          onClinicDone?.call(c);
        } catch (e) {
          debugPrint('[GP] Verify candidate failed: ${needsPrice[i].name}: $e');
          results[i] = needsPrice[i];
        } finally {
          active--;
        }
      }
    }

    final workers = math.min(_kClinicVerifyConcurrency, needsPrice.length);
    await Future.wait([for (var w = 0; w < workers; w++) runWorker()]);
    final done = [
      for (var i = 0; i < needsPrice.length; i++) results[i] ?? needsPrice[i],
    ];

    final enrichedMap = Map.fromEntries(done.map((c) => MapEntry(c.name, c)));

    return [
      for (final c in clinics)
        enrichedMap[c.name] ??
            ((requireWebsiteConfirm && c.priceMin > 0)
                ? _clearedUnverifiedPrice(c)
                : c),
    ];
  }

  OpenAIClinic _clearedUnverifiedPrice(
    OpenAIClinic clinic, {
    String reason = 'revalidation_rejected',
  }) {
    debugPrint(
      '[GP] Unverified AI price cleared: ${clinic.name} '
      '(was ${clinic.priceMin} ${clinic.currency}) · $reason',
    );
    return clinic.copyWith(
      priceMin: 0,
      priceMax: 0,
      priceGbp: 0,
      priceLabel: '',
      pricePending: true,
      priceVerificationStatus: PriceVerificationStatus.unverified,
      priceVerificationConfidence: 0,
      priceRejectionReason: reason,
      lastCheckedAt: DateTime.now().toUtc(),
    );
  }

  OpenAIClinic _markVerifiedProcedurePrice(
    OpenAIClinic clinic, {
    required double priceMin,
    required String currency,
    required String sourceUrl,
    required String evidence,
    required PriceVerificationStatus status,
    double confidence = 1.0,
    String priceLabel = '',
    double? priceMax,
    ExtractedPriceEvidence? priceEvidence,
    String procedureRelation = '',
  }) {
    final now = DateTime.now().toUtc();
    final url = sourceUrl.trim();
    final max = (priceMax != null && priceMax >= priceMin)
        ? priceMax
        : priceMin;
    var label = priceLabel;
    if (label.isEmpty) {
      final unit = priceEvidence?.unit.trim().toLowerCase() ?? '';
      final perUnit =
          priceEvidence?.priceType == PriceType.perUnit ||
          unit == 'unit' ||
          unit == 'iu' ||
          unit == 'units';
      final variesWithAreas =
          RegExp(
            r'varies\s+with\s+(?:the\s+)?(?:number\s+of\s+)?(?:areas?|zones?)',
            caseSensitive: false,
          ).hasMatch(
            '${priceEvidence?.rawPriceText ?? ''} ${priceEvidence?.rawEvidence ?? ''}',
          );
      final graftUnit = unit == 'graft' || unit == 'grafts';
      final perGraft = looksLikePerGraftQuotedPrice(
        '${priceEvidence?.rawPriceText ?? ''} ${priceEvidence?.rawEvidence ?? ''}',
      );
      if (perUnit &&
          (isBotoxExploreProcedure(clinic.brand) ||
              isBotoxExploreProcedure(priceEvidence?.rawProcedureText ?? ''))) {
        label = formatBotoxPerUnitPriceLabel(priceMin, currency);
      } else if (!variesWithAreas &&
          !(graftUnit && !perGraft) &&
          (priceEvidence?.priceType == PriceType.perUnit ||
              priceEvidence?.priceType == PriceType.perArea ||
              unit.isNotEmpty)) {
        final suffix = unit.isNotEmpty
            ? '/${unit == 'units' || unit == 'iu'
                  ? 'unit'
                  : unit == 'areas'
                  ? 'area'
                  : unit}'
            : '';
        label = 'from ${priceMin.round()} $currency$suffix';
      } else {
        label =
            'from ${_formatPrice(priceMin, currency).replaceFirst(RegExp(r'^from\s+', caseSensitive: false), '')}';
        if (!label.toLowerCase().startsWith('from ')) {
          label = 'from $label';
        }
      }
    }
    final marked = clinic.copyWith(
      priceMin: priceMin,
      priceMax: max,
      priceGbp: priceMin.round(),
      priceLabel: label,
      currency: currency,
      currencyConfirmed: true,
      pricePending: false,
      hasProcedure: true,
      priceSourceUrl: url.isNotEmpty ? url : clinic.priceSourceUrl,
      priceEvidenceText: sanitizePriceEvidence(
        priceEvidence?.rawEvidence ?? evidence,
      ),
      priceVerificationStatus: status,
      priceVerificationConfidence: confidence,
      priceVerifiedAt: now,
      lastCheckedAt: now,
      priceRejectionReason: '',
      area: url.isNotEmpty ? _withSourceUrl(clinic.area, url) : clinic.area,
      rawProcedureText:
          priceEvidence?.rawProcedureText ?? clinic.rawProcedureText,
      rawPriceText: priceEvidence?.rawPriceText ?? clinic.rawPriceText,
      extractionMethod:
          priceEvidence?.extractionMethod.wire ?? clinic.extractionMethod,
      evidenceHash: priceEvidence?.evidenceHash ?? clinic.evidenceHash,
      priceType: priceEvidence?.priceType.wire ?? clinic.priceType,
      priceUnit: priceEvidence?.unit.isNotEmpty == true
          ? priceEvidence!.unit
          : clinic.priceUnit,
      priceQuantity: priceEvidence?.quantity ?? clinic.priceQuantity,
      sourceType: priceEvidence?.sourceType.wire ?? clinic.sourceType,
      procedureFamily: priceEvidence?.procedureFamily ?? clinic.procedureFamily,
      procedureCanonical:
          priceEvidence?.procedureCanonical ?? clinic.procedureCanonical,
      procedureDisplayName: exploreNormalizeProcedureDisplayName(
        procedureCanonical:
            priceEvidence?.procedureCanonical ?? clinic.procedureCanonical,
        procedureFamily:
            priceEvidence?.procedureFamily ?? clinic.procedureFamily,
        rawProcedureText:
            priceEvidence?.rawProcedureText ?? clinic.rawProcedureText,
        brand: clinic.brand,
      ),
      procedureDetail: exploreNormalizeProcedureDetail(
        priceEvidence?.rawProcedureText ?? clinic.rawProcedureText,
      ),
      procedureRelation: procedureRelation.trim().isNotEmpty
          ? procedureRelation.trim()
          : clinic.procedureRelation,
      priceExtractRevision: kExplorePriceExtractRevision,
    );
    final host = exploreClinicWebsiteHost(marked).isNotEmpty
        ? exploreClinicWebsiteHost(marked)
        : normalizeExploreHost(marked.priceSourceUrl);
    if (host.isNotEmpty && marked.priceSourceUrl.trim().isNotEmpty) {
      unawaited(
        ExploreSiteUrlCacheStore.instance.save(
          host: host,
          urls: [marked.priceSourceUrl],
          extractionMethod: marked.extractionMethod,
          procedureFamily: marked.procedureFamily,
          clinicName: marked.name,
          source: 'verified_price',
        ),
      );
    }
    return marked;
  }

  OpenAIClinic? _clinicFromDeterministicEvidence({
    required OpenAIClinic clinic,
    required String procedure,
    required String preferredUrl,
    Iterable<String> extraUrls = const [],
    String city = '',
  }) {
    // Sync path — AI relation classify is skipped; use async variant when needed.
    return _clinicFromDeterministicEvidenceSync(
      clinic: clinic,
      procedure: procedure,
      preferredUrl: preferredUrl,
      extraUrls: extraUrls,
      city: city,
    );
  }

  Future<OpenAIClinic?> _clinicFromDeterministicEvidenceAsync({
    required OpenAIClinic clinic,
    required String procedure,
    required String preferredUrl,
    Iterable<String> extraUrls = const [],
    String city = '',
  }) async {
    // Parse pending pages off the frame thread first; the sync readers below
    // (which also scan every cached page on this clinic's host) then hit the
    // cache instead of parsing a 175k-char menu on the UI isolate.
    final urls = _deterministicEvidenceUrls(
      clinic: clinic, preferredUrl: preferredUrl, extraUrls: extraUrls,
    );
    await ExploreHtmlPriceParseCache.instance.warmEvidence(urls);
    final sync = _clinicFromDeterministicEvidenceSync(
      clinic: clinic,
      procedure: procedure,
      preferredUrl: preferredUrl,
      extraUrls: extraUrls,
      city: city,
      allowAmbiguousForAi: true,
    );
    if (sync != null) return sync;
    // Retry with AI relation only when the best row was relation-ambiguous.
    final rows = <ExtractedPriceEvidence>[
      for (final url in urls)
        ...ExploreHtmlPriceParseCache.instance.evidenceFor(url),
    ];
    if (rows.isEmpty) return null;
    final picked = selectEvidenceForProcedure(rows: rows, procedure: procedure);
    if (picked == null) return null;
    final pageHtml =
        ExploreHtmlPriceParseCache.instance.htmlByUrl[picked.sourceUrl] ?? '';
    final lock = lockExplorePriceEvidence(
      candidate: picked,
      procedure: procedure,
      sourceHtmlOrText: pageHtml.isNotEmpty
          ? pageHtml
          : '${picked.rawEvidence}\n${picked.rawPriceText}',
      pageHasFamilyWitness: pageHasRequestedFamilyWitness(
        rows: rows,
        procedure: procedure,
      ),
    );
    if (!(lock.rejected &&
        lock.relation?.relation == ProcedureRelation.ambiguous)) {
      return null;
    }
    final aiRel = await _classifyProcedureRelationWithAi(
      procedure: procedure,
      label: picked.rawProcedureText,
      evidence: picked.rawEvidence,
    );
    if (aiRel == null || !aiRel.eligibleForFromPrice) return null;
    return _finalizeLockedEvidence(
      clinic: clinic,
      procedure: procedure,
      city: city,
      locked: picked,
      relation: aiRel,
    );
  }

  OpenAIClinic? _clinicFromDeterministicEvidenceSync({
    required OpenAIClinic clinic,
    required String procedure,
    required String preferredUrl,
    Iterable<String> extraUrls = const [],
    String city = '',
    bool allowAmbiguousForAi = false,
  }) {
    final urls = _deterministicEvidenceUrls(
      clinic: clinic, preferredUrl: preferredUrl, extraUrls: extraUrls,
    );
    if (urls.isEmpty) return null;
    final rows = <ExtractedPriceEvidence>[
      for (final url in urls)
        ...ExploreHtmlPriceParseCache.instance.evidenceFor(url),
    ];
    if (rows.isEmpty) return null;
    final picked = selectEvidenceForProcedure(rows: rows, procedure: procedure);
    if (picked == null) return null;
    if (picked.sourceType == PriceSourceType.searchSnippet) return null;

    final pageHtml =
        ExploreHtmlPriceParseCache.instance.htmlByUrl[picked.sourceUrl] ?? '';
    logPriceSource(
      picked.extractionMethod.wire.isNotEmpty
          ? picked.extractionMethod.wire
          : 'html_cache',
      url: picked.sourceUrl,
    );

    final lock = lockExplorePriceEvidence(
      candidate: picked,
      procedure: procedure,
      sourceHtmlOrText: pageHtml.isNotEmpty
          ? pageHtml
          : '${picked.rawEvidence}\n${picked.rawPriceText}',
      pageHasFamilyWitness: pageHasRequestedFamilyWitness(
        rows: rows,
        procedure: procedure,
      ),
    );
    if (!lock.accepted || lock.evidence == null || lock.relation == null) {
      if (allowAmbiguousForAi &&
          lock.relation?.relation == ProcedureRelation.ambiguous) {
        return null; // async path will AI-classify
      }
      return null;
    }
    return _finalizeLockedEvidence(
      clinic: clinic,
      procedure: procedure,
      city: city,
      locked: lock.evidence!,
      relation: lock.relation!,
    );
  }

  List<String> _deterministicEvidenceUrls({
    required OpenAIClinic clinic,
    required String preferredUrl,
    required Iterable<String> extraUrls,
  }) => ExploreHtmlPriceParseCache.instance.urlsForHost(
    host: _extractDomain(clinic.area),
    sourceUrls: [preferredUrl, ...extraUrls],
  );

  OpenAIClinic? _finalizeLockedEvidence({
    required OpenAIClinic clinic,
    required String procedure,
    required String city,
    required ExtractedPriceEvidence locked,
    required ProcedureRelationResult relation,
  }) {
    if (city.trim().isNotEmpty &&
        exploreQuotedPriceConflictsWithSearchCity(
          city: city,
          url: locked.sourceUrl,
          evidence:
              '${locked.rawProcedureText} ${locked.rawPriceText} ${locked.rawEvidence}',
        )) {
      logPriceReject('other_city_quote');
      return null;
    }
    final htmlForCity =
        ExploreHtmlPriceParseCache.instance.htmlByUrl[locked.sourceUrl] ?? '';
    final cityBlob =
        '${locked.rawProcedureText} ${locked.rawPriceText} ${locked.rawEvidence} '
        '${clinic.area} ${clinic.name} $htmlForCity';
    if (city.trim().isNotEmpty &&
        (exploreTextConflictsWithSearchCity(cityBlob, city) ||
            explorePlacesAddressConflictsWithSearchCity(clinic.area, city) ||
            exploreUrlConflictsWithSearchCity(locked.sourceUrl, city))) {
      logPriceReject('other_city_quote');
      return null;
    }
    final clinicHost = _stripWww(
      _normalizeProbeHost(_extractDomain(clinic.area)),
    );
    final srcHost = _stripWww(_normalizeProbeHost(locked.sourceUrl));
    final marketplaceSource =
        locked.sourceType == PriceSourceType.marketplace ||
        locked.sourceType == PriceSourceType.aggregator ||
        isMarketplaceOrDirectoryHost(locked.sourceUrl);
    if (!marketplaceSource &&
        clinicHost.isNotEmpty &&
        srcHost.isNotEmpty &&
        !_hostsSameDomainOrSubdomain(clinicHost, srcHost) &&
        !_hostsSameDomainOrSubdomain(srcHost, clinicHost)) {
      logPriceReject(
        'source_host_mismatch',
        detail: 'clinic=$clinicHost source=$srcHost',
      );
      return null;
    }
    var providerName = locked.providerClinic.trim();
    if (exploreClinicNameLooksLikeSeoHeadline(providerName) ||
        exploreClinicNameLooksLikeMarketingSlogan(providerName)) {
      providerName = '';
    }
    if (locked.sourceType == PriceSourceType.marketplace ||
        locked.sourceType == PriceSourceType.aggregator ||
        isMarketplaceOrDirectoryHost(locked.sourceUrl)) {
      if (providerName.isEmpty) {
        final html =
            ExploreHtmlPriceParseCache.instance.htmlByUrl[locked.sourceUrl] ??
            '';
        providerName = extractMarketplaceProviderName(
          html,
          sourceUrl: locked.sourceUrl,
          marketplaceName: clinic.name,
        );
      }
      if (providerName.isEmpty ||
          isMarketplaceBrandName(providerName) ||
          isGenericShopIdentity(providerName)) {
        logExploreDiscoveryReject(
          reason: 'marketplace_without_provider',
          placeId: clinic.placeId,
          name: clinic.name,
        );
        return null;
      }
      final pageBlob =
          '${locked.rawEvidence} ${locked.rawProcedureText} ${locked.rawPriceText}';
      if (!exploreMarketplaceLocationStronglyMatches(
        city: city,
        placeAddress: clinic.area,
        sourceUrl: locked.sourceUrl,
        pageText: pageBlob,
      )) {
        logExploreDiscoveryReject(
          reason: 'marketplace_location_mismatch',
          placeId: clinic.placeId,
          name: clinic.name,
        );
        return null;
      }
    }
    if (locked.sourceType == PriceSourceType.aggregator &&
        providerName.isEmpty) {
      logPriceReject('aggregator_without_provider', detail: locked.sourceUrl);
      return null;
    }
    final displayName = providerName.isNotEmpty ? providerName : clinic.name;
    if (looksLikeNonAestheticVenueName(displayName) ||
        !isUsableExploreClinicIdentity(
          name: displayName,
          websiteHost: locked.sourceUrl,
          providerClinic: providerName,
          sourceType:
              locked.sourceType == PriceSourceType.marketplace ||
                  locked.sourceType == PriceSourceType.aggregator ||
                  isMarketplaceOrDirectoryHost(locked.sourceUrl)
              ? 'marketplace'
              : clinic.sourceType,
        )) {
      logExploreDiscoveryReject(
        reason: 'wrong_business_type',
        placeId: clinic.placeId,
        name: displayName,
      );
      return null;
    }
    if (providerName.isNotEmpty &&
        clinic.name.trim().isNotEmpty &&
        !namesLookLikeSameProvider(clinic.name, providerName)) {
      debugPrint(
        '[GP] Marketplace identity rebind: ${clinic.name} → $providerName',
      );
    }
    logExtractedEvidence(locked, clinicName: clinic.name);
    if (!isJustifiedProcedurePriceValue(
      priceMin: locked.priceMin,
      currency: () {
        final c = locked.currency.isNotEmpty
            ? locked.currency
            : clinic.currency;
        if (c.trim().isNotEmpty) return c;
        return detectExploreCurrencyToken(
          '${locked.rawPriceText} ${locked.rawEvidence}',
        );
      }(),
      procedure: procedure,
      evidence:
          '${locked.rawProcedureText} ${locked.rawPriceText} ${locked.rawEvidence}',
    )) {
      logPriceReject(
        'unjustified_amount',
        detail: '${locked.priceMin} ${locked.currency}',
      );
      return null;
    }
    var min = locked.priceMin;
    var max = locked.priceMax >= min ? locked.priceMax : min;
    final pageText =
        ExploreHtmlPriceParseCache.instance.htmlByUrl[locked.sourceUrl] ?? '';
    final ladder = pageText.isEmpty
        ? null
        : _botoxPublishedMenuRange(_stripHtmlContent(pageText), procedure);
    if (ladder != null) {
      min = ladder.from;
      max = ladder.max;
    }
    logPriceAcceptLock(
      clinic: clinic.name,
      procedure: procedure,
      evidence: locked,
      relation: relation,
    );
    var acceptName = providerName.isNotEmpty ? providerName : clinic.name;
    final hostForName = normalizeExploreHost(locked.sourceUrl);
    final nameFold = foldExploreIdentityText(acceptName);
    final cityFold = foldExploreIdentityText(city);
    if (cityFold.isNotEmpty &&
        (nameFold == cityFold ||
            (RegExp(
                  r'^(?:ceni|цени|prices?|pricing|tarife|preturi)\b',
                  caseSensitive: false,
                ).hasMatch(nameFold) &&
                nameFold.contains(cityFold)))) {
      final fromHost = exploreClinicDisplayNameFromHost(hostForName);
      if (fromHost.isNotEmpty) acceptName = fromHost;
    }
    return _markVerifiedProcedurePrice(
      clinic.copyWith(
        name: acceptName,
        sourcePlatform: locked.sourcePlatform.isNotEmpty
            ? locked.sourcePlatform
            : (isMarketplaceOrDirectoryHost(locked.sourceUrl)
                  ? marketplacePlatformLabel(locked.sourceUrl)
                  : clinic.sourcePlatform),
        providerClinic: providerName,
        procedureRelation: relation.logToken,
      ),
      priceMin: min,
      priceMax: max,
      currency: () {
        if (locked.currency.trim().isNotEmpty) return locked.currency;
        if (clinic.currency.trim().isNotEmpty) return clinic.currency;
        return detectExploreCurrencyToken(
          '${locked.rawPriceText} ${locked.rawEvidence}',
        );
      }(),
      sourceUrl: locked.sourceUrl,
      evidence: '${locked.rawProcedureText} ${locked.rawPriceText}',
      status: () {
        final host = normalizeExploreHost(locked.sourceUrl);
        if (host.contains('fresha')) {
          return PriceVerificationStatus.freshaMarketplace;
        }
        if (host.contains('booksy')) {
          return PriceVerificationStatus.booksyMarketplace;
        }
        if (marketplaceSource) {
          // Other directories stay search evidence unless identity-matched
          // Fresha/Booksy menus above — never invent "official website".
          return PriceVerificationStatus.searchEvidence;
        }
        return PriceVerificationStatus.officialWebsite;
      }(),
      confidence: locked.confidence,
      priceEvidence: locked,
      procedureRelation: relation.logToken,
    );
  }

  /// AI classifies procedureRelation only — never receives or returns a price.
  Future<ProcedureRelationResult?> _classifyProcedureRelationWithAi({
    required String procedure,
    required String label,
    required String evidence,
  }) async {
    if (_apiKey.isEmpty) return null;
    final excerpt = sanitizePriceEvidence('$label\n$evidence', maxChars: 700);
    final scrubbed = excerpt.replaceAll(RegExp(r'\d[\d.,\s]*'), '[n]');
    if (scrubbed.trim().length < 12) return null;
    try {
      debugPrint('[PROCEDURE RELATION] ambiguous · asking AI (no price field)');
      final uri = Uri.parse('https://api.openai.com/v1/chat/completions');
      final body = <String, Object?>{
        'model': _kPriceVerifierModel,
        ..._temperatureParam(_kPriceVerifierModel, 0),
        ..._tokenLimitParam(_kPriceVerifierModel, 120),
        'response_format': {'type': 'json_object'},
        'messages': [
          {
            'role': 'system',
            'content':
                'Classify how a clinic menu line relates to a requested aesthetic '
                'procedure. Return JSON only with key "procedureRelation" as one of: '
                'exact, variant, bundle, add_on, different_procedure, '
                'market_information, ambiguous. '
                'exact = same treatment. variant = same treatment by brand/amount/'
                'area/session/unit. bundle = two+ treatments sold together. '
                'Never invent or return any numeric price.',
          },
          {
            'role': 'user',
            'content':
                'Requested procedure:\n$procedure\n\n'
                'Menu / evidence text (numbers redacted):\n$scrubbed\n\n'
                'Return JSON: {"procedureRelation":"exact|variant|bundle|add_on|'
                'different_procedure|market_information|ambiguous"}',
          },
        ],
      };
      final resp = await _client
          .post(
            uri,
            headers: {
              'Authorization': 'Bearer $_apiKey',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
      final decoded = jsonDecode(resp.body);
      if (decoded is! Map) return null;
      final choices = decoded['choices'];
      if (choices is! List || choices.isEmpty) return null;
      final msg = choices.first is Map ? choices.first['message'] : null;
      final content = msg is Map ? '${msg['content'] ?? ''}' : '';
      final parsed = jsonDecode(content);
      if (parsed is! Map) return null;
      for (final banned in const [
        'price',
        'amount',
        'price_min',
        'actual_price',
        'numeric_price',
      ]) {
        if (parsed.containsKey(banned)) {
          debugPrint('[PROCEDURE RELATION] AI numeric field ignored ($banned)');
        }
      }
      final raw = '${parsed['procedureRelation'] ?? ''}'.trim().toLowerCase();
      final relation = switch (raw) {
        'exact' => ProcedureRelation.exact,
        'variant' => ProcedureRelation.variant,
        'bundle' => ProcedureRelation.bundle,
        'add_on' || 'addon' => ProcedureRelation.addOn,
        'different_procedure' ||
        'different' => ProcedureRelation.differentProcedure,
        'market_information' || 'market' => ProcedureRelation.marketInformation,
        _ => ProcedureRelation.ambiguous,
      };
      return ProcedureRelationResult(
        relation: relation,
        reason: 'ai_classify_$raw',
      );
    } catch (e) {
      debugPrint('[PROCEDURE RELATION] AI classify error: $e');
      return null;
    }
  }

  // ignore: unused_element
  Future<ExplorePriceVerifyResult?> _verifyPriceWithCheapAi({
    required OpenAIClinic clinic,
    required String procedure,
    required double candidateAmount,
    required String currency,
    required String sourceText,
  }) async {
    debugPrint('[GP PRICE] AMBIGUOUS · sending to cheap verifier');
    final excerpt = sanitizePriceEvidence(sourceText, maxChars: 900);
    if (excerpt.isEmpty || _apiKey.isEmpty) return null;
    try {
      final uri = Uri.parse('https://api.openai.com/v1/chat/completions');
      final body = <String, Object?>{
        'model': _kPriceVerifierModel,
        ..._temperatureParam(_kPriceVerifierModel, 0),
        ..._tokenLimitParam(_kPriceVerifierModel, 220),
        'response_format': {'type': 'json_object'},
        'messages': [
          {
            'role': 'system',
            'content':
                'You verify whether a price found on an aesthetic clinic website belongs '
                'to a requested procedure. Use ONLY SOURCE TEXT. Do not infer or estimate. '
                'Financing, deposits, consultations, monthly payments, vouchers and unrelated '
                'treatments are NOT procedure prices. If unclear, reject it. Return JSON only.',
          },
          {
            'role': 'user',
            'content':
                'Procedure:\n$procedure\n\n'
                'Clinic:\n${clinic.name}\n\n'
                'Candidate price:\n$candidateAmount $currency\n\n'
                'SOURCE TEXT:\n$excerpt\n\n'
                'Return JSON only:\n'
                '{"matches_procedure":true,"candidate_price_is_procedure_price":false,'
                '"actual_price":null,"price_type":"fixed|from|range|per_area|per_unit|unknown",'
                '"confidence":0.0}',
          },
        ],
      };
      final resp = await _client
          .post(
            uri,
            headers: {
              'Authorization': 'Bearer $_apiKey',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
      final decoded = jsonDecode(resp.body);
      if (decoded is! Map) return null;
      final choices = decoded['choices'];
      if (choices is! List || choices.isEmpty) return null;
      final first = choices.first;
      if (first is! Map) return null;
      final message = first['message'];
      if (message is! Map) return null;
      final raw = '${message['content'] ?? ''}'.trim();
      if (raw.isEmpty) return null;
      final jsonStart = raw.indexOf('{');
      final jsonEnd = raw.lastIndexOf('}');
      if (jsonStart < 0 || jsonEnd <= jsonStart) return null;
      final parsed = jsonDecode(raw.substring(jsonStart, jsonEnd + 1));
      if (parsed is! Map) return null;
      final matches = parsed['matches_procedure'] == true;
      final isProcPrice = parsed['candidate_price_is_procedure_price'] == true;
      final confidence = (parsed['confidence'] as num?)?.toDouble() ?? 0;
      if (!matches ||
          !isProcPrice ||
          confidence < kExplorePriceVerifierMinConfidence) {
        debugPrint(
          '[GP PRICE] REJECT · ambiguous_low_confidence '
          'confidence=$confidence',
        );
        return null;
      }
      var amount = candidateAmount;
      final actual = parsed['actual_price'];
      if (actual is num && actual.toDouble() > 0) {
        debugPrint('[GP PRICE] AI numeric field ignored');
      }
      debugPrint('[GP PRICE] AI VERIFIED · confidence=$confidence');
      return ExplorePriceVerifyResult(
        decision: ExplorePriceVerifyDecision.verified,
        priceMin: amount,
        currency: currency,
        evidence: excerpt,
        reason: 'ai_verified',
        confidence: confidence,
      );
    } catch (e) {
      debugPrint('[GP PRICE] cheap verifier error: $e');
      return null;
    }
  }

  /// LLM prose price extraction. Used only when deterministic tabular
  /// and prose extractors both fail on a page that mentions the procedure.
  ///
  /// The model is instructed to return the clinic's OWN published price
  /// (a specific numeric amount stated on this page), NOT a market average
  /// or a phrase like "call for a quote". If the page has no price, it
  /// must return null. All decisions still route through
  /// [_verifyClinicPriceFromPage] so the price is re-anchored in the
  /// source text before it can display.
  Future<
    ({double priceMin, double? priceMax, String currency, String sourceQuote})?
  >
  _extractProcedurePriceWithLlm({
    required String pageText,
    required String procedure,
    required String clinicName,
    required String sourceUrl,
  }) async {
    if (_apiKey.isEmpty) return null;
    if (pageText.trim().length < 500) return null;

    // Windowing: prices in prose pages usually appear near where the
    // procedure is discussed. Prefer a slice centered on the first
    // procedure mention rather than the head of the page.
    String excerpt;
    final lower = pageText.toLowerCase();
    final needle = procedure
        .toLowerCase()
        .split(' ')
        .firstWhere(
          (t) => t.length >= 4,
          orElse: () => procedure.toLowerCase(),
        );
    final idx = lower.indexOf(needle);
    if (pageText.length <= 4000) {
      excerpt = pageText;
    } else if (idx < 0) {
      excerpt = pageText.substring(0, 4000);
    } else {
      final start = math.max(0, idx - 800);
      final end = math.min(pageText.length, start + 4000);
      excerpt = pageText.substring(start, end);
    }
    excerpt = sanitizePriceEvidence(excerpt, maxChars: 4000);
    if (excerpt.trim().length < 300) return null;

    debugPrint(
      '[GP PRICE] LLM narrative semantic extraction · $clinicName · ${excerpt.length} chars',
    );

    try {
      final uri = Uri.parse('https://api.openai.com/v1/chat/completions');
      final body = <String, Object?>{
        'model': _kPriceVerifierModel,
        ..._temperatureParam(_kPriceVerifierModel, 0),
        ..._tokenLimitParam(_kPriceVerifierModel, 260),
        'response_format': {'type': 'json_object'},
        'messages': [
          {
            'role': 'system',
            'content':
                'Extract this clinic\'s OWN published price for the requested '
                'procedure from the SOURCE TEXT. Rules:\n'
                '- Return ONLY a specific numeric amount that is on this page '
                'for this procedure.\n'
                '- Reject market averages, city ranges, "typically" / "in this '
                'city" statements, consultations, deposits, monthly financing, '
                'unrelated treatments, and prices that belong to a different '
                'procedure family.\n'
                '- "Starts from AED 700", "AED 700 per session", "700 AED" '
                'are all valid amounts for chemical peel if the price is '
                'attributed to that treatment on this page.\n'
                '- If the page mentions the procedure but has no specific '
                'amount, return {"has_price": false}.\n'
                '- Do not invent, average, or convert currencies. Return the '
                'exact number and currency shown.\n'
                'Return JSON only.',
          },
          {
            'role': 'user',
            'content':
                'Procedure: $procedure\n'
                'Clinic: $clinicName\n'
                'Source URL: $sourceUrl\n\n'
                'SOURCE TEXT:\n$excerpt\n\n'
                'Return JSON only in this shape:\n'
                '{"has_price": true|false, "price_min": number|null, '
                '"price_max": number|null, "currency": "AED|EUR|GBP|USD|RON|TRY|null", '
                '"source_quote": "exact sentence containing the price", '
                '"confidence": 0.0-1.0}',
          },
        ],
      };
      final resp = await _client
          .post(
            uri,
            headers: {
              'Authorization': 'Bearer $_apiKey',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        debugPrint('[GP PRICE] LLM extract HTTP ${resp.statusCode}');
        return null;
      }
      final decoded = jsonDecode(resp.body);
      if (decoded is! Map) return null;
      final choices = decoded['choices'];
      if (choices is! List || choices.isEmpty) return null;
      final message = (choices.first as Map)['message'];
      if (message is! Map) return null;
      final raw = '${message['content'] ?? ''}'.trim();
      if (raw.isEmpty) return null;
      final jsonStart = raw.indexOf('{');
      final jsonEnd = raw.lastIndexOf('}');
      if (jsonStart < 0 || jsonEnd <= jsonStart) return null;
      final parsed = jsonDecode(raw.substring(jsonStart, jsonEnd + 1));
      if (parsed is! Map) return null;

      final hasPrice = parsed['has_price'] == true;
      if (!hasPrice) return null;
      final priceMin = (parsed['price_min'] as num?)?.toDouble() ?? 0;
      final priceMax = (parsed['price_max'] as num?)?.toDouble();
      final currency = ('${parsed['currency'] ?? ''}').trim().toUpperCase();
      final quote = ('${parsed['source_quote'] ?? ''}').trim();
      final confidence = (parsed['confidence'] as num?)?.toDouble() ?? 0;

      if (priceMin < 20 || currency.isEmpty) return null;
      if (confidence < 0.6) {
        debugPrint('[GP PRICE] LLM extract low confidence=$confidence');
        return null;
      }
      // Re-anchor: the quote must appear verbatim (case-insensitive,
      // whitespace-tolerant) in the excerpt so the LLM cannot fabricate.
      if (quote.isNotEmpty) {
        final normQuote = quote.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
        final normText = excerpt.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
        if (!normText.contains(normQuote)) {
          debugPrint(
            '[GP PRICE] LLM extract quote not found in source — '
            'rejecting hallucinated match',
          );
          return null;
        }
      }
      return (
        priceMin: priceMin,
        priceMax: (priceMax != null && priceMax >= priceMin) ? priceMax : null,
        currency: currency,
        sourceQuote: quote,
      );
    } catch (e) {
      debugPrint('[GP PRICE] LLM extract error: $e');
      return null;
    }
  }

  Future<OpenAIClinic?> _verifyClinicPriceFromPage({
    required OpenAIClinic clinic,
    required String procedure,
    required String pageText,
    required String sourceUrl,
    double? candidateAmount,
    String? candidateCurrency,
    String city = '',
  }) async {
    // Candidate amounts (snippets / leftover AI) are hints only.
    // The numeric price must come from HTML evidence.
    final fromHtml = _clinicFromDeterministicEvidence(
      clinic: clinic,
      procedure: procedure,
      preferredUrl: sourceUrl,
      city: city,
    );
    if (fromHtml != null) return fromHtml;
    return _clinicFromClinicOwnPublishedProse(
      clinic: clinic,
      procedure: procedure,
      pageText: pageText,
      sourceUrl: sourceUrl,
    );
  }

  OpenAIClinic? _clinicFromClinicOwnPublishedProse({
    required OpenAIClinic clinic,
    required String procedure,
    required String pageText,
    required String sourceUrl,
  }) {
    final own = pickClinicOwnPublishedPrice(pageText, procedure: procedure);
    if (own == null || sourceUrl.trim().isEmpty) return null;
    if (!_pageOffersProcedure(
      pageText,
      procedure: procedure,
      brand: clinic.brand,
    )) {
      return null;
    }
    final parsed = parsePriceText(own);
    if (parsed == null || parsed.priceMin <= 0) return null;
    if (!isValidExtractedPriceCandidate(
      rawPriceText: own,
      priceMin: parsed.priceMin,
      currency: parsed.currency,
      extractionMethod: PriceExtractionMethod.textProximity.wire,
      rawEvidence: own,
      procedure: procedure,
      sourceUrl: sourceUrl,
    )) {
      return null;
    }
    if (!isJustifiedProcedurePriceValue(
      priceMin: parsed.priceMin,
      currency: parsed.currency.isNotEmpty ? parsed.currency : clinic.currency,
      procedure: procedure,
      evidence: own,
    )) {
      return null;
    }
    final family = matchRawProcedureLabel(
      pageText,
      requestedProcedure: procedure,
    );
    if (!family.accepted || family.family == 'other') {
      return null;
    }
    final picked = ExtractedPriceEvidence(
      rawProcedureText: procedureLabelFromPricedBlob(
        rawProcedureText: '',
        rawEvidence: pageText,
        requestedProcedure: procedure,
      ),
      rawPriceText: own,
      priceMin: parsed.priceMin,
      priceMax: parsed.priceMax >= parsed.priceMin
          ? parsed.priceMax
          : parsed.priceMin,
      currency: parsed.currency,
      sourceUrl: sourceUrl,
      extractionMethod: PriceExtractionMethod.textProximity,
      rawEvidence: own,
      confidence: 0.7,
      priceType: parsed.priceType,
      procedureFamily: family.family,
      procedureCanonical: family.canonical,
    );
    debugPrint(
      '[GP PRICE] VERIFIED evidence=clinic_own_prose '
      'source=official_clinic',
    );
    logPriceAccept(
      clinic: clinic.name,
      procedure: procedure,
      rawPriceText: own,
      parsedAmount: parsed.priceMin,
      currency: parsed.currency.isNotEmpty ? parsed.currency : clinic.currency,
      extractionMethod: PriceExtractionMethod.textProximity.wire,
      sourceUrl: sourceUrl,
    );
    return _markVerifiedProcedurePrice(
      clinic,
      priceMin: parsed.priceMin,
      priceMax: parsed.priceMax,
      currency: parsed.currency.isNotEmpty ? parsed.currency : clinic.currency,
      sourceUrl: sourceUrl,
      evidence: own,
      status: PriceVerificationStatus.officialWebsite,
      confidence: 0.7,
      priceEvidence: picked,
    );
  }

  List<OpenAIProfileProcedureRow> _procedureRowsFromHtmlEvidence({
    required String html,
    required String sourceUrl,
  }) {
    if (html.trim().isEmpty || sourceUrl.trim().isEmpty) {
      return const [];
    }
    final rows = ExploreHtmlPriceParseCache.instance.evidenceForHtml(
      html: html,
      sourceUrl: sourceUrl,
    );
    return [
      for (final e in rows)
        if (e.hasUsablePrice)
          OpenAIProfileProcedureRow(
            name: e.rawProcedureText,
            detail: e.rawPriceText,
            category: e.procedureFamily.isNotEmpty
                ? e.procedureFamily
                : 'Treatments',
            iconKind: 'inject',
            priceMin: e.priceMin,
            priceMax: e.priceMax >= e.priceMin ? e.priceMax : e.priceMin,
            priceLabel: e.rawPriceText,
            tags: [
              'evidence',
              e.extractionMethod.wire,
              if (e.evidenceHash.isNotEmpty) e.evidenceHash,
            ],
            featured: false,
          ),
    ];
  }

  bool _windowLooksLikeExpiredPromo(String window) {
    final t = window.toLowerCase();
    return t.contains('expirat') ||
        t.contains('expired') ||
        t.contains('oferta expirada') ||
        t.contains('promo expir') ||
        t.contains('no longer valid') ||
        t.contains('până la') ||
        t.contains('pana la') ||
        t.contains('valabil până') ||
        t.contains('valabil pana');
  }

  bool _windowLooksLikeCityAverage(String window) {
    if (looksLikeGoogleAreaEstimateBlurb(window) ||
        looksLikeMarketAveragePriceBlurb(window)) {
      return true;
    }
    final t = window.toLowerCase();
    return t.contains('typical range') ||
        t.contains('typically range') ||
        t.contains('on average') ||
        t.contains('city average') ||
        t.contains('habitualmente') ||
        t.contains('suelen') ||
        t.contains('media de') ||
        t.contains('en promedio') ||
        t.contains('average price') ||
        t.contains('expect to pay') ||
        t.contains('average price range') ||
        t.contains('expect to pay between') ||
        t.contains('preț mediu') ||
        t.contains('pret mediu') ||
        t.contains('prix moyen') ||
        t.contains('în general') ||
        t.contains('in general');
  }

  bool _windowLooksLikeConsultFee(String window) {
    final t = window.toLowerCase();
    return t.contains('consulta') ||
        t.contains('consult ') ||
        t.contains('consultation') ||
        t.contains('primera visita') ||
        t.contains('valoración') ||
        t.contains('valoracion') ||
        t.contains('assessment fee') ||
        t.contains('evaluation fee');
  }

  bool _windowLooksLikeDepositOrBookingFee(String window) {
    final t = window.toLowerCase();
    return t.contains('a cuenta') ||
        t.contains('depósito') ||
        t.contains('deposito') ||
        t.contains('reserva') ||
        t.contains('señal') ||
        t.contains('senal') ||
        t.contains('deposit') ||
        t.contains('booking fee') ||
        t.contains('reservation fee') ||
        t.contains('down payment') ||
        t.contains('descontado del precio') ||
        t.contains('descuento del precio') ||
        t.contains('se descontará') ||
        t.contains('se descontara') ||
        t.contains('será descontado') ||
        t.contains('sera descontado');
  }

  /// "EXCELENTE 4.6 1839 reseñas" on defelipe.com was parsed as €1,839.
  bool _windowLooksLikeReviewCount(String window) {
    final t = window.toLowerCase();
    return RegExp(
          r'\d{2,5}\s*(?:rese[nñ]as|reviews?|valoraciones|opiniones|'
          r'google\s*reviews|estrellas)\b',
        ).hasMatch(t) ||
        RegExp(
          r'(?:rese[nñ]as|reviews?|valoraciones|opiniones)\s*\d{2,5}',
        ).hasMatch(t);
  }

  bool _windowLooksLikeClinicProgram(String window) {
    final t = window.toLowerCase();
    return RegExp(
      r'\bprograma\b|pago unico|pago único|pago fraccionado|'
      r'\b(?:4|6|8|10)\s*sesiones\b|\d\s*x\s*tratamientos',
    ).hasMatch(t);
  }

  bool _windowLooksLikePriceTableRow(String window) {
    final t = window.toLowerCase();
    if (_zoneCountHint(t) != null) return true;
    if (t.contains('|') || t.contains('\t')) return true;
    if (RegExp(r'(zona|zone|area|zonă).{0,16}\d').hasMatch(t)) return true;
    return false;
  }

  /// HIFU copy often says "avoid recent peeling" next to 360 lei — that is
  /// not the chemical-peel price (495 lei on dianaciobanu.com).
  bool _windowConflictsWithProcedure(String window, String procedure) {
    final t = window.toLowerCase();
    if (t.contains('contraindic') ||
        t.contains('nu este indicat') ||
        t.contains('nu e indicat') ||
        t.contains('not indicated') ||
        t.contains('tratamente recente')) {
      return true;
    }
    final want = exploreTreatmentFamily(procedure);
    if (want == ExploreTreatmentFamily.filler &&
        (t.contains('lip lift') ||
            t.contains('lip-lift') ||
            t.contains('liplift') ||
            t.contains('queiloplast') ||
            t.contains('liposuc'))) {
      return true;
    }
    if (want == ExploreTreatmentFamily.botox &&
        (t.contains('masseter') ||
            t.contains('brux') ||
            t.contains('hiperhidros') ||
            t.contains('hyperhidros') ||
            t.contains('platism') ||
            t.contains('gingival'))) {
      return true;
    }
    if (want == ExploreTreatmentFamily.other) return false;
    final got = exploreTreatmentFamily(window);
    if (got == ExploreTreatmentFamily.other) return false;
    return want != got;
  }

  /// Official 1/2/3-area Botox tariff on the clinic site (De Felipe 250–650).
  /// Used as the card "from" price so a 900 € rejuvenation package cannot win.
  ({double from, double max})? _botoxPublishedMenuRange(
    String pageText,
    String procedure,
  ) {
    if (exploreTreatmentFamily(procedure) != ExploreTreatmentFamily.botox) {
      return null;
    }
    if (pageText.isEmpty) return null;
    final t = _foldExploreMatchText(pageText);
    var start = -1;
    for (final needle in ['toxina botulin', 'botulinum', 'botox']) {
      final i = t.indexOf(_foldExploreMatchText(needle));
      if (i >= 0 && (start < 0 || i < start)) start = i;
    }
    if (start < 0) return null;
    var end = math.min(t.length, start + 1400);
    for (final cut in [
      'acido hialuron',
      'hilos tensores',
      'morpheus',
      'cirugia plastica',
      'peeling quimico',
    ]) {
      final c = t.indexOf(cut, start + 80);
      if (c > start && c < end) end = c;
    }
    final slice = t.substring(start, end);

    double? firstEuroAfter(RegExp re) {
      final m = re.firstMatch(slice);
      if (m == null) return null;
      final v = double.tryParse(m.group(1)!.replaceAll(' ', ''));
      if (v == null || v < 40 || v > 800) return null;
      return v;
    }

    final z1 = firstEuroAfter(
      RegExp(
        r'(?:1|una)\s*(?:area|zona)[^0-9]{0,48}(\d{2,4})\s*(?:€|eur)',
        caseSensitive: false,
      ),
    );
    final z2 = firstEuroAfter(
      RegExp(
        r'(?:2|dos)\s*(?:areas|zonas)[^0-9]{0,48}(\d{2,4})\s*(?:€|eur)',
        caseSensitive: false,
      ),
    );
    final z3 = firstEuroAfter(
      RegExp(
        r'(?:3|tres)\s*(?:areas|zonas)[^0-9]{0,48}(\d{2,4})\s*(?:€|eur)',
        caseSensitive: false,
      ),
    );
    final full = firstEuroAfter(
      RegExp(
        r'(?:full[\s-]?tox|fulltox|100\s*iu)[\s\S]{0,80}?(\d{2,4})\s*(?:€|eur)',
        caseSensitive: false,
      ),
    );
    if (z1 == null) return null;
    if (z2 == null && z3 == null && full == null) return null;
    if (z2 != null && z2 + 1 < z1) return null;
    if (z3 != null && z3 + 1 < z1) return null;
    final max = [z1, z2, z3, full].whereType<double>().reduce(math.max);
    return (from: z1, max: max);
  }

  /// Prose fallback for pages that describe prices in free text
  /// (e.g. "prețul operației de implant mamar variază: 4700 EUR").
  ///
  /// Compact tariff lists put unrelated rows (consult, tricoscopie 150 lei)
  /// within a few hundred characters of "Toxina Botulinica 1 zona 900lei".
  /// Pick the amount closest in *text* to the procedure keyword — not the
  /// cheapest number in a wide window.
  ({double priceMin, String currency})? _findProcedurePriceInProse({
    required String pageText,
    required String procedure,
    required String brand,
    String listingHint = '',
  }) {
    if (pageText.isEmpty) return null;
    final head = pageText.length > 900 ? pageText.substring(0, 900) : pageText;
    if (_windowLooksLikeCityAverage(head) &&
        (head.toLowerCase().contains('what to expect') ||
            head.toLowerCase().contains('average price range') ||
            head.toLowerCase().contains('expect to pay between'))) {
      return null;
    }
    final keywords = _procedureConfirmKeywords(procedure, brand);
    if (keywords.isEmpty) return null;

    final lower = pageText.toLowerCase();
    final keywordSpans = <({int start, int end})>[];
    for (final k in keywords) {
      if (k.isEmpty) continue;
      final escaped = RegExp.escape(k);
      final suffix = k.length >= 5 ? r'[a-zà-ÿ]{0,8}' : '';
      final kr = RegExp(
        '(^|[^a-zà-ÿ])$escaped$suffix([^a-zà-ÿ]|\$)',
        caseSensitive: false,
      );
      for (final km in kr.allMatches(lower)) {
        keywordSpans.add((start: km.start, end: km.end));
      }
    }
    if (keywordSpans.isEmpty) return null;

    final re = RegExp(
      r'(from|de\s+la|ab|desde|à\s+partir\s+de|porneste(?:\s+de\s+la)?|'
      r'pornește(?:\s+de\s+la)?|începe(?:\s+de\s+la)?|'
      r'starting(?:\s+from|\s+at)?|approximately)?\s*'
      r'(?:'
      r'(?:aed|eur|euro|euros|gbp|usd|try|ron|lei|₩|krw|hkd|sgd|thb|'
      r'درهم|د\.إ|€|£|\$)\s*'
      r'(\d{1,3}(?:[.,\s]\d{3})+|\d{3,6}(?:[.,]\d{1,2})?)'
      r'|'
      r'[€£₩$]?\s*'
      r'(\d{1,3}(?:[.,\s]\d{3})+|\d{3,6}(?:[.,]\d{1,2})?)'
      r'\s*(?:de\s+)?(?:€|eur|euro|euros|£|gbp|\$|usd|try|ron|lei|₩|krw|aed|hkd|sgd|thb|درهم|د\.إ)'
      r')',
      caseSensitive: false,
    );

    int? nearestKeywordGap(int priceStart, int priceEnd) {
      int? best;
      for (final k in keywordSpans) {
        final int gap;
        if (priceStart >= k.end) {
          gap = priceStart - k.end;
        } else if (priceEnd <= k.start) {
          gap = k.start - priceEnd;
        } else {
          gap = 0;
        }
        if (best == null || gap < best) best = gap;
      }
      return best;
    }

    bool attachedToKeyword({
      required int priceStart,
      required int priceEnd,
      required bool tableRow,
    }) {
      final afterMax = tableRow ? 180 : 80;
      final beforeMax = tableRow ? 40 : 30;
      for (final k in keywordSpans) {
        if (priceStart >= k.end && priceStart - k.end <= afterMax) {
          return true;
        }
        if (priceEnd <= k.start && k.start - priceEnd <= beforeMax) {
          return true;
        }
        if (priceStart < k.end && priceEnd > k.start) return true;
      }
      return false;
    }

    final advertisedZones =
        _zoneCountHint(listingHint) ?? _zoneCountHint(pageText);
    final preferZones = advertisedZones ?? _zoneCountHint(procedure);

    ({double priceMin, String currency, int gap, bool hasFrom, bool zoned})?
    best;
    for (final m in re.allMatches(pageText)) {
      final raw = m.group(0) ?? '';
      final parsed = _parseAnyPrice(raw);
      if (parsed == null || parsed < 20) continue;

      final localStart = math.max(0, m.start - 48);
      final localEnd = math.min(pageText.length, m.end + 48);
      final window = lower.substring(localStart, localEnd);
      final tableRow = _windowLooksLikePriceTableRow(window);
      if (!attachedToKeyword(
        priceStart: m.start,
        priceEnd: m.end,
        tableRow: tableRow,
      )) {
        continue;
      }

      if (_windowLooksLikeExpiredPromo(window)) continue;
      if (_windowLooksLikeCityAverage(window)) continue;
      if (_windowLooksLikeConsultFee(window) && parsed < 250) continue;
      if (_windowLooksLikeDepositOrBookingFee(window)) continue;
      if (_windowLooksLikeReviewCount(window)) continue;
      if (_windowLooksLikeClinicProgram(window)) continue;
      final neg = explorePriceNegativeReason(window);
      if (neg != null && !(neg == 'consultation_price' && parsed >= 250)) {
        continue;
      }
      if (_windowConflictsWithProcedure(window, procedure)) continue;

      final rawLo = raw.toLowerCase();
      final curr = rawLo.contains('€') || rawLo.contains('eur')
          ? '€'
          : rawLo.contains('£') || rawLo.contains('gbp')
          ? '£'
          : rawLo.contains('ron') || rawLo.contains('lei')
          ? 'RON'
          : rawLo.contains('try')
          ? 'TRY'
          : rawLo.contains('₩') || rawLo.contains('krw')
          ? '₩'
          : rawLo.contains(r'$') || rawLo.contains('usd')
          ? r'$'
          : rawLo.contains('aed') ||
                rawLo.contains('dhs') ||
                rawLo.contains('dirham')
          ? 'AED'
          : rawLo.contains('hkd')
          ? 'HKD'
          : rawLo.contains('sgd')
          ? 'SGD'
          : rawLo.contains('thb')
          ? 'THB'
          : '';
      if (curr.isEmpty) continue;
      final gap = nearestKeywordGap(m.start, m.end);
      if (gap == null) continue;
      final prefix = (m.group(1) ?? '').trim();
      final hasFrom = prefix.isNotEmpty;
      final zoned =
          preferZones != null && _zoneCountHint(window) == preferZones;
      final cand = (
        priceMin: parsed,
        currency: curr,
        gap: gap,
        hasFrom: hasFrom,
        zoned: zoned,
      );
      if (best == null) {
        best = cand;
        continue;
      }
      // "desde 200€" beats an unlabeled nearby amount.
      if (cand.hasFrom != best.hasFrom) {
        if (cand.hasFrom) best = cand;
        continue;
      }
      if (preferZones != null && cand.zoned != best.zoned) {
        if (cand.zoned) best = cand;
        continue;
      }
      // Closest in text; lowest value only when equally close.
      if ((cand.gap - best.gap).abs() > 8) {
        if (cand.gap < best.gap) best = cand;
        continue;
      }
      if (cand.priceMin < best.priceMin) best = cand;
    }
    final own = pickClinicOwnPublishedPrice(pageText, procedure: procedure);
    if (own != null) {
      final parsedOwn = parsePriceText(own);
      if (parsedOwn != null && parsedOwn.priceMin >= 20) {
        return (priceMin: parsedOwn.priceMin, currency: parsedOwn.currency);
      }
    }
    if (best == null) return null;
    return (priceMin: best.priceMin, currency: best.currency);
  }

  bool _pageMentionsProcedure(
    String pageText, {
    required String procedure,
    required String brand,
  }) {
    if (pageText.isEmpty) return false;
    final keywords = _procedureConfirmKeywords(procedure, brand);
    if (keywords.isEmpty) return false;
    final lower = _foldExploreMatchText(pageText);
    return keywords.any((k) {
      final needle = _foldExploreMatchText(k);
      return needle.contains(' ')
          ? lower.contains(needle)
          : _windowHasKeyword(lower, needle);
    });
  }

  /// True when the clinic page actually lists this treatment — not merely
  /// "wrinkles" in marketing copy. Used to drop clinics GPT invented onto
  /// a Botox search (e.g. a filler-only clinic).
  bool _pageOffersProcedure(
    String pageText, {
    required String procedure,
    required String brand,
  }) {
    if (pageText.isEmpty) return false;
    final text = '$procedure $brand'.toLowerCase();
    final botoxSearch =
        text.contains('botox') ||
        text.contains('btx') ||
        text.contains('toxin') ||
        text.contains('neuromodul') ||
        text.contains('anti-wrinkle') ||
        text.contains('antiwrinkle');
    final rhinoSearch =
        text.contains('rhino') ||
        text.contains('nose job') ||
        text.contains('rinoplast');
    final peelSearch = text.contains('peel') || text.contains('peeling');
    final laserSearch =
        text.contains('laser') ||
        text.contains('epilare') ||
        text.contains('depilacion') ||
        text.contains('hair removal') ||
        text.contains('ipl') ||
        text.contains('diode');
    final hairSearch =
        text.contains('hair transplant') ||
        text.contains('fue') ||
        text.contains('dhi') ||
        text.contains('transplant par') ||
        text.contains('transplant de par') ||
        text.contains('implant de par') ||
        text.contains('implant par') ||
        (text.contains('hair') &&
            (text.contains('implant') ||
                text.contains('graft') ||
                text.contains('restoration')));
    final breastSearch =
        _exploreTextIsAestheticBreast(text) ||
        text.contains('augmentation') && text.contains('mamma');
    final fillerSearch =
        exploreTreatmentFamily(procedure) == ExploreTreatmentFamily.filler ||
        text.contains('filler') ||
        text.contains('relleno') ||
        text.contains('hyaluron') ||
        text.contains('hialuron');
    if (botoxSearch ||
        rhinoSearch ||
        peelSearch ||
        laserSearch ||
        hairSearch ||
        breastSearch ||
        fillerSearch) {
      final keywords = _procedureOfferKeywords(procedure, brand);
      final lower = _foldExploreMatchText(pageText);
      return keywords.any((k) {
        final needle = _foldExploreMatchText(k);
        return needle.contains(' ')
            ? lower.contains(needle)
            : _windowHasKeyword(lower, needle);
      });
    }
    return _pageMentionsProcedure(pageText, procedure: procedure, brand: brand);
  }

  List<String> _procedureOfferKeywords(String procedure, String brand) {
    final text = '$procedure $brand'.toLowerCase();
    if (text.contains('botox') ||
        text.contains('btx') ||
        text.contains('toxin') ||
        text.contains('neuromodul') ||
        text.contains('anti-wrinkle') ||
        text.contains('antiwrinkle')) {
      return [
        'botox',
        'botoks',
        'botulin',
        'toxina',
        'toxină',
        'vistabel',
        'dysport',
        'xeomin',
        'bocouture',
        'nuceiva',
        'azzalure',
        'azalure',
        'neuromodul',
        ...exploreLocalProcedureTokens('botox'),
      ];
    }
    if (text.contains('rhino') ||
        text.contains('nose job') ||
        text.contains('nose reshaping') ||
        text.contains('rinoplast')) {
      return [
        'rhinoplasty',
        'rinoplastie',
        'rinoplast',
        'rhinoplast',
        'nose job',
        'nose reshaping',
        ...exploreLocalProcedureTokens('rhinoplasty'),
      ];
    }
    if (text.contains('peel') || text.contains('peeling')) {
      return [
        'peel',
        'peeling',
        'tca',
        'glycolic',
        'jessner',
        'mandelic',
        'chimic',
        ...exploreLocalProcedureTokens('peel'),
      ];
    }
    if (text.contains('laser') ||
        text.contains('epilare') ||
        text.contains('depilacion') ||
        text.contains('ipl') ||
        text.contains('diode') ||
        text.contains('fraxel') ||
        text.contains('hair removal')) {
      return [
        'laser',
        'epilare',
        'epilat',
        'depilacion',
        'depilacion laser',
        'diode',
        'ipl',
        'fraxel',
        'alexandrite',
        'co2',
        ...exploreLocalProcedureTokens('laser'),
      ];
    }
    if (text.contains('hair transplant') ||
        text.contains('fue') ||
        text.contains('dhi') ||
        text.contains('transplant par') ||
        text.contains('implant de par') ||
        text.contains('implant par') ||
        (text.contains('hair') && text.contains('implant'))) {
      return [
        'fue',
        'dhi',
        'graft',
        'grafturi',
        'transplant',
        'capilar',
        'follicle',
        'implant par',
        'transplant par',
        'fir cu fir',
        ...exploreLocalProcedureTokens('hair'),
      ];
    }
    if (_exploreTextIsAestheticBreast(text) ||
        (text.contains('augmentation') && text.contains('mamma'))) {
      return [
        ..._kExploreBreastOfferKeywords,
        ...exploreLocalProcedureTokens('breast'),
      ];
    }
    if (text.contains('filler') ||
        text.contains('relleno') ||
        text.contains('hyaluron') ||
        text.contains('hialuron') ||
        exploreTreatmentFamily(procedure) == ExploreTreatmentFamily.filler) {
      return [
        'filler',
        'fillers',
        'relleno',
        'rellenos',
        'juvederm',
        'restylane',
        'teosyal',
        'labios',
        'labio',
        'buze',
        ...exploreLocalProcedureTokens('filler'),
      ];
    }
    return _procedureConfirmKeywords(procedure, brand);
  }

  /// 1 / 2 / 3 from "Botox 3 areas", "3 zone", "o zonă", etc.
  int? _zoneCountHint(String text) {
    final t = text.toLowerCase();
    if (RegExp(
      r'(?:^|[^a-z0-9])(?:3|three|trei)\s*(?:area|areas|zone|zones|zonas|zon[eăa]s?)',
    ).hasMatch(t)) {
      return 3;
    }
    if (RegExp(
      r'(?:^|[^a-z0-9])(?:2|two|dou[aă])\s*(?:area|areas|zone|zones|zonas|zon[eăa]s?)',
    ).hasMatch(t)) {
      return 2;
    }
    if (RegExp(
      r'(?:^|[^a-z0-9])(?:1|one|o)\s*(?:area|areas|zone|zones|zonas|zon[eăa]|zonă)',
    ).hasMatch(t)) {
      return 1;
    }
    // Current Romanian lists often name the 1-zone row by anatomy only.
    if (RegExp(r'periocular|laba\s*g[aâ]s|crow.?s?\s*feet').hasMatch(t)) {
      return 1;
    }
    return null;
  }

  /// One facial area (forehead / crow's feet) — a subset, not the base Botox price.
  bool _extractedRowLooksLikeAnatomySubset(String name) {
    final t = name.toLowerCase();
    return RegExp(
      r'\b(?:forehead|frente|glabella|entrecejo|crow.?s?\s*feet|periocular|'
      r'laba\s*g[aâ]s)\b',
    ).hasMatch(t);
  }

  /// One facial area (forehead / crow's feet) — a subset, not the base Botox price.
  bool _extractedRowLooksLikeSingleArea(String name) {
    final t = name.toLowerCase();
    if (_extractedRowLooksLikeAnatomySubset(t)) return true;
    return RegExp(r'\b(?:one\s+area|only\s+one|una\s+sola)\b').hasMatch(t);
  }

  bool _extractedRowLooksLikeClinicProgram(String name) {
    final t = name.toLowerCase();
    return RegExp(
      r'\bprograma\b|pago unico|pago único|pago fraccionado|'
      r'\b(?:4|6|8|10)\s*sesiones\b|\d\s*x\s*tratamientos|'
      r'rejuvenecimiento',
    ).hasMatch(t);
  }

  /// Generic treatment name with no 1-zone / anatomy subset qualifier.
  bool _extractedRowLooksLikeBaseTreatmentName(String name, String topic) {
    final n = name.toLowerCase().trim();
    final top = topic.toLowerCase().trim();
    if (n.isEmpty || top.isEmpty) return false;
    if (_extractedRowLooksLikeSingleArea(n)) return false;
    if (_zoneCountHint(n) == 1) return false;
    var rest = n.replaceAll(top, ' ');
    rest = rest.replaceAll(
      RegExp(
        r'\b(?:treatment|treatments|injection|injections|inyeccion|inyección|'
        r'tratamiento|facial|face|anti.?wrinkle|arrugas|toxina|botul[ií]nica|'
        r'botulinum|toxin|vials?|units?|precio|price|desde|from)\b',
      ),
      ' ',
    );
    rest = rest.replaceAll(RegExp(r'[^a-zà-ÿ0-9]+'), ' ').trim();
    if (rest.isEmpty) return true;
    // "3 zonas" / "full face" still counts as the advertised base package.
    if (_zoneCountHint(n) == 3 ||
        RegExp(
          r'\b(?:full\s*face|paquete|package|standard|completo)\b',
        ).hasMatch(n)) {
      return true;
    }
    return rest.split(RegExp(r'\s+')).where((w) => w.length > 1).length <= 1;
  }

  /// Higher = more like the representative / standard row for [procedure].
  int _extractedRowBaseRank(OpenAIProfileProcedureRow row, String procedure) {
    final n = '${row.name} ${row.detail}'.toLowerCase();
    var rank = 50;
    final zones = _zoneCountHint(n);
    final effectiveZones =
        zones ?? (_extractedRowLooksLikeSingleArea(n) ? 1 : null);
    final wanted = _zoneCountHint(procedure);
    if (wanted != null) {
      if (effectiveZones == wanted) {
        rank += 40;
      } else if (effectiveZones != null) {
        rank -= 20;
      }
    } else {
      if (effectiveZones == 1) rank += 24;
      if (effectiveZones == 2) rank += 10;
      if (effectiveZones == 3) rank += 6;
      if (effectiveZones == null) rank += 12;
      if (_extractedRowLooksLikeAnatomySubset(n)) rank -= 22;
    }
    if (_extractedRowLooksLikeClinicProgram(n)) rank -= 50;
    if (RegExp(r'full[\s-]?tox|fulltox|100\s*iu|completo').hasMatch(n)) {
      rank -= 20;
    }
    if (_labelLooksLikePerUnitOrGraft(row.priceLabel) ||
        RegExp(r'(?:per|/)\s*(?:iu|unit|unidad)').hasMatch(n)) {
      rank -= 45;
    }
    if (_extractedRowLooksLikePromo(row)) rank -= 12;
    if (RegExp(
      r'masseter|brux|hiperhidros|hyperhidros|platism|gingival|gummy',
    ).hasMatch(n)) {
      rank -= 40;
    }
    if (RegExp(r'lip[\s-]?lift|queiloplast').hasMatch(n)) {
      rank -= 40;
    }
    if (RegExp(r'\b(?:desde|from|ab)\b').hasMatch(n) ||
        RegExp(
          r'\b(?:desde|from|ab)\b',
        ).hasMatch(row.priceLabel.toLowerCase())) {
      rank += 6;
    }
    return rank;
  }

  bool _extractedRowLooksLikePromo(OpenAIProfileProcedureRow row) {
    final t = '${row.name} ${row.detail} ${row.priceLabel}'.toLowerCase();
    return t.contains('ofert') ||
        t.contains('promo') ||
        t.contains('reducere') ||
        t.contains('discount') ||
        t.contains('expirat');
  }

  List<String> _procedureConfirmKeywords(String procedure, String brand) {
    // Only mix the AI brand in when it is the same treatment family.
    // "Testicular implant" on a breast search used to inject "implant"
    // into the keyword list and confirm the wrong row.
    if (brand.trim().isEmpty) return _anatomyKeywordsFrom(procedure);
    final procFam = exploreTreatmentFamily(procedure);
    final brandFam = exploreTreatmentFamily(brand);
    if (brandFam == procFam) {
      return _anatomyKeywordsFrom('$procedure $brand');
    }
    return _anatomyKeywordsFrom(procedure);
  }

  List<String> _anatomyKeywordsFrom(String raw) {
    final text = raw.toLowerCase();
    final out = <String>{};

    void add(Iterable<String> xs) => out.addAll(xs);

    final fam = exploreTreatmentFamily(raw);
    if (fam != ExploreTreatmentFamily.other) {
      add(exploreLocalProcedureTokens(fam.name));
      final ck = exploreCoreKeywordForProcedure(raw);
      if (ck != null) {
        add(exploreSynonymsForCoreKeyword(ck));
      }
    }

    if (text.contains('nasolabial') ||
        text.contains('nasogenian') ||
        text.contains('marionette') ||
        text.contains('surco')) {
      add([
        'nasolabial',
        'nasogenian',
        'marionette',
        'surco',
        'pliegue',
        'fold',
      ]);
    }
    if (text.contains('lip') ||
        text.contains('labio') ||
        text.contains('labial') ||
        text.contains('buze') ||
        text.contains('aumento de labios')) {
      add(['lip', 'lips', 'labio', 'labios', 'labial', 'buze']);
    }
    if (text.contains('cheek') ||
        text.contains('pómulo') ||
        text.contains('pomulo') ||
        text.contains('pomet') ||
        text.contains('malar')) {
      add([
        'cheek',
        'cheeks',
        'pomulo',
        'pómulo',
        'pometi',
        'pomeți',
        'pomet',
        'malar',
        'volumizare',
      ]);
    }
    if (text.contains('jaw') ||
        text.contains('jawline') ||
        text.contains('mentón') ||
        text.contains('menton') ||
        text.contains('mandib')) {
      add(['jaw', 'jawline', 'menton', 'mentón', 'mandib']);
    }
    if (text.contains('botox') ||
        text.contains('wrinkle') ||
        text.contains('toxina') ||
        text.contains('tóxina') ||
        text.contains('anti-wrinkle') ||
        text.contains('neuromodul')) {
      add([
        'botox',
        'botulin',
        'toxina',
        'vistabel',
        'dysport',
        'xeomin',
        'neuromodul',
        'arruga',
        'arrugas',
        'wrinkle',
      ]);
    }
    if (text.contains('filler') ||
        text.contains('relleno') ||
        text.contains('dermal')) {
      add([
        'filler',
        'fillers',
        'relleno',
        'rellenos',
        'teosyal',
        'juvederm',
        'restylane',
        'injectable',
        'injectables',
        'hyaluron',
        ...exploreLocalProcedureTokens('filler'),
      ]);
    }
    if (text.contains('profhilo') ||
        text.contains('skin booster') ||
        text.contains('skinbooster') ||
        text.contains('polynucleotid') ||
        text.contains('hydrafacial') ||
        text.contains('biostimulator') ||
        text.contains('sunekos') ||
        text.contains('jalupro')) {
      add([
        'profhilo',
        'skinbooster',
        'skin booster',
        'polynucleotide',
        'polinucleotide',
        'pdrn',
        'hydrafacial',
        'biostimulator',
        'mesotherapy',
        'exosome',
        ...exploreLocalProcedureTokens('skin'),
      ]);
    }
    if (text.contains('rhino') ||
        text.contains('nose job') ||
        text.contains('nose reshaping') ||
        text.contains('rinoplast')) {
      add([
        'rhinoplasty',
        'rinoplastie',
        'rinoplast',
        'rhinoplast',
        'nose job',
        'nose reshaping',
        ...exploreLocalProcedureTokens('rhinoplasty'),
      ]);
    }
    if (text.contains('peel') || text.contains('peeling')) {
      add([
        'peel',
        'peeling',
        'tca',
        'glycolic',
        'jessner',
        'mandelic',
        'chimic',
        ...exploreLocalProcedureTokens('peel'),
      ]);
    }
    if (text.contains('laser') ||
        text.contains('epilare') ||
        text.contains('epilat') ||
        text.contains('depilacion') ||
        text.contains('ipl') ||
        text.contains('diode') ||
        text.contains('fraxel') ||
        text.contains('hair removal')) {
      add([
        'laser',
        'epilare',
        'epilat',
        'depilacion',
        'depilacion laser',
        'diode',
        'ipl',
        'fraxel',
        'alexandrite',
        'co2',
        ...exploreLocalProcedureTokens('laser'),
      ]);
    }
    if (text.contains('breast') ||
        text.contains('boob') ||
        text.contains('mamar') ||
        text.contains('mammaire') ||
        text.contains('mastopex') ||
        text.contains('mamoplast') ||
        text.contains('mastoplast')) {
      add(_kExploreBreastOfferKeywords);
      add(exploreLocalProcedureTokens('breast'));
    }
    if ((text.contains('hair transplant') ||
            text.contains('fue') ||
            text.contains('dhi') ||
            text.contains('transplant par') ||
            text.contains('implant par') ||
            text.contains('implant de par')) &&
        !text.contains('laser') &&
        !text.contains('hair removal') &&
        !text.contains('epilare')) {
      add([
        'hair',
        'fue',
        'dhi',
        'graft',
        'follicle',
        'capil',
        'implant-par',
        'transplant-par',
        'implant par',
        'transplant par',
      ]);
      add(exploreLocalProcedureTokens('hair'));
    }

    if (out.isEmpty) {
      for (final token in text.split(RegExp(r'[^a-záéíóúàèìòùäëïöüñ]+'))) {
        if (token.length < 4) continue;
        if (_genericPriceStopwords.contains(token)) continue;
        out.add(token);
      }
    }
    return out.toList();
  }

  static const _genericPriceStopwords = {
    'dermal',
    'filler',
    'fillers',
    'acid',
    'hialuronic',
    'hyaluronic',
    'hialuronico',
    'hialurónico',
    'facial',
    'chemical',
    'treatment',
    'clinic',
    'clinica',
    'clínica',
    'price',
    'from',
    'with',
    'that',
    'this',
    'procedure',
    'injectable',
    'injectables',
    'barcelona',
    'madrid',
    'milan',
    'london',
    'paris',
    'istanbul',
  };

  /// Laser "from" price: bikini/inguinal when listed (Sandal Spa 130 RON),
  /// not a cheaper underarm/decollete row (120) or a micro facial zone (70).
  List<OpenAIProfileProcedureRow> _preferLaserHairRemovalStartingRows(
    List<OpenAIProfileProcedureRow> rows,
  ) {
    if (rows.length <= 1) return rows;
    bool micro(String raw) {
      final n = raw.toLowerCase();
      return n.contains('mustat') ||
          n.contains('pomet') ||
          n.contains('barbie') ||
          n.contains('degete') ||
          n.contains('perciun') ||
          n.contains('upper lip') ||
          n.contains('chin') ||
          n.contains('finger') ||
          n.contains('toe');
    }

    bool bikiniOrInguinal(String raw) {
      final n = raw.toLowerCase();
      return n.contains('bikini') ||
          n.contains('inghinal') ||
          n.contains('inguinal') ||
          n.contains('brazilian') ||
          n.contains('intimate');
    }

    final bikini = rows.where((p) => bikiniOrInguinal(p.name)).toList();
    if (bikini.isNotEmpty) return bikini;
    final body = rows.where((p) => !micro(p.name)).toList();
    return body.isNotEmpty ? body : rows;
  }

  bool _extractedRowMatchesProcedure({
    required String rowName,
    required String procedure,
    required String brand,
  }) {
    if (_extractedRowIsWrongCategory(rowName: rowName, procedure: procedure)) {
      return false;
    }
    final keywords = _procedureConfirmKeywords(procedure, brand);
    if (keywords.isEmpty) return false;
    final name = rowName.toLowerCase();
    return keywords.any(
      (k) => k.contains(' ') ? name.contains(k) : _windowHasKeyword(name, k),
    );
  }

  int _compareExtractedProcedureRows(
    OpenAIProfileProcedureRow a,
    OpenAIProfileProcedureRow b,
    String procedure,
  ) {
    final sa = _extractedRowMatchScore(rowName: a.name, procedure: procedure);
    final sb = _extractedRowMatchScore(rowName: b.name, procedure: procedure);
    if (sa != sb) return sb.compareTo(sa);
    final ba = _extractedRowBaseRank(a, procedure);
    final bb = _extractedRowBaseRank(b, procedure);
    if (ba != bb) return bb.compareTo(ba);
    return a.priceMin.compareTo(b.priceMin);
  }

  /// Closest procedure-price row wins. Exact name > base/standard phrase >
  /// loose keyword. Subtype (FUE) still ranks above a cheaper family-
  /// adjacent row (Second Session DHI).
  int _extractedRowMatchScore({
    required String rowName,
    required String procedure,
  }) {
    final n = rowName.toLowerCase().trim();
    final p = procedure.toLowerCase().trim();
    if (n.isEmpty || p.isEmpty) return 0;
    var score = 0;
    final topic = exploreProcedurePriceTopic(procedure).toLowerCase();
    if (n == p || n == topic) {
      score = 100;
    } else if (p.isNotEmpty &&
        (n.startsWith(p) || (p.startsWith(n) && n.length >= 6))) {
      score = 96;
    } else if (topic.isNotEmpty &&
        _extractedRowLooksLikeBaseTreatmentName(n, topic)) {
      score = 92;
    } else if (topic.isNotEmpty && n.contains(topic)) {
      // Every "Botox …" row used to tie at 90, then cheapest won.
      score = 72;
      if (_zoneCountHint(n) == 3) score = 84;
      if (_extractedRowLooksLikeSingleArea(n) || _zoneCountHint(n) == 1) {
        score = 58;
      }
    } else if (topic.isNotEmpty && topic.contains(n) && n.length >= 4) {
      score = 80;
    }

    final wantsFue = p.contains('fue') || topic.contains('fue');
    final wantsDhi = p.contains('dhi');
    if (isHairExploreProcedure(procedure)) {
      if (wantsFue && n.contains('fue')) {
        score = math.max(score, 92);
      } else if (wantsDhi && n.contains('dhi') && !n.contains('session')) {
        score = math.max(score, 92);
      } else if (n.contains('hair transplant') ||
          n.contains('transplant') ||
          n.contains('injerto') ||
          n.contains('greffe') ||
          n.contains('capilar') ||
          n.contains('implant capilar') ||
          n.contains('implant par') ||
          n.contains('transplant par') ||
          n.contains('fir cu fir') ||
          n.contains('transplant de par')) {
        score = math.max(score, 70);
      } else if (n.contains('dhi') ||
          n.contains('fue') ||
          n.contains('graft')) {
        score = math.max(score, 45);
      }
    }

    final wantFam = exploreTreatmentFamily(procedure);
    final gotFam = exploreTreatmentFamily(rowName);
    if (wantFam != ExploreTreatmentFamily.other && wantFam == gotFam) {
      score = math.max(score, 40);
    }
    if (wantFam == ExploreTreatmentFamily.laser &&
        (n.contains('hair removal') ||
            n.contains('epilare') ||
            n.contains('depilacion') ||
            n.contains('depilación') ||
            n.contains('epilasyon'))) {
      score = math.max(score, 88);
    }

    if (score == 0 &&
        _extractedRowMatchesProcedure(
          rowName: rowName,
          procedure: procedure,
          brand: '',
        )) {
      score = 20;
    }

    if (RegExp(
      r'\b(second|2nd|extra|additional)\s+session\b'
      r'|\bsession\s*[2-9]\b'
      r'|\bsesiune\b'
      r'|\bsedinta\b',
      caseSensitive: false,
    ).hasMatch(n)) {
      score -= 50;
    }
    if (RegExp(
      r'\+|\bpackage\b|\bcombo\b|\bpachet\b',
      caseSensitive: false,
    ).hasMatch(n)) {
      score -= 15;
    }
    if (RegExp(r'(?:per|/)\s*(?:iu|unit|unidad|graft)').hasMatch(n)) {
      score -= 40;
    }
    return score;
  }

  bool _extractedRowIsWrongCategory({
    required String rowName,
    required String procedure,
  }) {
    final n = rowName.toLowerCase();
    final want = exploreTreatmentFamily(procedure);
    final got = exploreTreatmentFamily(rowName);

    if (n.contains('liposuc') ||
        n.contains('lipovaser') ||
        n.contains('lipo vaser') ||
        n.contains('lipo-vaser')) {
      return true;
    }

    if (want == ExploreTreatmentFamily.breast &&
        (n.contains('testicul') ||
            n.contains('testicle') ||
            n.contains('scrot') ||
            n.contains('penil') ||
            n.contains('penile') ||
            _exploreTextIsBreastReconstruction(n))) {
      return true;
    }

    if (want != ExploreTreatmentFamily.other &&
        got != ExploreTreatmentFamily.other &&
        want != got) {
      return true;
    }

    switch (want) {
      case ExploreTreatmentFamily.filler:
        if (n.contains('hifu') ||
            n.contains('ulthera') ||
            n.contains('ultraformer')) {
          return true;
        }
        if (n.contains('lip lift') ||
            n.contains('lip-lift') ||
            n.contains('liplift') ||
            n.contains('queiloplast') ||
            n.contains('lifting de labio')) {
          return true;
        }
        break;
      case ExploreTreatmentFamily.botox:
        if (_extractedRowLooksLikeClinicProgram(n) &&
            !n.contains('toxina') &&
            !n.contains('botox') &&
            !n.contains('botulin')) {
          return true;
        }
        if (n.contains('masseter') ||
            n.contains('brux') ||
            n.contains('hiperhidros') ||
            n.contains('hyperhidros') ||
            n.contains('platism') ||
            n.contains('gingival') ||
            n.contains('gummy')) {
          return true;
        }
        if ((n.contains('filler') || n.contains('relleno')) &&
            !n.contains('botox') &&
            !n.contains('toxina') &&
            !n.contains('neuromodul')) {
          return true;
        }
        break;
      case ExploreTreatmentFamily.peel:
        if ((n.contains('hifu') ||
                n.contains('ulthera') ||
                n.contains('laser') ||
                n.contains('fue') ||
                n.contains('dhi')) &&
            !n.contains('peel') &&
            !n.contains('peeling') &&
            !n.contains('tca')) {
          return true;
        }
        break;
      case ExploreTreatmentFamily.laser:
        if ((n.contains('fue') ||
                n.contains('dhi') ||
                n.contains('transplant') ||
                n.contains('rhino') ||
                n.contains('rinoplast')) &&
            !n.contains('laser') &&
            !n.contains('epil') &&
            !n.contains('depil')) {
          return true;
        }
        break;
      case ExploreTreatmentFamily.hair:
        if ((n.contains('laser') ||
                n.contains('epil') ||
                n.contains('depil')) &&
            !n.contains('transplant') &&
            !n.contains('fue') &&
            !n.contains('dhi') &&
            !n.contains('graft')) {
          return true;
        }
        break;
      case ExploreTreatmentFamily.rhinoplasty:
        if ((n.contains('filler') ||
                n.contains('botox') ||
                n.contains('peel')) &&
            !n.contains('rhino') &&
            !n.contains('rinoplast') &&
            !n.contains('nose')) {
          return true;
        }
        break;
      default:
        break;
    }
    return false;
  }

  bool _textHasSynonym(String haystack, String synonym) {
    final s = synonym.trim().toLowerCase();
    if (s.isEmpty) return false;
    if (s.contains(' ')) return haystack.contains(s);
    return _windowHasKeyword(haystack, s);
  }

  bool _windowHasKeyword(String window, String keyword) {
    if (keyword.isEmpty) return false;
    final escaped = RegExp.escape(keyword);
    // Allow a short suffix so "neuromodul" matches "neuromodulators"
    // and "labio" matches "labios", without "lip" matching "liposuction".
    final suffix = keyword.length >= 5 ? r'[a-zà-ÿ]{0,8}' : '';
    return RegExp(
      '(^|[^a-zà-ÿ])$escaped$suffix([^a-zà-ÿ]|\$)',
      caseSensitive: false,
    ).hasMatch(window);
  }

  // ignore: unused_element
  bool _windowMentionsCurrency(String window, String currency) {
    final t = window.toLowerCase();
    final c = currency.trim().toLowerCase();
    if (c.isEmpty) {
      return t.contains('€') ||
          t.contains('eur') ||
          t.contains('£') ||
          t.contains(r'$') ||
          t.contains('ron') ||
          t.contains('lei');
    }
    return _pageTextMentionsCurrency(window, currency);
  }

  bool _pageTextMentionsCurrency(String text, String currency) {
    final t = text.toLowerCase();
    final c = currency.trim().toLowerCase();
    if (c.isEmpty) return true;
    if (c == '€' || c == 'eur') {
      return t.contains('€') || t.contains('eur') || t.contains('euro');
    }
    if (c == '£' || c == 'gbp') {
      return t.contains('£') || t.contains('gbp') || t.contains('pound');
    }
    if (c == r'$' || c == 'usd') {
      return t.contains(r'$') || t.contains('usd') || t.contains('dollar');
    }
    if (c == 'ron' || c == 'lei') {
      return t.contains('ron') || t.contains('lei');
    }
    if (c == 'try' || c == '₺') {
      return t.contains('try') || t.contains('₺') || t.contains('tl');
    }
    if (c == '₩' || c == 'krw') {
      return t.contains('₩') || t.contains('krw') || t.contains('won');
    }
    if (c == 'aed') {
      return t.contains('aed') ||
          t.contains('dirham') ||
          t.contains('درهم') ||
          t.contains('د.إ');
    }
    if (c == 'hkd') return t.contains('hkd') || t.contains('hk\$');
    return t.contains(c);
  }

  /// Extracts clinic name from area string
  // ignore: unused_element
  String _extractClinicNameFromArea(String area) {
    return area.split('·').first.trim();
  }

  /// Apply a cached Places lookup (rating / reviews / verified host) without
  /// calling the Places API. Website-denylist behavior stays the same.
  OpenAIClinic? _clinicFromCachedPlace(
    OpenAIClinic clinic,
    ExplorePlaceCacheEntry cached,
  ) {
    if (!cached.matched) return null;
    final placesHost = _normalizeProbeHost(cached.websiteHost);
    final aiDomainRaw = _extractDomain(clinic.area);
    final aiHost = _normalizeProbeHost(aiDomainRaw);
    if (_denylistedWebsiteHost(aiHost) || _denylistedWebsiteHost(placesHost)) {
      return null;
    }

    final curated = exploreCuratedPriceIsTrusted(clinic);
    // Alias writes (mapsName / host brand) can make Clinic A reuse Clinic B's
    // cache row. Reject host mismatches so Alter-MED never inherits
    // chirurgie-estetica.md identity (or the reverse).
    final hostMismatch =
        aiHost.isNotEmpty &&
        placesHost.isNotEmpty &&
        !_isGenericSocialOrDirectoryHost(placesHost) &&
        !_hostsSameDomainOrSubdomain(aiHost, placesHost);
    if (hostMismatch && !exploreMapsProviderIdentityMatches(
      sourceName: clinic.name, mapsName: cached.mapsName,
      sourceHost: aiHost, mapsHost: placesHost,
      marketplace: exploreClinicUsesMarketplacePriceSource(clinic),
    )) return clinic;
    // Old mismatch entries may have deliberately saved an empty websiteHost.
    // Do not apply another clinic's score just because that field is empty.
    if (aiHost.isNotEmpty && placesHost.isEmpty &&
        !_mapsNameAgreesWithHost(cached.mapsName, aiHost) &&
        !exploreMapsProviderIdentityMatches(sourceName: clinic.name,
            mapsName: cached.mapsName, sourceHost: aiHost, mapsHost: '',
            marketplace: exploreClinicUsesMarketplacePriceSource(clinic))) return clinic;

    String correctedArea = clinic.area;
    // Curated rows already carry the audited street address — do not swap the
    // host or district from a Places cache hit.
    if (!curated && placesHost.isNotEmpty) {
      if (aiDomainRaw.isNotEmpty) {
        correctedArea = clinic.area.replaceFirst(aiDomainRaw, placesHost);
      } else {
        final district = clinic.area.split('·').first.trim();
        correctedArea = '$district · $placesHost';
      }
    }
    final sourceUrl = _sourceUrlFromArea(clinic.area);
    final rating = cached.rating > 0 ? cached.rating : clinic.rating;
    final reviews = cached.reviews > 0 ? cached.reviews : clinic.reviews;
    final lat = (!curated && cached.lat != 0) ? cached.lat : clinic.coord.lat;
    final lng = (!curated && cached.lng != 0) ? cached.lng : clinic.coord.lng;
    return clinic.copyWith(
      name: () {
        // Public-price audit names must stay as imported.
        if (curated) return clinic.name;
        final mapsName = cached.mapsName.trim();
        if (mapsName.isNotEmpty &&
            !exploreClinicNameLooksLikeSeoHeadline(mapsName) &&
            (aiHost.isEmpty || _mapsNameAgreesWithHost(mapsName, aiHost))) {
          return mapsName;
        }
        return clinic.name;
      }(),
      area: _withSourceUrl(correctedArea, sourceUrl ?? ''),
      rating: rating,
      reviews: reviews,
      lat: lat,
      lng: lng,
    );
  }

  void _writePlaceCache({
    required OpenAIClinic clinic,
    required String city,
    required GooglePlacesResult matched,
    required String placesHost,
  }) {
    unawaited(
      ExplorePlaceCacheStore.instance.put(
        city: city,
        clinicName: clinic.name,
        rating: matched.rating,
        reviews: matched.reviewsTotal,
        websiteHost: placesHost,
        mapsName: matched.name.trim(),
        lat: matched.lat,
        lng: matched.lng,
      ),
    );
  }

  Future<OpenAIClinic?> _enrichOrFilterClinicWithPlaces(
    OpenAIClinic clinic,
    String city,
  ) async {
    try {
      final aiDomainRaw = _extractDomain(clinic.area);
      final aiHost = _normalizeProbeHost(aiDomainRaw);
      final lookupQueries = _placesClinicLookupQueries(clinic);
      GooglePlacesResult? place;
      var lookupFailed = false;
      for (final q in lookupQueries) {
        try {
          place = await _places.lookupClinic(clinicName: q, city: city)
              .timeout(const Duration(seconds: 10));
        } catch (error) {
          lookupFailed = true;
          debugPrint('[GP] Places lookup unavailable: ${clinic.name} · $city · $error');
          continue;
        }
        if (place != null) {
          final candidateHost = _normalizeProbeHost(
            Uri.tryParse(place.website.contains('://')
                ? place.website : 'https://${place.website}')?.host ?? '',
          );
          final sameWebsite = aiHost.isNotEmpty && candidateHost.isNotEmpty &&
              _hostsSameDomainOrSubdomain(aiHost, candidateHost);
          final sameName = _mapsNameAgreesWithHost(place.name, aiHost) ||
              exploreMapsProviderIdentityMatches(
                sourceName: clinic.name, mapsName: place.name,
                sourceHost: aiHost, mapsHost: candidateHost,
                marketplace: exploreClinicUsesMarketplacePriceSource(clinic),
              );
          if (aiHost.isNotEmpty && !sameWebsite && !sameName) {
            debugPrint('[GP] Places identity rejected: ${clinic.name} '
                'source=$aiHost candidate=$candidateHost');
            place = null;
            continue;
          }
          if (place.address.trim().isNotEmpty && city.trim().isNotEmpty &&
              !exploreMarketplaceLocationStronglyMatches(city: city, placeAddress: place.address)) {
            debugPrint('[GP] Places city rejected: ${clinic.name} '
                'expected=$city candidate=${place.address}');
            place = null;
            continue;
          }
          if (q.toLowerCase() != clinic.name.toLowerCase()) {
            debugPrint('[GP] Places match via "$q": ${clinic.name}');
          }
          break;
        }
      }

      if (place == null) {
        debugPrint('[GP] No Google Maps match: ${clinic.name}');
        if (!lookupFailed) {
          ExplorePlaceCacheStore.instance.rememberMiss(city: city, clinicName: clinic.name);
        }
        return null;
      }
      final matched = place;

      OpenAIClinic withMapsRating({String? area, String? name}) {
        final rating = matched.rating > 0 ? matched.rating : clinic.rating;
        final reviews = matched.reviewsTotal > 0
            ? matched.reviewsTotal
            : clinic.reviews;
        final lat = matched.lat != 0 ? matched.lat : clinic.coord.lat;
        final lng = matched.lng != 0 ? matched.lng : clinic.coord.lng;
        final hostName = _clinicNameFromHost(aiHost);
        final explicit = (name ?? '').trim();
        final mapsName = explicit.isNotEmpty ? explicit : matched.name.trim();
        final clinicNameIsSeo = exploreClinicNameLooksLikeSeoHeadline(
          clinic.name,
        );
        final mapsOk =
            mapsName.isNotEmpty &&
            !_serpTitleLooksLikeSeoHeadline(mapsName) &&
            (explicit.isNotEmpty ||
                clinicNameIsSeo ||
                _mapsNameAgreesWithHost(mapsName, aiHost));
        final nextName = mapsOk
            ? mapsName
            : (exploreClinicNameNeedsMapsRefresh(clinic) && hostName.isNotEmpty
                  ? hostName
                  : clinic.name);
        if (rating > 0) {
          debugPrint(
            '[GP] Places rating for $nextName: '
            '$rating (${reviews} reviews)',
          );
        }
        return clinic.copyWith(
          name: nextName,
          area: area ?? clinic.area,
          rating: rating,
          reviews: reviews,
          lat: lat,
          lng: lng,
        );
      }

      // City sanity check before copying a rating from the wrong city.
      final addressLo = matched.address.toLowerCase();
      final cityLo = city.trim().toLowerCase();
      final cityKey = cityLo.isEmpty
          ? ''
          : cityLo.split(RegExp(r'[,·]')).first.trim();
      if (cityKey.isNotEmpty && addressLo.isNotEmpty) {
        final cityTokens = cityKey
            .split(RegExp(r'\s+'))
            .where((t) => t.length >= 3)
            .toList();
        final tokensMatch =
            cityTokens.isEmpty ||
            cityTokens.every((t) => addressLo.contains(t)) ||
            exploreMarketplaceLocationStronglyMatches(city: city, placeAddress: matched.address);
        if (explorePlacesAddressConflictsWithSearchCity(
          matched.address,
          city,
        )) {
          debugPrint(
            '[GP] Filtered wrong-city clinic: ${clinic.name} — '
            'expected "$cityKey", got "${matched.address}"',
          );
          ExplorePlaceCacheStore.instance.rememberMiss(
            city: city,
            clinicName: clinic.name,
          );
          return null;
        }
        if (!tokensMatch) {
          debugPrint(
            '[GP] Filtered wrong-city clinic: ${clinic.name} — '
            'expected "$cityKey", got "${matched.address}"',
          );
          ExplorePlaceCacheStore.instance.rememberMiss(
            city: city,
            clinicName: clinic.name,
          );
          return null;
        }
      }

      if (!_looksLikeAestheticMedicalBusiness(
        clinicName: clinic.name,
        place: matched,
      )) {
        // Compare cards that already have a verified price should still show
        // the Maps star. Editorial text is too noisy to throw the rating away
        // (e.g. "their" matching reject token "hair").
        if (matched.rating > 0) {
          debugPrint(
            '[GP] Maps listing failed aesthetic check — keeping rating: '
            '${clinic.name} (${matched.rating}, ${matched.address})',
          );
          _writePlaceCache(
            clinic: clinic,
            city: city,
            matched: matched,
            placesHost: '',
          );
          return withMapsRating();
        }
        debugPrint('[GP] Filtered non-aesthetic business: ${clinic.name}');
        ExplorePlaceCacheStore.instance.rememberMiss(
          city: city,
          clinicName: clinic.name,
        );
        return null;
      }

      var placesHost = '';
      final w = matched.website.trim();
      final uri = w.isEmpty
          ? null
          : Uri.tryParse(w.contains('://') ? w : 'https://$w');
      if (uri != null && uri.hasAuthority && uri.host.isNotEmpty) {
        placesHost = _normalizeProbeHost(uri.host);
      }

      if (matched.website.trim().isEmpty) {
        debugPrint(
          '[GP] Maps listing has no website — keeping rating: ${clinic.name}',
        );
        _writePlaceCache(
          clinic: clinic,
          city: city,
          matched: matched,
          placesHost: '',
        );
        return withMapsRating();
      }

      if (placesHost.isEmpty ||
          uri == null ||
          !uri.hasScheme ||
          !uri.hasAuthority) {
        debugPrint(
          '[GP] Maps website unusable — keeping rating: ${clinic.name}',
        );
        _writePlaceCache(
          clinic: clinic,
          city: city,
          matched: matched,
          placesHost: placesHost,
        );
        return withMapsRating();
      }

      if (_denylistedWebsiteHost(aiHost) ||
          _denylistedWebsiteHost(placesHost)) {
        debugPrint('[GP] Filtered denylisted clinic website: ${clinic.name}');
        ExplorePlaceCacheStore.instance.rememberMiss(
          city: city,
          clinicName: clinic.name,
        );
        return null;
      }

      if (aiHost.isNotEmpty) {
        if (_isGenericSocialOrDirectoryHost(placesHost)) {
          if (!_hostsSameDomainOrSubdomain(aiHost, placesHost)) {
            debugPrint(
              '[GP] AI domain≠Places social website, keeping source: ${clinic.name} '
              'ai=$aiHost places=$placesHost',
            );
          }
        } else if (!_hostsSameDomainOrSubdomain(aiHost, placesHost)) {
          final mapsName = matched.name.trim();
          final useMapsName = _mapsNameAgreesWithHost(mapsName, aiHost);
          if (!useMapsName) return clinic;
          debugPrint(
            '[GP] AI domain≠Places website — keep source host: ${clinic.name} '
            'ai=$aiHost places=$placesHost'
            '${useMapsName ? ' · Maps name' : ''}',
          );
          _writePlaceCache(
            clinic: clinic,
            city: city,
            matched: matched,
            placesHost: '',
          );
          return withMapsRating(
            name: useMapsName
                ? mapsName
                : (_clinicNameFromHost(aiHost).isNotEmpty
                      ? _clinicNameFromHost(aiHost)
                      : clinic.name),
          );
        }
      }

      // Same website as Serp/source — use the Maps business name.
      String correctedArea = clinic.area;
      if (placesHost.isNotEmpty) {
        if (aiDomainRaw.isNotEmpty) {
          correctedArea = clinic.area.replaceFirst(aiDomainRaw, placesHost);
        } else {
          final district = clinic.area.split('·').first.trim();
          correctedArea = '$district · $placesHost';
        }
        if (aiHost != placesHost) {
          debugPrint(
            '[GP] Using Places domain for ${clinic.name}: '
            '$aiDomainRaw → $placesHost',
          );
        }
      }

      // Replace "District" placeholder with real area from Places
      final loArea = correctedArea.toLowerCase();
      if (loArea.startsWith('district') ||
          loArea.contains('· district ·') ||
          loArea.contains('district ·')) {
        final realDistrict = matched.area.isNotEmpty
            ? matched.area
            : matched.address.isNotEmpty
            ? matched.address.split(',').first.trim()
            : '';
        if (realDistrict.isNotEmpty) {
          correctedArea = correctedArea.replaceAll(
            RegExp(r'\bDistrict\b', caseSensitive: false),
            realDistrict,
          );
          debugPrint(
            '[GP] Replaced District placeholder with: '
            '"$realDistrict" for ${clinic.name}',
          );
        }
      }

      final sourceUrl = _sourceUrlFromArea(clinic.area);
      _writePlaceCache(
        clinic: clinic,
        city: city,
        matched: matched,
        placesHost: placesHost,
      );
      final mapsName = matched.name.trim();
      final curated = exploreCuratedPriceIsTrusted(clinic);
      final mapsOk =
          !curated &&
          mapsName.isNotEmpty &&
          !_serpTitleLooksLikeSeoHeadline(mapsName) &&
          (aiHost.isEmpty || _mapsNameAgreesWithHost(mapsName, aiHost));
      return withMapsRating(
        area: curated
            ? clinic.area
            : _withSourceUrl(correctedArea, sourceUrl ?? ''),
        name: mapsOk ? mapsName : clinic.name,
      );
    } catch (_) {
      return clinic;
    }
  }

  /// Extracts domain from area string like "Sector 1 · ultraestetic.ro · 0.0 mi"
  String _extractDomain(String area) {
    final src = _sourceUrlFromArea(area);
    if (src != null) {
      final u = Uri.tryParse(src);
      if (u != null && u.host.isNotEmpty) return u.host;
    }
    final parts = area.split('·');
    for (final part in parts) {
      final trimmed = part.trim();
      if (trimmed.startsWith('src:')) continue;
      if (trimmed.contains('.') &&
          !trimmed.contains(' ') &&
          trimmed.length > 4) {
        return trimmed;
      }
    }
    return '';
  }

  bool _isSessionBlockedHost(String hostOrUrl) {
    final h = _stripWww(_normalizeProbeHost(hostOrUrl));
    return h.isNotEmpty && _http403Domains.contains(h);
  }

  bool _rendererHostBudgetSpent(String hostOrUrl) {
    final h = _stripWww(_normalizeProbeHost(hostOrUrl));
    return h.isNotEmpty && (_rendersPerHost[h] ?? 0) >= _kMaxRendersPerHost;
  }

  void _rememberHttp403(String hostOrUrl) {
    final h = _stripWww(_normalizeProbeHost(hostOrUrl));
    if (h.isEmpty) return;
    if (_http403Domains.add(h)) {
      debugPrint('[GP] Domain 403 — skip for rest of session: $h');
    }
  }

  String _serpApiKey() => (dotenv.env['SERPAPI_API_KEY'] ?? '').trim();

  String _serperApiKey() => (dotenv.env['SERPER_API_KEY'] ?? '').trim();

  String _firecrawlApiKey() => (dotenv.env['FIRECRAWL_API_KEY'] ?? '').trim();

  String _zyteApiKey() => (dotenv.env['ZYTE_API_KEY'] ?? '').trim();

  String _dataForSeoLogin() => (dotenv.env['DATAFORSEO_LOGIN'] ?? '').trim();

  String _dataForSeoPassword() =>
      (dotenv.env['DATAFORSEO_PASSWORD'] ?? '').trim();

  ExploreSerpProviderKind _serpProvider() {
    // Healthy Serper stays first (fast + cheap).
    if (!_serperDisabled && _serperApiKey().isNotEmpty) {
      return ExploreSerpProviderKind.serper;
    }
    // Serper dead (credits/403): skip DataForSEO for live Explore. It serializes
    // and routinely misses the 8s soft deadline; SerpApi finishes in time.
    if (_serperDisabled && _serpApiKey().isNotEmpty) {
      return ExploreSerpProviderKind.serpApi;
    }
    return exploreSerpProviderKind(
      serperApiKey: _serperDisabled ? '' : _serperApiKey(),
      dataForSeoLogin: _dataForSeoDisabled ? '' : _dataForSeoLogin(),
      dataForSeoPassword: _dataForSeoDisabled ? '' : _dataForSeoPassword(),
      serpApiKey: _serpApiKey(),
    );
  }

  /// True when any discovery upstream can answer. Discovery only ever yields
  /// URLs and titles; prices still come from the clinic's own page.
  bool _webDiscoveryConfigured() =>
      _serpProvider() != ExploreSerpProviderKind.none;

  Future<List<_SerpSearchResult>> _searchSerpApi(
    String query, {
    Duration? timeout,
    String hl = '',
    String gl = '',
    ExploreRequestMode mode = ExploreRequestMode.foreground,
    String procedureKey = '',
    bool allPreview = false,
    bool uiDeadlinePassed = false,
  }) {
    final q = query.trim();
    if (q.isEmpty) return Future.value(const []);
    final cacheKey = '${hl.trim().toLowerCase()}|${gl.trim().toLowerCase()}|$q'
        .toLowerCase();
    final pending = _serpApiQueryCache[cacheKey];
    if (pending != null) {
      debugPrint('[GP] Discovery cache HIT: $q');
      return pending;
    }
    final fut =
        _searchSerpApiUncached(
          q,
          timeout: timeout,
          hl: hl,
          gl: gl,
          mode: mode,
          procedureKey: procedureKey,
          allPreview: allPreview,
          uiDeadlinePassed: uiDeadlinePassed,
        ).then((results) {
          if (results.isEmpty) {
            _serpApiQueryCache.remove(cacheKey);
          }
          return results;
        });
    _serpApiQueryCache[cacheKey] = fut;
    return fut;
  }

  /// Native-language and English Google queries in the same timeout window.
  /// [stopWhenFound] runs them one at a time and keeps the second query
  /// unbilled when the first already answered — worth it for `site:` lookups,
  /// which Google charges five times the plain rate for.
  Future<List<_SerpSearchResult>> _searchSerpApiBilingual({
    required List<String> queries,
    required String city,
    required Duration timeout,
    bool stopWhenFound = false,
    ExploreRequestMode mode = ExploreRequestMode.foreground,
    String procedureKey = '',
    bool allPreview = false,
    bool uiDeadlinePassed = false,
  }) async {
    final qs = [
      for (final q in queries)
        if (q.trim().isNotEmpty) q.trim(),
    ];
    if (qs.isEmpty) return const [];
    final loc = exploreCityPriceSearchTerms(
      city,
      countryCode: _countryCodeForCity(city),
    );
    final gl = exploreGoogleGl(
      loc.lang,
      city,
      countryCode: _countryCodeForCity(city),
    );
    String hlFor(String q) =>
        q.toLowerCase().contains('prices in') ||
            q.toLowerCase().contains('price ')
        ? 'en'
        : (loc.lang == 'en' ? 'en' : loc.lang);
    final rows = <List<_SerpSearchResult>>[];
    if (stopWhenFound) {
      for (final q in qs) {
        final hit = await _searchSerpApi(
          q,
          timeout: timeout,
          hl: hlFor(q),
          gl: gl,
          mode: mode,
          procedureKey: procedureKey,
          allPreview: allPreview,
          uiDeadlinePassed: uiDeadlinePassed,
        );
        rows.add(hit);
        if (hit.isNotEmpty || _serpApiLastTimedOut) break;
      }
    } else {
      // Bound concurrency via coordinator; still launch at most 2 in parallel.
      final capped = qs.take(2).toList();
      rows.addAll(
        await Future.wait([
          for (final q in capped)
            _searchSerpApi(
              q,
              timeout: timeout,
              hl: hlFor(q),
              gl: gl,
              mode: mode,
              procedureKey: procedureKey,
              allPreview: allPreview,
              uiDeadlinePassed: uiDeadlinePassed,
            ),
        ]),
      );
    }
    final out = <_SerpSearchResult>[];
    final seen = <String>{};
    for (final list in rows) {
      for (final r in list) {
        final k = r.link.trim().toLowerCase();
        if (k.isEmpty || !seen.add(k)) continue;
        out.add(r);
      }
    }
    return out;
  }

  Future<List<_SerpSearchResult>> _searchSerpApiUncached(
    String query, {
    Duration? timeout,
    String hl = '',
    String gl = '',
    ExploreRequestMode mode = ExploreRequestMode.foreground,
    String procedureKey = '',
    bool allPreview = false,
    bool uiDeadlinePassed = false,
  }) async {
    if (_discoveryStalled()) {
      _serpApiLastTimedOut = false;
      return const [];
    }
    final rows = await _searchWithProvider(
      query,
      timeout: timeout,
      hl: hl,
      gl: gl,
      mode: mode,
      procedureKey: procedureKey,
      allPreview: allPreview,
      uiDeadlinePassed: uiDeadlinePassed,
    );
    if (_serpApiLastTimedOut) {
      _liveDiscoveryTimeouts++;
    } else if (rows.isNotEmpty) {
      _liveDiscoveryTimeouts = 0;
    }
    return rows;
  }

  Future<List<_SerpSearchResult>> _searchWithProvider(
    String query, {
    Duration? timeout,
    String hl = '',
    String gl = '',
    ExploreRequestMode mode = ExploreRequestMode.foreground,
    String procedureKey = '',
    bool allPreview = false,
    bool uiDeadlinePassed = false,
  }) async {
    switch (_serpProvider()) {
      case ExploreSerpProviderKind.serper:
        return _searchSerper(
          query,
          timeout: timeout,
          hl: hl,
          gl: gl,
          mode: mode,
          procedureKey: procedureKey,
          allPreview: allPreview,
          uiDeadlinePassed: uiDeadlinePassed,
        );
      case ExploreSerpProviderKind.dataForSeo:
        return _searchDataForSeo(query, timeout: timeout, hl: hl, gl: gl);
      case ExploreSerpProviderKind.serpApi:
        return _searchSerpApiHttp(query, timeout: timeout, hl: hl, gl: gl);
      case ExploreSerpProviderKind.none:
        if (!_loggedSerpApiMissingConfig) {
          _loggedSerpApiMissingConfig = true;
          debugPrint(
            '[GP] Discovery skipped — set SERPER_API_KEY (or '
            'DATAFORSEO_LOGIN + DATAFORSEO_PASSWORD, or SERPAPI_API_KEY) '
            'in .env',
          );
        }
        return const [];
    }
  }

  /// Serper discovery: one POST returns the organic page list. The response is
  /// read for URLs and titles only — never for prices.
  Future<List<_SerpSearchResult>> _searchSerper(
    String query, {
    Duration? timeout,
    String hl = '',
    String gl = '',
    ExploreRequestMode mode = ExploreRequestMode.foreground,
    String procedureKey = '',
    bool allPreview = false,
    bool uiDeadlinePassed = false,
  }) async {
    final wait = timeout ?? _kSerpApiTimeout;
    final allowRetry = ExploreRequestCoordinator.instance.mayRetrySerper(
      mode: mode,
      uiDeadlinePassed: uiDeadlinePassed,
      procedureKey: procedureKey,
      allPreview: allPreview,
    );
    final body = jsonEncode(
      exploreSerperRequestBody(query: query, hl: hl, gl: gl),
    );

    return ExploreRequestCoordinator.instance.runSerpQuery<
      List<_SerpSearchResult>
    >(
      queryKey: 'serper|$hl|$gl|${query.trim().toLowerCase()}',
      procedureKey: procedureKey.isNotEmpty ? procedureKey : query,
      mode: mode,
      allPreview: allPreview,
      onBudgetExhausted: () => const <_SerpSearchResult>[],
      run: () async {
        _serpApiCallCount++;
        debugPrint(
          '[GP] Serper query: $query (#$_serpApiCallCount · $mode'
          '${allowRetry ? " · mayRetry" : ""})',
        );
        for (var attempt = 0; attempt < (allowRetry ? 2 : 1); attempt++) {
          if (attempt > 0) {
            if (uiDeadlinePassed ||
                !ExploreRequestCoordinator.instance.mayRetrySerper(
                  mode: mode,
                  uiDeadlinePassed: uiDeadlinePassed,
                  procedureKey: procedureKey,
                  allPreview: allPreview,
                )) {
              return const [];
            }
            await Future<void>.delayed(const Duration(milliseconds: 350));
          }
          _serpApiLastTimedOut = false;
          http.Response res;
          try {
            res = await _client
                .post(
                  exploreSerperEndpoint(),
                  headers: exploreSerperHeaders(_serperApiKey()),
                  body: body,
                )
                .timeout(wait);
          } on TimeoutException catch (e) {
            _serpApiLastTimedOut = true;
            debugPrint('[GP] Serper failed: $e');
            if (allowRetry && attempt == 0) continue;
            return const [];
          } catch (e) {
            debugPrint('[GP] Serper failed: $e');
            if (allowRetry && attempt == 0) continue;
            return const [];
          }

          if (exploreSerperKeyUnusable(res.statusCode) ||
              exploreSerperOutOfCredits(res.statusCode, res.body)) {
            _serperDisabled = true;
            final why = exploreSerperOutOfCredits(res.statusCode, res.body)
                ? 'out of credits'
                : 'HTTP ${res.statusCode}';
            debugPrint(
              '[GP] Serper unusable ($why) — falling back to next search provider',
            );
            final requested = timeout ?? _kSerpApiTimeout;
            final nextTimeout = requested < _kSerpApiTimeout
                ? _kSerpApiTimeout
                : requested;
            return _searchSerpApiUncached(
              query,
              timeout: nextTimeout,
              hl: hl,
              gl: gl,
            );
          }
          if (res.statusCode == 429) _serpApiLastRateLimited = true;
          if (res.statusCode != 200) {
            debugPrint('[GP] Serper HTTP ${res.statusCode}');
            final retry = res.statusCode == 429 || res.statusCode >= 500;
            if (retry && allowRetry && attempt == 0) continue;
            return const [];
          }

          Object? decoded;
          try {
            decoded = jsonDecode(res.body);
          } catch (_) {
            debugPrint('[GP] Serper malformed response');
            return const [];
          }
          final hits = exploreParseSerperOrganic(decoded);
          debugPrint('[GP] Serper results: ${hits.length}');
          return [
            for (final h in hits)
              _SerpSearchResult(
                title: h.title,
                link: h.link,
                snippet: h.snippet,
                displayedLink: h.displayedLink,
              ),
          ];
        }
        return const [];
      },
    );
  }

  /// DataForSEO discovery: one live POST returns the organic page list. The
  /// response is read for URLs and titles only — never for prices.
  Future<List<_SerpSearchResult>> _searchDataForSeo(
    String query, {
    Duration? timeout,
    String hl = '',
    String gl = '',
  }) async {
    final wait = timeout ?? _kSerpApiTimeout;
    final allowRetry = timeout == null || timeout > _kForegroundSerpApiTimeout;
    final body = jsonEncode(
      exploreDataForSeoRequestBody(
        query: query,
        hl: hl,
        gl: gl,
        depth: exploreDataForSeoDepth(query),
      ),
    );

    Future<http.Response?> postOnce() async {
      _serpApiLastTimedOut = false;
      final res = await _withDataForSeoSlot<http.Response>(wait, (
        remaining,
      ) async {
        try {
          return await _client
              .post(
                exploreDataForSeoEndpoint(),
                headers: {
                  'Authorization': exploreDataForSeoAuthHeader(
                    _dataForSeoLogin(),
                    _dataForSeoPassword(),
                  ),
                  'Content-Type': 'application/json',
                },
                body: body,
              )
              .timeout(remaining);
        } on TimeoutException catch (e) {
          debugPrint('[GP] DataForSEO failed: $e');
          return null;
        } catch (e) {
          debugPrint('[GP] DataForSEO failed: $e');
          return null;
        }
      });
      if (res == null) _serpApiLastTimedOut = true;
      return res;
    }

    Future<List<_SerpSearchResult>> disableAndFallBack(String why) {
      _dataForSeoDisabled = true;
      debugPrint('[GP] DataForSEO unusable ($why) — check .env / balance');
      if (_serpApiKey().isNotEmpty) {
        debugPrint('[GP] Discovery falling back to SerpApi for this session');
        return _searchSerpApiHttp(query, timeout: timeout, hl: hl, gl: gl);
      }
      return Future.value(const []);
    }

    _serpApiCallCount++;
    debugPrint('[GP] DataForSEO query: $query (#$_serpApiCallCount)');
    // One retry: Google itself sometimes answers 40101 / a 5xx through
    // DataForSEO, and the same query usually lands on the second attempt.
    for (var attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
      final res = await postOnce();
      if (res == null) return const [];
      final retryHttp = res.statusCode == 429 || res.statusCode >= 500;
      if (res.statusCode == 401 || res.statusCode == 403) {
        return disableAndFallBack('HTTP ${res.statusCode}');
      }
      if (res.statusCode == 402) {
        return disableAndFallBack('HTTP 402 payment required');
      }
      if (res.statusCode == 429) _serpApiLastRateLimited = true;
      if (res.statusCode != 200) {
        debugPrint('[GP] DataForSEO HTTP ${res.statusCode}');
        if (retryHttp && allowRetry && attempt == 0) continue;
        return const [];
      }

      Object? decoded;
      try {
        decoded = jsonDecode(res.body);
      } catch (e) {
        debugPrint('[GP] DataForSEO decode failed: $e');
        return const [];
      }
      final status = exploreDataForSeoStatus(decoded);
      if (status.providerUnusable) return disableAndFallBack(status.logLine);
      if (status.rateLimited) {
        _serpApiLastRateLimited = true;
        debugPrint('[GP] DataForSEO ${status.logLine}');
        return const [];
      }
      if (status.noResults) {
        debugPrint('[GP] DataForSEO no results: $query');
        return const [];
      }
      if (!status.ok) {
        debugPrint('[GP] DataForSEO ${status.logLine}');
        if (status.retryable && allowRetry && attempt == 0) continue;
        return const [];
      }
      _serpApiLastRateLimited = false;
      return [
        for (final hit in exploreParseDataForSeoOrganic(decoded))
          _SerpSearchResult(
            title: hit.title,
            link: hit.link,
            snippet: hit.snippet,
            displayedLink: hit.displayedLink,
          ),
      ];
    }
    return const [];
  }

  Future<List<_SerpSearchResult>> _searchSerpApiHttp(
    String query, {
    Duration? timeout,
    String hl = '',
    String gl = '',
  }) async {
    final apiKey = _serpApiKey();
    final wait = timeout ?? _kSerpApiTimeout;
    final allowRetry = timeout == null || timeout > _kForegroundSerpApiTimeout;

    Future<http.Response?> getOnce() async {
      final params = <String, String>{
        'engine': 'google',
        'q': query,
        'api_key': apiKey,
        'num': '10',
      };
      if (hl.trim().isNotEmpty) params['hl'] = hl.trim();
      if (gl.trim().isNotEmpty) params['gl'] = gl.trim();
      final uri = Uri.https('serpapi.com', '/search.json', params);
      try {
        _serpApiLastTimedOut = false;
        return await _client.get(uri).timeout(wait);
      } on TimeoutException catch (e) {
        _serpApiLastTimedOut = true;
        debugPrint('[GP] SerpApi failed: $e');
        return null;
      } catch (e) {
        debugPrint('[GP] SerpApi failed: $e');
        return null;
      }
    }

    _serpApiCallCount++;
    debugPrint('[GP] SerpApi query: $query (#$_serpApiCallCount)');
    var res = await getOnce();
    if (res == null) return const [];
    if (allowRetry &&
        !_serpApiLastTimedOut &&
        (res.statusCode == 429 || res.statusCode >= 500)) {
      debugPrint('[GP] SerpApi HTTP ${res.statusCode}');
      await Future<void>.delayed(const Duration(milliseconds: 800));
      res = await getOnce();
      if (res == null) return const [];
    }
    if (res.statusCode == 401 || res.statusCode == 403) {
      debugPrint('[GP] SerpApi HTTP ${res.statusCode}');
      return const [];
    }
    if (res.statusCode == 429) {
      _serpApiLastRateLimited = true;
    }
    if (res.statusCode != 200) {
      debugPrint('[GP] SerpApi HTTP ${res.statusCode}');
      return const [];
    }
    _serpApiLastRateLimited = false;

    Object? decoded;
    try {
      decoded = jsonDecode(res.body);
    } catch (e) {
      debugPrint('[GP] SerpApi decode failed: $e');
      return const [];
    }
    return [
      for (final hit in exploreParseSerpApiOrganic(decoded))
        _SerpSearchResult(
          title: hit.title,
          link: hit.link,
          snippet: hit.snippet,
          displayedLink: hit.displayedLink,
        ),
    ];
  }

  int _scoreSerpResult(
    _SerpSearchResult r, {
    required String clinicName,
    required String procedure,
    required String city,
    required String host,
  }) {
    var score = 0;
    final blob = '${r.title} ${r.link} ${r.snippet} ${r.displayedLink}'
        .toLowerCase();
    final clinicLo = clinicName.trim().toLowerCase();
    if (host.isNotEmpty &&
        r.link.isNotEmpty &&
        _hostsSameDomainOrSubdomain(r.link, host)) {
      score += 40;
    }
    if (clinicLo.length >= 4 && blob.contains(clinicLo)) score += 12;
    final loc = exploreCityPriceSearchTerms(
      city,
      countryCode: _countryCodeForCity(city),
    );
    final procTokens = exploreSerpProcedureMatchTokens(
      procedure,
      lang: loc.lang,
    );
    if (procTokens.any(blob.contains)) score += 24;
    if (procTokens.any((t) => r.link.toLowerCase().contains(t))) {
      score += 30;
    }
    final want = exploreTreatmentFamily(procedure);
    final linkFam = exploreTreatmentFamily(
      r.link.toLowerCase().replaceAll(RegExp(r'[/_\-]+'), ' '),
    );
    if (want != ExploreTreatmentFamily.other &&
        linkFam != ExploreTreatmentFamily.other &&
        linkFam != want) {
      score -= 50;
    }
    final priceWords = <String>{
      'price',
      'prices',
      'pricing',
      'cost',
      'costs',
      ...loc.priceWords.map((w) => w.toLowerCase()),
    };
    if (priceWords.any(blob.contains)) score += 8;
    score += _priceLinkScore(r.link) * 3;
    if (_serpApiUrlIsJunk(r.link, procedure)) score -= 80;
    return score;
  }

  /// After HTTP + internal links + Serper miss, map the official domain via
  /// Firecrawl and fetch the top 3–5 pricing/treatment/PDF pages. Bodies go
  /// through [ExploreHtmlPriceParseCache] → extractPriceEvidence — Firecrawl
  /// never supplies a trusted numeric price.
  Future<OpenAIClinic?> _tryFirecrawlClinicPriceFallback({
    required OpenAIClinic clinic,
    required String procedure,
    required String city,
    required String domainKey,
    required String baseUrl,
    required bool Function(String url, String text) considerPage,
    required Future<String> Function(String url, {bool allowRender})
    cachedFetch,
  }) async {
    final key = _firecrawlApiKey();
    if (domainKey.isEmpty) return null;
    debugPrint(
      '[GP DISCOVERY] sitemap/firecrawl · ${clinic.name} · $domainKey',
    );

    final client = ExploreFirecrawlClient(apiKey: key);
    var candidates = await ExploreSiteUrlCacheStore.instance.load(domainKey);
    if (candidates.isEmpty) {
      final sitemap = await exploreDiscoverSitemapUrls(hostOrBase: domainKey);
      candidates = [...sitemap];
      if (client.isConfigured) {
        final loc = exploreCityPriceSearchTerms(
          city,
          countryCode: _countryCodeForCity(city),
        );
        final search = exploreFirecrawlMapSearch(
          procedure: procedure,
          priceWords: loc.priceWords,
        );
        final mapped = await client.mapSite(
          siteUrl: baseUrl,
          search: search,
          limit: 50,
        );
        candidates = [
          ...candidates,
          for (final u in mapped)
            if (!isNonLiteralClinicPriceUrl(u)) u,
        ];
      }
    }
    final picked = exploreRankFirecrawlUrls(
      candidates,
      procedure: procedure,
      host: domainKey,
      city: city,
      max: 5,
    );
    if (picked.isEmpty) {
      debugPrint('[GP FIRECRAWL] no ranked urls · ${clinic.name}');
      return null;
    }
    unawaited(
      ExploreSiteUrlCacheStore.instance.save(
        host: domainKey,
        urls: picked,
        procedure: procedure,
        city: city,
        clinicName: clinic.name,
        source: 'firecrawl_map',
      ),
    );

    final useful = <String>[];
    for (final url in picked) {
      String text = '';
      if (exploreIsPdfUrl(url)) {
        final page = await client.scrapePage(url);
        if (page.usable) {
          text = page.html;
          ExploreHtmlPriceParseCache.instance.rememberHtml(page.url, page.html);
          considerPage(page.url, page.html);
        }
      } else {
        await _fetchRawHtml(url);
        text = await cachedFetch(url, allowRender: true);
        if (text.isEmpty) {
          final page = await client.scrapePage(url);
          if (page.usable) {
            text = page.html;
            ExploreHtmlPriceParseCache.instance.rememberHtml(
              page.url,
              page.html,
            );
            considerPage(page.url, page.html);
          } else {
            final zyteKey = _zyteApiKey();
            if (zyteKey.isNotEmpty &&
                !exploreIsPdfUrl(url) &&
                !ExploreZyteClient.isUnsupportedUrl(url)) {
              logPriceSource('zyte_after_firecrawl_empty', url: url);
              final zyteHtml = await ExploreZyteClient(
                apiKey: zyteKey,
              ).fetchBrowserHtml(url);
              if (zyteHtml.length >= 200) {
                text = zyteHtml;
                ExploreHtmlPriceParseCache.instance.rememberHtml(url, zyteHtml);
                await Future<void>.delayed(Duration.zero);
                considerPage(url, zyteHtml);
              }
            }
          }
        } else {
          considerPage(url, text);
        }
      }
      if (text.isEmpty) continue;
      ExploreHtmlPriceParseCache.instance.rememberHtml(url, text);
      await ExploreHtmlPriceParseCache.instance.warmEvidence([url]);
      final evidence = ExploreHtmlPriceParseCache.instance.evidenceFor(url);
      // evidenceFor uses cache keyed by remembered URL — also try url itself
      final rows = evidence.isNotEmpty
          ? evidence
          : ExploreHtmlPriceParseCache.instance.evidenceForHtml(
              html: text,
              sourceUrl: url,
            );
      if (rows.isNotEmpty) useful.add(url);
    }

    if (useful.isNotEmpty) {
      unawaited(
        ExploreSiteUrlCacheStore.instance.save(
          host: domainKey,
          urls: useful,
          procedure: procedure,
          city: city,
          clinicName: clinic.name,
          source: 'firecrawl_useful',
        ),
      );
    }

    final verified = await _clinicFromDeterministicEvidenceAsync(
      clinic: clinic,
      procedure: procedure,
      preferredUrl: useful.isNotEmpty ? useful.first : picked.first,
      extraUrls: [...useful, ...picked],
      city: city,
    );
    if (verified != null) {
      debugPrint(
        '[GP FIRECRAWL] HTML evidence for ${clinic.name}: '
        '${verified.priceLabel}',
      );
    }
    return verified;
  }

  /// When HTTP / renderer / Firecrawl leave a blocked or empty DOM, fetch
  /// browser-rendered HTML via Zyte (`browserHtml` only — never AI extract).
  Future<OpenAIClinic?> _tryZyteClinicPriceFallback({
    required OpenAIClinic clinic,
    required String procedure,
    required String city,
    required String domainKey,
    required String preferredUrl,
    required bool Function(String url, String text) considerPage,
    required bool pageLooksBlocked,
  }) async {
    final useZyte = (dotenv.env['USE_ZYTE_FALLBACK'] ?? 'false')
        .trim()
        .toLowerCase();
    if (useZyte != 'true' && useZyte != '1' && useZyte != 'yes') {
      debugPrint('[ZYTE FALLBACK] disabled · USE_ZYTE_FALLBACK=false');
      return null;
    }
    final key = _zyteApiKey();
    if (key.isEmpty) return null;
    if (!pageLooksBlocked && preferredUrl.trim().isEmpty) return null;

    final client = ExploreZyteClient(apiKey: key);
    // One procedure-shaped URL only — never spray Zyte across sitemap caches.
    final preferred = preferredUrl.trim();
    if (preferred.isEmpty ||
        ExploreZyteClient.isUnsupportedUrl(preferred) ||
        exploreIsPdfUrl(preferred) ||
        _urlConflictsWithSearchedProcedure(preferred, procedure)) {
      debugPrint('[ZYTE FALLBACK] skip · no procedure URL for ${clinic.name}');
      return null;
    }

    logPriceSource('zyte_browserHtml', url: preferred);
    final html = await client.fetchBrowserHtml(preferred);
    if (html.length < 200) return null;
    await Future<void>.delayed(Duration.zero);
    ExploreHtmlPriceParseCache.instance.rememberHtml(preferred, html);
    if (!considerPage(preferred, html)) return null;
    final verified = await _clinicFromDeterministicEvidenceAsync(
      clinic: clinic,
      procedure: procedure,
      preferredUrl: preferred,
      city: city,
    );
    if (verified != null) {
      debugPrint(
        '[ZYTE FALLBACK] evidence for ${clinic.name}: '
        '${verified.priceLabel}',
      );
    }
    return verified;
  }

  /// Discovery fallback when the direct scrape is blocked/thin: returns the
  /// clinic's own best price URL to fetch (or render), never page text.
  Future<String> _serpApiPriceFallback({
    required OpenAIClinic clinic,
    required String procedure,
    required String city,
    required String host,
  }) {
    final domain = _stripWww(_normalizeProbeHost(host));
    if (domain.isNotEmpty && _isSessionBlockedHost(domain)) {
      debugPrint('[GP] Discovery skip blocked domain $domain — ${clinic.name}');
      return Future.value('');
    }
    final key =
        '$domain|'
        '${clinic.name.trim().toLowerCase()}|'
        '${procedure.trim().toLowerCase()}|'
        '${city.trim().toLowerCase()}';
    final pending = _serpApiFallbackCache[key];
    if (pending != null) {
      debugPrint('[GP] Discovery cache HIT: ${clinic.name}');
      return pending;
    }
    final fut = _serpApiPriceFallbackUncached(
      clinic: clinic,
      procedure: procedure,
      city: city,
      domain: domain,
    );
    _serpApiFallbackCache[key] = fut;
    return fut;
  }

  Future<String> _serpApiPriceFallbackUncached({
    required OpenAIClinic clinic,
    required String procedure,
    required String city,
    required String domain,
  }) async {
    if (!_webDiscoveryConfigured()) {
      if (!_loggedSerpApiMissingConfig) {
        _loggedSerpApiMissingConfig = true;
        debugPrint(
          '[GP] Discovery skipped — set SERPER_API_KEY (or DATAFORSEO_LOGIN + '
          'DATAFORSEO_PASSWORD, or SERPAPI_API_KEY) in .env',
        );
      }
      return '';
    }
    // A blocked domain used to be a dead end, because the only thing left was
    // a snippet and snippet prices are never accepted. The headless renderer
    // can read its price page, so the slot is worth spending when rendering is
    // available.
    if (domain.isNotEmpty &&
        _isSessionBlockedHost(domain) &&
        exploreRendererEndpoint(_rendererBase()) == null) {
      debugPrint('[GP] Discovery skip blocked domain $domain — ${clinic.name}');
      return '';
    }
    if (_liveSerpApiBudget <= 0) {
      debugPrint('[GP] Discovery budget empty — skip ${clinic.name}');
      return '';
    }
    _liveSerpApiBudget--;

    debugPrint('[GP] Discovery search: ${clinic.name} · $procedure · $city');
    final loc = exploreCityPriceSearchTerms(
      city,
      countryCode: _countryCodeForCity(city),
    );
    final topic = exploreProcedurePriceTopic(procedure);
    final localNames = exploreProcedureLocalSearchNames(procedure, loc.lang);
    var localProc = localNames.isNotEmpty ? localNames.first : topic;
    if (localProc.toLowerCase() == topic.toLowerCase()) {
      final translated = await _translatedProcedureFallback(
        procedure: procedure,
        city: city,
      );
      if (translated != null && translated.trim().isNotEmpty) {
        localProc = translated.trim();
      }
    }
    final localPrice = loc.priceWords.isNotEmpty
        ? loc.priceWords.first
        : 'price';
    final clinicName = clinic.name.trim();
    final site = domain.isEmpty ? '' : ' site:$domain';
    final useLocal =
        localPrice.toLowerCase() != 'price' &&
        localPrice.toLowerCase() != 'prices' &&
        localProc.toLowerCase() != topic.toLowerCase();
    final preferLocal = explorePrefersLocalSearchFirst(loc.lang) && useLocal;
    final englishQ = domain.isEmpty
        ? '"$clinicName" "$topic" price $city'
        : '$clinicName $topic price $city$site';
    final localQ = domain.isEmpty
        ? '"$clinicName" $localProc $localPrice $city'
        : '$clinicName $localProc $localPrice$site';
    final pair = <String>[
      if (preferLocal) localQ else englishQ,
      if (useLocal && localQ != englishQ) (preferLocal ? englishQ : localQ),
    ];
    final results = await _searchSerpApiBilingual(
      queries: pair,
      city: city,
      timeout: _kSerpApiTimeout,
      stopWhenFound: true,
    );
    // [_serpApiLastTimedOut] is shared by every concurrent pill search, so a
    // sibling pill's timeout must never discard results this candidate did
    // get back. Only report a timeout when nothing came back.
    if (results.isEmpty) {
      debugPrint(
        _serpApiLastTimedOut
            ? '[GP] Discovery timeout — skip candidate ${clinic.name}'
            : '[GP] Discovery: no useful price source · ${clinic.name}',
      );
      _refundLiveSerpApi();
      return '';
    }

    debugPrint('[GP] Discovery results: ${results.length}');

    final scored = [
      for (final r in results)
        (
          r: r,
          score: _scoreSerpResult(
            r,
            clinicName: clinicName,
            procedure: procedure,
            city: city,
            host: domain,
          ),
        ),
    ]..sort((a, b) => b.score.compareTo(a.score));

    var ranked = scored;
    if (domain.isNotEmpty) {
      final onDomain = scored
          .where(
            (e) =>
                e.r.link.isNotEmpty &&
                _hostsSameDomainOrSubdomain(e.r.link, domain),
          )
          .toList();
      debugPrint('[GP] Discovery domain matches: ${onDomain.length}');
      if (onDomain.isNotEmpty) ranked = onDomain;
    }

    var useful = ranked.where((e) => e.score >= 10).toList();
    if (useful.isEmpty) {
      debugPrint('[GP] Discovery: no useful price source');
      _refundLiveSerpApi();
      return '';
    }
    useful = useful
        .where(
          (e) =>
              !isNonLiteralClinicPriceUrl(e.r.link) &&
              !_serpApiUrlIsJunk(e.r.link, procedure) &&
              !_urlConflictsWithSearchedProcedure(e.r.link, procedure),
        )
        .toList();
    if (useful.isEmpty) {
      debugPrint(
        '[GP] Discovery: only blog/guide URLs on domain (${clinic.name})',
      );
      _refundLiveSerpApi();
      return '';
    }
    final procTokens = exploreSerpProcedureMatchTokens(
      procedure,
      lang: loc.lang,
    );
    final matchingProc = useful.where((e) {
      final blob =
          '${e.r.title} ${e.r.link} ${e.r.snippet} ${e.r.displayedLink}'
              .toLowerCase();
      return procTokens.any(blob.contains);
    }).toList();
    if (matchingProc.isNotEmpty) {
      useful = matchingProc;
    } else {
      debugPrint('[GP] Discovery: no procedure-matching URL (${clinic.name})');
      _refundLiveSerpApi();
      return '';
    }

    final bestUrl = useful.first.r.link;
    debugPrint('[GP] Discovery best URL: $bestUrl');
    return bestUrl;
  }

  String _normalizeProbeHost(String raw) {
    var s = raw.trim().toLowerCase();
    if (s.isEmpty) return '';
    if (s.contains('://')) {
      try {
        final u = Uri.parse(s);
        if (u.hasAuthority && u.host.isNotEmpty) s = u.host;
      } catch (_) {
        return '';
      }
    } else {
      final slash = s.indexOf('/');
      if (slash > 0) s = s.substring(0, slash);
    }
    final colon = s.indexOf(':');
    if (colon > 0) s = s.substring(0, colon);
    return s;
  }

  String _stripWww(String host) {
    final h = host.trim().toLowerCase();
    if (h.startsWith('www.')) return h.substring(4);
    return h;
  }

  bool _isGenericSocialOrDirectoryHost(String host) {
    final h = _stripWww(_normalizeProbeHost(host));
    if (h.isEmpty) return true;
    return h == 'facebook.com' ||
        h == 'm.facebook.com' ||
        h == 'instagram.com' ||
        h == 'tiktok.com' ||
        h == 'linktr.ee' ||
        h == 'maps.app.goo.gl' ||
        h == 'g.page' ||
        h == 'business.google.com' ||
        h == 'youtube.com' ||
        h == 'wa.me';
  }

  bool _hostsSameDomainOrSubdomain(String a, String b) {
    final ca = _stripWww(_normalizeProbeHost(a));
    final cb = _stripWww(_normalizeProbeHost(b));
    if (ca.isEmpty || cb.isEmpty) return false;
    if (ca == cb) return true;
    return ca.endsWith('.$cb') || cb.endsWith('.$ca');
  }

  bool _denylistedWebsiteHost(String rawHost) {
    final h = _stripWww(_normalizeProbeHost(rawHost));
    if (h.isEmpty) return false;
    for (final blocked in _kBlockedClinicWebsiteHosts) {
      if (h == blocked || h.endsWith('.$blocked')) return true;
    }
    return false;
  }

  bool _blobHasWholeWord(String blob, String word) {
    final w = word.trim().toLowerCase();
    if (w.isEmpty) return false;
    return RegExp('\\b${RegExp.escape(w)}\\b').hasMatch(blob);
  }

  bool _looksLikeAestheticMedicalBusiness({
    required String clinicName,
    required GooglePlacesResult place,
    bool hairProcedure = false,
  }) {
    if (looksLikeNonAestheticVenueName(clinicName)) {
      return false;
    }
    if (place.editorialSummary.trim().isEmpty) {
      return true;
    }
    if (placesNameLooksLikeMedicalClinic(clinicName)) {
      return true;
    }

    final blob =
        '${clinicName.toLowerCase()} ${place.editorialSummary.toLowerCase()}';

    bool hasAny(List<String> needles) => needles.any(blob.contains);

    // Filler / med-spa listings win even if the blurb also says "their"
    // (substring "hair") or "medical center".
    const strongAccept = <String>[
      'aesthetic',
      'esthetic',
      'estetic',
      'cosmetic',
      'dermat',
      'med spa',
      'medical spa',
      'plastic surgery',
      'filler',
      'botox',
      'juvederm',
      'restylane',
      'dysport',
      'hyaluron',
      'inject',
      'transplant',
      'implant de par',
      'implant par',
      'fue',
      'rinoplast',
      'rhinoplast',
      'chirurgie plastic',
      'chirurgie estet',
    ];
    if (hasAny(strongAccept)) return true;
    if (hairProcedure &&
        (hasAny(const [
          'hair implant',
          'hair transplant',
          'graft',
          'capilar',
        ]))) {
      return true;
    }

    // Hard rejects: nails / hair / generic salons / unrelated medicine.
    // Whole-word only for short English tokens — "their" must not match "hair".
    const rejectWords = <String>[
      'nail',
      'nails',
      'lash',
      'lashes',
      'gene',
      'brow',
      'barber',
      'dental',
      'dentist',
      'pharmacy',
      'hospital',
    ];
    if (_blobHasWholeWord(blob, 'hair') &&
        !hasAny(const ['inject', 'botox', 'filler', 'aesthetic', 'laser'])) {
      return false;
    }
    if (rejectWords.any((w) => _blobHasWholeWord(blob, w))) return false;

    const reject = <String>[
      'unghii',
      'manichi',
      'pedichi',
      'gelish',
      'shellac',
      'sprâncen',
      'sprancen',
      'coaf',
      'frizer',
      'hair salon',
      'nail salon',
      'beauty salon',
      'stomat',
      'farmac',
      'spital',
      'policlin',
      'family medicine',
      'medicină de familie',
      'medicina de familie',
      'cardio',
      'ortoped',
      'oftalm',
      'pediatr',
      'ginecolog',
      'neurolog',
      'clinic medical',
      'laborator',
    ];
    if (hasAny(reject)) return false;

    // Must strongly indicate aesthetic / cosmetic medicine / surgery.
    const accept = <String>[
      'estetica',
      'medicina estetica',
      'medicină estetică',
      'cosmet',
      'skin clinic',
      'skin',
      'anti-aging',
      'antiaging',
      'anti aging',
      'beauty',
      'frumusete',
      'frumusețe',
      'îngrijire',
      'ingrijire',
      'rejuvenar',
      'laser',
      'prp',
      'platelet',
      'facial',
      'centru medical',
      'cabinet medical',
      'cabinet',
      'medic',
      'doctor',
      'dr.',
      'clinique',
      'klinik',
      'centre',
      'center',
      'institut',
      'studio medical',
      'slimming',
      'body contouring',
      'wellness',
      'chirurgie estet',
      'chirurgie plastic',
      'chirurgie cosmetic',
    ];
    return hasAny(accept);
  }

  Future<bool> _uriNetworkReachable(Uri uri) async {
    Future<bool> tryOnce({required bool head}) async {
      try {
        final r = head
            ? await _client.head(uri).timeout(_kClinicWebsiteProbeTimeout)
            : await _client.get(uri).timeout(_kClinicWebsiteProbeTimeout);
        return r.statusCode >= 200 && r.statusCode < 600;
      } on Object {
        return false;
      }
    }

    if (await tryOnce(head: true)) return true;
    if (await tryOnce(head: false)) return true;
    return false;
  }

  /// True when [hostOrDomain] (e.g. trueglow.ro) responds over HTTPS or HTTP.
  Future<bool> _probeWebsiteHost(String hostOrDomain) async {
    var h = _normalizeProbeHost(hostOrDomain);
    if (h.isEmpty || !h.contains('.')) return false;

    Future<bool> tryHost(String host) async {
      final https = Uri(scheme: 'https', host: host, path: '/');
      if (await _uriNetworkReachable(https)) return true;
      final httpRoot = Uri(scheme: 'http', host: host, path: '/');
      if (await _uriNetworkReachable(httpRoot)) return true;
      return false;
    }

    if (await tryHost(h)) return true;
    if (!h.startsWith('www.')) return await tryHost('www.$h');
    return false;
  }

  /// Drops GPT-fabricated rows: [area] must pass TLD rules, domain must probe,
  /// then optionally [GooglePlaces]-verified when configured.
  Future<OpenAIComparisonResult> _postFilterUncachedClinicList(
    OpenAIComparisonResult result, {
    required String city,
  }) async {
    if (result.clinics.isEmpty) return result;

    final tldPassed = _filterClinicsAreaHasRecognizedTld(result.clinics);
    final probed = <OpenAIClinic>[];

    for (final c in tldPassed) {
      final d = _extractDomain(c.area);
      if (d.isEmpty) {
        debugPrint('[GP] Uncached post-filter: missing domain · ${c.name}');
        continue;
      }
      if (_denylistedWebsiteHost(d)) {
        debugPrint('[GP] Uncached post-filter: denylisted · ${c.name}');
        continue;
      }
      if (!await _probeWebsiteHost(d)) {
        debugPrint(
          '[GP] Uncached post-filter: unreachable host · ${c.name} → $d',
        );
        continue;
      }
      probed.add(c);
    }

    if (probed.isEmpty) {
      debugPrint('[GP] Uncached post-filter: no clinics survived probing');
      return result.copyWith(clinics: const []);
    }

    final enriched = await _enrichClinicsWithPlaces(
      clinics: probed,
      city: city,
    );
    if (enriched.isEmpty) {
      debugPrint('[GP] Uncached post-filter: enrichment removed all clinics');
      return result.copyWith(clinics: const []);
    }

    return result.copyWith(clinics: enriched);
  }

  List<OpenAIClinic> _sortClinics(List<OpenAIClinic> clinics) {
    final sorted = [...clinics]
      ..sort((a, b) {
        final aHasReviews = a.reviews > 0;
        final bHasReviews = b.reviews > 0;
        if (aHasReviews && !bHasReviews) return -1;
        if (!aHasReviews && bHasReviews) return 1;

        final aScore = _wilsonScore(a.rating, a.reviews);
        final bScore = _wilsonScore(b.rating, b.reviews);
        final scoreDiff = bScore.compareTo(aScore);
        if (scoreDiff != 0) return scoreDiff;

        if (a.priceMin > 0 && b.priceMin > 0) {
          return a.priceMin.compareTo(b.priceMin);
        }
        if (a.priceMin > 0 && b.priceMin == 0) return -1;
        if (a.priceMin == 0 && b.priceMin > 0) return 1;

        return 0;
      });

    return sorted
        .asMap()
        .entries
        .map((e) => e.value.copyWith(rank: e.key + 1))
        .toList();
  }

  Future<OpenAIComparisonResult> _buildClinicsListUncached({
    required String procedure,
    required String city,
    required int count,
    required List<String> excludeNames,
    required List<String> aliases,
    String? openAiCompletionModelOverride,
  }) async {
    if (_quotaExhausted) {
      debugPrint('[GP] Skipping AI call — quota exhausted');
      throw StateError(
        'OpenAI quota exhausted — top up at platform.openai.com/billing',
      );
    }
    debugPrint(
      '[GP] _buildClinicsListUncached called — '
      'returning empty to avoid hallucinated clinics',
    );
    return OpenAIComparisonResult(
      city: city,
      topic: procedure,
      topicType: OpenAISearchItemType.procedure,
      summary: '',
      rangeLabel: '',
      mapCenter: const OpenAICoord(0, 0),
      clinics: const [],
    );
  }

  /// Returns clinics in [city] whose **name** matches or closely matches
  /// [nameQuery] (brands, "Dr …", spacing variants, bilingual names).
  /// Same JSON shape as [buildClinicsList]; `topic_type` must be `"clinic"`.
  Future<OpenAIComparisonResult> buildClinicsListByNameSearch({
    required String nameQuery,
    required String city,
    int count = 10,
    List<String> excludeNames = const [],
    List<String> seedNames = const [],
  }) {
    if (ExplorePriceDiscoveryTool.instance.enabled) {
      return _buildIndexedClinicsByName(
        query: nameQuery, city: city, count: count, excludeNames: excludeNames,
      );
    }
    if (!isConfigured) {
      throw StateError(
        'Missing OPENAI_API_KEY. Add it to .env or --dart-define.',
      );
    }
    final key =
        'clinicsByName|v7|$nameQuery|$city|$count|${excludeNames.join(",")}|${seedNames.join(",")}';
    return _memoize<OpenAIComparisonResult>(
      key,
      () => _buildClinicsListByNameFromWeb(
        nameQuery: nameQuery,
        city: city,
        count: count,
        excludeNames: excludeNames,
        seedNames: seedNames,
      ),
    );
  }


  Future<OpenAIComparisonResult> _buildIndexedClinicsByName({
    required String query, required String city, required int count,
    required List<String> excludeNames,
  }) async {
    final rows = await ExplorePriceDiscoveryTool.instance.searchClinics(
      query: query, city: city, countryCode: _countryCodeForCity(city),
      limit: count > 20 ? 20 : count,
      throwOnFailure: true,
    );
    final excluded = excludeNames.map((n) => n.toLowerCase().trim()).toSet();
    final clinics = <OpenAIClinic>[];
    for (final row in rows) {
      final name = '${row['title'] ?? ''}'.trim();
      if (name.isEmpty || excluded.contains(name.toLowerCase())) continue;
      clinics.add(OpenAIClinic.fromJson({
        'rank': clinics.length + 1, 'name': name,
        'area': '$city · ${row['official_website'] ?? ''}',
        'rating': row['rating'] ?? 0, 'reviews': row['reviews'] ?? 0,
        'price_min': 0, 'price_max': 0, 'price_gbp': 0,
        'price_label': 'Price on request', 'brand': 'Clinic',
        'has_procedure': true, 'price_pending': false,
      }));
    }
    return OpenAIComparisonResult(
      city: city, topic: query, topicType: OpenAISearchItemType.clinic,
      summary: clinics.isEmpty ? 'No matching clinic found. Check the name or city.' : '',
      rangeLabel: '', mapCenter: const OpenAICoord(0, 0), clinics: clinics,
    );
  }

  Future<OpenAIComparisonResult> _buildClinicsListByNameFromWeb({
    required String nameQuery,
    required String city,
    required int count,
    required List<String> excludeNames,
    required List<String> seedNames,
  }) async {
    final systemPrompt =
        'You are a clinic research assistant for a beauty app.\n'
        'Search Google to find the real clinic matching the '
        'search name in the given city.\n\n'
        'Return ONLY valid JSON — no markdown:\n'
        '{"city":string,"topic":string,"topic_type":"clinic",'
        '"summary":string,"currency":string,"range_label":string,'
        '"map_center":{"lat":number,"lng":number},'
        '"clinics":[{"rank":number,"name":string,"area":string,'
        '"distance_mi":number,"rating":number,"reviews":number,'
        '"price_min":number,"price_max":number,"price_label":string,'
        '"price_gbp":number,"currency":string,"brand":string,'
        '"badge":string,"badge_variant":"best"|"mid"|"hi",'
        '"lat":number,"lng":number}]}\n\n'
        'RULES:\n'
        '- Find the REAL clinic by this name in the city\n'
        '- Include all branches/locations if multiple exist\n'
        '- Get real Google Maps rating and review count\n'
        '- Get real price range from their website\n'
        '- If clinic has no public prices: price_min=0, '
        '"price_label"="Price on request"\n'
        '- NEVER invent clinics — only real ones\n'
        '- topic_type MUST be "clinic"\n'
        '- area: district/neighborhood + website domain\n'
        '- brand: clinic specialty (e.g. "Aesthetic medicine")';

    final seedNote = seedNames.isEmpty
        ? ''
        : 'Possible matches seen in search: ${seedNames.join(", ")}.';
    final excludeNote = excludeNames.isEmpty
        ? ''
        : 'Already shown: ${excludeNames.join(", ")}.';

    final userMsg =
        'Find real clinic named "$nameQuery" in "$city".\n'
        '$seedNote\n$excludeNote\n'
        'Search Google Maps and their website.\n'
        'Return $count results. JSON only.';

    try {
      final oaSearchJson = await _queueSearchPreview(
        () => _chatCompletionSearchPreviewJson(
          messages: [
            {'role': 'system', 'content': systemPrompt},
            {'role': 'user', 'content': userMsg},
          ],
          maxTokens: 8000,
        ),
      );
      final content = _extractTextFromSearchPreview(oaSearchJson);
      final jsonObj = jsonDecode(content) as Map;
      final result = OpenAIComparisonResult.fromJson(
        jsonObj.cast<String, Object?>(),
      );
      if (result.clinics.isNotEmpty) return result;
    } catch (_) {}

    try {
      final oaJson = await _openAiChatJsonCompletion(
        openAiModel: _kFallbackClinicListModel,
        systemPrompt: systemPrompt,
        userMessage: userMsg,
        maxTokens: 3600,
      );
      final jsonObj = jsonDecode(oaJson) as Map;
      final openAiResult = OpenAIComparisonResult.fromJson(
        jsonObj.cast<String, Object?>(),
      );
      if (openAiResult.clinics.isNotEmpty) return openAiResult;
    } catch (_) {}

    return _buildClinicsListByNameSearchUncached(
      nameQuery: nameQuery,
      city: city,
      count: count,
      excludeNames: excludeNames,
      seedNames: seedNames,
      openAiCompletionModelOverride: _kFallbackClinicListModel,
    );
  }

  Future<OpenAIComparisonResult> _buildClinicsListByNameSearchUncached({
    required String nameQuery,
    required String city,
    required int count,
    required List<String> excludeNames,
    required List<String> seedNames,
    String? openAiCompletionModelOverride,
  }) async {
    final excludeNote = excludeNames.isEmpty
        ? ''
        : '\nDo NOT include these clinics (already shown): ${excludeNames.join(', ')}.';

    final seedNote = seedNames.isEmpty
        ? ''
        : '\nThe user already saw these name candidates in search previews — prefer real '
              'matches from this list when they fit the city, then add more distinct clinics: '
              '${seedNames.join(', ')}.';

    final uri = Uri.parse('https://api.openai.com/v1/chat/completions');
    final body = <String, Object?>{
      'model': openAiCompletionModelOverride ?? model,
      ..._temperatureParam(openAiCompletionModelOverride ?? model, 0.45),
      ..._tokenLimitParam(openAiCompletionModelOverride ?? model, 1800),
      'response_format': {'type': 'json_object'},
      'messages': [
        {
          'role': 'system',
          'content':
              'You generate a structured clinic list for a beauty/clinic comparison app when '
              'the user is searching by **clinic / brand / doctor name**, not by procedure. '
              'Return ONLY valid JSON (no markdown). Schema:\n'
              '{'
              '"city": string,'
              '"topic": string,'
              '"topic_type": "clinic",'
              '"summary": string,'
              '"currency": string,                       // "RON","£","€","\$","TRY","PLN" etc.'
              '"range_label": string,                    // overall list spread, e.g. "RON 200–600", "£80–600"'
              '"map_center": {"lat": number, "lng": number},'
              '"clinics": ['
              '{"rank": number, "name": string, "area": string, "distance_mi": number, '
              '"rating": number, "reviews": number, '
              '"price_min": number, "price_max": number, '
              '"price_label": string,                    // formatted clinic range, e.g. "RON 200–400" or "£180–280"'
              '"price_gbp": number,                      // legacy "from" anchor (same currency as price_min)'
              '"currency": string, '
              '"brand": string, '
              '"badge": string, "badge_variant": "best"|"mid"|"hi", '
              '"lat": number, "lng": number}'
              ']'
              '}\n'
              'Rules: clinics length must be exactly $count. rank 1..$count. '
              'topic MUST be exactly: Clinics matching the search name in this city (short English summary OK). '
              'topic_type MUST be "clinic".\n'
              'Include only clinics whose **business name** matches or closely matches the query '
              '(same brand, spelling variants, "Dr X" vs "Dr. X", with/without spaces, Romanian diacritics, '
              'English vs local language). Branches with slightly different names count if clearly the same brand.\n'
              'PRICING — REALISTIC FULL-MENU SPREAD:\n'
              '- Use the CITY\'S LOCAL CURRENCY everywhere (Romania=RON, UK=£, Spain/France/Italy/Germany=€, '
              '  Turkey=TRY, Poland=PLN, US=\$). The root "currency" and each clinic\'s "currency" must match.\n'
              '- price_min = the clinic\'s entry-level service price (e.g. basic consultation, eyebrow shape, '
              '  cleansing facial). Use realistic local floors: Romania RON 150–300, UK £60–120, EU €40–80.\n'
              '- price_max = the clinic\'s most expensive single treatment (premium laser packages, threadlift, '
              '  Sculptra, large-volume filler course, body contouring, hair transplant when offered, etc.). '
              '  This must be a genuine premium service — DO NOT cap maxes at a few hundred currency units. '
              '  Realistic local ceilings for an aesthetic clinic: Romania RON 3,000–10,000, UK £1,500–8,000, '
              '  EU €1,500–6,000. Surgical / hair-transplant clinics can go higher.\n'
              '- Do NOT stair-step ranges by rank. Two clinics in the same tier should have OVERLAPPING ranges, '
              '  not artificially shifted up/down. Vary the spread realistically per clinic.\n'
              '- price_label must be the formatted range string, e.g. "RON 250–4,500" or "£120–2,800".\n'
              '- range_label is the overall list spread across all clinics in the result.\n'
              '- Order clinics by OVERALL VALUE (rating × pricing): rank 1 = best perceived value for the '
              '  brand search, NOT necessarily the cheapest. Premium clinics with high ratings can be top-ranked '
              '  even at higher prices. Avoid strictly cheapest-first ordering.\n'
              '- price_gbp may stay as a legacy "from" anchor in the same currency as price_min.\n'
              'For "brand": short specialty label (e.g. "Dermatology", "Aesthetic medicine", "Med spa") — NOT a filler brand.\n'
              'badge_variant: best for rank1, mid for typical, hi for premium.',
        },
        {
          'role': 'user',
          'content':
              'Search name: "$nameQuery"\nCity: "$city"$seedNote$excludeNote\n'
              'Return $count distinct clinics matching this search name in this city.',
        },
      ],
    };

    final res = await _client.post(
      uri,
      headers: {
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(body),
    );

    _throwIfOpenAiHttpFailed(res);

    final decoded = jsonDecode(res.body) as Map<String, Object?>;
    final choices = (decoded['choices'] as List?) ?? const [];
    final first = choices.isNotEmpty ? (choices.first as Map) : const {};
    final msg = (first['message'] as Map?) ?? const {};
    final content = _stripCodeFences((msg['content'] as String?)?.trim() ?? '');
    if (content.isEmpty) throw StateError('Empty AI response');

    final jsonObj = jsonDecode(content) as Map;
    final parsed = OpenAIComparisonResult.fromJson(
      jsonObj.cast<String, Object?>(),
    );
    return _postFilterUncachedClinicList(parsed, city: city);
  }

  /// Returns the procedures offered by a specific clinic.
  Future<OpenAIClinicDetail> buildClinicProcedures({
    required String clinicName,
    required String city,
  }) async {
    if (!isConfigured) {
      throw StateError(
        'Missing OPENAI_API_KEY. Add it to .env or --dart-define.',
      );
    }

    final uri = Uri.parse('https://api.openai.com/v1/chat/completions');
    final body = <String, Object?>{
      'model': model,
      ..._temperatureParam(model, 0.3),
      ..._tokenLimitParam(model, 1800),
      'response_format': {'type': 'json_object'},
      'messages': [
        {
          'role': 'system',
          'content':
              'You generate a clinic profile with procedures for a beauty/clinic comparison app. '
              'Return ONLY a valid JSON object (no markdown, no code fences).\n\n'
              'SCHEMA:\n'
              '{'
              '"clinic_name": string,'
              '"city": string,'
              '"area": string,'
              '"rating": number,'
              '"reviews": number,'
              '"about": string (1 sentence),'
              '"currency": string (ISO/local symbol used everywhere, e.g. "RON", "£", "€", "\$"),'
              '"procedures": ['
              '  {'
              '    "name": string,                  // family/group name shown to user, e.g. "Fillers", "Botox", "Laser hair removal"'
              '    "category": string,              // broader bucket: Injectables, Skin Care, Laser, Surgery, Dermatology, etc.'
              '    "min_price": number,             // cheapest variant price as a plain number'
              '    "max_price": number,             // most expensive variant price as a plain number (== min_price if only one)'
              '    "price_label": string,           // pretty label, e.g. "500–1500 RON" or "700 RON"'
              '    "badge": string,                 // e.g. Popular, New, Doctor-led, Trending, Premium'
              '    "variants": ['
              '      {"name": string, "price": number, "price_label": string, "badge": string}'
              '    ]'
              '  }'
              ']'
              '}\n\n'
              'RULES:\n'
              '- procedures length: between 10 and 16 entries.\n'
              '- For procedure families that naturally have several treatments (Fillers, Botox, Laser, Peels, '
              'Skin boosters, Hair removal, Threads, Mesotherapy, PRP, Hydrafacial), include 3 to 6 variants '
              'covering the realistic spectrum from cheapest to most expensive (e.g. Fillers → Lip, Cheek, Chin, '
              'Tear trough, Nasolabial, Jawline). For single-price procedures (e.g. Mole removal, Skin cancer screening), '
              'include exactly 1 variant whose price equals min_price and max_price.\n'
              '- price_label MUST use the chosen currency (RON for Romania/București, £ for UK, € for EU, \$ for US/Dubai). '
              'Format the family price_label as a range "min–max CURRENCY" if min != max, else "price CURRENCY".\n'
              '- Variants must be ordered by price ascending.\n'
              '- Use realistic local prices for the given city.\n'
              '- Do not invent currencies that do not match the city.\n'
              'GLOBAL PRICE EXTRACTION — applies to ALL countries:\n'
              '- min_price, max_price and "price" in variants MUST be plain integers, NO thousand separators, NO currency symbols.\n'
              '- Thousand separator per locale: Romania/Turkey/Germany/Spain = dot (1.500→1500); UK/US = comma (1,500→1500); Russia/Sweden = space (1 500→1500); Switzerland = apostrophe (1\'500→1500).\n'
              '- lei/Lei=RON; TL/TRY=Turkish lira; zł=PLN. Strip currency words from the number.\n'
              '- price_label: "X CURRENCY" or "X–Y CURRENCY". Never return 0 if a price exists.',
        },
        {
          'role': 'user',
          'content':
              'Clinic: "$clinicName"\nCity: "$city"\n'
              'List the procedures this clinic typically offers with realistic local prices. '
              'Where a family has several treatments (e.g. Fillers includes lip / cheek / chin / tear trough), '
              'group them as one procedure with a price RANGE plus the variants array, '
              'sorted from cheapest to most expensive.',
        },
      ],
    };

    final res = await _client.post(
      uri,
      headers: {
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(body),
    );

    _throwIfOpenAiHttpFailed(res);

    final decoded = jsonDecode(res.body) as Map<String, Object?>;
    final choices = (decoded['choices'] as List?) ?? const [];
    final first = choices.isNotEmpty ? (choices.first as Map) : const {};
    final msg = (first['message'] as Map?) ?? const {};
    final content = _stripCodeFences((msg['content'] as String?)?.trim() ?? '');
    if (content.isEmpty) throw StateError('Empty AI response');

    final jsonObj = jsonDecode(content) as Map;
    return OpenAIClinicDetail.fromJson(jsonObj.cast<String, Object?>());
  }

  /// Returns a procedure-focused clinic profile: contact info, treatments
  /// (variants for the searched procedure with brand/dose/price), and recent
  /// reviews. Used by the clinic detail screen.
  ///
  /// [procedureContext] is the procedure the user was searching for, e.g.
  /// "Lip filler". Pass [aliases] (multilingual synonyms) so the AI can
  /// recognize the procedure in any language.
  Future<OpenAIClinicProfile> buildClinicProfile({
    required String clinicName,
    required String city,
    required String procedureContext,
    List<String> aliases = const [],
    String? websiteUrl,
  }) async {
    if (!isConfigured) {
      throw StateError(
        'Missing OPENAI_API_KEY. Add it to .env or --dart-define.',
      );
    }

    final aliasNote = aliases.isEmpty
        ? ''
        : '\nKnown synonyms / translations of the procedure (treat as the same procedure): '
              '${aliases.join(', ')}.';

    final web = (websiteUrl ?? '').trim();
    final webNote = web.isEmpty
        ? ''
        : '\nOfficial website URL (align contact.website with this domain; '
              'treatments and prices must be plausible for this clinic only): $web';

    final uri = Uri.parse('https://api.openai.com/v1/chat/completions');
    final body = <String, Object?>{
      'model': model,
      ..._temperatureParam(model, 0.4),
      ..._tokenLimitParam(model, 2000),
      'response_format': {'type': 'json_object'},
      'messages': [
        {
          'role': 'system',
          'content':
              'You generate a procedure-focused clinic detail page for a beauty/clinic '
              'comparison app. Return ONLY a valid JSON object (no markdown, no code fences).\n\n'
              'SCHEMA:\n'
              '{'
              '"clinic_name": string,'
              '"city": string,'
              '"area": string,'
              '"distance_mi": number,'
              '"rating": number,'
              '"reviews_count": number,'
              '"is_top_rated": boolean,'
              '"is_doctor_led": boolean,'
              '"is_verified": boolean,'
              '"about": string (1 sentence),'
              '"currency": string ("RON" / "£" / "€" / "\$"),'
              '"procedure_focus": string,                 // canonical English procedure name shown as section title'
              '"procedure_focus_local": string,           // procedure name in the user\'s language if different (else "")'
              '"treatments": ['
              '  {'
              '    "name": string,                        // specific treatment / brand, e.g. "Juvederm Volbella" or "Botox Forehead"'
              '    "brand": string,                       // product brand, e.g. "Juvederm", "Botox", "HydraFacial"'
              '    "dose": string,                        // dose / volume if applicable, e.g. "0.55ml", else ""'
              '    "description": string,                 // very short, e.g. "Natural definition · 12 months"'
              '    "price_label": string,                 // e.g. "£250" or "1100 RON"'
              '    "badge": string,                       // e.g. "Most popular", "Doctor-led", "New", or ""'
              '    "tags": string[],                      // 1–3 chips, e.g. ["Filler","Juvederm"]'
              '    "featured": boolean                    // true if this matches the searched procedure_focus'
              '  }'
              '],'
              '"contact": {'
              '  "address": string,                       // realistic street address in the city'
              '  "phone": string,'
              '  "website": string,                       // domain only, no scheme: e.g. "beautyaesthetic.ro"'
              '  "instagram": string,                     // handle only, e.g. "@beautyaestheticclinic"'
              '  "opening_hours": string,                 // e.g. "Mon–Fri 9:00–20:00 · Sat 10:00–14:00"'
              '  "is_open_now": boolean'
              '},'
              '"reviews": ['
              '  {'
              '    "author_name": string,                 // realistic local first name + surname initial'
              '    "initials": string,                    // 2 uppercase letters'
              '    "date": string,                        // "Apr 2026" / "May 2026"'
              '    "rating": number,                      // 4 to 5'
              '    "text": string                         // 1–2 short sentences mentioning the treatment'
              '  }'
              ']'
              '}\n\n'
              'RULES:\n'
              '- treatments length: 6 to 12 entries covering ALL main procedures this clinic likely '
              'offers — include different categories: fillers, toxins (Botox), skin treatments, '
              'lasers, body contouring, facials, etc. Do NOT limit to only the procedure_focus.\n'
              '- Treatments matching procedure_focus get "featured": true; all others get "featured": false.\n'
              '- reviews length: 2 to 4 entries.\n'
              '- Use realistic local prices, addresses (street + sector/district), phone format and '
              'a country-appropriate domain (e.g. .ro, .co.uk, .es, .ae).\n'
              '- MULTILINGUAL: the procedure_focus may have come from any language. Recognize the '
              'underlying treatment and treat all synonyms as the same. Always set procedure_focus '
              'to the canonical English name.\n'
              '- Reviews and "about" should be written in the user\'s likely language (e.g. Romanian '
              'for București, English for London, Spanish for Barcelona).\n'
              'GLOBAL PRICE EXTRACTION — applies to ALL countries:\n'
              '- price_label MUST use the correct local currency. The number MUST be a plain integer, NO thousand separators, NO currency symbols in the number itself.\n'
              '- Thousand separator per locale: Romania/Turkey/Germany/Spain = dot (1.500→1500); UK/US = comma (1,500→1500); Russia/Sweden = space (1 500→1500); Switzerland = apostrophe (1\'500→1500).\n'
              '- lei/Lei=RON; TL/TRY=Turkish lira; zł=PLN. Strip currency words from the price field.\n'
              '- price_label format: "1500 RON" or "£250" or "250–400 €". Never return empty price_label if a real price exists.',
        },
        {
          'role': 'user',
          'content':
              'Clinic: "$clinicName"\nCity: "$city"\nProcedure context: "$procedureContext"$aliasNote$webNote\n'
              'Generate a realistic full-menu clinic profile. List ALL main procedures this clinic '
              'likely offers (6–12 treatments across categories such as fillers, toxins, skin, lasers, '
              'body). Mark treatments matching the procedure context as featured: true. '
              'Include local contact details and 2–4 short recent reviews.',
        },
      ],
    };

    final res = await _client.post(
      uri,
      headers: {
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(body),
    );

    _throwIfOpenAiHttpFailed(res);

    final decoded = jsonDecode(res.body) as Map<String, Object?>;
    final choices = (decoded['choices'] as List?) ?? const [];
    final first = choices.isNotEmpty ? (choices.first as Map) : const {};
    final msg = (first['message'] as Map?) ?? const {};
    final content = _stripCodeFences((msg['content'] as String?)?.trim() ?? '');
    if (content.isEmpty) throw StateError('Empty AI response');

    final jsonObj = jsonDecode(content) as Map;
    return OpenAIClinicProfile.fromJson(jsonObj.cast<String, Object?>());
  }

  /// Fast Phase-1 call: hero, about, categories, doctors — NO procedures.
  /// Uses gpt-5.6-luna, resolves in ~5 seconds so the screen shows immediately.
  Future<OpenAIClinicProfilePage> buildClinicProfilePageMeta({
    required String clinicName,
    required String city,
  }) {
    if (!isConfigured) {
      throw StateError(
        'Missing OPENAI_API_KEY. Add it to .env or --dart-define.',
      );
    }
    final key = 'profileMeta-v2|$clinicName|$city';
    return _memoize<OpenAIClinicProfilePage>(
      key,
      () => _buildClinicProfileMetaFastUncached(
        clinicName: clinicName,
        city: city,
      ),
    );
  }

  Future<OpenAIClinicProfilePage> _buildClinicProfileMetaFastUncached({
    required String clinicName,
    required String city,
  }) async {
    final uri = Uri.parse('https://api.openai.com/v1/chat/completions');
    final body = <String, Object?>{
      'model': model,
      ..._temperatureParam(model, 0.3),
      ..._tokenLimitParam(model, 1000),
      'response_format': {'type': 'json_object'},
      'messages': [
        {
          'role': 'system',
          'content':
              'Generate basic clinic metadata for a beauty app. '
              'Return ONLY valid JSON (no markdown).\n\n'
              'SCHEMA:\n'
              '{"clinic_name":string,"city":string,"clinic_type_label":string,"area":string,'
              '"distance_mi":0,"lat":0,"lng":0,"rating":0,"reviews_total":0,"google_place_url":"",'
              '"procedure_count":0,"doctor_count":0,"is_verified":bool,"is_doctor_led":bool,'
              '"hero_tags":string[],"about":string,"currency":string,'
              '"price_range_label":"","price_min":0,"price_max":0,'
              '"categories":["Injectables","Skin","Laser","Body"],'
              '"procedures":[],'
              '"doctors":[{"name":string,"initials":string,"specialty":string,"badge":string,"years_experience":0}],'
              '"contact":{"address":"","phone":"","website":"","instagram":"","opening_hours":"","is_open_now":false},'
              '"reviews":[]}\n\n'
              'RULES:\n'
              '- procedures: MUST be [] — loaded separately in Phase 2\n'
              '- about: 1 sentence in the city\'s local language\n'
              '- hero_tags: 4–5 chips like "Injectables", "Skin", "Laser", "Doctor-led"\n'
              '- doctors: list ALL practitioners found on the clinic website; no maximum — never invent names\n'
              '- is_doctor_led: true for medical/aesthetic clinics\n'
              '- currency: RON for Romania, £ for UK, € for EU\n'
              '- Leave contact fields empty — Google Places fills those',
        },
        {
          'role': 'user',
          'content':
              'Clinic: "$clinicName"\nCity: "$city"\nReturn fast meta with empty procedures.',
        },
      ],
    };
    final res = await _client.post(
      uri,
      headers: {
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(body),
    );
    _throwIfOpenAiHttpFailed(res);
    final decoded = jsonDecode(res.body) as Map<String, Object?>;
    final choices = (decoded['choices'] as List?) ?? const [];
    final first = choices.isNotEmpty
        ? (choices.first as Map)
        : const <String, Object?>{};
    final msg = (first['message'] as Map?) ?? const {};
    final content = _stripCodeFences((msg['content'] as String?)?.trim() ?? '');
    if (content.isEmpty) throw StateError('Empty meta response');
    final jsonObj = jsonDecode(content) as Map;
    return OpenAIClinicProfilePage.fromJson(jsonObj.cast<String, Object?>());
  }

  /// Phase-2 stream: yields partial results as pages arrive in parallel.
  /// First emission ~8–10 s (homepage batch), second ~15–18 s (all pages).
  /// Caller (clinic_profile_screen) calls setState on each emission.
  Stream<OpenAIClinicProfilePage> buildClinicProfilePageStream({
    required String clinicName,
    required String city,
    String? websiteUrl,
  }) async* {
    if (!isConfigured) return;
    var url = (websiteUrl ?? '').trim();
    if (url.isNotEmpty && !url.startsWith('http')) url = 'https://$url';
    final currency = _inferCurrencyFromCity(city);

    // Build the AI search prompt once so it can be fired immediately.
    final urlNote = url.isNotEmpty
        ? ' Known website: $url — start there, visit all sub-pages.'
        : '';
    const _aiSystemPrompt =
        'You extract aesthetic clinic treatments and prices from websites worldwide.\n'
        'Return ONLY valid JSON — no markdown, no code fences.\n\n'
        'SCHEMA (keep all fields, use 0/empty for unknowns):\n'
        '{"clinic_name":string,"city":string,"clinic_type_label":string,"area":string,'
        '"distance_mi":0,"lat":0,"lng":0,"rating":0,"reviews_total":0,"google_place_url":"",'
        '"procedure_count":0,"doctor_count":0,"is_verified":bool,"is_doctor_led":bool,'
        '"hero_tags":string[],"about":string,"currency":string,'
        '"price_range_label":"","price_min":0,"price_max":0,"categories":string[],'
        '"procedures":[{"name":string,"category":string,"icon_kind":string,'
        '"price_min":number,"price_max":number,"price_label":string,'
        '"detail":"","tags":[],"featured":false}],'
        '"doctors":[{"name":string,"initials":string,"specialty":string,'
        '"badge":string,"years_experience":number}],'
        '"contact":{"address":"","phone":"","website":"","instagram":"","opening_hours":"","is_open_now":false},'
        '"reviews":[]}\n\n'
        '✅ SPECIFIC treatment names: "Lip filler", "Cheek filler", "Biostimulators", '
        '"Polynucleotides - PDRN", "Sculptra", "Profhilo", "Botox forehead", '
        "\"Botox crow's feet\", \"HIFU face lift\", \"Laser hair removal\", \"Hydrafacial\"\n"
        '❌ NEVER generic: "Injectable treatments", "Dermal fillers", "Laser treatments"\n'
        'icon_kind: inject | skin | laser | hair | body\n'
        'Doctors: include only from a real team/about page — never invent.\n\n'
        '━━━ SEARCH STRATEGY — try ALL steps, do not stop early ━━━\n'
        'Step 1 — SHOPIFY store (highest priority):\n'
        '  If URL contains .myshopify.com OR site has /collections/:\n'
        '  Visit /collections/all or /collections/ to see all products\n'
        '  Visit specific collections:\n'
        '    /collections/marire-buze → lip filler products\n'
        '    /collections/botox → botox products\n'
        '    /collections/filler → filler products\n'
        '    /collections/injectabile → injectable products\n'
        '  Each Shopify product = one procedure.\n'
        '  Product price = price_min. Use EXACT prices shown.\n'
        '  Do NOT use estimated prices for Shopify stores.\n\n'
        'Step 2 — WooCommerce shop:\n'
        '  Visit /shop/ /produse/ /servicii/ /?post_type=product\n'
        '  Each WooCommerce product = one procedure. Extract ALL products.\n'
        '  Sale price (<ins> tag or colored) = price_min.\n'
        '  Regular/crossed-out price (<del> tag) = price_max.\n'
        'Step 3 — Dedicated price page:\n'
        '  Visit /preturi/ /tarife/ /price-list/ /prices/ /oferte/\n'
        '       /nos-tarifs/ /preise/ /prezzi/ /precios/ /tarifs/\n'
        '  Extract all treatment+price rows from tables or lists.\n'
        'Step 4 — Treatment description pages:\n'
        '  Visit /tratamente/ /estetica-medicala/ /services/ /treatments/\n'
        '       /proceduri/ /soins/ /leistungen/ /anti-aging/\n'
        '  Extract names + any prices found. Follow sub-page links.\n'
        'Step 5 — Individual treatment pages (up to 15 pages):\n'
        '  Follow links from Step 4. Look for "from £X" / "prices from" on each page.\n'
        'Step 6 — Homepage: check for featured prices or price ranges.\n'
        'Step 7 — If NO prices found anywhere:\n'
        '  Set price_min=0, price_max=0, price_label="". Do NOT estimate prices.\n\n'
        '━━━ PRICE FORMAT BY COUNTRY ━━━\n'
        'RON (Romania) — DOT = thousand sep:\n'
        '  "545 lei"→545  "1.071 lei"→1071  "de la 545 lei"→min only\n'
        'GBP (UK) — COMMA = thousand sep:\n'
        '  "£250"→250  "£1,500"→1500  "from £250"→min only  "£250–£380"→range\n'
        'EUR Germany/Spain/Italy — DOT = thousand sep:\n'
        '  "250€"→250  "1.500€"→1500  "ab 250€"→min  "desde 250€"→min\n'
        'EUR France — SPACE = thousand sep:\n'
        '  "1 500€"→1500  "à partir de 250€"→min\n'
        'TRY (Turkey) — DOT = thousand sep:\n'
        '  "2.500 TL"→2500  "₺2.500"→2500\n'
        'PLN (Poland): "250 zł"→250  "od 250 zł"→min\n'
        'CHF: "CHF 250"→250  apostrophe = thousand sep\n'
        'RUB: "2 500 ₽"→2500  SPACE = thousand sep\n\n'
        '━━━ OUTPUT RULES ━━━\n'
        '- price_min and price_max = plain integers, NO separators, NO currency symbols.\n'
        '- price_label = formatted string, e.g. "659–1.071 RON" or "£250–380" or "€250".\n'
        '- If price_min == price_max: single price. If only min found: price_max = price_min.\n'
        '- NEVER return price_min=0 if any price exists anywhere on the site.\n'
        '- CRITICAL: ONLY return procedures explicitly '
        'listed on the clinic website. NEVER invent or '
        'assume procedures based on clinic type.\n'
        '- If the clinic only offers fillers and botox, '
        'return ONLY fillers and botox — not Hydrafacial, '
        'not HIFU, not Sculptra unless they appear on site.\n'
        '- If no prices exist, still return real procedure '
        'names with price_min=0, price_max=0.\n'
        '- Return as many procedures as are on the site. '
        'If only 3 are listed, return 3. Do NOT pad to 15.\n'
        '- If clinic website is not found or has no '
        'procedures listed, return empty procedures array.';
    final _aiUserMsg =
        'Clinic: "$clinicName" | City: "$city"\n'
        '${urlNote}'
        'SEARCH STRATEGY:\n'
        '1. Search Google for: "$clinicName preturi" OR\n'
        '   "$clinicName prices" OR "$clinicName tarife"\n'
        '2. Find the clinic price page URL from results\n'
        '3. Visit that price page directly\n'
        '4. Extract ALL treatments and prices from it\n'
        'Common Romanian price page URLs to try:\n'
        '  /preturi/ /lista-preturi/ /tarife/ /prices/\n'
        'Price formats to recognize:\n'
        '  "275€ (1375 lei)" → EUR=275\n'
        '  "de la 500€" → price_min=500 EUR\n'
        '  "180 lei/sedinta" → price=180 RON\n'
        '  "de la 150€ (750 lei)" → price_min=150 EUR\n'
        'Return ONLY procedures found on the website.\n'
        'DO NOT invent procedures not on the site.\n'
        'If only nav menu links found (no prices), '
        'return those with price_min=0.\n'
        'Return JSON only.';

    // Fire the AI web search NOW, in parallel with HTTP scraping.
    // For JS-rendered sites the HTTP scraper finds names but no prices, then
    // falls through here — by then the AI search has already been running and
    // the result arrives almost immediately instead of adding another 20–40 s.
    final aiSearchFuture = _startAiSearchPage(
      systemPrompt: _aiSystemPrompt,
      userMsg: _aiUserMsg,
    );

    if (url.isNotEmpty) {
      final base = url.replaceAll(RegExp(r'/+$'), '');

      // Fetch homepage — detect if site blocks scrapers (Shopify, Cloudflare).
      final homeResult = await _fetchPageTextWithShopify(base);
      final siteIsBlocked = homeResult.blocked;
      if (siteIsBlocked) {
        // ignore: avoid_print
        print('[GP] Site blocked HTTP scraping → names only, no AI prices');
        final aiPage = await aiSearchFuture;
        if (aiPage != null && aiPage.procedures.isNotEmpty) {
          yield _buildPageFromProcedures(
            clinicName: aiPage.clinicName.isNotEmpty
                ? aiPage.clinicName
                : clinicName,
            city: city,
            websiteUrl: url,
            procedures: [
              for (final p in aiPage.procedures)
                OpenAIProfileProcedureRow(
                  name: p.name,
                  detail: p.detail,
                  category: p.category,
                  iconKind: p.iconKind,
                  priceMin: 0,
                  priceMax: 0,
                  priceLabel: '',
                  tags: p.tags,
                  featured: p.featured,
                ),
            ],
            currency: aiPage.currency,
          );
        }
        return;
      }

      final homeHtmlFuture = _fetchRawHtml(base);

      // First emission: extract from homepage alone (~2–3 s fetch + ~6 s AI).
      final homeHtml = await homeHtmlFuture;
      final extractedName = _extractClinicNameFromHtml(homeHtml);
      final resolvedName = extractedName.isNotEmpty
          ? extractedName
          : clinicName;

      var firstBatch = <OpenAIProfileProcedureRow>[];
      if (homeHtml.isNotEmpty) {
        firstBatch = _procedureRowsFromHtmlEvidence(
          html: homeHtml,
          sourceUrl: base,
        );
      }

      // Discover real internal links from the homepage HTML, then fetch in parallel.
      final discoveredUrls = _discoverInternalLinks(
        html: homeHtml,
        baseUrl: base,
      );
      final batchResults = await Future.wait(
        discoveredUrls.map(_fetchPageTextWithShopify),
      );
      var blockedCount = 0;
      for (final r in batchResults) {
        if (r.blocked) blockedCount++;
      }
      if (batchResults.isNotEmpty && blockedCount > batchResults.length ~/ 2) {
        // ignore: avoid_print
        print('[GP] Most batch pages blocked → names only, no AI prices');
        final aiPage = await aiSearchFuture;
        if (aiPage != null && aiPage.procedures.isNotEmpty) {
          yield _buildPageFromProcedures(
            clinicName: aiPage.clinicName.isNotEmpty
                ? aiPage.clinicName
                : clinicName,
            city: city,
            websiteUrl: url,
            procedures: [
              for (final p in aiPage.procedures)
                OpenAIProfileProcedureRow(
                  name: p.name,
                  detail: p.detail,
                  category: p.category,
                  iconKind: p.iconKind,
                  priceMin: 0,
                  priceMax: 0,
                  priceLabel: '',
                  tags: p.tags,
                  featured: p.featured,
                ),
            ],
            currency: aiPage.currency,
          );
        }
        return;
      }
      var allProcs = firstBatch;
      if (discoveredUrls.isNotEmpty) {
        allProcs = _dedupeProcs([
          ...firstBatch,
          for (final u in discoveredUrls)
            ..._procedureRowsFromHtmlEvidence(
              html: ExploreHtmlPriceParseCache.instance.htmlByUrl[u] ?? '',
              sourceUrl: u,
            ),
        ]);
      }

      // Single yield after all pages are merged (avoids UI flicker from
      // multiple partial emissions).
      if (allProcs.isNotEmpty) {
        yield _buildPageFromProcedures(
          clinicName: resolvedName,
          city: city,
          websiteUrl: url,
          procedures: allProcs,
          currency: currency,
        );
      }
      final hasRealPricesInFull = allProcs.any((p) => p.priceMin > 0);
      if (allProcs.isNotEmpty && hasRealPricesInFull) return;

      // HTTP found procedures but no prices (nav-menu-only site).
      if (allProcs.isNotEmpty) {
        aiSearchFuture.ignore();
        return;
      }
    }

    // HTTP found ZERO priced procedures — names-only AI is allowed, not prices.
    final aiPage = await aiSearchFuture;
    if (aiPage != null && aiPage.procedures.isNotEmpty) {
      yield _buildPageFromProcedures(
        clinicName: aiPage.clinicName.isNotEmpty
            ? aiPage.clinicName
            : clinicName,
        city: city,
        websiteUrl: url,
        procedures: [
          for (final p in aiPage.procedures)
            OpenAIProfileProcedureRow(
              name: p.name,
              detail: p.detail,
              category: p.category,
              iconKind: p.iconKind,
              priceMin: 0,
              priceMax: 0,
              priceLabel: '',
              tags: p.tags,
              featured: p.featured,
            ),
        ],
        currency: aiPage.currency,
      );
    }
  }

  /// Fires the AI web-search call and returns a parsed page (or null on error).
  /// Extracted so it can be called as a plain Future that runs in the background.
  Future<OpenAIClinicProfilePage?> _startAiSearchPage({
    required String systemPrompt,
    required String userMsg,
  }) async {
    try {
      final content = await _queueSearchPreview(
        () => _chatCompletionSearchPreviewJson(
          maxTokens: 8000,
          messages: [
            {'role': 'system', 'content': systemPrompt},
            {'role': 'user', 'content': userMsg},
          ],
        ),
      );
      final jsonObj = jsonDecode(content) as Map;
      final page = OpenAIClinicProfilePage.fromJson(
        jsonObj.cast<String, Object?>(),
      );
      // ignore: avoid_print
      print('[GP] AI page procedures count: ${page.procedures.length}');
      // ignore: avoid_print
      print(
        '[GP] AI page first 3 procs: ${page.procedures.take(3).map((p) => p.name).toList()}',
      );
      return page;
    } catch (_) {
      return null;
    }
  }

  /// Convenience [Future] wrapper that collects the last stream emission.
  Future<OpenAIClinicProfilePage> buildClinicProfilePage({
    required String clinicName,
    required String city,
    String? websiteUrl,
  }) async {
    OpenAIClinicProfilePage? last;
    await for (final p in buildClinicProfilePageStream(
      clinicName: clinicName,
      city: city,
      websiteUrl: websiteUrl,
    )) {
      last = p;
    }
    return last ?? _emptyPage(clinicName, city);
  }

  /// True for shut-down / inaccessible models (404, model_not_found), not quota.
  static bool _openAiLooksLikeMissingModel(int statusCode, String body) {
    final lower = body.toLowerCase();
    if (statusCode == 404) return true;
    if (lower.contains('model_not_found')) return true;
    if (lower.contains('invalid_model')) return true;
    if (lower.contains('model_decommissioned')) return true;
    if (lower.contains('model') && lower.contains('does not exist')) {
      return true;
    }
    if (lower.contains('model') && lower.contains('no longer')) return true;
    if (lower.contains('model') && lower.contains('deprecated')) return true;
    return false;
  }

  /// Logs 404 / model_not_found distinctly from 429 / insufficient_quota.
  static void _logOpenAiHttpFailure(int statusCode, String body) {
    if (_openAiLooksLikeMissingModel(statusCode, body)) {
      debugPrint(
        '[GP] OpenAI model not found ($statusCode) — '
        'the requested model is unavailable or shut down. '
        'This is NOT quota exhaustion. body=$body',
      );
      return;
    }
    if (statusCode == 429) {
      if (body.contains('insufficient_quota')) {
        _quotaExhausted = true;
        debugPrint('[GP] OpenAI quota exhausted — all AI calls suspended');
      } else {
        debugPrint('[GP] OpenAI rate limited (429, not quota). body=$body');
      }
      return;
    }
    debugPrint('[GP] OpenAI HTTP $statusCode: $body');
  }

  /// Logs 404 / model_not_found distinctly from 429 / insufficient_quota, then throws.
  static void _throwIfOpenAiHttpFailed(
    http.Response res, {
    String? rateLimitMessage,
  }) {
    if (res.statusCode >= 200 && res.statusCode < 300) return;
    _logOpenAiHttpFailure(res.statusCode, res.body);
    if (res.statusCode == 429) {
      throw OpenAIHttpException(res.statusCode, rateLimitMessage ?? res.body);
    }
    throw OpenAIHttpException(res.statusCode, res.body);
  }

  /// Assistant text from a Responses API payload (`output` items / `output_text`).
  static String _extractResponsesOutputText(Map<String, Object?> decoded) {
    final convenience = decoded['output_text'];
    if (convenience is String && convenience.trim().isNotEmpty) {
      return convenience.trim();
    }
    final output = decoded['output'];
    if (output is! List) return '';
    final buf = StringBuffer();
    for (final item in output) {
      if (item is! Map) continue;
      final type = item['type']?.toString();
      if (type != null && type != 'message') continue;
      final role = item['role']?.toString();
      if (role != null && role != 'assistant') continue;
      final content = item['content'];
      if (content is String) {
        buf.write(content);
        continue;
      }
      if (content is! List) continue;
      for (final part in content) {
        if (part is! Map) continue;
        final pType = part['type']?.toString();
        if (pType == 'output_text' || pType == 'text') {
          final t = part['text']?.toString();
          if (t != null && t.isNotEmpty) buf.write(t);
        }
      }
    }
    return buf.toString().trim();
  }

  /// OpenAI Chat Completions with `response_format: json_object` (e.g. gpt-5.6-luna).
  Future<String> _openAiChatJsonCompletion({
    required String openAiModel,
    required String systemPrompt,
    required String userMessage,
    required int maxTokens,
    double temperature = 0.25,
  }) async {
    final uri = Uri.parse('https://api.openai.com/v1/chat/completions');
    final body = <String, Object?>{
      'model': openAiModel,
      ..._temperatureParam(openAiModel, temperature),
      ..._tokenLimitParam(openAiModel, maxTokens),
      'response_format': {'type': 'json_object'},
      'messages': [
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': userMessage},
      ],
    };

    final res = await _client.post(
      uri,
      headers: {
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(body),
    );
    _throwIfOpenAiHttpFailed(res);

    final decoded = jsonDecode(res.body) as Map<String, Object?>;
    final choices = (decoded['choices'] as List?) ?? const [];
    final first = choices.isNotEmpty ? (choices.first as Map) : const {};
    final msg = (first['message'] as Map?) ?? const {};
    final content = _stripCodeFences((msg['content'] as String?)?.trim() ?? '');
    if (content.isEmpty) throw StateError('Empty OpenAI response');
    return content;
  }

  /// Clinic/web discovery via Responses API + built-in `web_search` (gpt-5.6-terra).
  Future<String> _chatCompletionSearchPreviewJson({
    required List<Map<String, Object?>> messages,
    required int maxTokens,
  }) async {
    final enforced = List<Map<String, Object?>>.from(messages);
    for (var i = enforced.length - 1; i >= 0; i--) {
      final m = enforced[i];
      if (m['role'] != 'user') continue;
      final lastContent = (m['content'] as String? ?? '');
      if (!lastContent.toLowerCase().contains('json')) {
        enforced[i] = {
          ...m,
          'content':
              '$lastContent\n\n'
              'IMPORTANT: Return ONLY valid JSON. '
              'No prose, no explanation, no markdown.',
        };
      }
      break;
    }

    final uri = Uri.parse('https://api.openai.com/v1/responses');
    final body = <String, Object?>{
      'model': _kWebSearchModel,
      'input': enforced,
      'tools': [
        {'type': 'web_search'},
      ],
      'max_output_tokens': maxTokens,
    };

    final res = await _client
        .post(
          uri,
          headers: {
            'Authorization': 'Bearer $_apiKey',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 45));

    _throwIfOpenAiHttpFailed(
      res,
      rateLimitMessage: 'Rate limited — queued request still hit limit',
    );

    final decoded = jsonDecode(res.body) as Map<String, Object?>;
    final content = _stripCodeFences(_extractResponsesOutputText(decoded));
    if (content.isEmpty) throw StateError('Empty AI response');
    return _extractFirstJsonObject(content);
  }

  /// JSON text from web-search Responses (single-object string) for [jsonDecode].
  String _extractTextFromSearchPreview(String oaSearchJson) => oaSearchJson;

  /// For Shopify product pages, extract price from og:price meta tags
  /// BEFORE HTML stripping. Returns null if no og:price:amount is present.
  ({double? price, String? currency})? _extractShopifyMeta(String html) {
    final amountStr =
        RegExp(
          r'''(?:property|name)=["']og:price:amount["'][^>]*content=["']([^"']+)["']''',
          caseSensitive: false,
        ).firstMatch(html)?.group(1)?.trim() ??
        RegExp(
          r'''content=["']([^"']+)["'][^>]*(?:property|name)=["']og:price:amount["']''',
          caseSensitive: false,
        ).firstMatch(html)?.group(1)?.trim() ??
        RegExp(
          r'''og:price:amount["\s]+content=["']([^"']+)["']''',
          caseSensitive: false,
        ).firstMatch(html)?.group(1)?.trim();

    if (amountStr == null || amountStr.isEmpty) return null;

    final cur =
        RegExp(
          r'''(?:property|name)=["']og:price:currency["'][^>]*content=["']([^"']+)["']''',
          caseSensitive: false,
        ).firstMatch(html)?.group(1)?.trim() ??
        RegExp(
          r'''og:price:currency["\s]+content=["']([^"']+)["']''',
          caseSensitive: false,
        ).firstMatch(html)?.group(1)?.trim();
    final currency = (cur != null && cur.isNotEmpty) ? cur : 'RON';

    double? price;
    final roMatch = RegExp(r'^([\d.]+),\d{2}$').firstMatch(amountStr);
    if (roMatch != null) {
      price = double.tryParse(roMatch.group(1)!.replaceAll('.', ''));
    } else {
      price = double.tryParse(amountStr.replaceAll(',', ''));
    }

    return (price: price, currency: currency);
  }

  /// For Shopify collection / embedded product JSON, extract product names + min variant price.
  List<({String name, double price, String currency})>
  _extractShopifyCollectionProducts(String html) {
    final results = <({String name, double price, String currency})>[];
    final meta = _extractShopifyMeta(html);
    final metaCur = meta?.currency?.trim();
    final defaultCurrency = (metaCur != null && metaCur.isNotEmpty)
        ? metaCur
        : 'RON';

    final jsonScripts = RegExp(
      r'''type=["']application/json["'][^>]*>([\s\S]*?)</script>''',
      caseSensitive: false,
    ).allMatches(html);
    for (final match in jsonScripts) {
      try {
        final raw = match.group(1)?.trim() ?? '';
        if (raw.isEmpty || raw.length > 2_000_000) continue;
        final decoded = jsonDecode(raw);
        if (decoded is! Map) continue;
        final json = decoded.cast<String, Object?>();

        final products = json['products'] as List?;
        if (products != null) {
          for (final p in products) {
            if (p is! Map) continue;
            final pm = p.cast<String, Object?>();
            final title = (pm['title'] as String?)?.trim() ?? '';
            final variants = pm['variants'] as List?;
            if (title.isEmpty || variants == null) continue;
            var minPrice = double.infinity;
            for (final v in variants) {
              if (v is! Map) continue;
              final vm = v.cast<String, Object?>();
              final priceRaw = vm['price'];
              double price = 0;
              if (priceRaw is num) {
                price = priceRaw.toDouble();
              } else if (priceRaw is String) {
                price = double.tryParse(priceRaw.replaceAll(',', '.')) ?? 0;
              }
              final actualPrice = price > 10000 ? price / 100 : price;
              if (actualPrice > 0 && actualPrice < minPrice) {
                minPrice = actualPrice;
              }
            }
            if (minPrice != double.infinity) {
              results.add((
                name: title,
                price: minPrice,
                currency: defaultCurrency,
              ));
            }
          }
        }

        final title = (json['title'] as String?)?.trim() ?? '';
        final variants = json['variants'] as List?;
        if (title.isNotEmpty && variants != null) {
          var minPrice = double.infinity;
          for (final v in variants) {
            if (v is! Map) continue;
            final vm = v.cast<String, Object?>();
            final priceRaw = vm['price'];
            double price = 0;
            if (priceRaw is num) {
              price = priceRaw.toDouble();
            } else if (priceRaw is String) {
              price = double.tryParse(priceRaw.replaceAll(',', '.')) ?? 0;
            }
            final actualPrice = price > 10000 ? price / 100 : price;
            if (actualPrice > 0 && actualPrice < minPrice) {
              minPrice = actualPrice;
            }
          }
          if (minPrice != double.infinity) {
            results.add((
              name: title,
              price: minPrice,
              currency: defaultCurrency,
            ));
          }
        }
      } catch (_) {}
    }
    return results;
  }

  String _shopifyProductTitleFromUrl(String url) {
    final idx = url.toLowerCase().indexOf('/products/');
    if (idx < 0) return '';
    var rest = url.substring(idx + '/products/'.length);
    final q = rest.indexOf('?');
    if (q >= 0) rest = rest.substring(0, q);
    final slash = rest.indexOf('/');
    if (slash >= 0) rest = rest.substring(0, slash);
    final slug = rest.trim();
    if (slug.isEmpty) return '';
    return slug
        .split('-')
        .where((w) => w.isNotEmpty)
        .map(
          (w) =>
              '${w[0].toUpperCase()}${w.length > 1 ? w.substring(1).toLowerCase() : ''}',
        )
        .join(' ');
  }

  /// Like [_fetchPageTextEx] but prepends Shopify og:price / JSON product lines
  /// before stripping so real prices survive for the extractor.
  Future<({String text, bool blocked})> _fetchPageTextWithShopify(
    String url,
  ) async {
    if (_isSessionBlockedHost(url)) {
      debugPrint('[GP] Skip blocked domain $url');
      return (text: '', blocked: true);
    }
    try {
      final res = await _client
          .get(
            Uri.parse(url),
            headers: {
              'User-Agent':
                  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 '
                  'like Mac OS X) AppleWebKit/605.1.15 '
                  '(KHTML, like Gecko) Version/17.0 '
                  'Mobile/15E148 Safari/604.1',
              'Accept': 'text/html,application/xhtml+xml',
              'Accept-Language':
                  'en-US,en;q=0.9,ar;q=0.8,ro;q=0.7,es;q=0.6,fr;q=0.5',
            },
          )
          .timeout(const Duration(seconds: 5));

      if (res.statusCode == 403) {
        _rememberHttp403(url);
        print('[GP] BLOCKED $url (403)');
        return (text: '', blocked: true);
      }
      if (res.statusCode == 429) {
        print('[GP] BLOCKED $url (429)');
        return (text: '', blocked: true);
      }

      if (res.statusCode != 200) {
        return (text: '', blocked: false);
      }

      final html = decodeHtmlHttpBody(
        bodyBytes: res.bodyBytes,
        contentType: res.headers['content-type'] ?? '',
      );
      ExploreHtmlPriceParseCache.instance.rememberHtml(url, html);
      final shopifyMeta = _extractShopifyMeta(html);
      final shopifyProducts = _extractShopifyCollectionProducts(html);

      var text = _stripHtmlContent(html);

      final priceLines = StringBuffer();
      if (shopifyMeta?.price != null) {
        final p = shopifyMeta!.price!;
        final c = shopifyMeta.currency ?? 'RON';
        final productName = _shopifyProductTitleFromUrl(url);
        if (productName.isNotEmpty) {
          priceLines.writeln(
            'PRODUCT PRICE: $productName — ${p.toStringAsFixed(0)} $c',
          );
        } else {
          priceLines.writeln('PRODUCT PRICE: — ${p.toStringAsFixed(0)} $c');
        }
      }
      for (final prod in shopifyProducts) {
        priceLines.writeln(
          'PRODUCT PRICE: ${prod.name} — '
          '${prod.price.toStringAsFixed(0)} ${prod.currency}',
        );
      }

      final injected = priceLines.toString();
      final combined = injected.isNotEmpty ? '$injected\n\n$text' : text;

      final isPricePage =
          url.contains('preturi') ||
          url.contains('/pret/') ||
          (url.contains('/pret') && url.endsWith('pret')) ||
          url.contains('servicii-si-preturi') ||
          url.contains('servicii-preturi') ||
          url.contains('preturi-') ||
          url.contains('-preturi') ||
          url.contains('tarife') ||
          url.contains('tarif') ||
          url.contains('costuri') ||
          url.contains('price') ||
          url.contains('lista') ||
          url.contains('oferte') ||
          url.contains('servicii') ||
          url.contains('collections') ||
          url.contains('products') ||
          url.contains('shop');
      final limit = isPricePage ? 25000 : 12000;
      final out = combined.length > limit
          ? combined.substring(0, limit)
          : combined;

      final shopifyCount =
          shopifyProducts.length + (shopifyMeta?.price != null ? 1 : 0);
      // ignore: avoid_print
      print(
        '[GP] Fetched $url: ${out.length} chars'
        '${isPricePage ? " (price page)" : ""}'
        '${injected.isNotEmpty ? " +Shopify:$shopifyCount" : ""}',
      );

      return (text: out, blocked: false);
    } catch (_) {}
    return (text: '', blocked: false);
  }

  /// Price menus, service lists and shop pages get a bigger text budget and
  /// are worth a headless render when the plain fetch comes back empty.
  bool _looksLikePricePageUrl(String url) =>
      url.contains('preturi') ||
      url.contains('/pret/') ||
      (url.contains('/pret') && url.endsWith('pret')) ||
      url.contains('servicii-si-preturi') ||
      url.contains('servicii-preturi') ||
      url.contains('preturi-') ||
      url.contains('-preturi') ||
      url.contains('tarife') ||
      url.contains('tarif') ||
      url.contains('costuri') ||
      url.contains('price') ||
      url.contains('lista') ||
      url.contains('oferte') ||
      url.contains('servicii') ||
      url.contains('collections') ||
      url.contains('products') ||
      url.contains('shop') ||
      url.contains('precio') ||
      url.contains('tarifa') ||
      url.contains('prezzi') ||
      url.contains('preise') ||
      url.contains('fiyat') ||
      url.contains('cennik') ||
      url.contains('package') ||
      url.contains('offer');

  String _rendererBase() => (dotenv.env['RENDERER_URL'] ?? '').trim();

  String _rendererToken() => (dotenv.env['RENDERER_TOKEN'] ?? '').trim();

  /// Real DOM for a site that 403s our client or renders prices in JS.
  /// The HTML is handed to the same deterministic extractor as a normal fetch.
  Future<String> _renderHtml(String url, {required String reason}) {
    final endpoint = exploreRendererEndpoint(_rendererBase());
    if (endpoint == null) {
      if (!_loggedRendererMissingConfig) {
        _loggedRendererMissingConfig = true;
        debugPrint('[GP RENDER] skipped — set RENDERER_URL in .env');
      }
      return Future.value('');
    }
    if (!exploreRendererAllowsUrl(url)) return Future.value('');
    final cached = _renderCache[url];
    if (cached != null) return cached;
    final host = _stripWww(_normalizeProbeHost(url));
    if ((_rendersPerHost[host] ?? 0) >= _kMaxRendersPerHost) {
      debugPrint('[GP RENDER] host budget spent — $host');
      return Future.value('');
    }
    if (_rendersUsed >= _kMaxRendersPerSession) {
      debugPrint('[GP RENDER] session budget spent — $url');
      return Future.value('');
    }
    _rendersUsed++;
    _rendersPerHost[host] = (_rendersPerHost[host] ?? 0) + 1;

    final fut = () async {
      debugPrint('[GP RENDER] $reason → $url');
      try {
        final res = await _client
            .post(
              endpoint,
              headers: exploreRendererHeaders(_rendererToken()),
              body: exploreRendererRequestBody(url),
            )
            .timeout(_kRenderTimeout);
        if (res.statusCode != 200) {
          debugPrint('[GP RENDER] HTTP ${res.statusCode} — $url');
          return '';
        }
        final rendered = exploreParseRenderedHtml(res.body);
        if (!rendered.usable) {
          debugPrint(
            '[GP RENDER] unusable (page HTTP ${rendered.statusCode}, '
            '${rendered.html.length} chars) — $url',
          );
          if (rendered.statusCode == 403 || rendered.statusCode == 429) {
            _rememberHttp403(url);
          }
          return '';
        }
        debugPrint('[GP RENDER] ${rendered.html.length} chars — $url');
        return rendered.html;
      } catch (e) {
        debugPrint('[GP RENDER] failed: $e');
        return '';
      }
    }();
    _renderCache[url] = fut;
    return fut;
  }

  /// Rendered HTML → cache + stripped text, so callers treat it exactly like a
  /// normal fetch of the clinic's own page.
  Future<({String text, bool blocked})> _renderedPageText(
    String url, {
    required String reason,
  }) async {
    final html = await _renderHtml(url, reason: reason);
    if (html.isEmpty) return (text: '', blocked: true);
    ExploreHtmlPriceParseCache.instance.rememberHtml(url, html);
    final text = _stripHtmlContent(html);
    if (text.trim().isEmpty) return (text: '', blocked: true);
    final limit = _looksLikePricePageUrl(url) ? 25000 : 12000;
    final out = text.length > limit ? text.substring(0, limit) : text;
    debugPrint('[GP RENDER] usable text ${out.length} chars — $url');
    return (text: out, blocked: false);
  }

  Future<({String text, bool blocked})> _fetchPageTextEx(
    String url, {
    Duration? timeout,
    bool allowRender = false,
  }) async {
    if (ExploreZyteClient.isUnsupportedUrl(url)) {
      debugPrint('[GP] Skip unsupported URL $url');
      return (text: '', blocked: false);
    }
    if (_isSessionBlockedHost(url)) {
      debugPrint('[GP] Skip blocked domain $url');
      return (text: '', blocked: true);
    }
    try {
      final res = await _client
          .get(
            Uri.parse(url),
            headers: {
              'User-Agent':
                  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 '
                  'like Mac OS X) AppleWebKit/605.1.15 '
                  '(KHTML, like Gecko) Version/17.0 '
                  'Mobile/15E148 Safari/604.1',
              'Accept': 'text/html,application/xhtml+xml',
              'Accept-Language':
                  'en-US,en;q=0.9,ar;q=0.8,ro;q=0.7,es;q=0.6,fr;q=0.5',
            },
          )
          .timeout(timeout ?? const Duration(seconds: 5));

      if (res.statusCode == 403) {
        _rememberHttp403(url);
        print('[GP] BLOCKED $url (403)');
        // Cloudflare also blocks the headless browser. Rendering a 403
        // page costs ~14s and never yields a price table.
        return (text: '', blocked: true);
      }
      if (res.statusCode == 429) {
        print('[GP] BLOCKED $url (429)');
        _rememberHttp403(url);
        return (text: '', blocked: true);
      }

      if (res.statusCode == 200) {
        final contentType = res.headers['content-type'] ?? '';
        // PDF price lists: extract text via Firecrawl parsers before any OCR.
        if (exploreContentTypeIsPdf(contentType) ||
            exploreUrlLooksLikePdf(url)) {
          final fcKey = _firecrawlApiKey();
          if (fcKey.isNotEmpty) {
            final page = await ExploreFirecrawlClient(
              apiKey: fcKey,
            ).scrapePage(url);
            if (page.usable) {
              ExploreHtmlPriceParseCache.instance.rememberHtml(
                page.url,
                page.html,
              );
              final text = _stripHtmlContent(page.html);
              debugPrint(
                '[GP] PDF extract ${page.url}: ${text.length} chars'
                '${page.fromPdf ? " (pdf)" : ""}',
              );
              return (text: text, blocked: false);
            }
          }
          debugPrint('[GP] PDF skipped (no Firecrawl) $url');
          return (text: '', blocked: false);
        }
        final html = decodeHtmlHttpBody(
          bodyBytes: res.bodyBytes,
          contentType: contentType,
        );
        ExploreHtmlPriceParseCache.instance.rememberHtml(url, html);
        final text = _stripHtmlContent(html);
        final isPricePage = _looksLikePricePageUrl(url);
        // A JS shell has the price table in a script bundle we cannot read,
        // so the headless browser is the only honest way to see it.
        if (htmlLooksLikeJsShell(html) || text.trim().length < 400) {
          debugPrint('[GP EXTRACT] rendering_required $url');
          if (allowRender) {
            final rendered = await _renderedPageText(
              url,
              reason: htmlLooksLikeJsShell(html) ? 'js_shell' : 'thin_page',
            );
            if (rendered.text.length > text.trim().length) return rendered;
          }
        }
        final limit = isPricePage ? 25000 : 12000;
        final out = text.length > limit ? text.substring(0, limit) : text;
        // ignore: avoid_print
        print(
          '[GP] Fetched $url: ${out.length} chars'
          '${isPricePage ? " (price page)" : ""}',
        );
        return (text: out, blocked: false);
      }
    } catch (_) {}
    return (text: '', blocked: false);
  }

  /// Fetches a single page; returns stripped text or '' on failure.
  Future<String> _fetchPageText(String url) async {
    final r = await _fetchPageTextEx(url);
    return r.text;
  }

  /// Fetches raw HTML for link discovery. Longer timeout, no stripping.
  Future<String> _fetchRawHtml(String url) async {
    if (ExploreZyteClient.isUnsupportedUrl(url)) return '';
    try {
      final res = await _client
          .get(
            Uri.parse(url),
            headers: {'User-Agent': 'Mozilla/5.0 GlowPass/1.0'},
          )
          .timeout(const Duration(seconds: 6));
      if (res.statusCode == 403 || res.statusCode == 429) {
        _rememberHttp403(url);
        return '';
      }
      if (res.statusCode == 200) {
        final html = decodeHtmlHttpBody(
          bodyBytes: res.bodyBytes,
          contentType: res.headers['content-type'] ?? '',
        );
        ExploreHtmlPriceParseCache.instance.rememberHtml(url, html);
        return html;
      }
    } catch (_) {}
    return '';
  }

  String _extractClinicNameFromHtml(String html) {
    // 1) Organization / Physician JSON-LD (most reliable provider identity).
    final jsonLdBlocks = RegExp(
      r'<script[^>]*type=["'
      ']application/ld\+json["'
      '][^>]*>([\s\S]*?)</script>',
      caseSensitive: false,
    ).allMatches(html);
    for (final block in jsonLdBlocks) {
      final raw = (block.group(1) ?? '').trim();
      if (raw.isEmpty) continue;
      try {
        final decoded = jsonDecode(raw);
        final name = _jsonLdOrganizationName(decoded);
        if (name.isNotEmpty &&
            name.length < 80 &&
            !looksLikeProcedureNameAsClinicIdentity(name) &&
            clinicIdentityRejectReason(name) == null) {
          return name;
        }
      } catch (_) {
        /* ignore malformed JSON-LD */
      }
    }

    // 2) og:site_name
    final ogSite = RegExp(
      r'og:site_name["\s]+content="([^"]+)"',
      caseSensitive: false,
    ).firstMatch(html);
    if (ogSite != null) {
      final name = ogSite.group(1)?.trim() ?? '';
      if (name.isNotEmpty &&
          name.length < 80 &&
          !looksLikeProcedureNameAsClinicIdentity(name) &&
          clinicIdentityRejectReason(name) == null) {
        return name;
      }
    }

    // 3) Header / logo text
    final logoAlt = RegExp(
      r'<img[^>]*(?:class|id)=["'
      '][^"'
      ']*(?:logo|brand)[^"'
      ']*["'
      '][^>]*alt=["'
      ']([^"'
      ']+)["'
      ']',
      caseSensitive: false,
    ).firstMatch(html);
    if (logoAlt != null) {
      final name = logoAlt.group(1)?.trim() ?? '';
      if (name.isNotEmpty &&
          name.length < 80 &&
          !looksLikeProcedureNameAsClinicIdentity(name) &&
          clinicIdentityRejectReason(name) == null) {
        return name;
      }
    }

    // 4) <title> — prefer provider after "|" / "—" when left side is SEO
    //    ("Kalıcı Botoks Fiyatları 2026 | Dr. Mutlu Adıgüzel").
    final titleMatch = RegExp(
      r'<title[^>]*>([^<]+)</title>',
      caseSensitive: false,
    ).firstMatch(html);
    if (titleMatch != null) {
      var title = titleMatch.group(1)?.trim() ?? '';
      title = title
          .replaceAll(RegExp(r'\s+'), ' ')
          .replaceAll(
            RegExp(r'\s*[|–—]\s*WhatsApp.*$', caseSensitive: false),
            '',
          )
          .trim();
      final pipeParts = title.split(RegExp(r'\s*[|–—]\s*'));
      if (pipeParts.length >= 2) {
        final right = pipeParts.last.trim();
        if (right.isNotEmpty &&
            right.length < 80 &&
            !looksLikeProcedureNameAsClinicIdentity(right) &&
            clinicIdentityRejectReason(right) == null) {
          return right;
        }
      }
      title = title
          .replaceAll(
            RegExp(
              r'\s*[-–|]\s*(tarife|preturi|home|acasa|prices|about|'
              r'fiyatlar|fiyatları|ücretler|detaylı\s+rehber).*',
              caseSensitive: false,
            ),
            '',
          )
          .trim();
      if (title.isNotEmpty &&
          title.length < 80 &&
          !looksLikeProcedureNameAsClinicIdentity(title) &&
          clinicIdentityRejectReason(title) == null) {
        return title;
      }
    }

    // 4b) Turkish physician byline on the page body.
    final trDoctor = RegExp(
      r'(?:Uzm\.?\s*)?Dr\.?\s+([A-ZÇĞİÖŞÜ][\wçğıöşüÇĞİÖŞÜ'
      '\-]+'
      r'(?:\s+[A-ZÇĞİÖŞÜ][\wçğıöşüÇĞİÖŞÜ'
      '\-]+){0,3})|'
      r'Uzman\s+Doktor\s+([A-ZÇĞİÖŞÜ][\wçğıöşüÇĞİÖŞÜ'
      '\-]+'
      r'(?:\s+[A-ZÇĞİÖŞÜ][\wçğıöşüÇĞİÖŞÜ'
      '\-]+){0,3})',
    ).firstMatch(html.replaceAll(RegExp(r'<[^>]+>'), ' '));
    if (trDoctor != null) {
      final person = (trDoctor.group(1) ?? trDoctor.group(2) ?? '').trim();
      if (person.isNotEmpty) {
        final name = 'Dr. $person';
        if (name.length < 80 &&
            !looksLikeProcedureNameAsClinicIdentity(name) &&
            clinicIdentityRejectReason(name) == null) {
          return name;
        }
      }
    }

    // 5) og:title — same guard
    final ogTitle = RegExp(
      r'property="og:title"[^>]+content="([^"]+)"',
      caseSensitive: false,
    ).firstMatch(html);
    if (ogTitle != null) {
      var name = ogTitle.group(1)?.trim() ?? '';
      name = name.replaceAll(RegExp(r'\s*[-–|].*'), '').trim();
      if (name.isNotEmpty &&
          name.length < 80 &&
          !looksLikeProcedureNameAsClinicIdentity(name) &&
          clinicIdentityRejectReason(name) == null) {
        return name;
      }
    }

    return '';
  }

  /// Test hook for provider identity extraction (JSON-LD / og:site_name).
  @visibleForTesting
  String extractClinicNameFromHtmlForTest(String html) =>
      _extractClinicNameFromHtml(html);

  String _jsonLdOrganizationName(Object? node) {
    if (node is List) {
      for (final item in node) {
        final n = _jsonLdOrganizationName(item);
        if (n.isNotEmpty) return n;
      }
      return '';
    }
    if (node is! Map) return '';
    final map = node.map((k, v) => MapEntry('$k', v));
    final typeRaw = map['@type'];
    final types = <String>[];
    if (typeRaw is String) types.add(typeRaw.toLowerCase());
    if (typeRaw is List) {
      for (final t in typeRaw) {
        if (t is String) types.add(t.toLowerCase());
      }
    }
    final isOrg = types.any(
      (t) =>
          t.contains('organization') ||
          t.contains('localbusiness') ||
          t.contains('medicalclinic') ||
          t.contains('physician') ||
          t.contains('dentist') ||
          t.contains('hospital') ||
          t.contains('person'),
    );
    if (isOrg) {
      final name = '${map['name'] ?? ''}'.trim();
      if (name.isNotEmpty) return name;
    }
    final graph = map['@graph'];
    if (graph != null) return _jsonLdOrganizationName(graph);
    return '';
  }

  /// Extracts internal links from HTML, sorted by relevance to treatments/prices.
  /// Also appends WooCommerce pagination pages when a shop path is detected.
  List<String> _discoverInternalLinks({
    required String html,
    required String baseUrl,
    bool addGuessedPriceFallbacks = false,
  }) {
    final host = Uri.parse(baseUrl).host;
    final seen = <String>{};

    final hrefRegex = RegExp(
      r'''href=["']([^"'#?][^"']*?)["']''',
      caseSensitive: false,
    );
    for (final m in hrefRegex.allMatches(html)) {
      var href = m.group(1)?.trim() ?? '';
      if (href.isEmpty) continue;
      if (href.startsWith('/')) {
        href = baseUrl + href;
      } else if (!href.startsWith('http')) {
        continue;
      }
      if (!href.contains(host)) continue;
      if (href.contains('/wp-content/') ||
          href.contains('/wp-admin/') ||
          href.contains('/wp-login') ||
          href.contains('/feed') ||
          href.contains('/tag/') ||
          href.contains('/author/') ||
          href.contains('.jpg') ||
          href.contains('.jpeg') ||
          href.contains('.png') ||
          href.contains('.gif') ||
          href.contains('mailto:') ||
          href.contains('tel:'))
        continue;
      seen.add(href.replaceAll(RegExp(r'/+$'), ''));
    }

    final priorityKeywords = <String>[
      ...kExploreWorldUrlPriceTokens.take(40),
      'shop',
      'produse',
      'produs',
      'product',
      'store',
      'collections',
      'oferte',
      'booking',
      'rezervari',
      'servicii',
      'tratamente',
      'tratamientos',
      'estetica',
      'proceduri',
      'anti-aging',
      'injectabile',
      'laser',
      'dermatologie',
      'facial',
    ];

    final prioritized = <String>[];
    final rest = <String>[];
    for (final u in seen) {
      final lower = u.toLowerCase();
      if (priorityKeywords.any((k) => lower.contains(k))) {
        prioritized.add(u);
      } else {
        rest.add(u);
      }
    }

    int pricePathScore(String u) {
      final l = u.toLowerCase();
      if (l.contains('/preturi') ||
          l.contains('/tarife') ||
          l.contains('/prices') ||
          l.contains('/precios') ||
          l.contains('/tarifas') ||
          l.contains('/tarif')) {
        return 0;
      }
      return 1;
    }

    prioritized.sort((a, b) => pricePathScore(a).compareTo(pricePathScore(b)));

    final ordered = [...prioritized, ...rest].take(25).toList();
    // ignore: avoid_print
    print('[GP] Discovered ${ordered.length} URLs');

    // Add WooCommerce pagination for any shop/produse paths found.
    final shopPaths = <String>[];
    for (final u in ordered) {
      final lower = u.toLowerCase();
      if (lower.contains('/shop') || lower.contains('/produse')) {
        final shopBase = u.replaceAll(RegExp(r'/page/\d+/?$'), '');
        shopPaths
          ..add('$shopBase/page/2/')
          ..add('$shopBase/page/3/');
        break;
      }
    }
    // Also add well-known WooCommerce fallback paths.
    shopPaths
      ..add('$baseUrl/shop/page/2/')
      ..add('$baseUrl/shop/page/3/')
      ..add('$baseUrl/produse/page/2/')
      ..add('$baseUrl/produse/page/3/');

    // Append common price-list page URLs as fallback — tried even if not
    // discovered via link-scraping. Does not affect existing discovered URLs.
    final priceFallbacks = [
      '$baseUrl/pret/',
      '$baseUrl/pret',
      '$baseUrl/servicii-si-preturi/',
      '$baseUrl/servicii-si-preturi',
      '$baseUrl/servicii-preturi/',
      '$baseUrl/preturi-servicii-si-preturi/',
      '$baseUrl/lista-servicii/',
      '$baseUrl/tratamente-preturi/',
      '$baseUrl/preturi-tratamente-si-servicii/',
      '$baseUrl/lista-preturi/',
      '$baseUrl/lista-preturi',
      '$baseUrl/preturi.html',
      '$baseUrl/prices.html',
      '$baseUrl/tarife.html',
      '$baseUrl/tarife-servicii/',
      '$baseUrl/lista-tarife/',
      '$baseUrl/costuri/',
      '$baseUrl/price-list.html',
      '$baseUrl/lista-preturi.html',
      '$baseUrl/preturi/',
      '$baseUrl/preturi-tratamente-injectabile/',
      '$baseUrl/preturi-injectabile/',
      '$baseUrl/preturi-tratamente/',
      '$baseUrl/preturi-servicii/',
      '$baseUrl/preturi-botox/',
      '$baseUrl/preturi-filler/',
      '$baseUrl/preturi-laser/',
      '$baseUrl/preturi-epilare/',
      '$baseUrl/preturi-dermapen/',
      '$baseUrl/preturi-morpheus/',
      '$baseUrl/preturi-peeling/',
      '$baseUrl/preturi-hifu/',
      '$baseUrl/preturi-pdr/',
      '$baseUrl/preturi-prp/',
      '$baseUrl/preturi-mezoterapie/',
      '$baseUrl/tarife/',
      '$baseUrl/price-list/',
      '$baseUrl/prices/',
      '$baseUrl/fees/',
      '$baseUrl/fees',
      '$baseUrl/our-fees/',
      '$baseUrl/our-fees',
      '$baseUrl/prices/injectables/',
      '$baseUrl/prices/injectables',
      '$baseUrl/nos-tarifs/',
      '$baseUrl/preise/',
      '$baseUrl/prezzi/',
      '$baseUrl/precios/',
      // Shopify-style price/product paths (e.g. drestetix.ro/collections/marire-buze).
      '$baseUrl/collections/',
      '$baseUrl/collections/all',
    ];

    // Smart discovery: find price links in HTML text
    // Matches any internal URL containing price keywords
    final pricePageRegex = RegExp(
      r'''href=["']([^"']*(?:preturi[-/]|tarife[-/]|preturi|tarife|tarif|price|cost|fees|'''
      r'''servicii|lista|oferte|chirurgicale|tratamente|collections)[^"']*)["']''',
      caseSensitive: false,
    );
    for (final m in pricePageRegex.allMatches(html)) {
      var href = m.group(1)?.trim() ?? '';
      if (href.isEmpty) continue;
      if (href.startsWith('/')) href = baseUrl + href;
      if (!href.contains(host)) continue;
      if (!seen.contains(href)) {
        seen.add(href);
        ordered.insert(0, href); // put at front — high priority
      }
    }

    if (!addGuessedPriceFallbacks) {
      return [...ordered, ...shopPaths.where((u) => !seen.contains(u))];
    }

    final newFallbacks = priceFallbacks
        .where((u) => !seen.contains(u) && !ordered.contains(u))
        .toList();
    // ignore: avoid_print
    print('[GP] Price fallbacks added: ${newFallbacks.length}');

    return [
      ...ordered,
      ...shopPaths.where((u) => !seen.contains(u)),
      ...newFallbacks,
    ];
  }

  /// Splits a list of page texts into batches capped at [maxChars] each.
  // ignore: unused_element
  List<String> _splitIntoBatches(List<String> texts, int maxChars) {
    final batches = <String>[];
    var buf = StringBuffer();
    for (final t in texts) {
      if (buf.length + t.length > maxChars && buf.isNotEmpty) {
        batches.add(buf.toString());
        buf = StringBuffer();
      }
      buf.write('\n\n');
      buf.write(t);
    }
    if (buf.isNotEmpty) batches.add(buf.toString());
    return batches;
  }

  /// Legacy GPT procedure extract — no longer used for Explore prices.
  // ignore: unused_element
  Future<List<OpenAIProfileProcedureRow>> _extractProceduresFromText({
    required String text,
    required String clinicName,
    required String city,
  }) async {
    final trimmed = text.length > 30000 ? text.substring(0, 30000) : text;
    final currency = _inferCurrencyFromCity(city);
    final effectiveCurrency = _effectiveCurrencyFromPageText(trimmed, currency);
    final uri = Uri.parse('https://api.openai.com/v1/chat/completions');
    final body = <String, Object?>{
      'model': model,
      ..._temperatureParam(model, 0.1),
      ..._tokenLimitParam(model, 16000),
      'response_format': {'type': 'json_object'},
      'messages': [
        {
          'role': 'system',
          'content':
              'Extract every individual aesthetic treatment. SPECIFIC names required.\n'
              '✅ "Lip filler", "Cheek filler", "Biostimulators", "Polynucleotides - PDRN", '
              '"Sculptra", "Profhilo", "HIFU", "Radiofrequency skin tightening", '
              '"Botox forehead", "Botox crow\'s feet", "Laser hair removal", '
              '"Chemical peel", "Hydrafacial", "Thread lift"\n'
              '❌ "Injectable treatments", "Dermal fillers", "Laser treatments"\n'
              'Translate to English. Return ONLY valid JSON:\n'
              '{"procedures":[{"name":string,"category":string,"icon_kind":string,'
              '"price_min":number,"price_max":number,"price_label":string,'
              '"detail":"","tags":[],"featured":false}]}\n'
              'icon_kind: inject|skin|laser|hair|body\n'
              'category: Injectables|Skin|Laser|Hair Removal|Body|Surgery\n'
              'WOOCOMMERCE PRICE EXTRACTION:\n'
              '- Many clinic sites store prices in a WooCommerce shop (/shop/ /produse/ /?post_type=product).\n'
              '- Product title = treatment name. Product category = treatment category.\n'
              '- Sale price (inside <ins> or colored text) = price_min. Original/crossed-out price (<del>) = price_max.\n'
              '- Romanian WooCommerce format: "1.071 lei" → price_min=1071 (dot=thousand sep, lei=RON).\n'
              '- If the text contains product listings (name + price rows), extract ALL of them.\n'
              'GLOBAL PRICE EXTRACTION — applies to ALL countries:\n'
              '- price_min and price_max MUST be plain integers, NO thousand separators, NO currency symbols.\n'
              '- Thousand separator by locale: Romania/Turkey/Germany/Spain = dot (1.500→1500); UK/US = comma (1,500→1500); Russia/Sweden = space (1 500→1500); Switzerland = apostrophe (1\'500→1500).\n'
              '- "from X"/"de la X"/"ab X"/"desde X" → price_min only. "X–Y"/"X-Y" → price_min=X, price_max=Y.\n'
              '- lei/Lei=RON; TL/TRY=Turkish lira; zł=PLN. Strip currency words from the number.\n'
              '- price_label: "X CURRENCY" or "X–Y CURRENCY". '
              'Never return 0 if a price exists.\n'
              'PRP / PLATELET RICH PLASMA FORMAT:\n'
              '- "PRP facial 550 LEI" → name="PRP therapy face",\n'
              '  price_min=550, currency=RON\n'
              '- "PRP terapie" / "terapie PRP" / "plasma bogata\n'
              '  in trombocite" = PRP therapy\n'
              '- "Ez Gel" / "EZ GEL" = EZ GEL PRF treatment\n'
              '  (Platelet Rich Fibrin) — medical injectable\n'
              '- Always extract PRP/PRF as category: Skin\n'
              '  icon_kind: skin\n'
              'NAVIGATION MENU TREATMENTS:\n'
              'Some sites list treatments ONLY in their nav '
              'menu without prices — extract these too with '
              'price_min=0, price_max=0, price_label="".\n'
              'Common Romanian nav menu treatment names:\n'
              '"Volumizare buze"→Lip filler, inject\n'
              '"Corectie cearcane"→Tear trough filler, inject\n'
              '"Definire mandibulara"→Jawline filler, inject\n'
              '"Augmentare barbie"→Chin filler, inject\n'
              '"Volumizare pometi"→Cheek filler, inject\n'
              '"Santuri nazolabiale"→Nasolabial filler, inject\n'
              '"Linii marioneta"→Marionette lines, inject\n'
              '"Rinoplastie non-chirurgicala"→Non-surgical rhinoplasty, inject\n'
              '"Riduri frunte"→Forehead botox, inject\n'
              '"Riduri perioculare"→Crow\'s feet botox, inject\n'
              '"Riduri de incruntare"→Frown lines botox, inject\n'
              '"Lifting sprancene"→Brow lift botox, inject\n'
              '"Slabire faciala"→Face slimming botox, inject\n'
              '"Zambet gingival"→Gummy smile, inject\n'
              '"Lip flip"→Lip flip botox, inject\n'
              '"Tratament hiperhidroza"→Hyperhidrosis, inject\n'
              'CRITICAL: Only extract procedures actually on '
              'this clinic\'s website. Never add procedures '
              'not present in the scraped content.\n'
              'PLAIN TEXT PRICE LIST FORMAT (e.g. swissclinics.ro):\n'
              'Some sites use simple bullet lists:\n'
              '"- Treatment name PRICE RON"\n'
              '"- Treatment name PRICE EURO"\n'
              '"- Treatment name de la PRICE RON"\n'
              'Examples:\n'
              '"- Baby botox 3 zone 1050 RON" → price=1050, RON\n'
              '"- Volumizare buze JUVEDERM ULTRA 1 ml 1600 RON" → price=1600\n'
              '"- Rinoplastie estetica 4350 EURO" → price=4350, EUR\n'
              '"- Ginecomastie de la 3500 EURO" → price_min=3500 only\n'
              'Rules for plain text lists:\n'
              '- Last token = currency (RON/EURO/EUR/lei)\n'
              '- Number before currency = price\n'
              '- "de la X" = price_min only, price_max=0\n'
              '- Everything before price = treatment name\n'
              '- Translate Romanian names to English\n'
              'This is ADDITIONAL to WooCommerce extraction — apply whichever format matches.'
              '\nROMANIAN BOTULINUM / TOXINĂ BOTULINICĂ LISTS:\n'
              '- "1 zonă (perioculară / laba gâștei): 900 RON" → '
              'name="Botox 1 zone", price_min=900\n'
              '- "2 zone (frontal / glabelă): 1.100 RON" → '
              'name="Botox 2 zones", price_min=1100\n'
              '- Keep zone counts in the name. Do NOT rename a 1-zone or '
              '3-zone row to "Botox forehead".\n'
              '- SKIP ofertă / promo / expired campaign rows '
              '(date ranges, 50 UI packages advertised as a limited offer).\n'
              '\nWORDPRESS CARD FORMAT (e.g. juvenaclinic.ro):\n'
              'Some pages list treatments as cards:\n'
              '  "Treatment Name - variant\n"'
              '  "PRICE RON\n"'
              '  "Short description\n"\n'
              'Rules:\n'
              '- Line 1: treatment name (may include variant like "1ml")\n'
              '- Line 2: price (number + RON/EUR/LEI)\n'
              '- Line 3: description (ignore for extraction)\n'
              '- Extract EACH card as separate procedure\n'
              '- "Volumizare Buze Juvederm Ultra Smile - 0.55ml" +\n'
              '  "900 RON" → name="Lip filler Juvederm Ultra Smile 0.55ml",\n'
              '  price_min=900, currency=RON\n'
              '- "Botox Azalure - 1 Zonă" + "800 RON" →\n'
              '  name="Botox Azalure 1 zone", price_min=800\n'
              '- "Sculptra - Acid Polilactic (1 zonă)" + "2500 RON" →\n'
              '  name="Sculptra 1 zone", price_min=2500\n'
              '- Keep brand names: Juvederm/Restylane/Dysport/Sculptra\n'
              '- Keep ml/zone variants in the name for clarity\n'
              '- NEVER merge variants into one procedure\n'
              '\nDUAL CURRENCY FORMAT — CRITICAL:\n'
              'Romanian clinic pages show prices like this:\n'
              'EXAMPLE TEXT YOU WILL RECEIVE:\n'
              '"Fast botox o zonă   200 € (1000 lei)"\n'
              '"Sculptra 1 fiolă   650 € (3250 lei)"\n'
              '"Implant mamar   de la 7000€ (35000 lei)"\n'
              '"Injectare acid hialuronic   0.5 ml 275€ (1375 lei) 1 ml 400€ (2000 lei)"\n'
              '"HydraFacial   150€ (750 lei)"\n'
              '"Laser CO2   de la 400€ (2000 lei)"\n'
              'HOW TO PARSE:\n'
              '- "200 € (1000 lei)" → price_min=200, price_max=200, currency=EUR, price_label="€200"\n'
              '- "650 € (3250 lei)" → price_min=650, currency=EUR\n'
              '- "de la 7000€ (35000 lei)" → price_min=7000, price_max=0, currency=EUR\n'
              '- "de la 400€ (2000 lei)" → price_min=400, currency=EUR\n'
              '- "De la 200 € / zonă" → price_min=200, currency=EUR\n'
              '- "De la 5500 €" → price_min=5500, currency=EUR\n'
              '- "1500 – 1800 €" → price_min=1500, price_max=1800, EUR\n'
              '- "365 €" → price_min=365, currency=EUR\n'
              '- "250 €" → price_min=250, currency=EUR\n'
              '- "110 € / Fir" → price_min=110, currency=EUR\n'
              '- "500 LEI" → price_min=500, currency=RON\n'
              '- "1500 LEI" → price_min=1500, currency=RON\n'
              'RULE: "LEI" and "lei" = RON. "€" and "euro" = EUR.\n'
              'NEVER convert EUR to RON or RON to EUR.\n'
              'Return the price EXACTLY as shown on the page.\n'
              '- "0.5 ml 275€ (1375 lei) 1 ml 400€ (2000 lei)" →\n'
              '  TWO procedures: one at 275 EUR, one at 400 EUR\n'
              'RULE: The number BEFORE "€" is the price. \n'
              'The number in (brackets) is RON equivalent — IGNORE IT.\n'
              'NEVER return price_min=0 when you see "X € (Y lei)".\n'
              'price_label format: "€200" or "€200–400" or "from €400"\n'
              '\nMULTIPLE VARIANTS ON ONE LINE:\n'
              'When a line has multiple sizes/doses with prices:\n'
              '"0.5 ml 275€  1 ml 400€" → create TWO procedures:\n'
              '  1. "Hyaluronic acid filler 0.5ml" price=275\n'
              '  2. "Hyaluronic acid filler 1ml" price=400\n'
              '"1ml 300€  2ml 550€" → create TWO procedures\n'
              '\nTABLE FORMAT:\n'
              'Some pages use HTML tables with treatment | price columns.\n'
              'The stripped text will look like:\n'
              '"Treatment name   price€ (RON lei)"\n'
              'Extract each table row as one procedure.\n'
              'If a row has no price (empty second column), skip it.'
              '\nNUMBERED LIST FORMAT (e.g. raduionescu.doctor):\n'
              'Some pages list treatments as numbered lists:\n'
              '"1. Tratament Vistabel Palpebral: 275 euro"\n'
              '"2. Tratament Juvederm: 650 euro"\n'
              'Rules:\n'
              '- Number at start = list index, NOT price\n'
              '- Text after number = treatment name\n'
              '- Number after colon (:) = price\n'
              '- "euro" at end = EUR currency\n'
              '- Extract EVERY numbered item as separate procedure\n'
              '\nRANGE WITH "între" FORMAT:\n'
              '"Augmentare mamară: între 8100–9300 euro"\n'
              '"Mastopexie: între 8400–9900 euro"\n'
              '"Schimbare implant: între 8000-10900 euro"\n'
              'Rules:\n'
              '- "între X–Y" or "între X-Y" = price range\n'
              '- price_min = X, price_max = Y\n'
              '- "euro" = EUR currency\n'
              '- Translate Romanian surgery names to English:\n'
              '  "Augmentare mamară" → "Breast augmentation"\n'
              '  "Mastopexie" → "Breast lift"\n'
              '  "Schimbare implant" → "Implant exchange"\n'
              '  "Explantare implant" → "Implant removal"\n'
              '  "Reconstrucție sân" → "Breast reconstruction"\n'
              '  "Tratament Vistabel" → "Botox"\n'
              '  "Tratament Juvederm" → "Filler"\n'
              '  "Consult medical" → "Medical consultation"\n'
              '\nCOLON PRICE FORMAT:\n'
              '"Treatment name: PRICE euro"\n'
              '"Treatment name: PRICE lei"\n'
              'The number immediately before "euro" or "lei" = price.\n'
              'Extract these even when embedded in paragraphs.\n'
              '\nCRITICAL — NO INVENTING:\n'
              'ONLY extract procedures that appear in the '
              'text below. NEVER add procedures not present.\n'
              'If the text only mentions fillers and botox, '
              'return ONLY fillers and botox.\n'
              'Navigation menu links count as real procedures '
              '— extract them even without prices.\n'
              'price_min=0 is correct when no price is listed.',
        },
        {
          'role': 'user',
          'content':
              'Clinic: "$clinicName" · $city · $effectiveCurrency\n\n$trimmed\n\n'
              'List every treatment individually by specific name. '
              'If this text is from a shop/product page, extract ALL products with their prices.'
              '\n\nIMPORTANT: This page may have prices in format '
              '"X € (Y lei)" where X is EUR and Y is RON equivalent. '
              'The EUR number (before €) is ALWAYS the price_min. '
              'Extract price_min for EVERY procedure that has a price. '
              'price_min must NEVER be 0 if you see a € or lei amount '
              'next to the treatment name.'
              '\n\nNOTE: If prices on this page are in € (EUR), '
              'use currency=EUR and price_label like "€650" or "€200–400". '
              'Do NOT convert EUR to RON. Keep original currency.',
        },
      ],
    };
    final res = await _client.post(
      uri,
      headers: {
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(body),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      _logOpenAiHttpFailure(res.statusCode, res.body);
      return const [];
    }
    final decoded = jsonDecode(res.body) as Map<String, Object?>;
    final choices = (decoded['choices'] as List?) ?? const [];
    final first = choices.isNotEmpty
        ? (choices.first as Map)
        : const <String, Object?>{};
    final msg = (first['message'] as Map?) ?? const {};
    final content = _stripCodeFences((msg['content'] as String?)?.trim() ?? '');
    if (content.isEmpty) return const [];
    try {
      final jsonObj = jsonDecode(content) as Map<String, Object?>;
      final rawProc = (jsonObj['procedures'] as List?) ?? const [];
      // ignore: avoid_print
      print('[GP] Extracted ${rawProc.length} procedures from text');
      // ignore: avoid_print
      print('[GP] Text length: ${trimmed.length}');
      return rawProc
          .whereType<Map>()
          .map(
            (m) => OpenAIProfileProcedureRow.fromJson(
              m.cast<String, Object?>(),
              currencyHint: effectiveCurrency,
            ),
          )
          .where((p) => p.name.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  /// Streams procedures one-by-one from OpenAI as the response is produced.
  /// The model emits a single JSON object `{"procedures":[ {...}, {...}, ... ]}`;
  /// we skip past the array opener once, then balance-match each inner object
  /// (string-aware so `}` inside a string value doesn't fool the walk) and
  /// yield it the moment its closing brace arrives.
  Stream<OpenAIProfileProcedureRow> _extractProceduresStream({
    required String text,
    required String clinicName,
    required String city,
  }) async* {
    final trimmed = text.length > 30000 ? text.substring(0, 30000) : text;
    final currency = _inferCurrencyFromCity(city);
    final effectiveCurrency = _effectiveCurrencyFromPageText(trimmed, currency);
    final uri = Uri.parse('https://api.openai.com/v1/chat/completions');
    final body = <String, Object?>{
      'model': model,
      ..._temperatureParam(model, 0.1),
      ..._tokenLimitParam(model, 8000),
      'stream': true,
      'messages': [
        {
          'role': 'system',
          'content':
              'Extract every individual aesthetic treatment that appears '
              'in the scraped text ONLY. SPECIFIC names required.\n'
              '❌ NEVER output a treatment not written on the page '
              '(no HIFU / Hydrafacial / laser / generic filler unless named '
              'explicitly in the text).\n'
              '❌ Generic buckets: "Injectable treatments", "Dermal fillers"\n'
              'Translate Romanian names to English only when they match a row.\n\n'
              'CRITICAL OUTPUT FORMAT:\n'
              'Output a JSON array where EACH PROCEDURE is on '
              'its OWN LINE, one object per line:\n'
              '{"procedures":[\n'
              '{"name":"Botox forehead","category":"Injectables","icon_kind":"inject","price_min":545,"price_max":800,"price_label":"545–800 RON","detail":"","tags":[],"featured":false},\n'
              '{"name":"Lip filler","category":"Injectables","icon_kind":"inject","price_min":659,"price_max":1330,"price_label":"659–1330 RON","detail":"","tags":[],"featured":false},\n'
              '... one per line ...\n'
              ']}\n\n'
              'Each procedure MUST be on its own line ending with ,\n'
              'This allows progressive parsing as stream arrives.\n\n'
              'WOOCOMMERCE PRICE EXTRACTION:\n'
              '- Sale price = price_min, original = price_max\n'
              '- "1.071 lei" → 1071 RON\n'
              'DUAL CURRENCY FORMAT:\n'
              '- "275€ (1375 lei)" → price_min=275, currency=EUR\n'
              '- "de la 400€ (2000 lei)" → price_min=400, currency=EUR\n- "de la 200€ (1000 lei)" → price_min=200, currency=EUR\n- "de la 150€ (750 lei)" → price_min=150, currency=EUR\n- RULE: "de la X€" means price_min=X, price_max=0\n- The number in (brackets) is RON — IGNORE IT\n- price_label: "from €400" or "€400"\n- NEVER return price_min=0 for "de la X€" lines\n'
              'PLAIN TEXT LIST:\n'
              '- "Baby botox 3 zone 1050 RON" → price=1050\n'
              'GLOBAL RULES:\n'
              '- price_min/max = plain integers\n'
              '- NEVER return 0 if price exists on page\n'
              'ROMANIAN PROMO TABLES:\n'
              '- Use the promotional/bold price when both strikethrough '
              '"PREȚ NORMAL" and "PREȚ PROMOȚIONAL" appear — pick the lower '
              'promo number as price_min when it is the active offer.\n'
              'CRITICAL — NO INVENTING:\n'
              'ONLY extract procedures named in the text below. Every row '
              'in a TRATAMENTE / treatment table is one procedure.',
        },
        {
          'role': 'user',
          'content':
              'Clinic: "$clinicName" · $city · $effectiveCurrency\n\n'
              '$trimmed\n\n'
              'Extract ALL treatments that appear in this text only. '
              'Output each procedure on its own line in the JSON array.',
        },
      ],
    };

    final request = http.Request('POST', uri)
      ..headers['Authorization'] = 'Bearer $_apiKey'
      ..headers['Content-Type'] = 'application/json'
      ..headers['Accept'] = 'text/event-stream'
      ..body = jsonEncode(body);

    final streamed = await _client.send(request);
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      final errBody = await streamed.stream.bytesToString();
      _logOpenAiHttpFailure(streamed.statusCode, errBody);
      return;
    }

    final accumulated = StringBuffer();
    var foundArrayStart = false;
    var cursor = 0;

    await for (final line
        in streamed.stream
            .transform(const Utf8Decoder())
            .transform(const LineSplitter())) {
      if (!line.startsWith('data: ')) continue;
      final data = line.substring(6).trim();
      if (data == '[DONE]') break;
      if (data.isEmpty) continue;

      String chunkText;
      try {
        final json = jsonDecode(data) as Map<String, Object?>;
        final choices = (json['choices'] as List?) ?? const [];
        if (choices.isEmpty) continue;
        final delta = (choices.first as Map)['delta'] as Map?;
        chunkText = (delta?['content'] as String?) ?? '';
      } catch (_) {
        continue;
      }
      if (chunkText.isEmpty) continue;

      accumulated.write(chunkText);
      var working = accumulated.toString();

      // One-time: discard everything up to and including the array opener `[`
      // so the cursor lands inside `[ {...}, {...}, ... ]`.
      if (!foundArrayStart) {
        final bracket = working.indexOf('[');
        if (bracket < 0) continue;
        working = working.substring(bracket + 1);
        accumulated
          ..clear()
          ..write(working);
        foundArrayStart = true;
        cursor = 0;
      }

      // Yield as many complete inner objects as the buffer allows.
      while (true) {
        final objStart = working.indexOf('{', cursor);
        if (objStart < 0) {
          // No more candidates — compact and wait for more data.
          if (cursor > 0) {
            working = working.substring(cursor);
            accumulated
              ..clear()
              ..write(working);
            cursor = 0;
          }
          break;
        }
        final objEnd = _findJsonObjectEnd(working, objStart);
        if (objEnd == null) {
          // Incomplete — compact up to objStart and wait.
          if (objStart > 0) {
            working = working.substring(objStart);
            accumulated
              ..clear()
              ..write(working);
            cursor = 0;
          }
          break;
        }
        final slice = working.substring(objStart, objEnd + 1);
        cursor = objEnd + 1;
        try {
          final m = jsonDecode(slice) as Map<String, Object?>;
          final row = OpenAIProfileProcedureRow.fromJson(
            m,
            currencyHint: effectiveCurrency,
          );
          if (row.name.isNotEmpty) yield row;
        } catch (_) {
          // Malformed object — skip past it and keep going.
        }
      }
    }
  }

  /// Walks `s` from `start` (which must point at `{`), respecting JSON string
  /// literals so braces inside `"foo}bar"` are ignored. Returns the index of
  /// the matching closing `}`, or `null` if the buffer is not yet complete.
  int? _findJsonObjectEnd(String s, int start) {
    var depth = 0;
    var inStr = false;
    var esc = false;
    for (var i = start; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (esc) {
        esc = false;
        continue;
      }
      if (inStr) {
        if (c == 0x5C) {
          esc = true; // backslash
        } else if (c == 0x22) {
          inStr = false; // closing quote
        }
        continue;
      }
      if (c == 0x22) {
        inStr = true;
        continue;
      }
      if (c == 0x7B) {
        depth++; // {
      } else if (c == 0x7D) {
        depth--; // }
        if (depth == 0) return i;
      }
    }
    return null;
  }

  /// Public wrapper so screens can stream procedures without exposing the
  /// underlying private method.
  Stream<OpenAIProfileProcedureRow> extractProceduresStream({
    required String text,
    required String clinicName,
    required String city,
  }) =>
      _extractProceduresStream(text: text, clinicName: clinicName, city: city);

  /// Public wrapper around the HTML fetch-and-strip helper.
  Future<String> fetchPageText(String url) => _fetchPageText(url);

  OpenAIClinicProfilePage _buildPageFromProcedures({
    required String clinicName,
    required String city,
    required String websiteUrl,
    required List<OpenAIProfileProcedureRow> procedures,
    required String currency,
  }) {
    final cats = <String>{};
    double pMin = 0, pMax = 0;
    for (final p in procedures) {
      if (p.category.isNotEmpty) cats.add(p.category);
      if (p.priceMin > 0 && (pMin == 0 || p.priceMin < pMin)) pMin = p.priceMin;
      if (p.priceMax > 0 && p.priceMax > pMax) pMax = p.priceMax;
    }
    return OpenAIClinicProfilePage(
      clinicName: clinicName,
      city: city,
      clinicTypeLabel: 'Clinic',
      area: '',
      distanceMi: 0,
      lat: 0,
      lng: 0,
      rating: 0,
      reviewsTotal: 0,
      googlePlaceUrl: '',
      procedureCount: procedures.length,
      doctorCount: 0,
      isVerified: false,
      isDoctorLed: false,
      heroTags: const [],
      about: '',
      currency: currency,
      priceRangeLabel: '',
      priceMin: pMin,
      priceMax: pMax,
      categories: cats.toList(growable: false),
      procedures: procedures,
      doctors: const [],
      contact: OpenAIClinicContact(
        address: '',
        phone: '',
        website: websiteUrl,
        instagram: '',
        openingHours: '',
        isOpenNow: false,
      ),
      reviews: const [],
    );
  }

  OpenAIClinicProfilePage _emptyPage(String clinicName, String city) {
    return OpenAIClinicProfilePage(
      clinicName: clinicName,
      city: city,
      clinicTypeLabel: 'Clinic',
      area: '',
      distanceMi: 0,
      lat: 0,
      lng: 0,
      rating: 0,
      reviewsTotal: 0,
      googlePlaceUrl: '',
      procedureCount: 0,
      doctorCount: 0,
      isVerified: false,
      isDoctorLed: false,
      heroTags: const [],
      about: '',
      currency: _inferCurrencyFromCity(city),
      priceRangeLabel: '',
      priceMin: 0,
      priceMax: 0,
      categories: const [],
      procedures: const [],
      doctors: const [],
      contact: const OpenAIClinicContact(
        address: '',
        phone: '',
        website: '',
        instagram: '',
        openingHours: '',
        isOpenNow: false,
      ),
      reviews: const [],
    );
  }

  /// Web-search trending aesthetic procedures via gpt-5.6-terra (cached per month).
  Future<List<TrendingProcedure>> fetchTrendingProcedures({
    required String city,
    required String countryCode,
  }) {
    final now = DateTime.now();
    final cacheKey =
        'trending|v3|${city.trim().toLowerCase()}|${now.year}|${now.month}';
    return _memoize<List<TrendingProcedure>>(
      cacheKey,
      () => _fetchTrendingUncached(city: city, countryCode: countryCode),
    );
  }

  /// Public wrapper — lets UI sanitize procedure names
  /// from cached trending results.
  String sanitizeProcedureName(String raw) => _sanitizeProcedureName(raw);

  /// Strips brand names, qualifiers, and over-specific
  /// suffixes from AI-generated procedure names, mapping
  /// them to short canonical English names.
  /// Works for any language — Romanian, Turkish, Spanish,
  /// French, Italian, German, Arabic, etc.
  String _sanitizeProcedureName(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return s;

    // Step 1: remove parentheticals (brand names, subtitles)
    // "Botox (Allergan)" → "Botox"
    // "Terapia Vampir (PRP Saga)" → "Terapia Vampir"
    s = s.replaceAll(RegExp(r'\s*\([^)]*\)'), '').trim();

    // Step 2: remove after dash/colon separators
    // "PRP – Vampire Facial" → "PRP"
    s = s.replaceAll(RegExp(r'\s*[-–:]\s+.*$'), '').trim();

    // Step 3: remove qualifier phrases in any language
    // "Lipoliză pentru contur" → "Lipoliză"
    // "Laser for hair removal" → "Laser"
    // "Botox con ácido" → "Botox"
    const qualifierWords = [
      'pentru', 'pentru a', // Romanian: "for"
      'pentru contur', 'pentru corp', 'pentru față',
      'cu acid', 'cu prp', 'cu laser',
      ' for ', // English
      ' con ', // Spanish/Italian
      ' avec ', // French
      ' mit ', // German
      ' ile ', // Turkish
      ' pour ', // French
      ' per ', // Italian
      ' para ', // Spanish/Portuguese
      ' با ', // Arabic/Farsi
    ];
    for (final q in qualifierWords) {
      final idx = s.toLowerCase().indexOf(q);
      if (idx > 3) {
        // must have at least 3 chars before qualifier
        s = s.substring(0, idx).trim();
        break;
      }
    }

    // Step 4: strip generic medical suffixes
    // "Profhilo Injections" → "Profhilo"
    // "PRP Treatment" → "PRP"
    final suffixPattern = RegExp(
      r'\s+(injections?|injection|treatments?|therapy|procedure|'
      r'sessions?|injectabil[eă]?|tratament[e]?|terapie|'
      r'procedura|şedinta|sedinta|séance|sitzung|seans|'
      r'inyección|inyecciones|traitement|trattamento|'
      r'behandlung|tedavi|علاج|درمان)$',
      caseSensitive: false,
    );
    s = s.replaceAll(suffixPattern, '').trim();

    // Step 5: canonical map — covers all major languages
    // Key = substring (lowercase), Value = canonical English name
    // Ordered from most specific to least specific
    final canonicalMap = <String, String>{
      // ── PRP / Platelet ──────────────────────────────────────
      'platelet rich': 'PRP therapy',
      'platelet-rich': 'PRP therapy',
      'vampire facial': 'PRP therapy',
      'vampire': 'PRP therapy',
      'vampir': 'PRP therapy', // RO/TR/DE
      'terapia vampir': 'PRP therapy',
      'plasma bogata': 'PRP therapy', // RO
      'plasmă': 'PRP therapy', // RO
      'plasma rica': 'PRP therapy', // ES/PT
      'plasma riche': 'PRP therapy', // FR
      'plasmareich': 'PRP therapy', // DE
      'trombocite': 'PRP therapy', // RO
      'trombocit': 'PRP therapy', // TR
      // ── Lip filler ──────────────────────────────────────────
      'lip filler': 'Lip filler',
      'lip augmentation': 'Lip filler',
      'lip enhancement': 'Lip filler',
      'augmentare buze': 'Lip filler', // RO
      'marire buze': 'Lip filler', // RO
      'mărire buze': 'Lip filler', // RO
      'buze': 'Lip filler', // RO (catches all lip variants)
      'relleno labios': 'Lip filler', // ES
      'rellenos labios': 'Lip filler', // ES
      'injection lèvres': 'Lip filler', // FR
      'augmentation lèvres': 'Lip filler', // FR
      'riempimento labbra': 'Lip filler', // IT
      'lippen': 'Lip filler', // DE
      'dudak dolgusu': 'Lip filler', // TR
      'حقن الشفاه': 'Lip filler', // AR
      'شفاه': 'Lip filler', // AR
      'dudak': 'Lip filler', // TR
      // ── Botox ───────────────────────────────────────────────
      'botulinum': 'Botox',
      'botulínica': 'Botox', // ES/PT
      'botulinique': 'Botox', // FR
      'botulinica': 'Botox', // RO/IT
      'botulinică': 'Botox', // RO
      'toxina botulinica': 'Botox', // RO
      'toxină botulinică': 'Botox', // RO
      'anti-wrinkle': 'Botox',
      'antirughe': 'Botox', // IT
      'antiride': 'Botox', // FR
      'anti-rid': 'Botox', // RO
      'antirid': 'Botox', // RO
      'botoks': 'Botox', // TR
      'بوتوكس': 'Botox', // AR
      // ── Laser hair removal ──────────────────────────────────
      'laser hair': 'Laser hair removal',
      'hair removal': 'Laser hair removal',
      'epilare': 'Laser hair removal', // RO
      'depilación laser': 'Laser hair removal', // ES
      'dépilation laser': 'Laser hair removal', // FR
      'epilazione laser': 'Laser hair removal', // IT
      'lazer epilasyon': 'Laser hair removal', // TR
      'haarentfernung': 'Laser hair removal', // DE
      'إزالة الشعر': 'Laser hair removal', // AR
      // ── HIFU / Lifting ──────────────────────────────────────
      'ultraformer': 'HIFU',
      'ultherapy': 'HIFU',
      'ulthera': 'HIFU',
      'lifting hifu': 'HIFU',
      'hifu facial': 'HIFU',
      'focused ultrasound': 'HIFU',

      // ── Thread lift ─────────────────────────────────────────
      'thread lift': 'Thread lift',
      'thread face': 'Thread lift',
      'pdo thread': 'Thread lift',
      'fire tensoare': 'Thread lift', // RO
      'fire pdo': 'Thread lift', // RO
      'fir tensor': 'Thread lift', // RO
      'fil tenseur': 'Thread lift', // FR
      'hilo tensor': 'Thread lift', // ES
      'filo': 'Thread lift', // IT
      'iplik': 'Thread lift', // TR
      'خيوط': 'Thread lift', // AR
      // ── Polynucleotides ─────────────────────────────────────
      'polynucleotide': 'Polynucleotides',
      'polinucleotide': 'Polynucleotides', // RO
      'polinucleotid': 'Polynucleotides', // RO
      'pdrn': 'Polynucleotides',
      'nucleofill': 'Polynucleotides',
      'rejuran': 'Polynucleotides',
      'juvelook': 'Polynucleotides',
      'ameela': 'Polynucleotides',

      // ── Mesotherapy ─────────────────────────────────────────
      'mesotherapy': 'Mesotherapy',
      'mezoterapie': 'Mesotherapy', // RO
      'mésothérapie': 'Mesotherapy', // FR
      'mesoterapia': 'Mesotherapy', // ES/IT
      'mezoterapi': 'Mesotherapy', // TR
      // ── Microneedling ───────────────────────────────────────
      'microneedling': 'Microneedling',
      'micro-needling': 'Microneedling',
      'dermapen': 'Microneedling',
      'skinpen': 'Microneedling',
      'collagen induction': 'Microneedling',

      // ── Chemical peel ───────────────────────────────────────
      'chemical peel': 'Chemical peel',
      'peeling chimic': 'Chemical peel', // RO
      'peeling chimique': 'Chemical peel', // FR
      'peeling quimico': 'Chemical peel', // ES
      'peeling chimico': 'Chemical peel', // IT
      'peeling': 'Chemical peel', // universal
      'peel': 'Chemical peel',

      // ── Biostimulators ──────────────────────────────────────
      'profhilo': 'Profhilo',
      'biostimulator': 'Biostimulators',
      'biostimulatoare': 'Biostimulators', // RO
      'biostimulant': 'Biostimulators',
      'sculptra': 'Sculptra',
      'radiesse': 'Radiesse',
      'belotero': 'Belotero',

      // ── Body contouring / lipolysis ─────────────────────────
      'injectable lipolysis': 'Injectable lipolysis',
      'lipoliză': 'Injectable lipolysis', // RO
      'lipoliza': 'Injectable lipolysis', // RO
      'aqualyx': 'Injectable lipolysis',
      'kybella': 'Injectable lipolysis',
      'fat dissolving': 'Injectable lipolysis',
      'body contouring': 'Body contouring',
      'contur corporal': 'Body contouring', // RO
      'modelare corporala': 'Body contouring', // RO
      'liposculpture': 'Body contouring',
      'cryolipolysis': 'Cryolipolysis',
      'coolsculpting': 'Cryolipolysis',
      'criolipoliza': 'Cryolipolysis', // RO
      // ── Morpheus8 / RF ──────────────────────────────────────
      'morpheus': 'Morpheus8',
      'rf microneedling': 'Morpheus8',
      'radiofrequency microneedling': 'Morpheus8',
      'radiofrecventa': 'Radiofrequency', // RO
      'radiofrecvență': 'Radiofrequency', // RO
      'radiofrequency': 'Radiofrequency',
      'radiofrequenza': 'Radiofrequency', // IT
      'radiofrecuencia': 'Radiofrequency', // ES
      // ── Skin boosters ───────────────────────────────────────
      'skin booster': 'Skin booster',
      'skinbooster': 'Skin booster',
      'aquagold': 'Skin booster',
      'volite': 'Skin booster',
      'restylane skin': 'Skin booster',

      // ── Hair transplant ─────────────────────────────────────
      'hair transplant': 'Hair transplant',
      'fue hair': 'Hair transplant',
      'transplant par': 'Hair transplant', // RO
      'transplant păr': 'Hair transplant', // RO
      'saç ekimi': 'Hair transplant', // TR
      'زراعة الشعر': 'Hair transplant', // AR
      // ── Rhinoplasty ─────────────────────────────────────────
      'rhinoplasty': 'Rhinoplasty',
      'nose job': 'Rhinoplasty',
      'rinoplastie': 'Rhinoplasty', // RO
      'rinoplastia': 'Rhinoplasty', // ES/IT
      'rhinoplastie': 'Rhinoplasty', // FR
      'burun': 'Rhinoplasty', // TR
      'تجميل الأنف': 'Rhinoplasty', // AR
    };

    final lower = s.toLowerCase();
    for (final entry in canonicalMap.entries) {
      if (lower.contains(entry.key)) {
        return entry.value;
      }
    }

    // Step 6: if still long (>25 chars), take only first
    // 2-3 words — likely still a long description
    final words = s.split(RegExp(r'\s+'));
    if (s.length > 25 && words.length > 3) {
      s = words.take(2).join(' ');
    }

    // Step 7: capitalize first letter
    if (s.isNotEmpty) {
      s = s[0].toUpperCase() + s.substring(1);
    }

    return s;
  }

  Future<List<TrendingProcedure>> _fetchTrendingUncached({
    required String city,
    required String countryCode,
  }) async {
    final m = DateTime.now().month;
    final y = DateTime.now().year;
    final cc = countryCode.trim().toUpperCase();
    final systemPrompt =
        'You are a market researcher for aesthetic medicine.\n'
        'Search Google Trends, beauty industry reports, and '
        'aesthetic clinic websites to find the most searched '
        'and trending aesthetic procedures RIGHT NOW.\n\n'
        'Return ONLY valid JSON — no markdown:\n'
        '{"procedures":['
        '{"name":string,"name_local":string,"category":string,"icon_kind":string,'
        '"badge":string,"trend_direction":string,"why_trending":string}'
        ']}\n\n'
        'RULES:\n'
        '- ALL string fields MUST be in English (name, name_local, '
        'category, badge, why_trending) — never Romanian or other languages\n'
        '- "name" field: SHORT canonical English name only, '
        'max 3 words (e.g. "Lip filler", "PRP therapy", "HIFU", '
        '"Polynucleotides"). NEVER include brand names, '
        'qualifiers, or "for X" descriptions in the name field\n'
        '- "name_local" field: same English name as "name" '
        '(do not translate)\n'
        '- "category" field: English bucket only '
        '(Injectables, Skin, Laser, Hair Removal, Surgery, Lifting)\n'
        '- "why_trending" field: one short English sentence\n'
        '- WRONG: "Mărire buze", "Injectabile", "Epilare laser"\n'
        '- RIGHT: "Lip filler", "Injectables", "Laser hair removal"\n'
        '- Return exactly 10 procedures\n'
        '- Order by current popularity (most searched first)\n'
        '- Use REAL current trends, not generic lists\n'
        '- Consider seasonal factors (current month: $m/$y)\n'
        '- Include mix of: injectables, skin, laser, surgery\n'
        '- Focus on what real patients are searching for NOW\n'
        '- For Romania/Eastern Europe: include local trends '
        'like polynucleotides, biostimulators, Profhilo '
        'which are huge there but less known globally\n'
        '- For UK: Lip filler, anti-wrinkle, Morpheus8\n'
        '- For Turkey: hair transplant, rhinoplasty, BBL\n'
        '- badge values: "Trending"=currently viral, '
        '"Rising"=growing fast, "Popular"=consistently high, '
        '"Seasonal"=peak season now, "New"=newly available';

    final userMsg =
        'Country: $cc | City: $city\n'
        'Month: $m/$y\n\n'
        'Search for:\n'
        '1. Google Trends for aesthetic procedures in $cc\n'
        '2. What aesthetic clinics in $city are promoting now\n'
        '3. Most booked treatments on platforms like Treatwell, '
        'Fresha, Booksy in $cc\n'
        '4. Beauty influencer trends in $cc right now\n\n'
        'Return the top 10 trending aesthetic procedures.\n'
        'Return JSON only.';

    try {
      final oaSearchJson = await _queueSearchPreview(
        () => _chatCompletionSearchPreviewJson(
          messages: [
            {'role': 'system', 'content': systemPrompt},
            {'role': 'user', 'content': userMsg},
          ],
          maxTokens: 3000,
        ),
      );
      final content = oaSearchJson;

      final json = jsonDecode(content) as Map<String, dynamic>;
      final raw = (json['procedures'] as List?) ?? [];

      final procedures = raw
          .whereType<Map>()
          .map((e) => TrendingProcedure.fromJson(e.cast<String, Object?>()))
          .where((p) => p.name.isNotEmpty)
          .map((p) => p.copyWith(name: _sanitizeProcedureName(p.name)))
          .where((p) => p.name.isNotEmpty)
          .take(10)
          .toList(growable: false);

      if (procedures.isEmpty) return _fallbackTrending(city: city);
      return procedures;
    } catch (_) {
      return _fallbackTrending(city: city);
    }
  }

  /// Returns the static fallback trending procedures instantly.
  /// Used to populate the UI before the real AI response arrives.
  List<TrendingProcedure> getFallbackTrending({String city = ''}) {
    final list = _fallbackTrending(city: city);
    return list
        .map((p) => p.copyWith(name: _sanitizeProcedureName(p.name)))
        .toList();
  }

  List<TrendingProcedure> _fallbackTrending({String city = ''}) {
    final c = city.toLowerCase();
    final isRomania =
        c.contains('bucur') ||
        c.contains('cluj') ||
        c.contains('timi') ||
        c.contains('iasi') ||
        c.contains('brasov');
    final isUK = c.contains('london') || c.contains('manchester');

    if (isRomania) {
      return const [
        TrendingProcedure(
          name: 'Botox',
          nameLocal: 'Botox',
          category: 'Injectables',
          iconKind: 'inject',
          badge: 'Popular',
          trendDirection: 'stable',
          whyTrending: 'Most searched aesthetic treatment',
        ),
        TrendingProcedure(
          name: 'Lip filler',
          nameLocal: 'Lip filler',
          category: 'Injectables',
          iconKind: 'inject',
          badge: 'Trending',
          trendDirection: 'up',
          whyTrending: 'Fast-growing booking trend',
        ),
        TrendingProcedure(
          name: 'PRP therapy',
          nameLocal: 'PRP therapy',
          category: 'Regenerative',
          iconKind: 'drop',
          badge: 'Rising',
          trendDirection: 'up',
          whyTrending: 'Popular in Bucharest clinics',
        ),
        TrendingProcedure(
          name: 'Polynucleotides',
          nameLocal: 'Polynucleotides',
          category: 'Biostimulators',
          iconKind: 'inject',
          badge: 'Trending',
          trendDirection: 'up',
          whyTrending: 'Very popular in Romania',
        ),
        TrendingProcedure(
          name: 'HIFU',
          nameLocal: 'HIFU',
          category: 'Lifting',
          iconKind: 'zap',
          badge: 'Popular',
          trendDirection: 'stable',
          whyTrending: 'Non-surgical lift alternative',
        ),
        TrendingProcedure(
          name: 'Laser hair removal',
          nameLocal: 'Laser hair removal',
          category: 'Laser',
          iconKind: 'zap',
          badge: 'Popular',
          trendDirection: 'stable',
          whyTrending: 'Standard service in most clinics',
        ),
        TrendingProcedure(
          name: 'Microneedling',
          nameLocal: 'Microneedling',
          category: 'Skin',
          iconKind: 'activity',
          badge: 'Rising',
          trendDirection: 'up',
          whyTrending: 'Rising patient demand',
        ),
        TrendingProcedure(
          name: 'Profhilo',
          nameLocal: 'Profhilo',
          category: 'Biostimulators',
          iconKind: 'inject',
          badge: 'New',
          trendDirection: 'up',
          whyTrending: 'Popular newer skin treatment',
        ),
        TrendingProcedure(
          name: 'Mesotherapy',
          nameLocal: 'Mesotherapy',
          category: 'Skin',
          iconKind: 'inject',
          badge: 'Popular',
          trendDirection: 'stable',
          whyTrending: 'Classic effective treatment',
        ),
        TrendingProcedure(
          name: 'Thread lift',
          nameLocal: 'Thread lift',
          category: 'Lifting',
          iconKind: 'activity',
          badge: 'Rising',
          trendDirection: 'up',
          whyTrending: 'Lift without surgery',
        ),
      ];
    }

    if (isUK) {
      return const [
        TrendingProcedure(
          name: 'Lip filler',
          nameLocal: 'Lip filler',
          category: 'Injectables',
          iconKind: 'inject',
          badge: 'Popular',
          trendDirection: 'stable',
          whyTrending: 'Most booked injectable in UK',
        ),
        TrendingProcedure(
          name: 'Botox',
          nameLocal: 'Anti-wrinkle',
          category: 'Injectables',
          iconKind: 'inject',
          badge: 'Popular',
          trendDirection: 'stable',
          whyTrending: 'Top treatment nationwide',
        ),
        TrendingProcedure(
          name: 'Morpheus8',
          nameLocal: 'Morpheus8',
          category: 'RF Microneedling',
          iconKind: 'zap',
          badge: 'Trending',
          trendDirection: 'up',
          whyTrending: 'Celebrity-endorsed treatment',
        ),
        TrendingProcedure(
          name: 'HIFU',
          nameLocal: 'HIFU facelift',
          category: 'Lifting',
          iconKind: 'zap',
          badge: 'Popular',
          trendDirection: 'stable',
          whyTrending: 'Non-surgical facelift',
        ),
        TrendingProcedure(
          name: 'Polynucleotides',
          nameLocal: 'Polynucleotides',
          category: 'Skin boosters',
          iconKind: 'inject',
          badge: 'Rising',
          trendDirection: 'up',
          whyTrending: 'Fast growing skin booster',
        ),
        TrendingProcedure(
          name: 'PRP therapy',
          nameLocal: 'PRP',
          category: 'Regenerative',
          iconKind: 'drop',
          badge: 'Popular',
          trendDirection: 'stable',
          whyTrending: 'Popular hair and skin treatment',
        ),
        TrendingProcedure(
          name: 'Laser hair removal',
          nameLocal: 'Laser hair removal',
          category: 'Laser',
          iconKind: 'zap',
          badge: 'Popular',
          trendDirection: 'stable',
          whyTrending: 'Year-round demand',
        ),
        TrendingProcedure(
          name: 'Chemical peel',
          nameLocal: 'Chemical peel',
          category: 'Peels',
          iconKind: 'activity',
          badge: 'Popular',
          trendDirection: 'stable',
          whyTrending: 'Accessible skin treatment',
        ),
        TrendingProcedure(
          name: 'Microneedling',
          nameLocal: 'Microneedling',
          category: 'Skin',
          iconKind: 'activity',
          badge: 'Rising',
          trendDirection: 'up',
          whyTrending: 'Growing demand',
        ),
        TrendingProcedure(
          name: 'Profhilo',
          nameLocal: 'Profhilo',
          category: 'Skin boosters',
          iconKind: 'inject',
          badge: 'Trending',
          trendDirection: 'up',
          whyTrending: 'Fastest growing skin booster',
        ),
      ];
    }

    return const [
      TrendingProcedure(
        name: 'Lip filler',
        nameLocal: 'Lip filler',
        category: 'Injectables',
        iconKind: 'inject',
        badge: 'Popular',
        trendDirection: 'stable',
        whyTrending: 'Consistently most searched aesthetic treatment',
      ),
      TrendingProcedure(
        name: 'Botox',
        nameLocal: 'Botox',
        category: 'Injectables',
        iconKind: 'inject',
        badge: 'Popular',
        trendDirection: 'stable',
        whyTrending: 'Most booked anti-wrinkle treatment globally',
      ),
      TrendingProcedure(
        name: 'Profhilo',
        nameLocal: 'Profhilo',
        category: 'Injectables',
        iconKind: 'inject',
        badge: 'Trending',
        trendDirection: 'up',
        whyTrending: 'Biostimulator trend growing fast worldwide',
      ),
      TrendingProcedure(
        name: 'Polynucleotides',
        nameLocal: 'Polynucleotides',
        category: 'Injectables',
        iconKind: 'inject',
        badge: 'Rising',
        trendDirection: 'up',
        whyTrending: 'New generation skin booster gaining popularity',
      ),
      TrendingProcedure(
        name: 'Laser hair removal',
        nameLocal: 'Laser hair removal',
        category: 'Hair Removal',
        iconKind: 'hair',
        badge: 'Seasonal',
        trendDirection: 'up',
        whyTrending: 'Peak season — summer preparation',
      ),
      TrendingProcedure(
        name: 'Hydrafacial',
        nameLocal: 'Hydrafacial',
        category: 'Skin',
        iconKind: 'skin',
        badge: 'Popular',
        trendDirection: 'stable',
        whyTrending: 'Top facial treatment by booking volume',
      ),
      TrendingProcedure(
        name: 'Morpheus8',
        nameLocal: 'Morpheus8',
        category: 'Skin',
        iconKind: 'skin',
        badge: 'Rising',
        trendDirection: 'up',
        whyTrending: 'RF microneedling trending on social media',
      ),
      TrendingProcedure(
        name: 'Sculptra',
        nameLocal: 'Sculptra',
        category: 'Injectables',
        iconKind: 'inject',
        badge: 'Rising',
        trendDirection: 'up',
        whyTrending: 'Collagen stimulator replacing traditional fillers',
      ),
      TrendingProcedure(
        name: 'Thread lift',
        nameLocal: 'Thread lift',
        category: 'Injectables',
        iconKind: 'inject',
        badge: 'Trending',
        trendDirection: 'up',
        whyTrending: 'Non-surgical lift popular among 35-50 age group',
      ),
      TrendingProcedure(
        name: 'Chemical peel',
        nameLocal: 'Chemical peel',
        category: 'Skin',
        iconKind: 'skin',
        badge: 'Seasonal',
        trendDirection: 'stable',
        whyTrending: 'Autumn skin renewal treatments in demand',
      ),
    ];
  }
}

/// Trending aesthetic procedure row from web search (+ fallback).
class TrendingProcedure {
  const TrendingProcedure({
    required this.name,
    required this.nameLocal,
    required this.category,
    required this.iconKind,
    required this.badge,
    required this.trendDirection,
    required this.whyTrending,
  });

  final String name;
  final String nameLocal;
  final String category;
  final String iconKind;
  final String badge;
  final String trendDirection;
  final String whyTrending;

  factory TrendingProcedure.fromJson(Map<String, Object?> json) {
    return TrendingProcedure(
      name: (json['name'] as String?)?.trim() ?? '',
      nameLocal: (json['name_local'] as String?)?.trim() ?? '',
      category: (json['category'] as String?)?.trim() ?? '',
      iconKind: (json['icon_kind'] as String?)?.trim() ?? 'inject',
      badge: (json['badge'] as String?)?.trim() ?? '',
      trendDirection: (json['trend_direction'] as String?)?.trim() ?? 'stable',
      whyTrending: (json['why_trending'] as String?)?.trim() ?? '',
    );
  }

  TrendingProcedure copyWith({String? name}) {
    return TrendingProcedure(
      name: name ?? this.name,
      nameLocal: nameLocal,
      category: category,
      iconKind: iconKind,
      badge: badge,
      trendDirection: trendDirection,
      whyTrending: whyTrending,
    );
  }
}

List<OpenAIProfileProcedureRow> _dedupeProcs(
  List<OpenAIProfileProcedureRow> rows,
) {
  OpenAIProfileProcedureRow pickBetter(
    OpenAIProfileProcedureRow a,
    OpenAIProfileProcedureRow b,
  ) {
    final aHas = a.priceMin > 0 || a.priceMax > 0;
    final bHas = b.priceMin > 0 || b.priceMax > 0;
    if (aHas && !bHas) return a;
    if (bHas && !aHas) return b;
    if (aHas && bHas && a.priceLabel.isEmpty != b.priceLabel.isEmpty) {
      return b.priceLabel.isNotEmpty ? b : a;
    }
    return b;
  }

  final byName = <String, OpenAIProfileProcedureRow>{};
  for (final r in rows) {
    final k = r.name.trim().toLowerCase();
    if (k.isEmpty) continue;
    final prev = byName[k];
    byName[k] = prev == null ? r : pickBetter(prev, r);
  }
  return byName.values.toList(growable: false);
}

String _inferCurrencyFromCity(String city) => CityCurrency.localCode(city);

bool exploreClinicFitsSearchCity(OpenAIClinic c, String city) {
  if (exploreProviderIdentityConflictsWithSearchCity(
    city: city, name: c.name, sourceUrl: c.priceSourceUrl,
    evidence: '${c.priceEvidenceText} ${c.rawProcedureText}',
  )) return false;
  final priceBlob =
      '${c.priceEvidenceText} ${c.rawPriceText} ${c.rawProcedureText} '
      '${c.procedureDetail} ${c.priceSourceUrl}';
  if (exploreTextConflictsWithSearchCity(priceBlob, city)) return false;
  final host = exploreHostFromListing(
    sourceUrl: c.priceSourceUrl,
    area: c.area,
  );
  return exploreListingFitsSearchCity(
    city: city,
    host: host,
    currency: c.currency,
    priceLabel: c.priceLabel,
    procedureText:
        '${c.brand} ${c.rawProcedureText} ${c.name} ${c.priceEvidenceText} '
        '${c.rawPriceText}',
    area: c.area,
    url: c.priceSourceUrl,
  );
}

/// Skip Serp/Places re-discovery only when this pool row is already a
/// showable card for the current city + procedure.
bool exploreDiscoveryShouldSkipPoolVerified(
  OpenAIClinic pooled, {
  required String procedure,
  required String city,
}) {
  return exploreClinicEligibleForVerifiedPool(
    pooled,
    procedure: procedure,
    city: city,
  );
}

/// Keep each clinic's website currency. Clinics in the same city may mix
/// HKD / USD / € — never force one city-wide currency over a published one.
OpenAIClinic _alignClinicCurrencyToCity(OpenAIClinic c, String city) {
  final fromLabel = FilterFx.detectCodeFromLabel(c.priceLabel, fallback: '');
  final clinicCur = c.currency.trim();
  final cityCur = city.trim().isEmpty ? '' : CityCurrency.localCode(city);

  // 1) Literal price-label currency always wins (e.g. "385 EUR" in Sofia).
  //    City default currency is only a soft fill when the page has none.
  if (fromLabel.isNotEmpty) {
    final resolved = CityCurrency.normalizeCode(fromLabel);
    if (resolved.isEmpty) return c;
    if (CityCurrency.matches(clinicCur, resolved)) return c;
    return c.copyWith(currency: resolved, currencyConfirmed: true);
  }

  // 2) Clinic already has an explicit currency field — keep it.
  if (clinicCur.isNotEmpty) {
    final resolved = CityCurrency.normalizeCode(clinicCur);
    if (resolved == clinicCur || resolved.isEmpty) return c;
    return c.copyWith(currency: resolved);
  }

  // 3) Nothing on the clinic — soft-fill known city local only.
  if (cityCur.isEmpty) return c;
  var label = c.priceLabel.trim();
  if (label.isEmpty && c.priceMin > 0) {
    label = _formatPrice(c.priceMin, cityCur);
  } else if (label.isNotEmpty) {
    label = _rewritePriceLabelToCurrency(label, cityCur);
  }
  return c.copyWith(
    priceLabel: label.isNotEmpty ? label : c.priceLabel,
    currency: cityCur,
    currencyConfirmed: false,
  );
}

String _rewritePriceLabelToCurrency(String label, String toCurrency) {
  var t = label;
  // Strip common currency tokens first, then append target.
  t = t.replaceAll(RegExp(r'[€$£₽₺¥₩฿]'), '');
  t = t.replaceAll(
    RegExp(
      r'\b(EUR|USD|GBP|RON|LEI|TRY|AED|RUB|KRW|JPY|HKD|SGD|THB|AUD|CAD|CHF|CNY)\b',
      caseSensitive: false,
    ),
    '',
  );
  t = t.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
  // "from 1,450" → "from 1,450 HKD"
  if (t.isEmpty) return t;
  final cur = toCurrency.trim();
  if (cur.isEmpty) return t;
  if (RegExp(r'(from\s+)?[\d.,]+', caseSensitive: false).hasMatch(t) &&
      !t.contains(cur)) {
    // Keep "from" prefix; put currency after the amount.
    final m = RegExp(r'^(from\s+)?(.+)$', caseSensitive: false).firstMatch(t);
    if (m != null) {
      final from = m.group(1) ?? '';
      final rest = m.group(2)!.trim();
      return '$from$rest $cur'.trim();
    }
  }
  return '$t $cur'.trim();
}

String _stripHtmlContent(String html) {
  var t = html.replaceAll(
    RegExp(r'<script[^>]*>[\s\S]*?</script>', caseSensitive: false),
    ' ',
  );
  t = t.replaceAll(
    RegExp(r'<style[^>]*>[\s\S]*?</style>', caseSensitive: false),
    ' ',
  );
  t = t.replaceAll(RegExp(r'<[^>]+>'), ' ');
  t = t
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");
  t = t.replaceAll(RegExp(r'\s{3,}'), '\n').trim();
  return t;
}

String _readKey() {
  final fromDefine = const String.fromEnvironment('OPENAI_API_KEY').trim();
  if (fromDefine.isNotEmpty) return fromDefine;
  final fromEnv = (dotenv.env['OPENAI_API_KEY'] ?? '').trim();
  return fromEnv;
}

/// Extracts the first balanced `{...}` JSON object from [s]. Returns the
/// original string when it already starts with `{`. Used after web-browsing
/// completions that may wrap JSON in prose.
String _extractFirstJsonObject(String s) {
  final t = s.trim();
  if (t.startsWith('{')) return t;
  final start = t.indexOf('{');
  if (start < 0) return t;
  var depth = 0;
  var inStr = false;
  var esc = false;
  for (var i = start; i < t.length; i++) {
    final ch = t[i];
    if (esc) {
      esc = false;
      continue;
    }
    if (ch == r'\\') {
      esc = true;
      continue;
    }
    if (ch == '"') {
      inStr = !inStr;
      continue;
    }
    if (inStr) continue;
    if (ch == '{') {
      depth++;
    } else if (ch == '}') {
      depth--;
      if (depth == 0) return t.substring(start, i + 1);
    }
  }
  return t.substring(start);
}

/// Fixes truncated AI JSON that dart:convert rejects (e.g. `"lat": 37.`).
String _sanitizeAiJsonText(String raw) {
  var t = raw.trim();
  // Incomplete decimal: `"lat": 37.` / `"lng": 126.` → `37.0` / `126.0`
  t = t.replaceAllMapped(
    RegExp(r'(:\s*-?\d+)\.(?=\s*[,}\]])'),
    (m) => '${m.group(1)}.0',
  );
  // Trailing incomplete number at EOF: `"lat": 37.`
  t = t.replaceAllMapped(
    RegExp(r'(:\s*-?\d+)\.\s*$'),
    (m) => '${m.group(1)}.0',
  );
  t = _escapeRawControlsInJsonStrings(t);
  return t;
}

/// Escapes raw newlines/controls inside JSON strings so Arabic (or any)
/// snippet with an unescaped linebreak cannot fail the whole decode.
String _escapeRawControlsInJsonStrings(String s) {
  final out = StringBuffer();
  var inString = false;
  var escape = false;
  for (var i = 0; i < s.length; i++) {
    final unit = s.codeUnitAt(i);
    final c = s[i];
    if (!inString) {
      if (c == '"') inString = true;
      out.write(c);
      continue;
    }
    if (escape) {
      out.write(c);
      escape = false;
      continue;
    }
    if (c == '\\') {
      out.write(c);
      escape = true;
      continue;
    }
    if (c == '"') {
      inString = false;
      out.write(c);
      continue;
    }
    if (unit == 0x0A || unit == 0x2028 || unit == 0x2029) {
      out.write(r'\n');
      continue;
    }
    if (unit == 0x0D) {
      out.write(r'\r');
      continue;
    }
    if (unit == 0x09) {
      out.write(r'\t');
      continue;
    }
    if (unit < 0x20) continue;
    if (unit >= 0xD800 && unit <= 0xDFFF) continue;
    out.write(c);
  }
  return out.toString();
}

Map<String, dynamic> _decodeAiComparisonJson(String raw) {
  final sanitized = _sanitizeAiJsonText(_extractFirstJsonObject(raw));
  try {
    return jsonDecode(sanitized) as Map<String, dynamic>;
  } on FormatException catch (firstError) {
    // Truncated mid-object — try closing open braces/brackets roughly.
    var repaired = sanitized;
    // Drop a trailing incomplete key/value like `"price_label":`
    repaired = repaired.replaceAll(RegExp(r',\s*"[^"]*"\s*:\s*$'), '');
    repaired = repaired.replaceAll(RegExp(r',\s*"[^"]*"\s*:\s*"[^"]*$'), '');
    final openCurly = '{'.allMatches(repaired).length;
    final closeCurly = '}'.allMatches(repaired).length;
    final openSquare = '['.allMatches(repaired).length;
    final closeSquare = ']'.allMatches(repaired).length;
    if (openSquare > closeSquare) {
      repaired = '$repaired${']' * (openSquare - closeSquare)}';
    }
    if (openCurly > closeCurly) {
      repaired = '$repaired${'}' * (openCurly - closeCurly)}';
    }
    try {
      return jsonDecode(repaired) as Map<String, dynamic>;
    } on FormatException catch (e) {
      debugPrint('[GP] Comparison AI JSON parse failed: $e');
      _logJsonParseContext(sanitized, firstError);
      final clinics = _extractParseableClinicMaps(sanitized);
      debugPrint(
        '[GP] Comparison AI JSON recovered ${clinics.length} clinic '
        'object(s) after parse failure',
      );
      return {'clinics': clinics};
    }
  }
}

void _logJsonParseContext(String json, FormatException e) {
  final offset = e.offset;
  if (offset == null || offset < 0 || offset >= json.length) {
    debugPrint('[GP] JSON fail (no offset): $e');
    return;
  }
  final from = math.max(0, offset - 80);
  final to = math.min(json.length, offset + 80);
  final before = json.substring(0, offset);
  final fields = RegExp(r'"([a-zA-Z_]+)"\s*:').allMatches(before);
  final field = fields.isEmpty ? '?' : fields.last.group(1)!;
  final name =
      RegExp(
        r'"name"\s*:\s*"((?:\\.|[^"\\])*)"',
      ).firstMatch(before)?.group(1) ??
      '?';
  debugPrint(
    '[GP] JSON fail near field=$field clinic=$name: '
    '${json.substring(from, to)}',
  );
}

void _logDroppedClinicJson(String slice, FormatException e) {
  final name =
      RegExp(r'"name"\s*:\s*"((?:\\.|[^"\\])*)"').firstMatch(slice)?.group(1) ??
      '?';
  final offset = e.offset;
  var field = '?';
  if (offset != null && offset >= 0 && offset <= slice.length) {
    final before = slice.substring(0, math.min(offset, slice.length));
    final fields = RegExp(r'"([a-zA-Z_]+)"\s*:').allMatches(before);
    if (fields.isNotEmpty) field = fields.last.group(1)!;
  }
  debugPrint(
    '[GP] Comparison AI clinic JSON dropped: name=$name field=$field '
    'error=$e',
  );
}

List<Map<String, dynamic>> _extractParseableClinicMaps(String json) {
  final key = RegExp(r'"clinics"\s*:\s*\[').firstMatch(json);
  if (key == null) return const [];
  final start = key.end;
  var depth = 0;
  var objStart = -1;
  var inString = false;
  var escape = false;
  final out = <Map<String, dynamic>>[];
  for (var i = start; i < json.length; i++) {
    final c = json[i];
    if (inString) {
      if (escape) {
        escape = false;
      } else if (c == '\\') {
        escape = true;
      } else if (c == '"') {
        inString = false;
      }
      continue;
    }
    if (c == '"') {
      inString = true;
      continue;
    }
    if (c == '{') {
      if (depth == 0) objStart = i;
      depth++;
      continue;
    }
    if (c == '}') {
      depth--;
      if (depth == 0 && objStart >= 0) {
        final slice = json.substring(objStart, i + 1);
        try {
          final decoded = jsonDecode(_sanitizeAiJsonText(slice));
          if (decoded is Map) {
            out.add(Map<String, dynamic>.from(decoded));
          }
        } on FormatException catch (e) {
          _logDroppedClinicJson(slice, e);
        }
        objStart = -1;
      }
      continue;
    }
    if (c == ']' && depth == 0) break;
  }
  return out;
}

String _stripCodeFences(String s) {
  var out = s.trim();
  if (out.startsWith('```')) {
    out = out.replaceFirst(RegExp(r'^```[a-zA-Z]*\s*'), '');
    if (out.endsWith('```')) {
      out = out.substring(0, out.length - 3);
    }
  }
  return out.trim();
}

/// Accepts either a raw JSON array or an object with a "results"/"items"/"data" array.
List<dynamic> _extractResultsArray(Object? parsed) {
  if (parsed is List) return parsed;
  if (parsed is Map) {
    for (final key in const ['results', 'items', 'data', 'matches']) {
      final v = parsed[key];
      if (v is List) return v;
    }
    for (final v in parsed.values) {
      if (v is List) return v;
    }
  }
  return const [];
}

/// True when [subtitle] clearly labels a clinic row (RO/EN/etc.), e.g. "… • Clinică".
bool _subtitleSuggestsClinicListing(String subtitle) {
  final s = subtitle.toLowerCase();
  if (s.contains('• clinic')) return true;
  if (s.contains('· clinic')) return true;
  if (s.contains('clinică')) return true;
  if (RegExp(r'\bclinica\b').hasMatch(s)) return true;
  if (s.contains('clinique')) return true;
  if (s.contains('aesthetics')) return true;
  if (s.contains('estetic')) return true;
  if (RegExp(r'\bstudio\b').hasMatch(s)) return true;
  return false;
}

/// Same idea as app search heuristics: clinic-like query when JSON parsing fails.
bool _fallbackQueryLooksLikeClinicName(String query) {
  final q = query.toLowerCase().trim();
  if (q.isEmpty) return false;
  if (RegExp(r'^dr\.?\s').hasMatch(q)) return true;
  if (RegExp(r'^dr\.[a-z]').hasMatch(q)) return true;
  if (q.startsWith('drs ') || q.startsWith('drs.')) return true;
  const clinicWords = [
    'clinic',
    'clinica',
    'clinique',
    'studio',
    'aesthetics',
    'aesthetic',
    'medical',
    'beauty',
    'spa',
    'salon',
    'centre',
    'center',
    'lounge',
    'institute',
    'practice',
    'estetica',
    'polyclinic',
    'derma',
  ];
  return clinicWords.any((w) => q.contains(w));
}

bool _userMeansEzGelPrfIntent(String trimmed) {
  final s = trimmed.toLowerCase();
  final isEzGel =
      RegExp(r'\bez\s*gel\b').hasMatch(s) || RegExp(r'\bezgel\b').hasMatch(s);
  if (!isEzGel) return false;
  if (s.contains('eyebrow') ||
      s.contains('eye brow') ||
      s.contains('sprâncene') ||
      s.contains('sprancene') ||
      s.contains('brow bar')) {
    return false;
  }
  return true;
}

bool _searchItemLooksLikeBrowBeautyMisread(OpenAISearchItem it) {
  final blob = '${it.title} ${it.subtitle} ${it.aliases.join(' ')}'
      .toLowerCase();
  final browBeauty = RegExp(
    r'eyebrow|\bsprân|\bsprän|sprancene|sprâncene|vopsire spr|modelare spr|brow\s+tint|brow\s+shaping|gene\b|sprancen\b',
    caseSensitive: false,
  ).hasMatch(blob);
  final medical = RegExp(
    r'\bprf\b|platelet|plasma|fibrin|bio-?stimul|skin\s+booster|\binject|autolog|mesotherapy|\bprp\b|alucell|rejuvenat',
    caseSensitive: false,
  ).hasMatch(blob);
  return browBeauty && !medical;
}

List<OpenAISearchItem> _filterSearchItemsForEzGelPrf(
  String query,
  List<OpenAISearchItem> items,
  String city,
  String categoryPill,
) {
  if (!_userMeansEzGelPrfIntent(query)) return items;
  final kept = items
      .where((e) => !_searchItemLooksLikeBrowBeautyMisread(e))
      .toList(growable: false);
  if (kept.isNotEmpty) return kept;
  return _fallbackEzGelPrfSearchRows(city, categoryPill);
}

List<OpenAISearchItem> _fallbackEzGelPrfSearchRows(
  String city,
  String categoryPill,
) {
  final pill = categoryPill.trim().isEmpty ? 'procedure' : categoryPill;
  return [
    OpenAISearchItem(
      title: 'EZ GEL (PRF)',
      subtitle:
          'Autologous platelet fibrin injectable · Skin rejuvenation · $city · $pill',
      type: OpenAISearchItemType.procedure,
      priceHint: null,
      aliases: const ['EZ gel', 'EZGEL PRF', 'Platelet rich fibrin gel'],
    ),
    OpenAISearchItem(
      title: 'PRF / PRP facial',
      subtitle: 'Platelet therapy · Injectable regeneration · $city · $pill',
      type: OpenAISearchItemType.procedure,
      priceHint: null,
      aliases: const ['PRP treatment', 'Plasma skin therapy'],
    ),
    OpenAISearchItem(
      title: 'Injectable skin booster',
      subtitle: 'Medical bioremodeling · Hydration protocols · $city · $pill',
      type: OpenAISearchItemType.procedure,
      priceHint: null,
      aliases: const ['Skin booster injection', 'Biostimulator facial'],
    ),
  ];
}

enum OpenAISearchItemType { procedure, clinic }

class OpenAISearchItem {
  const OpenAISearchItem({
    required this.title,
    required this.subtitle,
    required this.type,
    required this.priceHint,
    this.aliases = const [],
  });

  final String title;
  final String subtitle;
  final OpenAISearchItemType type;
  final String? priceHint;

  /// Multilingual synonyms for this item (e.g. ["Lip filler", "Acid hialuronic buze"]).
  /// Allows downstream search to match clinics offering the procedure under any
  /// of these names.
  final List<String> aliases;

  factory OpenAISearchItem.fromJson(Map<String, Object?> json) {
    final typeStr = (json['type'] as String?)?.toLowerCase().trim();
    var type = typeStr == 'clinic'
        ? OpenAISearchItemType.clinic
        : OpenAISearchItemType.procedure;
    final rawAliases = (json['aliases'] as List?) ?? const [];
    final aliases = rawAliases
        .whereType<String>()
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    final title = (json['title'] as String?)?.trim() ?? '';
    final subtitle = (json['subtitle'] as String?)?.trim() ?? '';
    if (type == OpenAISearchItemType.procedure &&
        _subtitleSuggestsClinicListing(subtitle)) {
      type = OpenAISearchItemType.clinic;
    }
    return OpenAISearchItem(
      title: title,
      subtitle: subtitle,
      type: type,
      priceHint: (json['price_hint'] as String?)?.trim(),
      aliases: aliases,
    );
  }
}

class OpenAIHttpException implements Exception {
  OpenAIHttpException(this.statusCode, this.body);
  final int statusCode;
  final String body;

  @override
  String toString() => 'OpenAIHttpException($statusCode): $body';
}

/// True for hair-transplant Explore queries (often priced per graft).
bool isHairExploreProcedure(String? procedure) {
  final proc = (procedure ?? '').toLowerCase();
  if (proc.isEmpty) return false;
  return proc.contains('hair transplant') ||
      proc.contains('fue') ||
      proc.contains('dhi') ||
      proc.contains('transplant de par') ||
      proc.contains('transplant par') ||
      proc.contains('implant de par') ||
      proc.contains('implant par') ||
      (proc.contains('transplant') && proc.contains('hair')) ||
      (proc.contains('hair') &&
          (proc.contains('restoration') || proc.contains('implant')));
}

/// True for package/surgery quotes (not hair — hair is often per-graft).
bool isHighTicketExploreProcedure(String? procedure) {
  final proc = (procedure ?? '').toLowerCase();
  if (proc.isEmpty) return false;
  if (isHairExploreProcedure(proc)) return false;
  // "lip augmentation" / FAQ copy containing "augmentation" is filler, not
  // surgery. Treating it as high-ticket hid real AED/EUR injector quotes.
  switch (exploreTreatmentFamily(proc)) {
    case ExploreTreatmentFamily.filler:
    case ExploreTreatmentFamily.botox:
    case ExploreTreatmentFamily.laser:
    case ExploreTreatmentFamily.peel:
    case ExploreTreatmentFamily.skin:
    case ExploreTreatmentFamily.hair:
      return false;
    case ExploreTreatmentFamily.rhinoplasty:
    case ExploreTreatmentFamily.breast:
    case ExploreTreatmentFamily.other:
      break;
  }
  return proc.contains('rhinoplasty') ||
      proc.contains('nose job') ||
      proc.contains('breast') ||
      proc.contains('boob') ||
      proc.contains('augmentation') ||
      proc.contains('tummy') ||
      proc.contains('facelift') ||
      proc.contains('blepharoplasty');
}

bool _labelLooksLikePerUnitOrGraft(String label) {
  final l = label.toLowerCase();
  return l.contains('per graft') ||
      l.contains('/graft') ||
      l.contains('per follicle') ||
      l.contains('/follicle') ||
      l.contains('لكل بصيلة') ||
      l.contains('للبصيلة') ||
      l.contains('per unit') ||
      l.contains('/unit') ||
      l.contains('per iu') ||
      l.contains('/iu') ||
      l.contains('por unidad') ||
      l.contains('per unità') ||
      l.contains('/ud') ||
      l.contains('pro einheit');
}

bool looksLikeHairPerGraftPrice(OpenAIClinic c, {String? procedure}) {
  final max = _hairPerGraftMaxForCurrency(c.currency);
  final blob =
      '${c.priceLabel} ${c.rawPriceText} ${c.rawProcedureText} ${c.brand} '
      '${c.priceEvidenceText}';
  if (looksLikeEffectivePerGraftMarketing(blob)) return false;
  if (!_labelLooksLikePerUnitOrGraft(blob) &&
      !looksLikePerGraftQuotedPrice(blob)) {
    return false;
  }
  if (!isHairExploreProcedure(procedure) &&
      !isHairExploreProcedure(c.brand) &&
      !isHairExploreProcedure(c.rawProcedureText)) {
    return false;
  }
  return c.priceMin > 0 && c.priceMin <= max;
}

/// True for Botox / Dysport / Xeomin / neuromodulator Explore queries.
bool isBotoxExploreProcedure(String? procedure) {
  final proc = (procedure ?? '').toLowerCase();
  if (proc.isEmpty) return false;
  if (exploreTreatmentFamily(proc) == ExploreTreatmentFamily.botox) {
    return true;
  }
  return proc.contains('botox') ||
      proc.contains('dysport') ||
      proc.contains('xeomin') ||
      proc.contains('vistabel') ||
      proc.contains('neuromodul') ||
      proc.contains('toxina') ||
      proc.contains('botulin') ||
      proc.contains('anti-wrinkle') ||
      proc.contains('antiwrinkle') ||
      proc.contains('anti wrinkle');
}

/// Published neuromodulator per-unit rate (e.g. "AED 42/unit") — valid starting price.
bool looksLikeBotoxPerUnitPrice(OpenAIClinic c, {String? procedure}) {
  final blob =
      '${c.priceLabel} ${c.rawPriceText} ${c.priceEvidenceText} ${c.priceType} '
      '${c.priceUnit}';
  if (!_labelLooksLikePerUnitOrGraft(blob) &&
      c.priceType != PriceType.perUnit.wire &&
      c.priceUnit.toLowerCase() != 'unit' &&
      c.priceUnit.toLowerCase() != 'iu') {
    return false;
  }
  return isBotoxExploreProcedure(procedure) || isBotoxExploreProcedure(c.brand);
}

String formatBotoxPerUnitPriceLabel(double amount, String currency) {
  final n = amount == amount.roundToDouble()
      ? amount.round().toString()
      : amount.toStringAsFixed(0);
  final cur = currency.trim().isNotEmpty ? currency.trim() : 'AED';
  return 'from $n $cur/unit';
}

/// Upper bound for a believable per-graft rate in local currency (worldwide).
double _hairPerGraftMaxForCurrency(String currency) =>
    hairPerGraftPlausibleMax(currency);

String formatHairPerGraftPriceLabel(double amount, String currency) {
  final n = amount == amount.roundToDouble()
      ? amount.round().toString()
      : amount.toStringAsFixed(1);
  final cur = currency.trim().isNotEmpty ? currency.trim() : r'$';
  return 'from $n $cur/graft';
}

/// Fixes AI shorthand for high-ticket package prices:
/// price_min=4 with label "from 4,000 $" / "4k" → 4000.
/// For hair: normalize real per-graft quotes — never invent package totals.
OpenAIClinic repairHighTicketExploreClinicPrice(
  OpenAIClinic c,
  String procedure,
) {
  final hair =
      isHairExploreProcedure(procedure) || isHairExploreProcedure(c.brand);
  final curr = c.currency.trim().isNotEmpty ? c.currency.trim() : r'$';

  if (hair) {
    final graftMax = _hairPerGraftMaxForCurrency(curr);
    final labelIsGraft = _labelLooksLikePerUnitOrGraft(c.priceLabel);
    // Real per-graft: amount within local ceiling.
    if (c.priceMin > 0 && c.priceMin <= graftMax) {
      return c.copyWith(
        priceLabel: formatHairPerGraftPriceLabel(c.priceMin, curr),
        priceMax: c.priceMax > 0 && c.priceMax <= graftMax
            ? c.priceMax
            : c.priceMin,
        priceGbp: c.priceMin.round(),
      );
    }
    // Package total mislabeled as /graft (e.g. "from 4125 €/graft").
    if (labelIsGraft && c.priceMin > graftMax) {
      final labelAmount = FilterFx.parseAmount(c.priceLabel) ?? c.priceMin;
      return c.copyWith(
        priceMin: labelAmount,
        priceMax: c.priceMax >= labelAmount ? c.priceMax : labelAmount,
        priceLabel: 'from ${labelAmount.round()} $curr',
        priceGbp: labelAmount.round(),
      );
    }
    // Package-sized hair quote only when the website/label clearly says so.
    final labelAmount = FilterFx.parseAmount(c.priceLabel);
    if (labelAmount != null && labelAmount >= 1500) {
      return c.copyWith(
        priceMin: labelAmount,
        priceMax: c.priceMax >= labelAmount ? c.priceMax : labelAmount,
        priceLabel: 'from ${labelAmount.round()} $curr',
        priceGbp: labelAmount.round(),
      );
    }
    // Reject AI-invented round package totals when there is no label evidence.
    // Leave as-is for justification to drop if it looks fake later.
    return c;
  }

  if (!isHighTicketExploreProcedure(procedure) &&
      !isHighTicketExploreProcedure(c.brand)) {
    return c;
  }
  if (_labelLooksLikePerUnitOrGraft(c.priceLabel)) return c;

  final label = c.priceLabel.trim();
  var min = c.priceMin;
  var max = c.priceMax;

  // Fill missing price_min from a package-sized label amount.
  if (min <= 0) {
    final fromLabel = FilterFx.parseAmount(label);
    if (fromLabel != null && fromLabel >= 1500) min = fromLabel;
  }

  final kMatch = RegExp(r'(\d+(?:[.,]\d+)?)\s*[kK]\b').firstMatch(label);
  if (kMatch != null) {
    final n = double.tryParse(kMatch.group(1)!.replaceAll(',', '.'));
    if (n != null && n > 0) min = n * 1000;
  } else {
    final labelAmount = FilterFx.parseAmount(label);
    if (labelAmount != null && labelAmount >= 1500) {
      if (min <= 0 || min < 500 || labelAmount >= min * 10) {
        min = labelAmount;
      }
    } else if (min >= 3 &&
        min <= 40 &&
        RegExp(r'\d,\d{3}|\d\s000\b').hasMatch(label)) {
      min = min * 1000;
    }
  }

  if (max > 0 && max < min) max = min;
  if (max > 0 && max <= 40 && min >= 1000) max = max * 1000;

  if (min == c.priceMin && max == c.priceMax) return c;

  var nextLabel = label;
  if (nextLabel.isEmpty ||
      !RegExp(r'\d').hasMatch(nextLabel) ||
      min != c.priceMin) {
    nextLabel = 'from ${min.round()} $curr';
  }

  return c.copyWith(
    priceMin: min,
    priceMax: max > 0 ? max : min,
    priceLabel: nextLabel,
    priceGbp: min.round(),
  );
}

/// Minimum believable clinic price for compare / enrichment (by currency + procedure).
bool isJustifiedProcedurePrice(OpenAIClinic c, {String? procedure}) {
  final proc = procedure ?? c.brand;
  // Curated public-site rows have no DOM evidence / extract revision. The
  // scrape sanity lock would drop every Miami JSON card and leave two live
  // scraps. Amount band + unilateral still apply.
  if (exploreCuratedPriceIsTrusted(c)) {
    if (looksLikeUnilateralBreastStartingRow(
      '${c.rawProcedureText} ${c.brand} $proc',
    )) {
      return false;
    }
    return isJustifiedProcedurePriceValue(
      priceMin: c.priceMin,
      currency: c.currency,
      procedure: proc,
      evidence:
          '${c.rawProcedureText} ${c.rawPriceText} ${c.priceEvidenceText} '
          '${c.priceLabel}',
    );
  }
  if (c.priceMin > 0 &&
      !isValidExtractedPriceCandidate(
        rawPriceText: c.rawPriceText.trim().isNotEmpty
            ? c.rawPriceText
            : c.priceLabel,
        priceMin: c.priceMin,
        currency: c.currency,
        extractionMethod: c.extractionMethod,
        rawEvidence: c.priceEvidenceText,
        rawProcedureText: c.rawProcedureText,
        procedure: proc,
        sourceUrl: c.priceSourceUrl,
        priceMax: c.priceMax,
      )) {
    return false;
  }
  final breastish =
      exploreTreatmentFamily(proc) == ExploreTreatmentFamily.breast ||
      exploreTreatmentFamily(c.brand) == ExploreTreatmentFamily.breast ||
      exploreTreatmentFamily(c.rawProcedureText) ==
          ExploreTreatmentFamily.breast;
  if (breastish) {
    if (looksLikeUnilateralBreastStartingRow(
      '${c.rawProcedureText} ${c.brand} $proc',
    )) {
      return false;
    }
    if (looksLikeRoundedMarketPriceSpread(
      priceMin: c.priceMin,
      priceMax: c.priceMax,
      currency: c.currency,
      procedure: proc.isNotEmpty ? proc : c.brand,
    )) {
      return false;
    }
  }
  // Hair: per-graft website rates are real — do not reject them.
  if (isHairExploreProcedure(proc) || isHairExploreProcedure(c.brand)) {
    if (looksLikeHairPerGraftPrice(c, procedure: proc)) {
      final max = _hairPerGraftMaxForCurrency(c.currency);
      return c.priceMin >= 1 && c.priceMin <= max;
    }
    return isJustifiedProcedurePriceValue(
      priceMin: c.priceMin,
      currency: c.currency,
      procedure: proc,
      evidence:
          '${c.rawProcedureText} ${c.rawPriceText} ${c.priceEvidenceText} '
          '${c.priceLabel}',
    );
  }

  if (_labelLooksLikePerUnitOrGraft(c.priceLabel) &&
      isHighTicketExploreProcedure(proc)) {
    return false;
  }
  // Per-unit neuromodulator rates are valid starting prices (e.g. AED 42/unit,
  // 150 lei/unit in Chișinău). Session lei totals still use the 350 floor.
  if (looksLikeBotoxPerUnitPrice(c, procedure: proc) ||
      looksLikeBotoxPerUnitQuote(
        '${c.rawProcedureText} ${c.rawPriceText} ${c.priceEvidenceText} '
        '${c.priceLabel}',
        procedure: proc,
      )) {
    return c.priceMin >= 5 &&
        c.priceMin <= botoxPerUnitJustifiedMax(c.currency);
  }
  return isJustifiedProcedurePriceValue(
    priceMin: c.priceMin,
    currency: c.currency,
    procedure: procedure,
    evidence:
        '${c.rawProcedureText} ${c.rawPriceText} ${c.priceEvidenceText} '
        '${c.priceLabel}',
  );
}

bool isJustifiedProcedurePriceValue({
  required double priceMin,
  required String currency,
  String? procedure,
  String evidence = '',
}) {
  if (priceMin <= 0) return true;

  final proc = (procedure ?? '').toLowerCase();
  final curr = currency.trim().toUpperCase();
  if (looksLikeBotoxPerUnitQuote(evidence, procedure: procedure ?? '')) {
    return priceMin >= 5 && priceMin <= botoxPerUnitJustifiedMax(currency);
  }
  final hair = isHairExploreProcedure(proc);
  final highTicket = isHighTicketExploreProcedure(proc);
  final rhino =
      exploreTreatmentFamily(proc) == ExploreTreatmentFamily.rhinoplasty ||
      proc.contains('rhinoplast') ||
      proc.contains('nose job') ||
      proc.contains('rinoplast');

  // Hair: published per-graft rates stay on the card; package totals must
  // not be accepted just because they sit below the per-graft ceiling.
  if (hair && priceMin > 0) {
    final max = _hairPerGraftMaxForCurrency(currency);
    if (priceMin <= max) {
      final c = currency.trim().toUpperCase();
      if (c == 'AED' || c == 'د.إ' || c == 'TRY' || c == 'TL' || c == '₺') {
        return priceMin >= 1;
      }
      return false;
    }
  }

  var minRon = 80.0;
  var maxRon = 1e9;
  if (hair) {
    minRon = 7000; // package total in RON
  } else if (highTicket) {
    minRon = 18000; // 5050 € surgery was passing as 5050 RON
  } else if (proc.contains('botox') ||
      proc.contains('btx') ||
      proc.contains('toxin')) {
    minRon = 350;
    // Surgery-sized RON figures (Cronos Med 6500) are not facial Botox.
    maxRon = 4000;
  } else if (proc.contains('filler') ||
      proc.contains('hialuronic') ||
      proc.contains('acid')) {
    // 200 lei on RO price lists is papiloame / consult / a misread of
    // "1,200 lei". Real 0.5–1 ml lips/cheeks start well above that.
    minRon = 400;
    maxRon = 5000;
  } else if (proc.contains('hifu') || proc.contains('ultraformer')) {
    minRon = 300;
  } else if (proc.contains('laser') || proc.contains('epilare')) {
    // Small facial laser zones often start €20–40 / $25–50.
    minRon = 80;
  } else if (proc.contains('prp') || proc.contains('mezoterapie')) {
    minRon = 150;
  }

  if (curr.isEmpty || curr == 'RON' || curr == 'LEI' || curr == 'MDL') {
    // Bare 5,500 on an EUR surgery menu is not 5,500 RON.
    if (curr.isEmpty && highTicket && priceMin >= 500 && priceMin <= 20000) {
      return true;
    }
    // Chișinău / RO surgery menus often print bare euro figures (3000–8000)
    // while the city default currency is MDL/RON. Treating those as lei
    // rejects every real public quote (Chirurgiaplastica PDF, Magnum, etc.).
    final breast =
        exploreTreatmentFamily(proc) == ExploreTreatmentFamily.breast ||
        proc.contains('breast') ||
        proc.contains('boob') ||
        proc.contains('pecho') ||
        proc.contains('mamar') ||
        proc.contains('marire sani') ||
        proc.contains('augmentare mamar');
    if (highTicket &&
        (rhino || breast) &&
        (curr == 'MDL' || curr == 'RON' || curr == 'LEI') &&
        priceMin >= 2000 &&
        priceMin <= 15000) {
      return true;
    }
    return priceMin >= minRon && priceMin <= maxRon;
  }
  if (curr == '€' || curr == 'EUR') {
    if (rhino) return priceMin >= 1500 && priceMin <= 100000;
    final breast =
        exploreTreatmentFamily(proc) == ExploreTreatmentFamily.breast ||
        proc.contains('breast') ||
        proc.contains('boob') ||
        proc.contains('pecho') ||
        proc.contains('mamar');
    if (breast) return priceMin >= 2000 && priceMin <= 100000;
    if (hair || highTicket) return priceMin >= 500 && priceMin <= 100000;
    if (proc.contains('laser') ||
        proc.contains('epilare') ||
        proc.contains('peel')) {
      return priceMin >= 10 && priceMin <= 5000;
    }
    if (proc.contains('botox') ||
        proc.contains('btx') ||
        proc.contains('toxin') ||
        proc.contains('anti-wrinkle') ||
        proc.contains('anti wrinkle')) {
      return priceMin >= 20 && priceMin <= 3000;
    }
    if (proc.contains('filler') ||
        proc.contains('hialuron') ||
        proc.contains('hyaluron') ||
        proc.contains('relleno')) {
      return priceMin >= 30 && priceMin <= 5000;
    }
    return priceMin >= 10 && priceMin <= 100000;
  }
  if (curr == '£' || curr == 'GBP') {
    if (rhino) return priceMin >= 2000 && priceMin <= 100000;
    final breast =
        exploreTreatmentFamily(proc) == ExploreTreatmentFamily.breast ||
        proc.contains('breast') ||
        proc.contains('boob') ||
        proc.contains('pecho') ||
        proc.contains('mamar');
    if (breast) return priceMin >= 4000 && priceMin <= 100000;
    if (hair) return priceMin >= 1500 && priceMin <= 100000;
    if (highTicket) return priceMin >= 500 && priceMin <= 100000;
    if (proc.contains('laser') ||
        proc.contains('epilare') ||
        proc.contains('peel')) {
      return priceMin >= 10 && priceMin <= 5000;
    }
    if (proc.contains('botox') || proc.contains('toxin')) {
      return priceMin >= 20 && priceMin <= 3000;
    }
    if (proc.contains('filler') || proc.contains('hialuron')) {
      return priceMin >= 30 && priceMin <= 5000;
    }
    return priceMin >= 10 && priceMin <= 100000;
  }
  if (curr == r'$' || curr == 'USD') {
    if (rhino) return priceMin >= 2500 && priceMin <= 100000;
    if (hair || highTicket) return priceMin >= 500 && priceMin <= 100000;
    if (proc.contains('botox') ||
        proc.contains('btx') ||
        proc.contains('toxin') ||
        proc.contains('anti-wrinkle') ||
        proc.contains('anti wrinkle')) {
      return priceMin >= 8 && priceMin <= 3000;
    }
    if (proc.contains('laser') ||
        proc.contains('epilare') ||
        proc.contains('peel')) {
      return priceMin >= 10 && priceMin <= 5000;
    }
    if (proc.contains('filler') || proc.contains('hialuron')) {
      return priceMin >= 30 && priceMin <= 5000;
    }
    return priceMin >= 10 && priceMin <= 100000;
  }
  if (curr == 'TRY') {
    return (hair || highTicket) ? priceMin >= 40000 : priceMin >= 400;
  }
  if (curr == 'BGN') {
    // Sofia menus: crow's feet 250 BGN, forehead 300, upper face 600.
    if (rhino || highTicket) return priceMin >= 3000 && priceMin <= 100000;
    if (hair) return priceMin >= 2000 && priceMin <= 100000;
    if (proc.contains('botox') ||
        proc.contains('btx') ||
        proc.contains('toxin') ||
        proc.contains('anti-wrinkle') ||
        proc.contains('anti wrinkle')) {
      return priceMin >= 80 && priceMin <= 4000;
    }
    if (proc.contains('filler') || proc.contains('hialuron')) {
      return priceMin >= 100 && priceMin <= 5000;
    }
    if (proc.contains('laser') || proc.contains('peel')) {
      return priceMin >= 20 && priceMin <= 5000;
    }
    return priceMin >= 20 && priceMin <= 100000;
  }
  if (curr == 'AED') {
    if (hair) {
      return priceMin >= 4000 && priceMin <= 100000;
    }
    if (highTicket) return priceMin >= 8000;
    if (proc.contains('peel') || proc.contains('تقشير')) {
      // GP checkup / tiny promo amounts are not facial peels.
      return priceMin >= 250 && priceMin <= 15000;
    }
    if (proc.contains('filler') || proc.contains('فيلر')) {
      return priceMin >= 400 && priceMin <= 15000;
    }
    if (proc.contains('botox') || proc.contains('بوتوكس')) {
      // Session totals; per-unit is handled separately via looksLikeBotoxPerUnitPrice.
      return priceMin >= 200 && priceMin <= 8000;
    }
    return priceMin >= 100;
  }
  if (curr == '₩' || curr == 'KRW' || curr == 'WON') {
    if (hair || highTicket) return priceMin >= 1500000; // packages in millions
    return priceMin >= 30000;
  }
  if (curr == 'JPY') {
    return (hair || highTicket) ? priceMin >= 200000 : priceMin >= 3000;
  }
  if (curr == 'HKD') {
    if (hair || highTicket) return priceMin >= 15000;
    return priceMin >= 80;
  }
  if (curr == 'INR' || curr == '₹') {
    if (hair || highTicket) return priceMin >= 40000;
    return priceMin >= 500;
  }
  if (curr == 'SGD') {
    if (hair || highTicket) return priceMin >= 3000;
    return priceMin >= 30;
  }
  if (curr == 'THB') {
    if (hair || highTicket) return priceMin >= 50000;
    return priceMin >= 500;
  }
  if (curr == 'AUD' || curr == 'CAD') {
    if (hair || highTicket) return priceMin >= 2000;
    return priceMin >= 30;
  }
  return (hair || highTicket) ? priceMin >= 2000 : priceMin >= 20;
}

/// Canonical dedup key for a clinic. Prefers the registered domain so
/// "Dr. Paul Nistor" and "Clinica Dr. Paul Nistor" on the same website are
/// treated as one clinic. Falls back to a normalized name where "clinica",
/// "dr.", "doctor", "medical center" prefixes are stripped so the same
/// entity spelled two ways still collapses.
/// Website host key even after Places attaches a `placeId` (primary dedup
/// then becomes `id:…`). Without this, rated Maps rows cannot patch the
/// unrated card that only had `host:clinic.ro`.
String exploreClinicHostDedupKey(OpenAIClinic c) {
  final sourceHost = normalizeExploreHost(c.priceSourceUrl);
  if (sourceHost.isNotEmpty && !isMarketplaceOrDirectoryHost(sourceHost)) {
    return 'host:$sourceHost';
  }
  for (final part in c.area.split('·')) {
    final t = part.trim().toLowerCase();
    if (t.isEmpty) continue;
    if (!t.contains('.') || t.contains(' ') || t.length < 5) continue;
    final host = t
        .replaceFirst(RegExp(r'^https?://'), '')
        .replaceFirst(RegExp(r'^www\.'), '')
        .split('/')
        .first
        .split(':')
        .first;
    if (host.contains('.') && !isMarketplaceOrDirectoryHost(host)) {
      return 'host:$host';
    }
  }
  return '';
}

String exploreClinicDedupKey(OpenAIClinic c) {
  final placeId = c.placeId.trim();
  if (placeId.isNotEmpty) return 'id:$placeId';
  final hostKey = exploreClinicHostDedupKey(c);
  if (hostKey.isNotEmpty) return hostKey;
  final packed = packedCanonicalClinicName(c.name);
  if (packed.length >= 6) return 'name:$packed';
  return exploreClinicNameDedupKey(c.name);
}

/// Name-only half of [exploreClinicDedupKey], so a saved "Cronos Med" with
/// `cronosmed.ro` in area still matches a later Google hit with no host.
String exploreClinicNameDedupKey(String rawName) {
  final packed = packedCanonicalClinicName(rawName);
  if (packed.length >= 6) return 'name:$packed';
  var name = rawName.toLowerCase().trim();
  // Strip punctuation THEN collapse whitespace so "Clinica Dr. Paul" (with
  // period) becomes "clinica dr paul" — otherwise the prefix "clinica dr "
  // never matches because of the double-space "clinica dr  paul".
  name = name
      .replaceAll(RegExp(r'[\.,]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  const stripPrefixes = <String>[
    'clinica de ',
    'clinica dr ',
    'clinica del dr ',
    'clinica ',
    'clínica ',
    'clinic ',
    'centro médico ',
    'centro medico ',
    'centro ',
    'medical center ',
    'dr med ',
    'dr ',
    'dra ',
    'doctor ',
    'doctora ',
    'dott ',
    'prof ',
  ];
  var changed = true;
  while (changed) {
    changed = false;
    for (final p in stripPrefixes) {
      if (name.startsWith(p)) {
        name = name.substring(p.length).trim();
        changed = true;
        break;
      }
    }
  }
  // Collapse remaining whitespace so "paul  nistor" == "paul nistor".
  name = name.replaceAll(RegExp(r'\s+'), ' ').trim();
  return name.isEmpty ? 'name:${rawName.toLowerCase().trim()}' : 'name:$name';
}

/// Host key (when known) plus normalized name, so pool membership does not
/// miss the same clinic just because one row has a website and the other
/// does not.
Set<String> exploreClinicIdentityKeys(OpenAIClinic c) {
  final keys = <String>{};
  final primary = exploreClinicDedupKey(c);
  if (primary.isNotEmpty) keys.add(primary);
  final placeId = c.placeId.trim();
  if (placeId.isNotEmpty) keys.add('id:$placeId');
  final hostKey = exploreClinicHostDedupKey(c);
  if (hostKey.isNotEmpty) keys.add(hostKey);
  final nameKey = exploreClinicNameDedupKey(c.name);
  if (nameKey.isNotEmpty) keys.add(nameKey);
  final packed = packedCanonicalClinicName(c.name);
  if (packed.length >= 6) keys.add('name:$packed');
  return keys;
}

bool exploreClinicHitsKeys(OpenAIClinic c, Set<String> keys) {
  if (keys.isEmpty) return false;
  for (final k in exploreClinicIdentityKeys(c)) {
    if (keys.contains(k)) return true;
  }
  return false;
}

String exploreClinicWebsiteHost(OpenAIClinic c) {
  final key = exploreClinicHostDedupKey(c);
  if (key.startsWith('host:')) return key.substring(5);
  return '';
}

String exploreClinicBrandFromHost(String host) {
  var h = host.toLowerCase().trim();
  h = h.replaceFirst(RegExp(r'^https?://'), '');
  h = h.replaceFirst(RegExp(r'^www\.'), '');
  h = h.split('/').first.split(':').first.trim();
  if (h.isEmpty) return '';
  const known = {
    'doctorskin.ro': 'Doctor SKiN',
    'clinicabarbatilor.ro': 'Clinica Barbatilor',
    'skinexperience.ro': 'Skin Experience Clinic',
    'elenamartin.ro': 'Doctor Elena Martin',
    'doctorlica.md': 'Doctor Lica',
    'beautysphera.md': 'Beauty Sphera',
  };
  if (known.containsKey(h)) return known[h]!;
  var brand = h.split('.').first.replaceAll(RegExp(r'[-_]+'), ' ').trim();
  brand = _splitPackedClinicBrand(brand);
  if (brand.length < 3) return '';
  return brand
      .split(RegExp(r'\s+'))
      .map((w) {
        if (w.isEmpty) return w;
        if (w.toLowerCase() == 'dr' || w.toLowerCase() == 'dra') {
          return w[0].toUpperCase() + w.substring(1).toLowerCase();
        }
        return '${w[0].toUpperCase()}${w.substring(1)}';
      })
      .join(' ');
}

bool _mapsNameAgreesWithHost(String mapsName, String host) {
  final maps = foldExploreCityText(mapsName);
  if (maps.trim().length < 3 || host.trim().isEmpty) return false;
  final packed = host
      .split('.')
      .first
      .replaceAll(RegExp(r'[-_]'), '')
      .toLowerCase();
  final mapsCompact = maps.replaceAll(RegExp(r'[^a-z0-9]'), '');
  if (packed.length >= 5 && mapsCompact.contains(packed)) return true;
  final brand = exploreClinicBrandFromHost(host).toLowerCase();
  final parts = brand
      .split(RegExp(r'\s+'))
      .where((w) => w.length >= 3)
      .toList();
  if (parts.length >= 2 && parts.every(maps.contains)) return true;
  final compactBrand = brand.replaceAll(' ', '');
  return compactBrand.length >= 5 && mapsCompact.contains(compactBrand);
}

/// A provider may use an aesthetic site and a medical site for the same brand.
/// Require both the distinctive host stem and Maps name to agree.
bool exploreMapsProviderIdentityMatches({
  required String sourceName, required String mapsName,
  required String sourceHost, required String mapsHost,
  bool marketplace = false,
}) {
  if (marketplace) return namesLookLikeSameProvider(sourceName, mapsName);
  String stem(String host) => foldExploreCityText(host.split('.').first)
      .replaceAll(RegExp(r'[^a-z0-9]'), '')
      .replaceFirst(RegExp(r'(?:aesthetic|aesthetics|medical|clinic|clinics|dental)$'), '');
  final source = stem(sourceHost);
  final candidate = stem(mapsHost);
  final name = foldExploreCityText(mapsName).replaceAll(RegExp(r'[^a-z0-9]'), '');
  return source.length >= 7 && source == candidate && name.contains(source);
}

bool exploreClinicUsesMarketplacePriceSource(OpenAIClinic clinic) =>
    clinic.sourceType == 'marketplace' ||
    isMarketplaceOrDirectoryHost(clinic.priceSourceUrl) ||
    isMarketplaceOrDirectoryHost(exploreClinicWebsiteHost(clinic));

bool exploreClinicNameLooksPackedFromHost(OpenAIClinic c) {
  final host = exploreClinicWebsiteHost(c);
  if (host.isEmpty) return false;
  final name = c.name.trim();
  if (name.contains(RegExp(r'\s'))) return false;
  final packed = host
      .split('.')
      .first
      .replaceAll(RegExp(r'[-_]'), '')
      .toLowerCase();
  final compact = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  return packed.length >= 5 && compact == packed;
}

/// `doctorskin` → `doctor skin`; `drsanmiguel` → `dr sanmiguel`.
String _splitPackedClinicBrand(String raw) {
  var n = raw.trim();
  if (n.isEmpty) return n;
  n = n.replaceFirstMapped(
    RegExp(r'^(doctor)(?=[a-z])', caseSensitive: false),
    (m) => '${m[1]} ',
  );
  n = n.replaceFirstMapped(
    RegExp(r'^(dra?)(?=[a-z])', caseSensitive: false),
    (m) => '${m[1]} ',
  );
  n = n.replaceFirstMapped(
    RegExp(r'^(clinica|clinique|clinic)(?=[a-z])', caseSensitive: false),
    (m) => '${m[1]} ',
  );
  n = n.replaceFirstMapped(
    RegExp(r'^(elena)(?=martin)', caseSensitive: false),
    (m) => '${m[1]} ',
  );
  n = n.replaceFirstMapped(
    RegExp(r'^(beauty)(?=sphera)', caseSensitive: false),
    (m) => '${m[1]} ',
  );
  n = n.replaceFirstMapped(
    RegExp(
      r'(barcelona|madrid|valencia|sevilla|london|paris|roma|milan)$',
      caseSensitive: false,
    ),
    (m) => ' ${m[1]}',
  );
  return n.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Prefer domain branding over SEO SERP titles for broad discovery leads.
String resolveBroadSerpClinicCandidateName(String title, String host) {
  final hostName = exploreClinicBrandFromHost(host);
  final fromTitle = exploreClinicNameFromSerpTitle(title, host);
  if (fromTitle.isEmpty ||
      exploreSerpTitleLooksLikeNonClinicIdentity(fromTitle) ||
      looksLikeProcedureNameAsClinicIdentity(fromTitle) ||
      looksLikeCountryMarketPriceMarketing(fromTitle) ||
      looksLikePricingProseProcedureTitle(fromTitle)) {
    return hostName;
  }
  // "Breast Augmentation Tirana - Prices and Clinics" → host brand.
  if (RegExp(
        r'\b(?:prices?|cost|clinics?|procedures?)\b',
        caseSensitive: false,
      ).hasMatch(fromTitle) &&
      looksLikeProcedureNameAsClinicIdentity(
        fromTitle
            .replaceAll(
              RegExp(
                r'\b(?:prices?|cost|clinics?|in\s+\w+)\b',
                caseSensitive: false,
              ),
              '',
            )
            .trim(),
      )) {
    return hostName;
  }
  return fromTitle;
}

/// Google titles are SEO ("Preț rinoplastie… de la 5.000€"). Prefer the
/// brand after "|" or the website host — never drop the result.
String exploreClinicNameFromSerpTitle(String title, String host) {
  final hostName = exploreClinicBrandFromHost(host);
  var t = title.trim();
  if (t.isEmpty) return hostName;
  if (exploreSerpTitleLooksLikeNonClinicIdentity(t)) {
    return hostName;
  }
  final parts = t
      .split(RegExp(r'\s[\|\-–—]\s+|:\s+'))
      .map((s) => s.trim())
      .where((s) => s.length >= 3 && s.length <= 80)
      .toList();
  for (final part in parts.reversed) {
    if (exploreClinicNameLooksLikeSeoHeadline(part)) continue;
    if (isInvalidClinicIdentity(part)) continue;
    if (exploreSerpTitleLooksLikeNonClinicIdentity(part)) continue;
    return part;
  }
  if (hostName.isNotEmpty) return hostName;
  t = parts.isNotEmpty ? parts.first : t;
  t = t.replaceAll(RegExp(r'\s+[-–—]\s+.*$'), '').trim();
  if (t.length >= 3 &&
      !exploreClinicNameLooksLikeSeoHeadline(t) &&
      !isInvalidClinicIdentity(t) &&
      !exploreSerpTitleLooksLikeNonClinicIdentity(t)) {
    return t;
  }
  return hostName;
}

/// Bare city / tariff / procedure labels are not clinic identities.
bool exploreSerpTitleLooksLikeNonClinicIdentity(
  String title, {
  String city = '',
}) {
  final t = title.replaceAll('\u00a0', ' ').trim();
  if (t.isEmpty) return true;
  final lo = t.toLowerCase();
  if (RegExp(
    r'^(?:tarife|preturi|prețuri|prices?|pricing|fees?|cost|costs)$',
    caseSensitive: false,
  ).hasMatch(lo)) {
    return true;
  }
  if (looksLikeProcedureNameAsClinicIdentity(t)) return true;
  if (looksLikeCountryMarketPriceMarketing(t)) return true;
  if (looksLikePricingProseProcedureTitle(t)) return true;
  if (RegExp(
    r'^(?:breast|botox|filler|rhinoplast|chemical\s+peel|hair\s+transplant).{0,40}'
    r'(?:prices?|cost|tirana|london|paris|dubai|albania)\b',
    caseSensitive: false,
  ).hasMatch(lo)) {
    return true;
  }
  if (RegExp(
    r'\bprices?\s+and\s+clinics\b|\bclinics?\s+in\s+\w+\b|'
    r'\bprocedures?\s+in\s+\w+\b',
    caseSensitive: false,
  ).hasMatch(lo)) {
    return true;
  }
  final cityFold = foldExploreCityText(city);
  final titleFold = foldExploreCityText(t);
  if (cityFold.isNotEmpty && titleFold == cityFold) return true;
  // Title is only a city name (with optional country).
  if (RegExp(
    r'^(?:brasov|brașov|braşov|timisoara|timișoara|bucharest|bucurești|'
    r'chisinau|chișinău|iasi|iași|cluj)(?:\s*,?\s*\w+)?$',
    caseSensitive: false,
  ).hasMatch(lo)) {
    return true;
  }
  return false;
}

bool exploreClinicNameLooksLikeSeoHeadline(String title) {
  final lo = title.toLowerCase().trim();
  if (lo.length < 3) return true;
  if (looksLikeSeoQuotedPriceHeadline(title) ||
      looksLikeBarePriceLabel(title) ||
      looksLikePriceQuotedClinicName(title) ||
      looksLikeSearchQuickFactsBlob(title) ||
      exploreClinicNameLooksLikeCategoryOrServiceTitle(title)) {
    return true;
  }
  const ads = [
    'precio',
    'precios',
    'price',
    'prices',
    'starts at',
    'starting at',
    'oferta',
    'tratamiento',
    'tratamientos',
    'arrugas de',
    'arrugas',
    'expresión',
    'expresion',
    'zonas',
    'botox treatment',
    'dermal filler',
    'hair transplant',
    'injerto',
    'trasplante',
    'depilaci',
    'peeling',
    'rinoplast',
    'best ',
    'aumento de labios',
    'aumento de pecho',
    'acido hialuron',
    'ácido hialurón',
    'relleno de',
    'en barcelona',
    'en madrid',
    'in barcelona',
    'masseter',
    'bruxism',
    'bruxismo',
    'lip lift',
    'toxina botul',
    'preț',
    'preturi',
    'pret ',
    ' marire buze',
    'mărire buze',
    'acid hialuronic',
    'acid hialuron',
    'tarife',
    'epilare definitiva',
    'epilare definit',
    'epilare laser',
    'cu laser din',
    'nasul potrivit',
    'piele straluc',
    'piele străluc',
    'interval de preț',
    'interval de pret',
  ];
  if (ads.any(lo.contains) &&
      !lo.contains('clinic') &&
      !lo.contains('clínic') &&
      !lo.contains('clinica') &&
      !RegExp(r'\bdr\.?\b').hasMatch(lo)) {
    return true;
  }
  return false;
}

/// Category / menu page titles scraped as the clinic card ("Cosmetologie",
/// "Aesthetic cosmetology procedures"). Prefer the website brand instead.
bool exploreClinicNameLooksLikeCategoryOrServiceTitle(String title) {
  final t = decodeExploreHtmlEntities(title).replaceAll('\u00a0', ' ').trim();
  if (t.isEmpty) return true;
  final lo = foldExploreIdentityText(t)
      .replaceAll(RegExp(r'[^a-z0-9 ]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (lo.isEmpty) return true;

  // Real clinic brands usually carry a proper name cue.
  if (RegExp(
    r'\b(clinic|clinica|clinique|klinik|hospital|centre|center|medspa|'
    r'doctor|dra?|md)\b',
  ).hasMatch(lo)) {
    return false;
  }

  const categoryOnly = {
    'cosmetologie',
    'cosmetology',
    'cosmetics',
    'cosmetic',
    'dermatologie',
    'dermatology',
    'estetica',
    'estetika',
    'aesthetic',
    'esthetics',
    'peeling',
    'peelings',
    'peels',
    'filler',
    'fillers',
    'botox',
    'services',
    'servicii',
    'procedures',
    'procedure',
    'treatments',
    'treatment',
    'tratamente',
    'tratament',
    'products',
    'product',
    'produse',
  };
  final tokens = lo.split(' ').where((w) => w.isNotEmpty).toList();
  if (tokens.length == 1 && categoryOnly.contains(tokens.first)) {
    return true;
  }
  if (tokens.every(categoryOnly.contains)) return true;

  // "Aesthetic cosmetology procedures", "Buy Cosmetics and Products…"
  if (RegExp(
    r'\b(procedures?|treatments?|services?|servicii|tratamente|products?|'
    r'produse|cosmetics?)\b',
  ).hasMatch(lo)) {
    final brandish = tokens.where(
      (w) =>
          !categoryOnly.contains(w) &&
          !const {
            'and',
            'or',
            'the',
            'in',
            'at',
            'for',
            'with',
            'of',
            'a',
            'an',
          }.contains(w),
    );
    if (brandish.isEmpty) return true;
  }
  if (RegExp(r'^(buy|shop|online|catalog|catalogue|magazin)\b').hasMatch(lo)) {
    return true;
  }
  return false;
}

/// Landing-page slogans ("Nasul Potrivit Fetei Tale") are not clinic brands.
bool exploreClinicNameLooksLikeMarketingSlogan(String title) {
  final t = title.replaceAll('\u00a0', ' ').trim();
  if (t.isEmpty) return false;
  final lo = foldExploreIdentityText(t);
  if (lo.contains('potrivit') ||
      lo.contains('stralucit') ||
      lo.contains('fetei tale') ||
      lo.contains('pentru tine') ||
      lo.contains('visul tau')) {
    return true;
  }
  final clinicCue =
      lo.contains('clinic') ||
      lo.contains('clinique') ||
      lo.contains('doctor') ||
      RegExp(r'\bdr\.?\b').hasMatch(t.toLowerCase());
  if (t.contains('&') && !clinicCue) return true;
  final words = t.split(RegExp(r'\s+'));
  return words.length >= 4 && !clinicCue;
}

/// Host-only labels ("Clinicpoint") and Serp titles ("Aumento de labios…")
/// still need a Google Maps business name.
bool exploreClinicNameNeedsMapsRefresh(OpenAIClinic c) {
  final name = c.name.trim();
  if (name.isEmpty) return true;
  if (exploreClinicNameLooksLikeSeoHeadline(name)) return true;
  if (exploreClinicNameLooksLikeMarketingSlogan(name)) return true;
  if (exploreClinicNameLooksPackedFromHost(c)) return true;
  final hostBrand = exploreClinicBrandFromHost(exploreClinicWebsiteHost(c));
  if (hostBrand.isEmpty) return false;
  final compactName = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  final compactHost = hostBrand.toLowerCase().replaceAll(
    RegExp(r'[^a-z0-9]'),
    '',
  );
  return compactName.length >= 5 && compactName == compactHost;
}

/// Card title: Google business / website brand — never the Serp SEO snippet
/// or the procedure name ("Botox treatment").
String exploreClinicDisplayName(OpenAIClinic c) {
  final listing = marketplaceListingBusinessNameFromUrl(
    c.priceSourceUrl.trim().isNotEmpty ? c.priceSourceUrl : c.area,
  );
  if (listing.isNotEmpty) return listing;
  final name = c.name.trim();
  if (isMarketplaceBrandName(name)) return '';
  final fromHost = exploreClinicBrandFromHost(exploreClinicWebsiteHost(c));
  if (name.isEmpty ||
      looksLikeBarePriceLabel(name) ||
      looksLikePriceQuotedClinicName(name) ||
      looksLikeSeoQuotedPriceHeadline(name) ||
      looksLikeSearchQuickFactsBlob(name) ||
      exploreClinicNameLooksLikeCategoryOrServiceTitle(name)) {
    return fromHost.isNotEmpty ? fromHost : '';
  }
  const procedureTitles = {
    'botox treatment',
    'dermal filler',
    'hair transplant',
    'chemical peel',
    'laser',
    'rhinoplasty',
    'breast augmentation',
  };
  if (exploreClinicNameLooksLikeSeoHeadline(name) ||
      exploreClinicNameLooksLikeMarketingSlogan(name) ||
      procedureTitles.contains(name.toLowerCase())) {
    return fromHost.isNotEmpty ? fromHost : name;
  }
  // "Elenamartin" from the domain is not the public clinic name.
  if (fromHost.isNotEmpty && exploreClinicNameLooksPackedFromHost(c)) {
    return fromHost;
  }
  return name;
}

OpenAIClinic withExploreClinicDisplayName(OpenAIClinic c) {
  final display = exploreClinicDisplayName(c);
  if (display.isEmpty) return c;
  final provider = c.providerClinic.trim().isNotEmpty
      ? c.providerClinic
      : (isMarketplaceOrDirectoryHost(c.priceSourceUrl) ||
                isMarketplaceOrDirectoryHost(c.area)
            ? display
            : c.providerClinic);
  if (display == c.name && provider == c.providerClinic) return c;
  return c.copyWith(name: display, providerClinic: provider);
}

/// A page revalidation that explicitly rejected the amount. The previous
/// verified flag on the cached card is not evidence anymore.
bool exploreRevalidationRemovesCard(OpenAIClinic revalidated) {
  return revalidated.priceRejectionReason.trim().isNotEmpty;
}

/// Lowercase, strip punctuation / legal suffixes so Places can match
/// "TajClinic SRL" when Maps only knows "TajClinic".
String _normalizeClinicNameForPlaces(String raw) {
  var n = raw.toLowerCase().trim();
  n = n.replaceAll(RegExp(r'[^\w\sà-ÿăâîșțÁ-ÝĂÂÎȘȚ]+'), ' ');
  n = n.replaceAll(RegExp(r'\s+'), ' ').trim();
  const suffixes = <String>[
    ' srl d',
    ' srl-d',
    ' srl',
    ' sa',
    ' pfa',
    ' ltd',
    ' llc',
    ' gmbh',
    ' inc',
    ' spa',
    ' s.r.l',
    ' clinic',
    ' clinique',
    ' clinica',
    ' cabinet medical',
    ' cabinet',
  ];
  var changed = true;
  while (changed) {
    changed = false;
    for (final s in suffixes) {
      if (n.endsWith(s)) {
        n = n.substring(0, n.length - s.length).trim();
        changed = true;
        break;
      }
    }
  }
  return n;
}

/// Explore Top Clinics: paint up to 4 verified Firestore clinics immediately.
/// Background finds fresh clinics into the shared pool per [planExplorePoolMix].
/// Do **not** bump this for price/currency extraction fixes — that empties
/// the clinic pool.
const kExploreComparisonCacheRevision = 'v39';

const _kExploreComparisonPreviousRevisions = [
  'v38',
  'v37',
  'v34',
  'v33',
  'v32',
];

const kExploreCompareMinClinics = kExploreCompareGoodEnough;
const kExploreCompareMaxClinics = ExplorePriceDiscoveryTool.compareDisplayLimit;

/// Keep the fill session / progress listener alive while under the visible
/// target (or under live Google slots) and background work is still pending.
///
/// Critical: [pricedFinal] is total visible cards; [liveGoogleTarget] is only
/// the number of *new* live slots. Comparing them directly freezes at
/// Firestore=2 + Google=0 when liveTarget=2 (2 < 2 is false).
bool exploreFillShouldKeepTopUpAlive({
  required int pricedFinal,
  required int uiVisibleTarget,
  required int googleShownCount,
  required int liveGoogleTarget,
  required bool hasPendingBackgroundWork,
  required bool paused,
  bool isPreviewFill = false,
}) {
  if (paused || isPreviewFill) return false;
  if (!hasPendingBackgroundWork) return false;
  // Visible target already met — do not keep searching for leftover live slots.
  if (pricedFinal >= uiVisibleTarget) return false;
  final visibleUnderTarget = pricedFinal < uiVisibleTarget;
  final liveUnderTarget = googleShownCount < liveGoogleTarget;
  return visibleUnderTarget || liveUnderTarget;
}

/// Mark Google/search mix complete only when the visible target is reached
/// or discovery is truly exhausted — never because `!isPreviewFill`.
bool exploreFillShouldMarkMixComplete({
  required int pricedFinal,
  required int uiVisibleTarget,
  required bool paused,
  required bool isPreviewFill,
  required bool trulyExhausted,
}) {
  if (paused || isPreviewFill) return false;
  if (pricedFinal >= uiVisibleTarget) return true;
  return trulyExhausted;
}

/// Preferred saved slots while the background worker searches for new clinics.
const kExploreFirestoreSeedClinics = ExplorePriceDiscoveryTool.compareStoredTarget;

/// At least two new clinics; an empty market searches for all visible slots.
const kExploreGoogleClinics = ExplorePriceDiscoveryTool.compareFreshTarget;
const kExploreAiFreshClinicsMin = kExploreGoogleClinics;
const kExploreAiFreshClinics = kExploreGoogleClinics;

/// Hard cap for the shared city+procedure verified clinic pool.
const kExploreFirestorePoolMax = 30;

class _ExplorePersistJob {
  const _ExplorePersistJob({
    required this.city,
    required this.procedure,
    required this.metaSource,
    required this.priced,
    required this.reason,
  });

  final String city;
  final String procedure;
  final OpenAIComparisonResult metaSource;
  final List<OpenAIClinic> priced;
  final String reason;
}

/// Broad Explore filter pills — never use as card titles.
const kBroadExplorePills = {
  'All',
  'Botox',
  'Fillers',
  'Laser',
  'Hair removal',
  'Skin laser',
  'Peels',
  'Skin',
  'Rhinoplasty',
  'Boob job',
  'Hair',
};

/// City Compare tabs that should show different clinics from each other.
const kExploreComparePills = <String>[
  'Botox',
  'Fillers',
  'Peels',
  'Rhinoplasty',
  'Boob job',
  'Hair',
];

/// Maps a saved/legacy pill onto the current Compare tab.
String exploreCanonicalComparePill(String pill) {
  switch (pill.trim()) {
    case 'Laser':
    case 'Hair removal':
    case 'Skin laser':
    case 'Laser skin':
      return 'Laser';
    default:
      return pill.trim();
  }
}

/// Retired Laser / All tabs are no longer in the Compare strip.
String exploreVisibleComparePill(String pill) {
  switch (pill.trim()) {
    case 'All':
      return 'Botox';
    case 'Laser':
    case 'Hair removal':
    case 'Skin laser':
    case 'Laser skin':
      return 'Hair';
    default:
      return pill.trim().isEmpty ? 'Botox' : pill.trim();
  }
}

bool isBroadExploreCategoryName(String name) {
  final t = name.trim();
  if (t.isEmpty) return false;
  if (kBroadExplorePills.contains(t)) return true;
  final lo = t.toLowerCase();
  for (final pill in kBroadExplorePills) {
    if (lo == pill.toLowerCase()) return true;
  }
  return false;
}

/// Coarse treatment family so Laser/Botox rows cannot land on Fillers.
enum ExploreTreatmentFamily {
  botox,
  filler,
  laser,
  peel,
  skin,
  rhinoplasty,
  hair,
  breast,
  other,
}

ExploreTreatmentFamily exploreTreatmentFamily(String raw) {
  final t = raw.toLowerCase().trim();
  if (t.isEmpty) return ExploreTreatmentFamily.other;

  bool has(String s) => t.contains(s);
  bool hasLocal(String family) {
    for (final token in exploreLocalProcedureTokens(family)) {
      if (token.length < 5) continue;
      if (has(token)) return true;
    }
    return false;
  }

  if (has('lip flip') || has('lipflip') || has('gummy smile')) {
    return ExploreTreatmentFamily.botox;
  }
  if (has('anti-wrinkle') ||
      has('antiwrinkle') ||
      has('anti wrinkle') ||
      has('wrinkle-relax') ||
      has('wrinkle relax') ||
      has('wrinkle relaxing')) {
    return ExploreTreatmentFamily.botox;
  }

  // Arabic menu / Google names (Dubai, Riyadh, Cairo, …).
  if (has('فيلر') || has('حمض الهيالورونيك') || has('هيالورونيك')) {
    return ExploreTreatmentFamily.filler;
  }
  if (has('بوتوكس')) return ExploreTreatmentFamily.botox;
  if (has('تقشير')) return ExploreTreatmentFamily.peel;
  if (has('تجميل الانف') ||
      has('تجميل الأنف') ||
      has('رأب الأنف') ||
      has('راب الانف')) {
    return ExploreTreatmentFamily.rhinoplasty;
  }
  if (has('تكبير الثدي') || has('تكبير الصدر') || has('زراعة الثدي')) {
    return ExploreTreatmentFamily.breast;
  }
  if (has('زراعة الشعر')) return ExploreTreatmentFamily.hair;
  if ((has('ليزر') || has('الليزر')) &&
      (has('شعر') || has('ازالة') || has('إزالة'))) {
    return ExploreTreatmentFamily.laser;
  }

  if (has('lip augmentation') ||
      has('lip filler') ||
      has('marire buze') ||
      has('mărire buze') ||
      has('volumizare buze') ||
      has('aumento de labios')) {
    return ExploreTreatmentFamily.filler;
  }

  final laserHair =
      has('hair removal') ||
      has('epilare') ||
      has('epilat') ||
      has('epil') ||
      has('laser hair') ||
      has('diode') ||
      has('alexandrite') ||
      has('ipl') ||
      has('photo rejuvenation') ||
      has('photorejuvenation') ||
      has('photofacial') ||
      has('byonik') ||
      (has('laser') &&
          (has('forearm') ||
              has('underarm') ||
              has('bikini') ||
              has('axila') ||
              has('mustat') ||
              has('full body')));
  if (laserHair && !has('filler') && !has('botox') && !has('transplant')) {
    return ExploreTreatmentFamily.laser;
  }
  if ((has('laser') || has('fraxel') || has('co2') || hasLocal('laser')) &&
      !has('filler') &&
      !has('botox') &&
      !has('toxin') &&
      !has('hyaluron') &&
      !has('hialuron')) {
    return ExploreTreatmentFamily.laser;
  }

  if (has('fue') ||
      has('dhi') ||
      has('hair transplant') ||
      has('graft') ||
      has('transplant de par') ||
      has('transplant păr') ||
      has('implant de par') ||
      has('implant par') ||
      hasLocal('hair')) {
    return ExploreTreatmentFamily.hair;
  }

  // Device / regenerative — not a chemical peel.
  if (has('hifu') ||
      has('ultraformer') ||
      has('ulthera') ||
      has('ultrasound') ||
      has('microneedl') ||
      has('dermapen') ||
      has('skinpen') ||
      has('radiofrequen') ||
      has('radiofrecven') ||
      has('pbserum') ||
      RegExp(r'\brf\b').hasMatch(t)) {
    return ExploreTreatmentFamily.skin;
  }

  if (has('botox') ||
      has('botulin') ||
      has('toxina') ||
      has('toxină') ||
      has('dysport') ||
      has('xeomin') ||
      has('azzalure') ||
      has('neuromodul') ||
      hasLocal('botox')) {
    if (!has('filler') && !has('hyaluron') && !has('hialuron')) {
      return ExploreTreatmentFamily.botox;
    }
  }

  if (has('filler') ||
      has('juvederm') ||
      has('restylane') ||
      has('teosyal') ||
      has('hyaluron') ||
      has('hialuron') ||
      has('relleno') ||
      has('acid hialuronic') ||
      hasLocal('filler')) {
    return ExploreTreatmentFamily.filler;
  }

  if (has('peel') ||
      has('peeling') ||
      has('tca') ||
      has('glycolic') ||
      has('jessner') ||
      has('mandelic') ||
      has('peeling chimic') ||
      hasLocal('peel')) {
    return ExploreTreatmentFamily.peel;
  }
  if (has('rhino') ||
      has('nose job') ||
      has('rinoplast') ||
      hasLocal('rhinoplasty')) {
    return ExploreTreatmentFamily.rhinoplasty;
  }
  // Urology / genital implants are not a boob job.
  if (has('testicul') ||
      has('testicle') ||
      has('scrot') ||
      has('penil') ||
      has('penile') ||
      has('glans')) {
    return ExploreTreatmentFamily.other;
  }
  // Cancer reconstruction is not an aesthetic boob job (Paris was showing
  // "latissimus dorsi flap" as the only Boob job card).
  if (_exploreTextIsBreastReconstruction(t)) {
    return ExploreTreatmentFamily.other;
  }
  if (_exploreTextIsAestheticBreast(t) || hasLocal('breast')) {
    return ExploreTreatmentFamily.breast;
  }
  if (has('profhilo') ||
      has('skin booster') ||
      has('polynucleotid') ||
      has('hidratare') ||
      has('rehydra') ||
      has('hydrafacial') ||
      hasLocal('skin')) {
    return ExploreTreatmentFamily.skin;
  }

  return ExploreTreatmentFamily.other;
}

/// Core scrape keyword for any Explore pill (Botox, Laser, Skin, …).
String? exploreCoreKeywordForProcedure(String procedure) {
  final normalizedProc = procedure.toLowerCase().trim();
  const entries = <String, String>{
    'hair transplant': 'hair transplant',
    'transplant de par': 'hair transplant',
    'implant capilar': 'hair transplant',
    'injerto capilar': 'hair transplant',
    'fue': 'hair transplant',
    'dhi': 'hair transplant',
    'lip filler': 'filler',
    'acid hialuronic': 'filler',
    'acid buze': 'filler',
    'filler buze': 'filler',
    'marire buze': 'filler',
    'mărire buze': 'filler',
    'volumizare buze': 'filler',
    'contur buze': 'filler',
    'prp': 'prp',
    'botox': 'botox',
    'filler': 'filler',
    'hifu': 'hifu',
    'laser': 'laser',
    'epilare': 'laser',
    'depilacion': 'laser',
    'depilación': 'laser',
    'hair removal': 'laser',
    'microneedling': 'microneedling',
    'dermapen': 'dermapen',
    'mesotherapy': 'mesotherapy',
    'morpheus': 'morpheus',
    'thread': 'thread',
    'polynucleotide': 'polynucleotide',
    'polinucleotide': 'polynucleotide',
    'exosome': 'exosome',
    'skinbooster': 'skin',
    'skin booster': 'skin',
    'profhilo': 'skin',
    'sculptra': 'sculptra',
    'chemical peel': 'peel',
    'chemical': 'peel',
    'peeling': 'peel',
    'peel': 'peel',
    'rhinoplasty': 'rhinoplasty',
    'rinoplast': 'rhinoplasty',
    'nose job': 'rhinoplasty',
    'breast augmentation': 'breast',
    'boob job': 'breast',
    'marire sani': 'breast',
    'mărire sâni': 'breast',
    'implant mamar': 'breast',
    'implanturi mamare': 'breast',
    'augmentare mamară': 'breast',
    'aumento de pecho': 'breast',
    'aumento pecho': 'breast',
    'aumento mamario': 'breast',
    'hydrafacial': 'skin',
  };
  for (final entry in entries.entries) {
    if (normalizedProc.contains(entry.key)) return entry.value;
  }
  return switch (exploreTreatmentFamily(procedure)) {
    ExploreTreatmentFamily.botox => 'botox',
    ExploreTreatmentFamily.filler => 'filler',
    ExploreTreatmentFamily.laser => 'laser',
    ExploreTreatmentFamily.peel => 'peel',
    ExploreTreatmentFamily.skin => 'skin',
    ExploreTreatmentFamily.rhinoplasty => 'rhinoplasty',
    ExploreTreatmentFamily.hair => 'hair transplant',
    ExploreTreatmentFamily.breast => 'breast',
    ExploreTreatmentFamily.other => null,
  };
}

/// Maps scrape core keywords to Explore treatment families for local synonyms.
String? exploreFamilyNameForCoreKeyword(String coreKeyword) {
  return switch (coreKeyword.trim().toLowerCase()) {
    'botox' => 'botox',
    'filler' => 'filler',
    'laser' => 'laser',
    'peel' => 'peel',
    'skin' => 'skin',
    'rhinoplasty' => 'rhinoplasty',
    'hair transplant' => 'hair',
    'breast' => 'breast',
    'hifu' ||
    'microneedling' ||
    'dermapen' ||
    'mesotherapy' ||
    'morpheus' ||
    'thread' ||
    'exosome' ||
    'skinbooster' ||
    'profhilo' ||
    'sculptra' ||
    'polynucleotide' ||
    'prp' => 'skin',
    _ => null,
  };
}

/// English + multilingual synonyms for menu-row matching on clinic sites.
List<String> exploreSynonymsForCoreKeyword(
  String coreKeyword, {
  Map<String, List<String>>? extra,
}) {
  final ck = coreKeyword.trim().toLowerCase();
  final base = extra?[ck] ?? _kExploreCoreSynonyms[ck] ?? const <String>[];
  final fam = exploreFamilyNameForCoreKeyword(ck);
  if (fam == null) return base;
  return {...base, ...exploreLocalProcedureTokens(fam)}.toList(growable: false);
}

const _kExploreCoreSynonyms = <String, List<String>>{
  'skin': [
    'profhilo',
    'skin booster',
    'skinbooster',
    'polynucleotide',
    'polinucleotide',
    'pdrn',
    'hydrafacial',
    'biostimulator',
    'biostimul',
    'mesotherapy',
    'mezoterapie',
    'exosome',
    'exozom',
    'volite',
    'sunekos',
    'jalupro',
  ],
};

bool _exploreTextIsBreastReconstruction(String raw) {
  final t = raw.toLowerCase();
  return t.contains('reconstruct') ||
      t.contains('latissimus') ||
      t.contains('grand dorsal') ||
      t.contains('dorsi flap') ||
      t.contains('diep') ||
      t.contains('tram flap') ||
      t.contains('mastectom') ||
      t.contains('après cancer') ||
      t.contains('apres cancer') ||
      t.contains('after cancer') ||
      t.contains('post-cancer') ||
      t.contains('post cancer');
}

/// Aesthetic breast enlargement / implants, including French "mammaire"
/// (which does not contain Romanian "mamar", so Paris clinics were dropped).
bool _exploreTextIsAestheticBreast(String raw) {
  final t = raw.toLowerCase();
  return t.contains('breast') ||
      t.contains('boob') ||
      t.contains('mammaire') ||
      t.contains('mammaires') ||
      t.contains('mamar') ||
      t.contains('mastopex') ||
      t.contains('mamoplast') ||
      t.contains('mastoplast') ||
      t.contains('marire san') ||
      t.contains('mărire sân') ||
      t.contains('aumento de pecho') ||
      t.contains('aumento mamario') ||
      t.contains('aumento seno') ||
      t.contains('aumento de mamas');
}

const _kExploreBreastOfferKeywords = <String>[
  'breast augmentation',
  'breast implant',
  'breast implants',
  'augmentation mammaire',
  'prothèse mammaire',
  'prothese mammaire',
  'prothèses mammaires',
  'implant mammaire',
  'implants mammaires',
  'pose de prothèse',
  'lipofilling mammaire',
  'mammaire',
  'mammaires',
  'mastoplastica',
  'aumento de pecho',
  'aumento mamario',
  'aumento seno',
  'implant mamar',
  'implanturi mamare',
  'marire sani',
  'marire de sani',
  'marirea sanilor',
  'mărire sâni',
  'endoprotez',
  'proteza mamara',
  'breast',
  'mamar',
  'mastopex',
  'mamoplast',
];

/// Map stored extractor family ids (`chemical_peel`) onto Explore pills.
ExploreTreatmentFamily exploreFamilyFromStoredId(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'botox':
      return ExploreTreatmentFamily.botox;
    case 'filler':
    case 'lip_filler':
    case 'dermal_filler':
      return ExploreTreatmentFamily.filler;
    case 'laser':
      return ExploreTreatmentFamily.laser;
    case 'peel':
    case 'chemical_peel':
      return ExploreTreatmentFamily.peel;
    case 'rhinoplasty':
      return ExploreTreatmentFamily.rhinoplasty;
    case 'breast':
    case 'breast_augmentation':
      return ExploreTreatmentFamily.breast;
    case 'hair':
    case 'hair_transplant':
      return ExploreTreatmentFamily.hair;
    case 'skin':
    case 'skin_booster':
      return ExploreTreatmentFamily.skin;
    default:
      return ExploreTreatmentFamily.other;
  }
}

bool _procedureLabelLacksFamilySignal(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return true;
  if (looksLikeBarePriceLabel(t) || looksLikeCommerceChromeLabel(t)) {
    return true;
  }
  final lo = t.toLowerCase();
  return RegExp(
    r'^(price|prices|pricing|cost|costs|from)(\b|$)',
    caseSensitive: false,
  ).hasMatch(lo);
}

/// False when the clinic card is clearly a different treatment than the search.
///
/// Curated rows were already bucketed by family at import time. A Motiva or
/// "Gummy Smile Tox" label must still count for its pill even when the live
/// matcher is pickier than the audit.
bool exploreClinicFitsCompareProcedure(OpenAIClinic c, String procedure) {
  final proc = procedure.trim();
  final label = '${c.rawProcedureText} ${c.brand}'.trim();
  if (exploreTreatmentFamily(proc) == ExploreTreatmentFamily.filler &&
      looksLikeFillerDissolvingLabel(label)) {
    return false;
  }
  if (exploreClinicMatchesProcedure(c, proc)) return true;
  if (!exploreCuratedPriceIsTrusted(c)) return false;
  final keys = exploreCuratedFamilyKeys(proc);
  final fam = c.procedureFamily.trim();
  return keys.isNotEmpty && keys.contains(fam);
}

/// False when the clinic card is clearly a different treatment than the search.
bool exploreClinicMatchesProcedure(OpenAIClinic c, String procedure) {
  final proc = procedure.trim();
  if (proc.isEmpty || proc.toLowerCase() == 'all') return true;
  final want = exploreTreatmentFamily(proc);
  if (want == ExploreTreatmentFamily.other) return true;

  bool matchesWant(ExploreTreatmentFamily got, [String label = '']) {
    if (got != want &&
        !(want == ExploreTreatmentFamily.breast &&
            got == ExploreTreatmentFamily.breast)) {
      return false;
    }
    if (want == ExploreTreatmentFamily.laser && label.trim().isNotEmpty) {
      return exploreLaserRowFitsRequest(label: label, procedure: proc);
    }
    return true;
  }

  // Website row first — brand "Botox treatment" must not keep a laser/filler row.
  final raw = c.rawProcedureText.trim();
  if (raw.isNotEmpty && !_procedureLabelLacksFamilySignal(raw)) {
    final rawFam = exploreTreatmentFamily(raw);
    if (rawFam != ExploreTreatmentFamily.other) {
      return matchesWant(rawFam, raw);
    }
  }

  final storedFam = exploreFamilyFromStoredId(c.procedureFamily);
  if (storedFam != ExploreTreatmentFamily.other) {
    return matchesWant(storedFam, raw.isNotEmpty ? raw : c.brand);
  }
  final canonicalFam = exploreFamilyFromStoredId(c.procedureCanonical);
  if (canonicalFam != ExploreTreatmentFamily.other) {
    return matchesWant(canonicalFam, raw.isNotEmpty ? raw : c.brand);
  }

  final brand = c.brand.trim();
  if (brand.isNotEmpty && !_procedureLabelLacksFamilySignal(brand)) {
    final brandFam = exploreTreatmentFamily(brand);
    if (brandFam != ExploreTreatmentFamily.other) {
      return matchesWant(brandFam, brand);
    }
  }

  final got = exploreTreatmentFamily('${c.priceLabel} ${c.name}');
  if (matchesWant(got, '${c.priceLabel} ${c.brand} ${c.rawProcedureText}')) {
    return true;
  }
  // Named Explore pills need a matching treatment label, not a clinic name.
  return false;
}

/// Procedure name as locals would type it into Google (plus English).
List<String> exploreProcedureLocalSearchNames(String procedure, String lang) {
  return exploreProcedureNamesForLang(
    exploreTreatmentFamily(procedure).name,
    lang,
  );
}

/// Short topic used in "Find pages relevant to {topic} prices in {city}".
String exploreProcedurePriceTopic(String procedure, [String pill = '']) {
  switch (pill.trim()) {
    case 'Botox':
      return 'Botox';
    case 'Fillers':
      return 'dermal filler';
    case 'Laser':
    case 'Hair removal':
    case 'Skin laser':
      return 'laser skin rejuvenation';
    case 'Peels':
      return 'chemical peel';
    case 'Rhinoplasty':
      return 'rhinoplasty';
    case 'Boob job':
      return 'breast augmentation';
    case 'Hair':
      return 'hair transplant';
    case 'Skin':
      return 'skin booster';
  }
  final fam = exploreTreatmentFamily(procedure);
  return switch (fam) {
    ExploreTreatmentFamily.botox => 'Botox',
    ExploreTreatmentFamily.filler => 'dermal filler',
    ExploreTreatmentFamily.laser =>
      exploreLaserRequestedSubtype(procedure) == 'hair'
          ? 'laser hair removal'
          : 'laser skin rejuvenation',
    ExploreTreatmentFamily.peel => 'chemical peel',
    ExploreTreatmentFamily.rhinoplasty => 'rhinoplasty',
    ExploreTreatmentFamily.breast => 'breast augmentation',
    ExploreTreatmentFamily.hair => 'hair transplant',
    _ => procedure.trim().isEmpty ? 'aesthetic treatment' : procedure.trim(),
  };
}

/// Broad city×procedure SERP queries (no `site:`) for discovering new clinics.
/// Official-domain verification still owns the price — Serper only finds leads.
List<String> buildBroadProcedureDiscoveryQueries({
  required String city,
  required String procedure,
  String pill = '',
  String countryCode = '',
  int maxQueries = 6,
}) {
  final c = city.trim();
  final proc = procedure.trim();
  if (c.isEmpty || proc.isEmpty) return const [];
  final loc = exploreCityPriceSearchTerms(c, countryCode: countryCode);
  final priceWord = loc.priceWords.isNotEmpty ? loc.priceWords.first : 'price';
  final clinicWord = loc.clinicWord.trim().isEmpty
      ? 'clinic'
      : loc.clinicWord.trim();
  final localNames = exploreProcedureLocalSearchNames(proc, loc.lang);
  final topic = exploreProcedurePriceTopic(proc, pill);
  final out = <String>[];
  void add(String raw) {
    if (out.length >= maxQueries) return;
    final q = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (q.isEmpty) return;
    final lo = q.toLowerCase();
    if (out.any((e) => e.toLowerCase() == lo)) return;
    out.add(q);
  }

  add('"$topic" $c $priceWord');
  add('"$topic" $c $clinicWord $priceWord');
  for (final alias in localNames.take(3)) {
    add('"$alias" $c $priceWord');
  }
  final folded = foldExploreCityText(topic);
  if (folded.contains('breast') || folded.contains('boob')) {
    add('"breast implants" $c $priceWord');
  }
  add('$topic prices in $c');
  return out;
}

/// English + local-language Compare queries. Translation is optional and
/// applied by [buildLocalizedComparisonQueries] when curated names are missing.
List<String> exploreLocalizedSearchQueries({
  required String procedure,
  required String city,
  String pill = '',
  String? translatedFallback,
  String countryCode = '',
  int maxQueries = 6,
}) {
  final c = city.trim();
  if (c.isEmpty) return const [];
  final topic = exploreProcedurePriceTopic(procedure, pill);
  final loc = exploreCityPriceSearchTerms(c, countryCode: countryCode);
  final localNames = exploreProcedureLocalSearchNames(procedure, loc.lang);
  final priceWord = loc.priceWords.isNotEmpty ? loc.priceWords.first : 'price';
  final clinicWord = loc.clinicWord.trim().isEmpty
      ? 'clinic'
      : loc.clinicWord.trim();
  final useLocalPrice =
      priceWord.toLowerCase() != 'price' && priceWord.toLowerCase() != 'prices';
  final preferLocal = explorePrefersLocalSearchFirst(loc.lang);
  final keepEnglish =
      loc.lang == 'en' || exploreKeepsEnglishAlongsideLocal(loc.lang);

  final out = <String>[];
  void add(String raw) {
    if (out.length >= maxQueries) return;
    final q = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (q.isEmpty) return;
    final lo = q.toLowerCase();
    if (out.any((e) => e.toLowerCase() == lo)) return;
    out.add(q);
  }

  void addLocal(String name) {
    if (name.trim().isEmpty) return;
    if (useLocalPrice) {
      add('$name $priceWord $c');
    } else {
      add('$name prices in $c');
    }
  }

  // Native language first, then English — every country gets both.
  if (preferLocal) {
    if (localNames.isNotEmpty) {
      addLocal(localNames.first);
      // Turkish: bounded high-quality fiyat/ücret pairs (not every alias).
      if (loc.lang == 'tr') {
        final primary = localNames.first;
        add('$c $primary fiyatları $clinicWord');
        add('$c $primary ücretleri');
        if (localNames.length > 1) {
          add('$c ${localNames[1]} fiyatları');
        }
      }
    } else if (translatedFallback != null) {
      addLocal(translatedFallback);
    }
    if (keepEnglish) add('$topic prices in $c');
    for (final name in localNames.skip(1).take(2)) {
      addLocal(name);
    }
  } else {
    add('$topic prices in $c');
    for (final name in localNames.take(2)) {
      addLocal(name);
    }
    if (translatedFallback != null) addLocal(translatedFallback);
  }
  if (translatedFallback != null && preferLocal) {
    addLocal(translatedFallback);
  }
  add('$clinicWord $topic $c');

  final pillQuery = pill.trim().isEmpty ? '' : explorePillAiSearchQuery(pill);
  if (pillQuery.isNotEmpty && pillQuery.toLowerCase() != topic.toLowerCase()) {
    add('$pillQuery prices in $c');
  }

  // Brand cues find clinic menus that generic "filler" misses (Juvederm,
  // Restylane, Teosyal, Radiesse…). Rotate daily so successive searches
  // diversify the candidate pool.
  final brandCues = exploreFillerBrandDiscoveryCues(
    procedure: procedure,
    pill: pill,
    topic: topic,
    lang: loc.lang,
  );
  if (brandCues.isNotEmpty) {
    final day = DateTime.now().toUtc().day;
    final brand = brandCues[day % brandCues.length];
    addLocal(brand);
    if (keepEnglish || loc.lang == 'en') {
      add('$brand filler prices in $c');
    }
  }
  // Peel brand / product cues (BioRePeel, PRX, Cosmelan, TCA) — same idea:
  // clinics publish branded peels without ranking for "chemical peel prices".
  final peelCues = explorePeelBrandDiscoveryCues(
    procedure: procedure,
    pill: pill,
    topic: topic,
    lang: loc.lang,
  );
  if (peelCues.isNotEmpty) {
    final day = DateTime.now().toUtc().day;
    final brand = peelCues[day % peelCues.length];
    addLocal(brand);
    if (keepEnglish || loc.lang == 'en') {
      add('$brand peel prices in $c');
      add('$brand prices in $c');
    }
  }
  return out;
}

/// HA / CaHA brands people type into Google when looking for filler prices.
List<String> exploreFillerBrandDiscoveryCues({
  required String procedure,
  String pill = '',
  String topic = '',
  String lang = 'en',
}) {
  final blob = '$procedure $pill $topic'.toLowerCase();
  final isFiller =
      blob.contains('filler') ||
      blob.contains('buze') ||
      blob.contains('hialuron') ||
      blob.contains('hyaluron') ||
      blob.contains('juvederm') ||
      blob.contains('restylane') ||
      blob.contains('teosyal') ||
      blob.contains('radiesse');
  if (!isFiller) return const [];
  if (lang == 'ro') {
    return const [
      'juvederm',
      'restylane',
      'teosyal',
      'belotero',
      'radiesse',
      'acid hialuronic juvederm',
    ];
  }
  return const [
    'juvederm',
    'restylane kysse',
    'teosyal',
    'belotero',
    'radiesse',
    'juvederm volbella',
  ];
}

/// Branded / named peels clinics publish on menus worldwide (not only Tirana).
List<String> explorePeelBrandDiscoveryCues({
  required String procedure,
  String pill = '',
  String topic = '',
  String lang = 'en',
}) {
  final blob = '$procedure $pill $topic'.toLowerCase();
  final isPeel =
      blob.contains('peel') ||
      blob.contains('peeling') ||
      blob.contains('qërimi') ||
      blob.contains('qerimi') ||
      blob.contains('пилинг') ||
      blob.contains('biorepeel') ||
      blob.contains('prx') ||
      blob.contains('cosmelan') ||
      blob.contains('glycolic') ||
      blob.contains('tca');
  if (!isPeel) return const [];
  if (lang == 'sq') {
    return const ['biorepeel', 'prx-t33', 'peeling kimik', 'cosmelan', 'tca'];
  }
  if (lang == 'ro') {
    return const ['biorepeel', 'prx-t33', 'peeling chimic', 'cosmelan', 'tca'];
  }
  return const [
    'BioRePeel',
    'PRX-T33',
    'Cosmelan',
    'TCA peel',
    'glycolic peel',
  ];
}

bool exploreSearchQueryLooksEnglish(String query) {
  final lo = query.toLowerCase();
  return lo.contains('prices in') ||
      lo.contains('price in') ||
      RegExp(r'\bprices\b').hasMatch(lo) ||
      RegExp(r'\bprice\b').hasMatch(lo);
}

/// The queries every Google/Places lookup must run: local language + English,
/// and for fillers a rotating brand cue when [maxPair] allows it.
List<String> exploreBilingualSearchPair({
  required String procedure,
  required String city,
  String pill = '',
  String countryCode = '',
  String? translatedFallback,
  int maxPair = 2,
}) {
  final want = maxPair < 1 ? 1 : (maxPair > 3 ? 3 : maxPair);
  final loc = exploreCityPriceSearchTerms(city, countryCode: countryCode);
  final all = exploreLocalizedSearchQueries(
    procedure: procedure,
    city: city,
    pill: pill,
    countryCode: countryCode,
    translatedFallback: translatedFallback,
    maxQueries: 10,
  );
  if (all.isEmpty) return const [];
  if (loc.lang == 'en' || !exploreKeepsEnglishAlongsideLocal(loc.lang)) {
    return all.take(want).toList();
  }
  String? localQ;
  String? englishQ;
  for (final q in all) {
    if (exploreSearchQueryLooksEnglish(q)) {
      englishQ ??= q;
    } else {
      localQ ??= q;
    }
    if (localQ != null && englishQ != null) break;
  }
  if (englishQ == null) {
    for (final q in all) {
      if (q != localQ) {
        englishQ = q;
        break;
      }
    }
  }
  final out = <String>[
    if (localQ != null) localQ,
    if (englishQ != null && englishQ != localQ) englishQ,
  ];
  // Third slot: brand / alternate local cue (Juvederm, Radiesse, …).
  if (want >= 3) {
    for (final q in all) {
      if (out.any((e) => e.toLowerCase() == q.toLowerCase())) continue;
      out.add(q);
      break;
    }
  }
  return out.take(want).toList();
}

/// Places: one local query + one English query (never two locals).
List<String> exploreBilingualPlacesPair({
  required String procedure,
  required String city,
  String pill = '',
  String countryCode = '',
}) {
  final c = city.trim();
  if (c.isEmpty) return const [];
  final loc = exploreCityPriceSearchTerms(c, countryCode: countryCode);
  final topic = exploreProcedurePriceTopic(procedure, pill);
  final localNames = exploreProcedureLocalSearchNames(procedure, loc.lang);
  final localName = localNames.isNotEmpty ? localNames.first : topic;
  final clinicWord = loc.clinicWord.trim().isEmpty
      ? 'clinic'
      : loc.clinicWord.trim();
  if (exploreKeepsEnglishAlongsideLocal(loc.lang)) {
    return ['$clinicWord $localName $c', '$topic clinic $c'];
  }
  return ['$topic clinic $c'];
}

List<String> exploreLocalizedPlacesQueries({
  required String procedure,
  required String city,
  String pill = '',
  String? translatedFallback,
  String countryCode = '',
  int maxQueries = 6,
}) {
  final c = city.trim();
  if (c.isEmpty) return const [];
  final topic = exploreProcedurePriceTopic(procedure, pill);
  final loc = exploreCityPriceSearchTerms(c, countryCode: countryCode);
  final localNames = exploreProcedureLocalSearchNames(procedure, loc.lang);
  final clinicWord = loc.clinicWord.trim().isEmpty
      ? 'clinic'
      : loc.clinicWord.trim();
  final priceWord = loc.priceWords.isNotEmpty ? loc.priceWords.first : 'prices';
  final preferLocal = explorePrefersLocalSearchFirst(loc.lang);
  final out = <String>[];
  void add(String raw) {
    if (out.length >= maxQueries) return;
    final q = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (q.isEmpty) return;
    final lo = q.toLowerCase();
    if (out.any((e) => e.toLowerCase() == lo)) return;
    out.add(q);
  }

  // Find clinics that publish a price, not generic aesthetic businesses.
  if (!preferLocal) {
    add('$topic prices in $c');
    add('$topic prices $c');
  }
  if (localNames.isNotEmpty) {
    add('${localNames.first} $priceWord $c');
    add('$clinicWord ${localNames.first} $c');
  }
  if (translatedFallback != null &&
      translatedFallback.trim().toLowerCase() != topic.toLowerCase()) {
    add('$translatedFallback $priceWord $c');
  }
  for (final name in localNames.skip(1).take(1)) {
    add('$name $priceWord $c');
  }
  add('$topic prices in $c');
  add('$clinicWord $topic $c');
  final fam = exploreTreatmentFamily(procedure);
  if (fam == ExploreTreatmentFamily.filler) {
    add('lip filler prices in $c');
    add('juvederm prices $c');
  } else if (fam == ExploreTreatmentFamily.botox) {
    add('dysport prices $c');
  } else if (fam == ExploreTreatmentFamily.laser) {
    add('laser hair removal prices $c');
  } else if (fam == ExploreTreatmentFamily.hair) {
    add('FUE hair transplant prices $c');
  } else if (fam == ExploreTreatmentFamily.peel) {
    add('chemical peel prices $c');
  } else if (fam == ExploreTreatmentFamily.rhinoplasty) {
    add('rhinoplasty cost $c');
  } else if (fam == ExploreTreatmentFamily.breast) {
    add('breast augmentation cost $c');
  }
  return out;
}

Future<String?> _translatedProcedureFallback({
  required String procedure,
  required String city,
  String pill = '',
  String countryCode = '',
}) async {
  final cc = countryCode.trim().isNotEmpty
      ? countryCode.trim().toUpperCase()
      : (ExploreBackendService.instance.activeCityIdentity?.countryCode ?? '');
  final loc = exploreCityPriceSearchTerms(city, countryCode: cc);
  final family = exploreTreatmentFamily(procedure).name;
  if (!exploreCuratedLocalNamesInsufficient(family: family, lang: loc.lang)) {
    return null;
  }
  final topic = exploreProcedurePriceTopic(procedure, pill);
  try {
    return await ExploreProcedureTranslationStore.instance
        .translateIfNeeded(canonical: topic, lang: loc.lang)
        .timeout(const Duration(seconds: 2));
  } catch (e) {
    debugPrint('[GP] Translation skipped — continuing without it: $e');
    return null;
  }
}

Future<List<String>> buildLocalizedComparisonQueries({
  required String procedure,
  required String city,
  String pill = '',
  String countryCode = '',
}) async {
  final cc = countryCode.trim().isNotEmpty
      ? countryCode.trim().toUpperCase()
      : (ExploreBackendService.instance.activeCityIdentity?.countryCode ?? '');
  final translated = await _translatedProcedureFallback(
    procedure: procedure,
    city: city,
    pill: pill,
    countryCode: cc,
  );
  final queries = exploreLocalizedSearchQueries(
    procedure: procedure,
    city: city,
    pill: pill,
    translatedFallback: translated,
    countryCode: cc,
  );
  debugPrint(
    '[GP] Localized search queries ($city · $procedure · cc=$cc): '
    '${queries.join(" · ")}',
  );
  return queries;
}

List<String> _placesClinicSearchQueries({
  required String procedure,
  required String city,
  String pill = '',
  String? translatedFallback,
}) {
  return exploreLocalizedPlacesQueries(
    procedure: procedure,
    city: city,
    pill: pill,
    translatedFallback: translatedFallback,
  );
}

List<String> _placesExtraPriceQueries({
  required String procedure,
  required String city,
  String pill = '',
}) {
  final c = city.trim();
  if (c.isEmpty) return const [];
  final fam = exploreTreatmentFamily(procedure);
  return switch (fam) {
    ExploreTreatmentFamily.filler => [
      'lip filler prices in $c',
      'juvederm prices $c',
      'restylane clinic $c',
    ],
    ExploreTreatmentFamily.botox => ['dysport prices $c', 'xeomin clinic $c'],
    ExploreTreatmentFamily.laser => ['laser hair removal prices $c'],
    ExploreTreatmentFamily.hair => ['FUE hair transplant prices $c'],
    ExploreTreatmentFamily.peel => ['chemical peel prices $c'],
    ExploreTreatmentFamily.rhinoplasty => ['rhinoplasty cost $c'],
    ExploreTreatmentFamily.breast => ['breast augmentation cost $c'],
    _ => ['${exploreProcedurePriceTopic(procedure, pill)} clinic $c'],
  };
}

List<String> _placesBroadFallbackQueries({
  required String procedure,
  required String city,
  String pill = '',
}) {
  final c = city.trim();
  if (c.isEmpty) return const [];
  final fam = exploreTreatmentFamily(procedure);
  final loc = exploreCityPriceSearchTerms(
    c,
    countryCode:
        ExploreBackendService.instance.activeCityIdentity?.countryCode ?? "",
  );
  final clinicWord = loc.clinicWord.trim().isEmpty
      ? 'clinic'
      : loc.clinicWord.trim();
  return switch (fam) {
    ExploreTreatmentFamily.rhinoplasty || ExploreTreatmentFamily.breast => [
      'plastic surgeon $c',
      'best aesthetic $clinicWord $c',
    ],
    ExploreTreatmentFamily.hair => [
      'hair transplant $clinicWord $c',
      'best aesthetic $clinicWord $c',
    ],
    ExploreTreatmentFamily.laser => [
      'laser $clinicWord $c',
      'dermatology aesthetic $clinicWord $c',
    ],
    _ => [
      'best aesthetic $clinicWord $c',
      'dermatology aesthetic $clinicWord $c',
    ],
  };
}

String? _sourceUrlFromArea(String area) {
  final m = RegExp(r'src:(https?://[^\s·]+)').firstMatch(area);
  return m?.group(1);
}

DateTime? _parseExploreDate(Object? raw) {
  if (raw == null) return null;
  if (raw is DateTime) return raw;
  if (raw is Timestamp) return raw.toDate();
  final s = '$raw'.trim();
  if (s.isEmpty) return null;
  return DateTime.tryParse(s);
}

/// A curated public-site row carries a source URL and a check date but no DOM
/// evidence, so it can never satisfy the evidence-lock checks below. It is
/// trusted on its own terms instead: the price was read off the clinic's public
/// site by hand, and the fields that prove it are all present.
///
/// Deliberately narrow. It keys off the curated verification status, which only
/// [ExploreCuratedPriceStore] produces, so an AI or search-snippet row cannot
/// reach this branch by omitting its evidence.
bool exploreCuratedPriceIsTrusted(OpenAIClinic c) {
  if (c.priceVerificationStatus != PriceVerificationStatus.curatedPublicSite) {
    return false;
  }
  if (c.sourceType != kExploreCuratedSourceType) return false;
  if (!c.hasProcedure || c.pricePending || c.priceMin <= 0) return false;
  if (exploreClinicIsNoPublicPrice(c)) return false;
  if (c.currency.trim().isEmpty) return false;
  if (c.priceSourceUrl.trim().isEmpty) return false;
  if (c.lastCheckedAt == null) return false;
  return true;
}

/// True when Explore may show / persist this number as the procedure price.
/// Map a v11.67 `/discover-hybrid` row into a verified Explore card.
OpenAIClinic? _clinicFromDiscoveryToolRow(
  ExploreDiscoveryToolRow row, {
  required String city,
  required String procedure,
}) {
  final host = normalizeExploreHost(row.sourceUrl);
  if (host.isEmpty) return null;
  final marketplace =
      host.contains('fresha') ||
      host.contains('booksy') ||
      host.contains('treatwell') ||
      host.contains('whatclinic') || host.contains('bookimed');
  if (isMarketplaceOrDirectoryHost(host) &&
      !ExplorePriceDiscoveryTool.canUseMarketplacePrice(row)) return null;
  final status = host.contains('fresha')
      ? PriceVerificationStatus.freshaMarketplace
      : host.contains('booksy')
      ? PriceVerificationStatus.booksyMarketplace
      : marketplace
      ? PriceVerificationStatus.marketplaceMenu
      : PriceVerificationStatus.officialWebsite;
  final method = host.contains('fresha')
      ? 'fresha_menu'
      : host.contains('booksy')
      ? 'booksy_menu'
      : host.contains('treatwell')
      ? 'treatwell_menu'
      : host.contains('whatclinic')
      ? 'whatclinic_page'
      : marketplace
      ? 'marketplace_menu'
      : 'html_table';
  final max = row.priceMax ?? row.priceMin;
  final qualifier = row.qualifier.toLowerCase();
  final perUnit = row.procedureCanonical == 'botox' &&
      looksLikeBotoxPerUnitQuote('${row.rawProcedureText} ${row.rawEvidence}');
  final priceType = qualifier == 'approximate'
      ? 'approximate'
      : qualifier == 'from'
      ? 'from'
      : (max > row.priceMin + 0.5 ? 'range' : perUnit ? 'per_unit' : 'exact');
  final volume = exploreInjectableVolumeMl(row.rawProcedureText);
  return OpenAIClinic(
    rank: 0,
    name: row.clinicName,
    area: '$city · $host',
    distanceMi: 0,
    rating: row.rating,
    reviews: row.reviews,
    priceGbp: row.priceMin.round(),
    priceMin: row.priceMin,
    priceMax: max,
    priceLabel: row.rawPriceText,
    currency: row.currency,
    currencyConfirmed: true,
    brand: procedure,
    badge: '',
    badgeVariant: 'mid',
    coord: const OpenAICoord(0, 0),
    hasProcedure: true,
    pricePending: false,
    priceSourceUrl: row.sourceUrl,
    priceEvidenceText: row.rawEvidence.isNotEmpty
        ? row.rawEvidence
        : row.rawPriceText,
    priceVerificationStatus: status,
    priceVerificationConfidence: 0.9,
    priceVerifiedAt: row.lastVerifiedAt,
    discoveredAt: row.lastVerifiedAt,
    rawProcedureText: row.rawProcedureText.isNotEmpty
        ? row.rawProcedureText
        : row.procedureDisplayName,
    procedureFamily: row.procedureCanonical,
    rawPriceText: row.rawPriceText,
    extractionMethod: method,
    priceType: priceType,
    priceUnit: perUnit ? 'unit' : volume != null
        ? 'ml'
        : (row.unit == 'procedure' ? '' : row.unit),
    priceQuantity: volume,
    sourceType: ExplorePriceDiscoveryTool.canUseMarketplacePrice(row)
        ? 'marketplace' : 'discovery_tool',
    procedureCanonical: row.procedureCanonical,
    procedureDetail: row.procedureDetail,
    procedureDisplayName: row.procedureCanonical == 'breast_augmentation'
        ? exploreBreastProcedureDisplayName(
            rawProcedureText: row.rawProcedureText,
            procedureDetail: row.procedureDetail,
            evidence: row.rawEvidence,
            priceMin: row.priceMin,
            currency: row.currency,
          )
        : row.procedureDisplayName,
    providerClinic: row.clinicName,
    sourcePlatform: marketplace ? marketplacePlatformLabel(host) : '',
    priceExtractRevision: kExplorePriceExtractRevision,
    procedureRelation: 'exact',
  );
}

bool explorePriceIsVerified(OpenAIClinic c) {
  if (looksLikeNonInjectableBotox(
      '${c.rawProcedureText} ${c.priceEvidenceText} ${c.procedureDisplayName}')) return false;
  if (exploreClinicIsNoPublicPrice(c)) return false;
  if (explorePriceHasNonfacialScope(c)) return false;
  if (explorePublishedPriceIsIncentive(
    evidence: c.priceEvidenceText,
    priceMin: c.priceMin,
    currency: c.currency,
  ))
    return false;
  if (explorePublishedPriceIsSuperseded(
    evidence: c.priceEvidenceText,
    priceMin: c.priceMin,
    currency: c.currency,
  ))
    return false;
  if ((c.procedureCanonical == 'breast_augmentation' ||
          c.brand.toLowerCase().contains('augmentation') ||
          c.brand.toLowerCase() == 'boob job') &&
      exploreBreastPriceIsOtherSurgery(
        evidence: c.priceEvidenceText,
        priceMin: c.priceMin,
        currency: c.currency,
      ))
    return false;
  if (explorePricedLineIsIncomparablePackage(
    procedure: c.procedureCanonical.isNotEmpty ? c.procedureCanonical : c.brand,
    evidence:
        '${c.rawProcedureText}\n${c.procedureDetail}\n${c.rawPriceText}\n${c.priceEvidenceText}',
    priceMin: c.priceMin,
  )) {
    return false;
  }
  if (exploreCuratedPriceIsTrusted(c)) return true;
  if (!c.hasProcedure || c.pricePending || c.priceMin <= 0) return false;
  if (!c.priceVerificationStatus.isTrusted) return false;
  if (c.rawPriceText.trim().isEmpty) return false;
  if (c.priceSourceUrl.trim().isEmpty) return false;
  if (c.extractionMethod.trim().isEmpty) return false;
  if (!isValidExtractedPriceCandidate(
    rawPriceText: c.rawPriceText,
    priceMin: c.priceMin,
    currency: c.currency,
    extractionMethod: c.extractionMethod,
    rawEvidence: c.priceEvidenceText,
    rawProcedureText: c.rawProcedureText,
    procedure: c.brand,
    sourceUrl: c.priceSourceUrl,
    priceMax: c.priceMax,
  )) {
    return false;
  }
  return true;
}

bool explorePriceHasNonfacialScope(OpenAIClinic c) {
  final family = c.procedureCanonical.trim().isNotEmpty
      ? exploreFamilyFromStoredId(c.procedureCanonical)
      : exploreTreatmentFamily(c.brand);
  if (family != ExploreTreatmentFamily.filler &&
      family != ExploreTreatmentFamily.peel) return false;
  final row = '${c.rawProcedureText} ${c.procedureDetail} ${c.priceEvidenceText}';
  return RegExp(
    r'\b(?:intim\w*|genital\w*|vagin\w*|vulv\w*|labial?\s+major\w*|penis|penile|buttock\w*)\b|'
    r'\b(?:breast|body)\s+fillers?\b|\bzona\s+corporala\b',
    caseSensitive: false,
  ).hasMatch(foldExploreCityText(row));
}

/// Wire marker: clinic offers the procedure but publishes no literal price.
const kExplorePriceStatusNoPublicPrice = 'no_public_price';
const kExplorePriceOnRequestLabel = 'Price on request';

bool exploreClinicIsNoPublicPrice(OpenAIClinic c) {
  if (c.priceRejectionReason.trim().toLowerCase() ==
      kExplorePriceStatusNoPublicPrice) {
    return true;
  }
  final label = c.priceLabel.trim().toLowerCase();
  return label == 'price on request' || label == 'no public price';
}

bool exploreClinicEligibleAsNoPublicPrice(
  OpenAIClinic c, {
  required String procedure,
  required String city,
}) {
  if (!c.hasProcedure || c.pricePending) return false;
  if (explorePriceIsVerified(c)) return false;
  if (!exploreClinicIsNoPublicPrice(c)) return false;
  final host = exploreClinicWebsiteHost(c).isNotEmpty
      ? exploreClinicWebsiteHost(c)
      : normalizeExploreHost(c.priceSourceUrl);
  if (host.isEmpty || isMarketplaceOrDirectoryHost(host)) return false;
  if (looksLikeNonClinicContentHost(host)) return false;
  if (looksLikeMarketEstimateDirectoryUrl(host)) return false;
  if (isMarketplaceBrandName(c.name)) return false;
  if (clinicIdentityRejectReason(
        c.name,
        websiteHost: host,
        providerClinic: c.providerClinic,
        sourceType: c.sourceType,
      ) !=
      null) {
    return false;
  }
  if (!exploreClinicFitsSearchCity(c, city)) return false;
  return true;
}

OpenAIClinic exploreMarkNoPublicPriceClinic(
  OpenAIClinic clinic, {
  String sourceUrl = '',
  String evidence = '',
}) {
  final now = DateTime.now();
  return clinic.copyWith(
    priceMin: 0,
    priceMax: 0,
    priceGbp: 0,
    priceLabel: kExplorePriceOnRequestLabel,
    pricePending: false,
    hasProcedure: true,
    priceSourceUrl: sourceUrl.trim().isNotEmpty
        ? sourceUrl.trim()
        : clinic.priceSourceUrl,
    priceEvidenceText: evidence.trim().isNotEmpty
        ? evidence.trim()
        : clinic.priceEvidenceText,
    priceRejectionReason: kExplorePriceStatusNoPublicPrice,
    lastCheckedAt: now,
    discoveredAt: clinic.discoveredAt ?? now,
    rawPriceText: '',
    extractionMethod: '',
  );
}

List<OpenAIClinic> exploreOrderVerifiedThenNoPublicPrice(
  List<OpenAIClinic> clinics, {
  required String procedure,
  required String city,
}) {
  final priced = <OpenAIClinic>[];
  final onRequest = <OpenAIClinic>[];
  for (final c in clinics) {
    if (exploreClinicEligibleForVerifiedPool(
      c,
      procedure: procedure,
      city: city,
    )) {
      priced.add(c);
    } else if (exploreClinicEligibleAsNoPublicPrice(
      c,
      procedure: procedure,
      city: city,
    )) {
      onRequest.add(c);
    }
  }
  return [...priced, ...onRequest];
}

String exploreVerifiedAndOnRequestSummary({
  required int verifiedPriceCount,
  required int noPublicPriceCount,
}) {
  final parts = <String>[];
  if (verifiedPriceCount > 0) {
    parts.add(
      verifiedPriceCount == 1
          ? '1 verified price'
          : '$verifiedPriceCount verified prices',
    );
  }
  if (noPublicPriceCount > 0) {
    parts.add(
      noPublicPriceCount == 1
          ? '1 clinic without public prices'
          : '$noPublicPriceCount clinics without public prices',
    );
  }
  return parts.join(' · ');
}

String _withSourceUrl(String area, String url) {
  final cleaned = area
      .replaceAll(RegExp(r'\s*·\s*src:https?://[^\s·]+'), '')
      .trim();
  if (url.isEmpty) return cleaned;
  final parsed = Uri.tryParse(url);
  if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) {
    return cleaned;
  }
  return cleaned.isEmpty ? 'src:$url' : '$cleaned · src:$url';
}

/// True when the HTML already contains a currency amount or /unit quote.
/// Used to skip GPT extract on treatment menus with no numbers.
bool _pageHasPricedAmounts(String text) {
  if (text.trim().isEmpty) return false;
  final t = text.toLowerCase();
  if (RegExp(r'[€£$₩]\s*\d{1,5}(?:[.,]\d{1,2})?').hasMatch(t)) {
    return true;
  }
  if (RegExp(
    r'(?:aed|eur|euro|£|gbp|usd|ron|lei|try|₩|krw|hkd|sgd|thb|درهم|د\.إ)'
    r'\s*\d{2,6}',
    caseSensitive: false,
  ).hasMatch(t)) {
    return true;
  }
  if (RegExp(
    r'\d{1,5}(?:[.,]\d{1,2})?\s*(?:€|eur|£|gbp|usd|\$|ron|lei|try|'
    r'₩|krw|aed|hkd|sgd|thb|pln|zł|yen|jpy|درهم|د\.إ)',
    caseSensitive: false,
  ).hasMatch(t)) {
    return true;
  }
  if (RegExp(
    r'\d{1,3}(?:[.,]\d{1,2})?\s*(?:/|per)\s*'
    r'(?:unit|unitate|zona|zone|area|graft)',
    caseSensitive: false,
  ).hasMatch(t)) {
    return true;
  }
  if (RegExp(
    r'(?:from|starting at|de la|desde|ab|from only)\s*[€£$]?\s*\d{1,5}',
    caseSensitive: false,
  ).hasMatch(t)) {
    return true;
  }
  return false;
}

bool _pageSaysContactForPrice(String text) {
  final t = text.toLowerCase();
  return t.contains('preț personalizat') ||
      t.contains('pret personalizat') ||
      t.contains('preț la cerere') ||
      t.contains('pret la cerere') ||
      t.contains('contactați clinica') ||
      t.contains('contactati clinica') ||
      t.contains('contact the clinic') ||
      t.contains('price on request') ||
      t.contains('solicitați o cotație') ||
      t.contains('solicitati o cotatie');
}

/// Google / AI search phrase for each Explore filter pill (city mode).
String explorePillAiSearchQuery(String pill) {
  switch (exploreCanonicalComparePill(pill)) {
    case 'Botox':
      return 'Botox anti-wrinkle injection';
    case 'Fillers':
      return 'dermal filler lips cheeks';
    case 'Laser':
      return 'laser skin rejuvenation IPL';
    case 'Peels':
      return 'chemical peel facial';
    case 'Skin':
      return 'skin booster Profhilo';
    case 'Rhinoplasty':
      return 'rhinoplasty nose job';
    case 'Boob job':
      return 'breast augmentation';
    case 'Hair':
      return 'hair transplant';
    default:
      return pill.trim();
  }
}

bool _exploreCityLooksItalian(String city) {
  final c = city.toLowerCase();
  return c.contains('milan') ||
      c.contains('milano') ||
      c.contains('rome') ||
      c.contains('roma') ||
      c.contains('florence') ||
      c.contains('firenze') ||
      c.contains('naples') ||
      c.contains('napoli') ||
      c.contains('turin') ||
      c.contains('torino') ||
      c.contains('bologna') ||
      c.contains('italy') ||
      c.contains('italia');
}

/// Alternate search phrases on comparison refills (when top clinics lack prices).
String explorePillAlternateAiSearchQuery(String pill, String city, int pass) {
  final topic = exploreProcedurePriceTopic(
    explorePillAiSearchQuery(pill),
    pill,
  );
  final loc = exploreCityPriceSearchTerms(
    city,
    countryCode:
        ExploreBackendService.instance.activeCityIdentity?.countryCode ?? '',
  );
  final localNames = exploreProcedureLocalSearchNames(
    explorePillAiSearchQuery(pill),
    loc.lang,
  );
  final localProc = localNames.isNotEmpty ? localNames.first : topic;
  final localPrice = loc.priceWords.isNotEmpty ? loc.priceWords.first : 'price';
  final localPriceAlt = loc.priceWords.length > 1
      ? loc.priceWords[1]
      : localPrice;
  final useLocalPrice =
      localPrice.toLowerCase() != 'price' &&
      localPrice.toLowerCase() != 'prices';
  if (pass <= 1) {
    return '$topic prices in $city';
  }
  if (pass == 2) {
    return useLocalPrice ? '$topic $localPrice $city' : '$topic price $city';
  }
  if (pass == 3 &&
      useLocalPrice &&
      localProc.toLowerCase() != topic.toLowerCase()) {
    return '$localProc $localPrice $city';
  }
  if (useLocalPrice &&
      localPriceAlt.toLowerCase() != localPrice.toLowerCase()) {
    return '$topic $localPriceAlt $city';
  }
  return useLocalPrice
      ? '$localProc $localPrice $city'
      : '$topic prices in $city';
}

bool _isPriceOnRequestLabel(String label) {
  final l = label.toLowerCase();
  return l.contains('on request') ||
      l.contains('su richiesta') ||
      l.contains('a richiesta') ||
      l.contains('price on') ||
      l.contains('prezzo su') ||
      l.contains('la cerere') ||
      l.contains('preț personalizat') ||
      l.contains('pret personalizat') ||
      l.contains('contact the clinic') ||
      l.contains('contactați') ||
      l.contains('contactati') ||
      l.trim().isEmpty;
}

/// Clinics that share the most common currency in [clinics] (for ranges).
List<OpenAIClinic> clinicsSharingDominantCurrency(List<OpenAIClinic> clinics) {
  if (clinics.length <= 1) return clinics;
  final counts = <String, int>{};
  for (final c in clinics) {
    final key = CityCurrency.normalizeCode(c.currency);
    if (key.isEmpty) continue;
    counts[key] = (counts[key] ?? 0) + 1;
  }
  if (counts.isEmpty) return clinics;
  var bestKey = counts.keys.first;
  var bestCount = 0;
  for (final e in counts.entries) {
    if (e.value > bestCount) {
      bestKey = e.key;
      bestCount = e.value;
    }
  }
  final filtered = clinics
      .where((c) => CityCurrency.matches(c.currency, bestKey))
      .toList();
  return filtered.isNotEmpty ? filtered : clinics;
}

/// Examples shown to the AI for the [brand] field per Explore pill.
String exploreCategoryBrandExamples(String pill) {
  switch (pill.trim()) {
    case 'Botox':
      return 'Forehead Botox, Anti-wrinkle 3 areas, Crow\'s feet Botox, '
          'Masseter Botox';
    case 'Fillers':
      return 'Russian lip filler, Cheek filler 1ml, Jawline filler, '
          'Tear trough filler, Nasolabial fold filler';
    case 'Laser':
    case 'Hair removal':
    case 'Skin laser':
      return 'Photo rejuvenation face, Byonik laser facial, '
          'IPL rosacea, Fraxel, laser genesis';
    case 'Peels':
      return 'Glycolic peel, TCA peel, Jessner peel, Enzyme peel, '
          'Medical peel';
    case 'Skin':
      return 'Profhilo, Skin booster face, Polynucleotides, '
          'Mesotherapy, Exosome facial';
    case 'Rhinoplasty':
      return 'Rhinoplasty, Rhinoplasty consultation';
    case 'Boob job':
      return 'Breast augmentation 300cc, Breast lift, Implant replacement, '
          'Fat transfer breasts';
    case 'Hair':
      return 'FUE hair transplant, Beard transplant, Hairline restoration, '
          'DHI hair transplant';
    default:
      return 'exact treatment name from the clinic price list';
  }
}

/// Drops clinics whose only price signal is an obvious scrape/AI error (e.g. 1 RON).
List<OpenAIClinic> filterComparisonClinicsWithJustifiedPrices({
  required List<OpenAIClinic> clinics,
  required String procedure,
}) {
  return clinics
      .where((c) => exploreClinicFitsCompareProcedure(c, procedure))
      .where(
        (c) => isUsableExploreClinicIdentity(
          name: c.name,
          websiteHost: c.priceSourceUrl,
          providerClinic: c.providerClinic,
          sourceType: c.sourceType,
        ),
      )
      .where(
        (c) =>
            c.priceMin <= 0 ||
            isJustifiedProcedurePrice(c, procedure: procedure),
      )
      .toList();
}

/// Compare-widget sort: most Google Maps reviews first, then highest rating.
int compareClinicsByGoogleMapsPopularity(OpenAIClinic a, OpenAIClinic b) {
  final rc = b.reviews.compareTo(a.reviews);
  if (rc != 0) return rc;
  final rt = b.rating.compareTo(a.rating);
  if (rt != 0) return rt;
  return a.distanceMi.compareTo(b.distanceMi);
}

List<OpenAIClinic> sortClinicsByGoogleMapsPopularity(
  List<OpenAIClinic> clinics,
) {
  final sorted = List<OpenAIClinic>.from(clinics);
  sorted.sort(compareClinicsByGoogleMapsPopularity);
  return sorted;
}

class OpenAIComparisonResult {
  const OpenAIComparisonResult({
    required this.city,
    required this.topic,
    required this.topicType,
    required this.summary,
    required this.rangeLabel,
    required this.mapCenter,
    required this.clinics,
  });

  final String city;
  final String topic;
  final OpenAISearchItemType topicType;
  final String summary;
  final String rangeLabel;
  final OpenAICoord mapCenter;
  final List<OpenAIClinic> clinics;

  OpenAIComparisonResult copyWith({
    List<OpenAIClinic>? clinics,
    String? rangeLabel,
  }) {
    return OpenAIComparisonResult(
      city: city,
      topic: topic,
      topicType: topicType,
      summary: summary,
      rangeLabel: rangeLabel ?? this.rangeLabel,
      mapCenter: mapCenter,
      clinics: clinics ?? this.clinics,
    );
  }

  factory OpenAIComparisonResult.fromJson(Map<String, Object?> json) {
    final typeStr = (json['topic_type'] as String?)?.toLowerCase().trim();
    final topicType = typeStr == 'clinic'
        ? OpenAISearchItemType.clinic
        : OpenAISearchItemType.procedure;
    final mc =
        (json['map_center'] as Map?)?.cast<String, Object?>() ?? const {};
    final clinicsJson = (json['clinics'] as List?) ?? const [];
    final rootCurrency = (json['currency'] as String?)?.trim() ?? '';
    final clinics = clinicsJson
        .whereType<Map>()
        .map((m) {
          // Inherit currency from the root when an individual clinic omits it.
          final cast = m.cast<String, Object?>();
          // Never copy a root € onto a lei/RON clinic (Skina 990 LEI → 990 €).
          final label = (cast['price_label'] as String?) ?? '';
          final ownCur = (cast['currency'] as String?)?.trim() ?? '';
          if (ownCur.isEmpty) {
            final fromLabel = FilterFx.detectCodeFromLabel(label, fallback: '');
            if (fromLabel.isNotEmpty) {
              cast['currency'] = fromLabel == 'LEI' ? 'RON' : fromLabel;
            } else if (rootCurrency.isNotEmpty &&
                !RegExp(r'lei|\bron\b', caseSensitive: false).hasMatch(label)) {
              cast['currency'] = rootCurrency;
            }
          }
          try {
            return OpenAIClinic.fromJson(cast);
          } catch (e) {
            final name = (cast['name'] as String?)?.trim() ?? '?';
            debugPrint(
              '[GP] Comparison AI clinic fromJson dropped: name=$name error=$e',
            );
            return null;
          }
        })
        .whereType<OpenAIClinic>()
        .toList(growable: false);
    return OpenAIComparisonResult(
      city: (json['city'] as String?)?.trim() ?? '',
      topic: (json['topic'] as String?)?.trim() ?? '',
      topicType: topicType,
      summary: (json['summary'] as String?)?.trim() ?? '',
      rangeLabel: (json['range_label'] as String?)?.trim() ?? '',
      mapCenter: OpenAICoord(
        _toDouble(mc['lat']) ?? 51.5072,
        _toDouble(mc['lng']) ?? -0.1276,
      ),
      clinics: clinics,
    );
  }
}

OpenAIClinic stripStaleExtractedClinicPrice(OpenAIClinic c) {
  if (c.priceMin <= 0) return c;
  // Curated rows are not HTML-extracted; an extract-revision bump must not
  // blank Miami Skin Spa's Botox until a re-import.
  if (exploreCuratedPriceIsTrusted(c)) return c;
  if (c.priceExtractRevision.trim() == kExplorePriceExtractRevision) {
    return c;
  }
  final stamp = c.priceExtractRevision.trim();
  debugPrint(
    '[GP PRICE] STRIP stale_cache ${c.name} ${c.priceMin.round()} — '
    'extract ${stamp.isEmpty ? "none" : stamp} '
    'need $kExplorePriceExtractRevision',
  );
  return c.copyWith(
    priceMin: 0,
    priceMax: 0,
    priceGbp: 0,
    priceLabel: '',
    priceExtractRevision: '',
    priceVerificationStatus: PriceVerificationStatus.legacyUnverified,
    priceRejectionReason: 'stale_extract_revision',
  );
}

class OpenAIClinic {
  const OpenAIClinic({
    required this.rank,
    required this.name,
    required this.area,
    required this.distanceMi,
    required this.rating,
    required this.reviews,
    required this.priceGbp,
    required this.priceMin,
    required this.priceMax,
    required this.priceLabel,
    required this.currency,
    required this.brand,
    required this.badge,
    required this.badgeVariant,
    required this.coord,
    this.hasProcedure = true,
    this.pricePending = false,
    this.currencyConfirmed = false,
    this.priceSourceUrl = '',
    this.priceEvidenceText = '',
    this.priceVerificationStatus = PriceVerificationStatus.unverified,
    this.priceVerificationConfidence = 0,
    this.priceVerifiedAt,
    this.lastCheckedAt,
    this.discoveredAt,
    this.priceRejectionReason = '',
    this.rawProcedureText = '',
    this.rawPriceText = '',
    this.extractionMethod = '',
    this.evidenceHash = '',
    this.priceType = '',
    this.priceUnit = '',
    this.priceQuantity,
    this.sourceType = '',
    this.procedureFamily = '',
    this.procedureCanonical = '',
    this.procedureDisplayName = '',
    this.procedureDetail = '',
    this.placeId = '',
    this.sourcePlatform = '',
    this.providerClinic = '',
    this.priceExtractRevision = '',
    this.procedureRelation = '',
  });

  final int rank;
  final String name;
  final String area;
  final double distanceMi;
  final double rating;
  final int reviews;

  /// Legacy "from" anchor in the same currency as [priceMin]. Kept for back-compat.
  final int priceGbp;

  /// Cheapest service the clinic offers (in [currency]). 0 when unknown.
  final double priceMin;

  /// Most expensive service the clinic offers (in [currency]). 0 when unknown.
  final double priceMax;

  /// Pretty range, e.g. "RON 200–400" / "£180–280". Empty when unknown.
  final String priceLabel;

  /// Currency string ("RON", "£", "€", "\$", "TRY", "PLN", …).
  final String currency;

  /// True when a symbol/code was adjacent to the amount on the page.
  /// False when the city default was assumed — skip FX conversion.
  final bool currencyConfirmed;
  final String brand;
  final String badge;
  final String badgeVariant;

  /// True when the procedure was verified on the clinic site (web path) or
  /// unknown / assumed from legacy JSON (default true when key absent).
  final bool hasProcedure;

  /// True while direct HTTP price scrape may still fill [priceMin] (web list path).
  final bool pricePending;

  /// Official page the price was read from. Prefer this over encoding URLs in [area].
  final String priceSourceUrl;
  final String priceEvidenceText;
  final PriceVerificationStatus priceVerificationStatus;
  final double priceVerificationConfidence;
  final DateTime? priceVerifiedAt;
  final DateTime? lastCheckedAt;
  final DateTime? discoveredAt;
  final String priceRejectionReason;
  final String rawProcedureText;
  final String rawPriceText;
  final String extractionMethod;
  final String evidenceHash;
  final String priceType;

  /// Pricing unit when published (`ml`, `syringe`, `area`, `session`, …).
  final String priceUnit;

  /// Optional quantity for [priceUnit] (e.g. `1` ml).
  final double? priceQuantity;
  final String sourceType;
  final String procedureFamily;
  final String procedureCanonical;

  /// Clean card title — never raw article sentences.
  final String procedureDisplayName;

  /// Optional package subtitle (e.g. "Mentor implants included").
  final String procedureDetail;
  final String placeId;
  final String sourcePlatform;
  final String providerClinic;
  final String priceExtractRevision;

  /// exact | variant | bundle | add_on | different | market | ambiguous
  final String procedureRelation;

  final OpenAICoord coord;

  OpenAIClinic copyWith({
    int? rank,
    String? name,
    String? area,
    double? rating,
    int? reviews,
    double? lat,
    double? lng,
    bool? hasProcedure,
    double? priceMin,
    double? priceMax,
    String? priceLabel,
    int? priceGbp,
    bool? pricePending,
    String? brand,
    String? currency,
    bool? currencyConfirmed,
    String? badge,
    String? badgeVariant,
    String? priceSourceUrl,
    String? priceEvidenceText,
    PriceVerificationStatus? priceVerificationStatus,
    double? priceVerificationConfidence,
    DateTime? priceVerifiedAt,
    DateTime? lastCheckedAt,
    DateTime? discoveredAt,
    String? priceRejectionReason,
    String? rawProcedureText,
    String? rawPriceText,
    String? extractionMethod,
    String? evidenceHash,
    String? priceType,
    String? priceUnit,
    double? priceQuantity,
    bool clearPriceQuantity = false,
    String? sourceType,
    String? procedureFamily,
    String? procedureCanonical,
    String? procedureDisplayName,
    String? procedureDetail,
    String? placeId,
    String? sourcePlatform,
    String? providerClinic,
    String? priceExtractRevision,
    String? procedureRelation,
  }) {
    final nextLat = lat ?? coord.lat;
    final nextLng = lng ?? coord.lng;
    final nextCoord = lat != null || lng != null
        ? OpenAICoord(nextLat, nextLng)
        : coord;
    return OpenAIClinic(
      rank: rank ?? this.rank,
      name: name ?? this.name,
      area: area ?? this.area,
      distanceMi: distanceMi,
      rating: rating ?? this.rating,
      reviews: reviews ?? this.reviews,
      priceGbp: priceGbp ?? this.priceGbp,
      priceMin: priceMin ?? this.priceMin,
      priceMax: priceMax ?? this.priceMax,
      priceLabel: priceLabel ?? this.priceLabel,
      currency: currency ?? this.currency,
      currencyConfirmed: currencyConfirmed ?? this.currencyConfirmed,
      brand: brand ?? this.brand,
      badge: badge ?? this.badge,
      badgeVariant: badgeVariant ?? this.badgeVariant,
      coord: nextCoord,
      hasProcedure: hasProcedure ?? this.hasProcedure,
      pricePending: pricePending ?? this.pricePending,
      priceSourceUrl: priceSourceUrl ?? this.priceSourceUrl,
      priceEvidenceText: priceEvidenceText ?? this.priceEvidenceText,
      priceVerificationStatus:
          priceVerificationStatus ?? this.priceVerificationStatus,
      priceVerificationConfidence:
          priceVerificationConfidence ?? this.priceVerificationConfidence,
      priceVerifiedAt: priceVerifiedAt ?? this.priceVerifiedAt,
      lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
      discoveredAt: discoveredAt ?? this.discoveredAt,
      priceRejectionReason: priceRejectionReason ?? this.priceRejectionReason,
      rawProcedureText: rawProcedureText ?? this.rawProcedureText,
      rawPriceText: rawPriceText ?? this.rawPriceText,
      extractionMethod: extractionMethod ?? this.extractionMethod,
      evidenceHash: evidenceHash ?? this.evidenceHash,
      priceType: priceType ?? this.priceType,
      priceUnit: priceUnit ?? this.priceUnit,
      priceQuantity: clearPriceQuantity
          ? null
          : (priceQuantity ?? this.priceQuantity),
      sourceType: sourceType ?? this.sourceType,
      procedureFamily: procedureFamily ?? this.procedureFamily,
      procedureCanonical: procedureCanonical ?? this.procedureCanonical,
      procedureDisplayName: procedureDisplayName ?? this.procedureDisplayName,
      procedureDetail: procedureDetail ?? this.procedureDetail,
      placeId: placeId ?? this.placeId,
      sourcePlatform: sourcePlatform ?? this.sourcePlatform,
      providerClinic: providerClinic ?? this.providerClinic,
      priceExtractRevision: priceExtractRevision ?? this.priceExtractRevision,
      procedureRelation: procedureRelation ?? this.procedureRelation,
    );
  }

  factory OpenAIClinic.fromJson(Map<String, Object?> json) {
    final priceGbp = (_parseAnyPrice(json['price_gbp']) ?? 0).toInt();
    var pMin = _parseAnyPrice(json['price_min']) ?? priceGbp.toDouble();
    final pMaxRaw = _parseAnyPrice(json['price_max']) ?? 0;
    final labelStr = sanitizeUtf16(
      (json['price_label'] as String?)?.trim() ?? '',
    );
    final jsonSource = sanitizeUtf16(
      (json['price_source_url'] as String?)?.trim() ??
          (json['source_url'] as String?)?.trim() ??
          '',
    );
    final area = _withSourceUrl(
      sanitizeUtf16((json['area'] as String?)?.trim() ?? ''),
      jsonSource,
    );
    final sourceUrl = jsonSource.isNotEmpty
        ? jsonSource
        : (_sourceUrlFromArea(area) ?? '');
    final rawPriceText = sanitizeUtf16(
      (json['raw_price_text'] as String?)?.trim() ?? '',
    );
    final extractionMethod =
        (json['extraction_method'] as String?)?.trim() ?? '';
    final sourceType = (json['source_type'] as String?)?.trim() ?? '';
    final hasEvidence =
        rawPriceText.isNotEmpty &&
        sourceUrl.isNotEmpty &&
        extractionMethod.isNotEmpty;
    var status = PriceVerificationStatus.fromJson(
      json['price_verification_status'],
      hasPrice: pMin > 0,
    );
    final isCurated =
        status == PriceVerificationStatus.curatedPublicSite &&
        sourceType == kExploreCuratedSourceType;
    if (pMin > 0 && !hasEvidence && !isCurated) {
      status = PriceVerificationStatus.legacyUnverified;
    }
    if (status == PriceVerificationStatus.aiVerified) {
      status = PriceVerificationStatus.legacyUnverified;
    }
    var priceStripped = false;
    final extractRev =
        (json['price_extract_revision'] as String?)?.trim() ?? '';
    if (pMin > 0 && !isCurated && extractRev != kExplorePriceExtractRevision) {
      debugPrint(
        '[GP PRICE] STRIP stale_cache ${sanitizeUtf16((json['name'] as String?)?.trim() ?? '')} '
        '${pMin.round()} — extract $extractRev need $kExplorePriceExtractRevision',
      );
      status = PriceVerificationStatus.legacyUnverified;
      pMin = 0;
      priceStripped = true;
    }
    if (pMin > 0 &&
        !isCurated &&
        !isValidExtractedPriceCandidate(
          rawPriceText: rawPriceText.isNotEmpty ? rawPriceText : labelStr,
          priceMin: pMin,
          currency: (json['currency'] as String?)?.trim() ?? '',
          extractionMethod: extractionMethod,
          rawEvidence: sanitizeUtf16(
            (json['price_evidence_text'] as String?)?.trim() ?? '',
          ),
          rawProcedureText: sanitizeUtf16(
            (json['raw_procedure_text'] as String?)?.trim() ?? '',
          ),
          procedure: _readClinicProcedureName(json),
          sourceUrl: sourceUrl,
        )) {
      status = PriceVerificationStatus.legacyUnverified;
      pMin = 0;
      priceStripped = true;
    }
    if (pMin > 0 && !isCurated && isNonLiteralClinicPriceUrl(sourceUrl)) {
      status = PriceVerificationStatus.legacyUnverified;
      pMin = 0;
      priceStripped = true;
    }
    final pMax = pMin <= 0 ? 0.0 : (pMaxRaw < pMin ? pMin : pMaxRaw);
    return OpenAIClinic(
      rank: (json['rank'] as num?)?.toInt() ?? 0,
      name: sanitizeUtf16((json['name'] as String?)?.trim() ?? ''),
      area: area,
      distanceMi: _toDouble(json['distance_mi']) ?? 0,
      rating: _toDouble(json['rating']) ?? 0,
      reviews: (json['reviews'] as num?)?.toInt() ?? 0,
      priceGbp: priceStripped ? 0 : priceGbp,
      priceMin: pMin,
      priceMax: pMax,
      priceLabel: priceStripped ? '' : labelStr,
      currency: _detectCurrency(
        raw: (json['currency'] as String?)?.trim() ?? '',
        label: labelStr,
        pMin: pMin,
      ),
      brand: sanitizeUtf16(_readClinicProcedureName(json)),
      badge: sanitizeUtf16((json['badge'] as String?)?.trim() ?? ''),
      badgeVariant:
          (json['badge_variant'] as String?)?.trim().toLowerCase() ?? 'mid',
      coord: OpenAICoord(
        _toDouble(json['lat']) ?? 0,
        _toDouble(json['lng']) ?? 0,
      ),
      hasProcedure: _parseHasProcedure(json),
      pricePending: json['price_pending'] == true,
      currencyConfirmed: json['currency_confirmed'] == true,
      priceSourceUrl: sourceUrl,
      priceEvidenceText: sanitizeUtf16(
        (json['price_evidence_text'] as String?)?.trim() ?? '',
      ),
      priceVerificationStatus: status,
      priceVerificationConfidence:
          (json['price_verification_confidence'] as num?)?.toDouble() ?? 0,
      priceVerifiedAt: _parseExploreDate(json['price_verified_at']),
      lastCheckedAt: _parseExploreDate(json['last_checked_at']),
      discoveredAt: _parseExploreDate(json['discovered_at']),
      priceRejectionReason:
          (json['price_rejection_reason'] as String?)?.trim() ?? '',
      rawProcedureText: sanitizeUtf16(
        (json['raw_procedure_text'] as String?)?.trim() ?? '',
      ),
      rawPriceText: rawPriceText,
      extractionMethod: extractionMethod,
      evidenceHash: (json['evidence_hash'] as String?)?.trim() ?? '',
      priceType: (json['price_type'] as String?)?.trim() ?? '',
      priceUnit: (json['price_unit'] as String?)?.trim() ?? '',
      priceQuantity: _toDouble(json['price_quantity']),
      sourceType: sourceType,
      procedureFamily: (json['procedure_family'] as String?)?.trim() ?? '',
      procedureCanonical:
          (json['procedure_canonical'] as String?)?.trim() ?? '',
      procedureDisplayName:
          (json['procedure_display_name'] as String?)?.trim() ?? '',
      procedureDetail: (json['procedure_detail'] as String?)?.trim() ?? '',
      placeId:
          (json['place_id'] as String?)?.trim() ??
          (json['placeId'] as String?)?.trim() ??
          '',
      sourcePlatform: (json['source_platform'] as String?)?.trim() ?? '',
      providerClinic: sanitizeUtf16(
        (json['provider_clinic'] as String?)?.trim() ?? '',
      ),
      priceExtractRevision: priceStripped
          ? ''
          : (json['price_extract_revision'] as String?)?.trim() ?? '',
      procedureRelation: (json['procedure_relation'] as String?)?.trim() ?? '',
    );
  }
}

/// Strips a trailing price the AI/scrape sometimes bakes into the
/// procedure/brand title, e.g. "Lip filler 0.55ml | 1400 RON" or
/// "Tratament ... | 900". The price is already shown separately in the
/// card's price badge, so it must not also appear inside the title.
String _stripPriceSuffix(String raw) {
  var s = raw.trim();
  // "... | 1400 RON", "... - 900", "... — €350" (loop: some titles
  // stack more than one separator+price segment).
  final pipeOrDashPrice = RegExp(
    r'\s*[\|\-–—]\s*[£€$]?\s*\d[\d.,]*\s*'
    r'(RON|LEI|EUR|GBP|USD|TRY|PLN|KRW|JPY|BRL|INR|AED|RUB|AUD|€|£|\$)?'
    r'\s*$',
    caseSensitive: false,
  );
  while (true) {
    final next = s.replaceFirst(pipeOrDashPrice, '').trim();
    if (next == s) break;
    s = next;
  }
  // "Lip filler 1400 RON" — price glued on with no separator at all.
  final trailingPrice = RegExp(
    r'\s+[£€$]?\s*\d{2,6}[\d.,]*\s*'
    r'(RON|LEI|EUR|GBP|USD|TRY|PLN|KRW|JPY|BRL|INR|AED|RUB|AUD|€|£|\$)\s*$',
    caseSensitive: false,
  );
  s = s.replaceFirst(trailingPrice, '').trim();
  return s;
}

String _readClinicProcedureName(Map<String, Object?> json) {
  final brand = sanitizeUtf16((json['brand'] as String?)?.trim() ?? '');
  if (brand.isNotEmpty) return _stripPriceSuffix(brand);
  for (final key in [
    'procedure_name',
    'procedure',
    'treatment_name',
    'treatment',
    'raw_procedure_text',
  ]) {
    final value = sanitizeUtf16((json[key] as String?)?.trim() ?? '');
    if (value.isNotEmpty) return _stripPriceSuffix(value);
  }
  return '';
}

bool _parseHasProcedure(Map<String, Object?> json) {
  if (!json.containsKey('has_procedure')) return true;
  final hp = json['has_procedure'];
  if (hp is bool) return hp;
  if (hp is num) return hp != 0;
  if (hp is String) {
    final t = hp.toLowerCase().trim();
    return t == 'true' || t == '1' || t == 'yes';
  }
  return true;
}

class OpenAIClinicDetail {
  const OpenAIClinicDetail({
    required this.clinicName,
    required this.city,
    required this.area,
    required this.rating,
    required this.reviews,
    required this.about,
    required this.currency,
    required this.procedures,
  });

  final String clinicName;
  final String city;
  final String area;
  final double rating;
  final int reviews;
  final String about;
  final String currency;
  final List<OpenAIProcedureItem> procedures;

  factory OpenAIClinicDetail.fromJson(Map<String, Object?> json) {
    final procsJson = (json['procedures'] as List?) ?? const [];
    final currency = (json['currency'] as String?)?.trim() ?? '';
    return OpenAIClinicDetail(
      clinicName: (json['clinic_name'] as String?)?.trim() ?? '',
      city: (json['city'] as String?)?.trim() ?? '',
      area: (json['area'] as String?)?.trim() ?? '',
      rating: _toDouble(json['rating']) ?? 0,
      reviews: (json['reviews'] as num?)?.toInt() ?? 0,
      about: (json['about'] as String?)?.trim() ?? '',
      currency: currency,
      procedures: procsJson
          .whereType<Map>()
          .map(
            (m) => OpenAIProcedureItem.fromJson(
              m.cast<String, Object?>(),
              fallbackCurrency: currency,
            ),
          )
          .toList(growable: false),
    );
  }
}

class OpenAIProcedureItem {
  const OpenAIProcedureItem({
    required this.name,
    required this.category,
    required this.priceLabel,
    required this.badge,
    required this.minPrice,
    required this.maxPrice,
    required this.currency,
    required this.variants,
  });

  final String name;
  final String category;
  final String priceLabel;
  final String badge;
  final double? minPrice;
  final double? maxPrice;
  final String currency;
  final List<OpenAIProcedureVariant> variants;

  bool get hasRange =>
      minPrice != null &&
      maxPrice != null &&
      (maxPrice! - minPrice!).abs() > 0.001;

  factory OpenAIProcedureItem.fromJson(
    Map<String, Object?> json, {
    String fallbackCurrency = '',
  }) {
    final currency = ((json['currency'] as String?)?.trim().isNotEmpty ?? false)
        ? (json['currency'] as String).trim()
        : fallbackCurrency;

    final rawVariants = (json['variants'] as List?) ?? const [];
    final variants = rawVariants
        .whereType<Map>()
        .map(
          (m) => OpenAIProcedureVariant.fromJson(
            m.cast<String, Object?>(),
            currency: currency,
          ),
        )
        .toList(growable: false);

    double? minP = _parseAnyPrice(json['min_price']);
    double? maxP = _parseAnyPrice(json['max_price']);
    if ((minP == null || maxP == null) && variants.isNotEmpty) {
      final prices = variants
          .map((v) => v.price)
          .whereType<double>()
          .toList(growable: false);
      if (prices.isNotEmpty) {
        prices.sort();
        minP ??= prices.first;
        maxP ??= prices.last;
      }
    }

    String label = (json['price_label'] as String?)?.trim() ?? '';
    if (label.isEmpty && minP != null && maxP != null) {
      label = _formatRange(minP, maxP, currency);
    }

    return OpenAIProcedureItem(
      name: (json['name'] as String?)?.trim() ?? '',
      category: (json['category'] as String?)?.trim() ?? '',
      priceLabel: label,
      badge: (json['badge'] as String?)?.trim() ?? '',
      minPrice: minP,
      maxPrice: maxP,
      currency: currency,
      variants: variants,
    );
  }
}

class OpenAIProcedureVariant {
  const OpenAIProcedureVariant({
    required this.name,
    required this.price,
    required this.priceLabel,
    required this.badge,
  });

  final String name;
  final double? price;
  final String priceLabel;
  final String badge;

  factory OpenAIProcedureVariant.fromJson(
    Map<String, Object?> json, {
    required String currency,
  }) {
    final price = _parseAnyPrice(json['price']);
    String label = (json['price_label'] as String?)?.trim() ?? '';
    if (label.isEmpty && price != null) {
      label = _formatPrice(price, currency);
    }
    return OpenAIProcedureVariant(
      name: (json['name'] as String?)?.trim() ?? '',
      price: price,
      priceLabel: label,
      badge: (json['badge'] as String?)?.trim() ?? '',
    );
  }
}

String _formatRange(double a, double b, String currency) {
  final lo = a <= b ? a : b;
  final hi = a <= b ? b : a;
  if ((hi - lo).abs() < 0.001) return _formatPrice(lo, currency);
  if (currency == '£' || currency == '€' || currency == r'$') {
    return '$currency${_formatNumber(lo)}–${_formatNumber(hi)}';
  }
  return '${_formatNumber(lo)}–${_formatNumber(hi)} $currency'.trim();
}

String _formatScrapedPriceLabel(double min, double max, String currency) {
  if (max > 0 && (max - min).abs() > 0.001) {
    return _formatRange(min, max, currency);
  }
  return _formatPrice(min, currency);
}

String _formatPrice(double v, String currency) {
  final num = _formatNumber(v);
  if (currency.isEmpty) return num;
  // Prefix-style currencies stay on the left (£300 / €300 / $300), word-style on the right ("300 RON").
  if (currency == '£' || currency == '€' || currency == '\$')
    return '$currency$num';
  return '$num $currency';
}

String _formatNumber(double v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  return v.toStringAsFixed(0);
}

/// Fixes price_label when the model returns a wrong currency.
/// - Two-number RON labels where the second number is ~5x the first
///   are EUR-with-RON-conversion mislabels (e.g. "650–3250 RON" from
///   "650 € (3250 lei)") and get rewritten to €.
/// - Single-number RON labels are only flipped to € when the caller
///   provides explicit evidence the source was EUR via [currencyHint].
String _fixPriceLabel({
  required String raw,
  required double pMin,
  required double pMax,
  String currencyHint = '',
}) {
  if (raw.isEmpty) return raw;

  // Remove parenthesized RON conversions like "(1375 lei)" or "(3250 RON)"
  // before any other processing.
  raw = raw
      .replaceAll(
        RegExp(r'\(\s*[\d.,]+\s*(?:lei|RON|ron)\s*\)', caseSensitive: false),
        '',
      )
      .trim();
  if (raw.isEmpty) return raw;

  // If label contains € already, it is *usually* correct — but some sites show
  // dual currency like "650 € (3250 lei)" and models sometimes emit "€650–3250".
  // When the second number is ~5x the first, treat it as the RON conversion and
  // collapse to a single EUR price.
  if (raw.contains('€')) {
    final nums = RegExp(r'(\d+)')
        .allMatches(raw)
        .map((m) => double.tryParse(m.group(1) ?? '') ?? 0)
        .where((n) => n > 0)
        .toList();
    if (nums.length >= 2) {
      final a = nums.reduce((x, y) => x < y ? x : y); // smaller = EUR
      final b = nums.reduce((x, y) => x > y ? x : y); // larger = RON conversion
      final ratio = b / a;
      if (ratio >= 4.5 && ratio <= 5.5) return '€${_formatNumber(a)}';
    }
    return raw;
  }

  // If label ends with RON but numbers look like an EUR/RON pair.
  if (raw.contains('RON')) {
    final nums = RegExp(r'(\d+)')
        .allMatches(raw)
        .map((m) => double.tryParse(m.group(1) ?? '') ?? 0)
        .where((n) => n > 0)
        .toList();

    if (nums.length == 2) {
      final a = nums[0];
      final b = nums[1];
      // b ≈ 5× a → EUR primary, RON conversion in second slot.
      // e.g. "650 RON (3250)" or "275–1375 RON" with 1375/275 = 5.0.
      final ratio = b / a;
      if (ratio >= 4.5 && ratio <= 5.5) {
        if (pMin > 0 && pMin == pMax) return '€${_formatNumber(pMin)}';
        if (pMin > 0 && pMax > pMin) {
          return '€${_formatNumber(pMin)}–${_formatNumber(pMax)}';
        }
        return '€${_formatNumber(a)}';
      }
    }

    // Single-number branch: only flip when the caller has explicit evidence
    // the source page was in EUR (currencyHint == '€' or 'EUR'). This keeps
    // genuine RON labels (e.g. swissclinics "1050 RON") untouched.
    final isEurHint =
        currencyHint == '€' || currencyHint.toUpperCase() == 'EUR';
    if (nums.length == 1 && pMin > 0 && isEurHint) {
      final labelNum = nums[0];
      if ((labelNum - pMin).abs() < 1) {
        return '€${_formatNumber(pMin)}';
      }
    }
  }

  return raw;
}

class OpenAICoord {
  const OpenAICoord(this.lat, this.lng);
  final double lat;
  final double lng;
}

class OpenAIClinicProfile {
  const OpenAIClinicProfile({
    required this.clinicName,
    required this.city,
    required this.area,
    required this.distanceMi,
    required this.rating,
    required this.reviewsCount,
    required this.isTopRated,
    required this.isDoctorLed,
    required this.isVerified,
    required this.about,
    required this.currency,
    required this.procedureFocus,
    required this.procedureFocusLocal,
    required this.treatments,
    required this.contact,
    required this.reviews,
  });

  final String clinicName;
  final String city;
  final String area;
  final double distanceMi;
  final double rating;
  final int reviewsCount;
  final bool isTopRated;
  final bool isDoctorLed;
  final bool isVerified;
  final String about;
  final String currency;
  final String procedureFocus;
  final String procedureFocusLocal;
  final List<OpenAIClinicTreatment> treatments;
  final OpenAIClinicContact contact;
  final List<OpenAIClinicReview> reviews;

  factory OpenAIClinicProfile.fromJson(Map<String, Object?> json) {
    final rawTreatments = (json['treatments'] as List?) ?? const [];
    final rawReviews = (json['reviews'] as List?) ?? const [];
    final contactJson =
        (json['contact'] as Map?)?.cast<String, Object?>() ?? const {};
    return OpenAIClinicProfile(
      clinicName: (json['clinic_name'] as String?)?.trim() ?? '',
      city: (json['city'] as String?)?.trim() ?? '',
      area: (json['area'] as String?)?.trim() ?? '',
      distanceMi: _toDouble(json['distance_mi']) ?? 0,
      rating: _toDouble(json['rating']) ?? 0,
      reviewsCount: (json['reviews_count'] as num?)?.toInt() ?? 0,
      isTopRated: (json['is_top_rated'] as bool?) ?? false,
      isDoctorLed: (json['is_doctor_led'] as bool?) ?? false,
      isVerified: (json['is_verified'] as bool?) ?? false,
      about: (json['about'] as String?)?.trim() ?? '',
      currency: (json['currency'] as String?)?.trim() ?? '',
      procedureFocus: (json['procedure_focus'] as String?)?.trim() ?? '',
      procedureFocusLocal:
          (json['procedure_focus_local'] as String?)?.trim() ?? '',
      treatments: rawTreatments
          .whereType<Map>()
          .map((m) => OpenAIClinicTreatment.fromJson(m.cast<String, Object?>()))
          .toList(growable: false),
      contact: OpenAIClinicContact.fromJson(contactJson),
      reviews: rawReviews
          .whereType<Map>()
          .map((m) => OpenAIClinicReview.fromJson(m.cast<String, Object?>()))
          .toList(growable: false),
    );
  }
}

class OpenAIClinicTreatment {
  const OpenAIClinicTreatment({
    required this.name,
    required this.brand,
    required this.dose,
    required this.description,
    required this.priceLabel,
    required this.badge,
    required this.tags,
    required this.featured,
  });

  final String name;
  final String brand;
  final String dose;
  final String description;
  final String priceLabel;
  final String badge;
  final List<String> tags;
  final bool featured;

  factory OpenAIClinicTreatment.fromJson(Map<String, Object?> json) {
    final rawTags = (json['tags'] as List?) ?? const [];
    final tags = rawTags
        .whereType<String>()
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    return OpenAIClinicTreatment(
      name: (json['name'] as String?)?.trim() ?? '',
      brand: (json['brand'] as String?)?.trim() ?? '',
      dose: (json['dose'] as String?)?.trim() ?? '',
      description: (json['description'] as String?)?.trim() ?? '',
      priceLabel: (json['price_label'] as String?)?.trim() ?? '',
      badge: (json['badge'] as String?)?.trim() ?? '',
      tags: tags,
      featured: (json['featured'] as bool?) ?? false,
    );
  }
}

class OpenAIClinicContact {
  const OpenAIClinicContact({
    required this.address,
    required this.phone,
    required this.website,
    required this.instagram,
    required this.openingHours,
    required this.isOpenNow,
  });

  final String address;
  final String phone;
  final String website;
  final String instagram;
  final String openingHours;
  final bool isOpenNow;

  factory OpenAIClinicContact.fromJson(Map<String, Object?> json) {
    return OpenAIClinicContact(
      address: (json['address'] as String?)?.trim() ?? '',
      phone: (json['phone'] as String?)?.trim() ?? '',
      website: (json['website'] as String?)?.trim() ?? '',
      instagram: (json['instagram'] as String?)?.trim() ?? '',
      openingHours: (json['opening_hours'] as String?)?.trim() ?? '',
      isOpenNow: (json['is_open_now'] as bool?) ?? false,
    );
  }
}

class OpenAIClinicReview {
  const OpenAIClinicReview({
    required this.authorName,
    required this.initials,
    required this.date,
    required this.dateIso,
    required this.rating,
    required this.text,
  });

  final String authorName;
  final String initials;
  final String date;

  /// Optional ISO date (YYYY-MM-DD) — used to sort reviews newest-first.
  /// Empty when the model omits it.
  final String dateIso;
  final double rating;
  final String text;

  factory OpenAIClinicReview.fromJson(Map<String, Object?> json) {
    final author = (json['author_name'] as String?)?.trim() ?? '';
    String inits = (json['initials'] as String?)?.trim() ?? '';
    if (inits.isEmpty && author.isNotEmpty) {
      final parts = author
          .split(RegExp(r'\s+'))
          .where((e) => e.isNotEmpty)
          .toList();
      inits = parts.take(2).map((p) => p[0]).join().toUpperCase();
    }
    return OpenAIClinicReview(
      authorName: author,
      initials: inits.isEmpty ? '?' : inits,
      date: (json['date'] as String?)?.trim() ?? '',
      dateIso: (json['date_iso'] as String?)?.trim() ?? '',
      rating: _toDouble(json['rating']) ?? 5,
      text: (json['text'] as String?)?.trim() ?? '',
    );
  }
}

/// Full clinic profile (search → clinic, no procedure context).
class OpenAIClinicProfilePage {
  const OpenAIClinicProfilePage({
    required this.clinicName,
    required this.city,
    required this.clinicTypeLabel,
    required this.area,
    required this.distanceMi,
    required this.lat,
    required this.lng,
    required this.rating,
    required this.reviewsTotal,
    required this.googlePlaceUrl,
    required this.procedureCount,
    required this.doctorCount,
    required this.isVerified,
    required this.isDoctorLed,
    required this.heroTags,
    required this.about,
    required this.currency,
    required this.priceRangeLabel,
    required this.priceMin,
    required this.priceMax,
    required this.categories,
    required this.procedures,
    required this.doctors,
    required this.contact,
    required this.reviews,
  });

  final String clinicName;
  final String city;
  final String clinicTypeLabel;
  final String area;
  final double distanceMi;
  final double lat;
  final double lng;
  final double rating;
  final int reviewsTotal;
  final String googlePlaceUrl;
  final int procedureCount;
  final int doctorCount;
  final bool isVerified;
  final bool isDoctorLed;
  final List<String> heroTags;
  final String about;
  final String currency;
  final String priceRangeLabel;
  final double priceMin;
  final double priceMax;
  final List<String> categories;
  final List<OpenAIProfileProcedureRow> procedures;
  final List<OpenAIProfileDoctor> doctors;
  final OpenAIClinicContact contact;
  final List<OpenAIClinicReview> reviews;

  factory OpenAIClinicProfilePage.fromJson(Map<String, Object?> json) {
    final rawProc = (json['procedures'] as List?) ?? const [];
    final rawDoc = (json['doctors'] as List?) ?? const [];
    final rawRev = (json['reviews'] as List?) ?? const [];
    final rawCat = (json['categories'] as List?) ?? const [];
    final rawHero = (json['hero_tags'] as List?) ?? const [];
    final contactJson =
        (json['contact'] as Map?)?.cast<String, Object?>() ?? const {};
    final pageCurrency = (json['currency'] as String?)?.trim() ?? '';
    final procedures = rawProc
        .whereType<Map>()
        .map(
          (m) => OpenAIProfileProcedureRow.fromJson(
            m.cast<String, Object?>(),
            currencyHint: pageCurrency,
          ),
        )
        .toList(growable: false);
    final doctors = rawDoc
        .whereType<Map>()
        .map((m) => OpenAIProfileDoctor.fromJson(m.cast<String, Object?>()))
        .toList(growable: false);

    // Derive overall min/max from procedures when the model omits them.
    double? jsonPriceMin = _toDouble(json['price_min']);
    double? jsonPriceMax = _toDouble(json['price_max']);
    if ((jsonPriceMin == null || jsonPriceMin == 0) && procedures.isNotEmpty) {
      jsonPriceMin = procedures
          .map((p) => p.priceMin)
          .where((v) => v > 0)
          .fold<double?>(
            null,
            (acc, v) => acc == null ? v : (v < acc ? v : acc),
          );
    }
    if ((jsonPriceMax == null || jsonPriceMax == 0) && procedures.isNotEmpty) {
      jsonPriceMax = procedures
          .map((p) => p.priceMax)
          .where((v) => v > 0)
          .fold<double?>(
            null,
            (acc, v) => acc == null ? v : (v > acc ? v : acc),
          );
    }

    return OpenAIClinicProfilePage(
      clinicName: (json['clinic_name'] as String?)?.trim() ?? '',
      city: (json['city'] as String?)?.trim() ?? '',
      clinicTypeLabel:
          (json['clinic_type_label'] as String?)?.trim() ?? 'Clinic',
      area: (json['area'] as String?)?.trim() ?? '',
      distanceMi: _toDouble(json['distance_mi']) ?? 0,
      lat: _toDouble(json['lat']) ?? 0,
      lng: _toDouble(json['lng']) ?? 0,
      rating: _toDouble(json['rating']) ?? 0,
      reviewsTotal: (json['reviews_total'] as num?)?.toInt() ?? 0,
      googlePlaceUrl: (json['google_place_url'] as String?)?.trim() ?? '',
      procedureCount: procedures.length,
      doctorCount: doctors.length,
      isVerified: (json['is_verified'] as bool?) ?? false,
      isDoctorLed: (json['is_doctor_led'] as bool?) ?? false,
      heroTags: rawHero
          .whereType<String>()
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(growable: false),
      about: (json['about'] as String?)?.trim() ?? '',
      currency: (json['currency'] as String?)?.trim() ?? '',
      priceRangeLabel: (json['price_range_label'] as String?)?.trim() ?? '',
      priceMin: jsonPriceMin ?? 0,
      priceMax: jsonPriceMax ?? 0,
      categories: rawCat
          .whereType<String>()
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(growable: false),
      procedures: procedures,
      doctors: doctors,
      contact: OpenAIClinicContact.fromJson(contactJson),
      reviews: () {
        final list = rawRev
            .whereType<Map>()
            .map((m) => OpenAIClinicReview.fromJson(m.cast<String, Object?>()))
            .toList();
        // Newest first when ISO dates are provided; preserve model order otherwise.
        list.sort((a, b) {
          final ad = DateTime.tryParse(a.dateIso);
          final bd = DateTime.tryParse(b.dateIso);
          if (ad != null && bd != null) return bd.compareTo(ad);
          if (ad != null) return -1;
          if (bd != null) return 1;
          return 0;
        });
        return list.take(8).toList(growable: false);
      }(),
    );
  }
}

class OpenAIProfileProcedureRow {
  const OpenAIProfileProcedureRow({
    required this.name,
    required this.detail,
    required this.category,
    required this.iconKind,
    required this.priceMin,
    required this.priceMax,
    required this.priceLabel,
    required this.tags,
    required this.featured,
  });

  final String name;
  final String detail;
  final String category;
  final String iconKind;
  final double priceMin;
  final double priceMax;
  final String priceLabel;
  final List<String> tags;
  final bool featured;

  OpenAIProfileProcedureRow copyWith({
    bool? featured,
    String? priceLabel,
    String? iconKind,
  }) {
    return OpenAIProfileProcedureRow(
      name: name,
      detail: detail,
      category: category,
      iconKind: iconKind ?? this.iconKind,
      priceMin: priceMin,
      priceMax: priceMax,
      priceLabel: priceLabel ?? this.priceLabel,
      tags: tags,
      featured: featured ?? this.featured,
    );
  }

  factory OpenAIProfileProcedureRow.fromJson(
    Map<String, Object?> json, {
    String currencyHint = '',
  }) {
    final rawTags = (json['tags'] as List?) ?? const [];
    final pMin = _parseAnyPrice(json['price_min']) ?? 0;
    final pMaxRaw = _parseAnyPrice(json['price_max']) ?? 0;
    // If the model only sets price_min, treat the max as equal to min.
    final pMax = pMaxRaw < pMin ? pMin : pMaxRaw;
    return OpenAIProfileProcedureRow(
      name: (json['name'] as String?)?.trim() ?? '',
      detail: (json['detail'] as String?)?.trim() ?? '',
      category: (json['category'] as String?)?.trim() ?? '',
      iconKind:
          (json['icon_kind'] as String?)?.trim().toLowerCase() ?? 'inject',
      priceMin: pMin,
      priceMax: pMax,
      priceLabel: _fixPriceLabel(
        raw: (json['price_label'] as String?)?.trim() ?? '',
        pMin: pMin,
        pMax: pMax,
        currencyHint: currencyHint,
      ),
      tags: rawTags
          .whereType<String>()
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(growable: false),
      featured: (json['featured'] as bool?) ?? false,
    );
  }
}

class OpenAIProfileDoctor {
  const OpenAIProfileDoctor({
    required this.name,
    required this.initials,
    required this.specialty,
    required this.badge,
    required this.yearsExperience,
  });

  final String name;
  final String initials;
  final String specialty;
  final String badge;
  final int yearsExperience;

  factory OpenAIProfileDoctor.fromJson(Map<String, Object?> json) {
    final name = (json['name'] as String?)?.trim() ?? '';
    String inits = (json['initials'] as String?)?.trim() ?? '';
    if (inits.isEmpty && name.isNotEmpty) {
      final parts = name
          .split(RegExp(r'\s+'))
          .where((e) => e.isNotEmpty)
          .toList();
      inits = parts.take(2).map((p) => p[0]).join().toUpperCase();
    }
    return OpenAIProfileDoctor(
      name: name,
      initials: inits.isEmpty ? '?' : inits,
      specialty: (json['specialty'] as String?)?.trim() ?? '',
      badge: (json['badge'] as String?)?.trim() ?? '',
      yearsExperience: (json['years_experience'] as num?)?.toInt() ?? 0,
    );
  }
}

double? _toDouble(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

/// Wilson score lower bound — balances rating with review count.
/// A clinic with 4.8★ / 500 reviews scores higher than
/// 5.0★ / 3 reviews (small sample = unreliable).
/// Returns value 0.0–1.0.
double _wilsonScore(double rating, int reviews) {
  if (reviews == 0) return 0;
  // Normalize rating to 0–1 (from 0–5 stars)
  final p = (rating / 5.0).clamp(0.0, 1.0);
  final n = reviews.toDouble();
  // z = 1.96 for 95% confidence interval
  const z = 1.96;
  final z2 = z * z;
  final numerator =
      p + z2 / (2 * n) - z * math.sqrt(p * (1 - p) / n + z2 / (4 * n * n));
  final denominator = 1 + z2 / n;
  return numerator / denominator;
}

/// Currency for a scraped price row. Prefers a symbol/code adjacent to the
/// amount on that row. Never silently defaults to £/GBP — ambiguous numbers
/// use the city's local currency and are marked unconfirmed so FX conversion
/// cannot compound the guess.
({String code, bool confirmed}) _scrapedCurrencyDecision({
  required String priceLabel,
  required String pageText,
  required String city,
  String procedure = '',
  double amount = 0,
  String claimedCurrency = '',
}) {
  final fromLabel = _detectCurrency(raw: '', label: priceLabel, pMin: 0);
  final fromClaimed = CityCurrency.normalizeCode(claimedCurrency);
  final cityCur = _inferCurrencyFromCity(city);
  final fromPage = _effectiveCurrencyFromPageText(pageText, '');
  final highTicket = isHighTicketExploreProcedure(procedure);
  if (highTicket &&
      amount >= 2000 &&
      amount < 16000 &&
      fromLabel != 'RON' &&
      fromLabel != '£' &&
      fromClaimed != 'RON') {
    if (fromLabel == '€' ||
        fromClaimed == '€' ||
        fromPage == '€' ||
        _pageTextHasEuro(pageText)) {
      return (code: '€', confirmed: fromLabel == '€' || fromPage == '€');
    }
    if (cityCur == 'RON') {
      return (
        code: '€',
        confirmed: fromPage == '€' || _pageTextHasEuro(pageText),
      );
    }
  }
  // Injectables only: "900 €" on a lei page is usually 900 lei.
  if (fromPage == 'RON' && fromLabel == '€' && !highTicket) {
    return (code: 'RON', confirmed: true);
  }
  if (fromLabel.isNotEmpty) return (code: fromLabel, confirmed: true);
  return (code: cityCur, confirmed: false);
}

void _logScrapedCurrencySource(
  String clinicName,
  ({String code, bool confirmed}) decision,
) {
  if (decision.confirmed) {
    debugPrint(
      '[GP] currency detected on page: ${decision.code} ($clinicName)',
    );
  } else {
    debugPrint(
      '[GP] currency assumed from city default: ${decision.code} '
      '($clinicName)',
    );
  }
}

String _currencyForScrapedRow({
  required String priceLabel,
  required String pageText,
  required String city,
  String procedure = '',
  double amount = 0,
  String claimedCurrency = '',
}) {
  return _scrapedCurrencyDecision(
    priceLabel: priceLabel,
    pageText: pageText,
    city: city,
    procedure: procedure,
    amount: amount,
    claimedCurrency: claimedCurrency,
  ).code;
}

void _warnCurrencyWithoutPageBacking(
  OpenAIClinic c, {
  required String city,
  String pageText = '',
}) {
  final cityCur = CityCurrency.localCode(city);
  if (cityCur.isEmpty) return;
  final clinicCur = CityCurrency.normalizeCode(c.currency);
  if (clinicCur.isEmpty || CityCurrency.matches(clinicCur, cityCur)) return;
  final labelCur = FilterFx.detectCodeFromLabel(c.priceLabel, fallback: '');
  final pageCur = pageText.isEmpty
      ? ''
      : _effectiveCurrencyFromPageText(pageText, '');
  final backed =
      (labelCur.isNotEmpty && CityCurrency.matches(labelCur, clinicCur)) ||
      (pageCur.isNotEmpty && CityCurrency.matches(pageCur, clinicCur));
  if (backed) return;
  debugPrint(
    '[GP] currency mismatch without page backing: ${c.name} '
    '${c.priceMin} ${c.currency} in $city (expected $cityCur)',
  );
}

/// True when AI tagged a Romanian lei amount as euro (MyDerm 900lei → 900 €).
bool _leiMislabeledAsEuro(
  OpenAIClinic c, {
  required String city,
  required String procedure,
  String pageText = '',
}) {
  if (CityCurrency.localCode(city) != 'RON') return false;
  final cur = CityCurrency.normalizeCode(c.currency);
  final label = c.priceLabel.toUpperCase();
  final looksEuro =
      cur == '€' || label.contains('€') || RegExp(r'\bEUR\b').hasMatch(label);
  if (!looksEuro || c.priceMin <= 0) return false;

  if (pageText.isNotEmpty) {
    final hasLei = _pageTextHasLei(pageText);
    final hasEuro = _pageTextHasEuro(pageText);
    if (hasLei && !hasEuro) return true;
    if (hasLei &&
        RegExp(r'\d[\d.\s]*lei\b', caseSensitive: false).hasMatch(pageText) &&
        !pageText.contains('€')) {
      return true;
    }
  }

  final proc = procedure.toLowerCase();
  final botox =
      proc.contains('botox') ||
      proc.contains('toxin') ||
      proc.contains('wrinkle') ||
      proc.contains('neuromodul');
  final filler =
      proc.contains('filler') ||
      proc.contains('hialuronic') ||
      proc.contains('lip') ||
      proc.contains('cheek');
  // Real 1-zone botox in RO is ~80–250 € or 400–1300 lei. 900 € is 900 lei.
  if (botox && c.priceMin >= 400) return true;
  // Real 1 ml filler in RO is rarely ≥700 €; that band is lei.
  if (filler && c.priceMin >= 700) return true;
  return false;
}

OpenAIClinic _fixLeiMislabeledAsEuro(
  OpenAIClinic c, {
  required String city,
  required String procedure,
  String pageText = '',
}) {
  if (!_leiMislabeledAsEuro(
    c,
    city: city,
    procedure: procedure,
    pageText: pageText,
  )) {
    return c;
  }
  debugPrint(
    '[GP] Lei mislabeled as euro: ${c.name} '
    '${c.priceMin.toInt()} ${c.currency} → RON',
  );
  return c.copyWith(
    currency: 'RON',
    priceLabel: _formatPrice(c.priceMin, 'RON'),
  );
}

/// Surgical quotes like Cronos Med 5050 € stored as 5050 RON because
/// București defaults to lei. Real lei rhinoplasty/breast is 18k+ RON.
bool _euroMislabeledAsLei(
  OpenAIClinic c, {
  required String city,
  required String procedure,
}) {
  if (CityCurrency.localCode(city) != 'RON') return false;
  if (!isHighTicketExploreProcedure(procedure) &&
      !isHighTicketExploreProcedure(c.brand)) {
    return false;
  }
  final cur = CityCurrency.normalizeCode(c.currency);
  final label = c.priceLabel.toUpperCase();
  final looksRon =
      cur == 'RON' ||
      cur == 'LEI' ||
      cur.isEmpty ||
      label.contains('RON') ||
      label.contains('LEI');
  final looksEuro =
      cur == '€' || label.contains('€') || RegExp(r'\bEUR\b').hasMatch(label);
  if (looksEuro) return false;
  if (!looksRon || c.priceMin <= 0) return false;
  return c.priceMin >= 2000 && c.priceMin < 16000;
}

OpenAIClinic _fixEuroMislabeledAsLei(
  OpenAIClinic c, {
  required String city,
  required String procedure,
}) {
  if (!_euroMislabeledAsLei(c, city: city, procedure: procedure)) {
    return c;
  }
  debugPrint(
    '[GP] Euro mislabeled as lei: ${c.name} '
    '${c.priceMin.toInt()} ${c.currency} → €',
  );
  return c.copyWith(currency: '€', priceLabel: _formatPrice(c.priceMin, '€'));
}

OpenAIClinic _fixRomanianPublishedCurrency(
  OpenAIClinic c, {
  required String city,
  required String procedure,
  String pageText = '',
}) {
  final leiFixed = _fixLeiMislabeledAsEuro(
    c,
    city: city,
    procedure: procedure,
    pageText: pageText,
  );
  return _fixEuroMislabeledAsLei(leiFixed, city: city, procedure: procedure);
}

/// Infers display currency from scraped page text.
/// Empty [currency] means "no signal" — do not invent RON.
String _effectiveCurrencyFromPageText(String trimmed, String currency) {
  final hasEuro = _pageTextHasEuro(trimmed);
  final hasLei = _pageTextHasLei(trimmed);
  final hasGbp = trimmed.contains('£');
  final hasAed = RegExp(
    r'\baed\b|\bdirhams?\b|درهم|د\.إ',
    caseSensitive: false,
  ).hasMatch(trimmed);

  if (hasGbp) {
    return '£';
  }
  if (hasAed && !hasLei && !hasEuro) {
    return 'AED';
  }
  if (hasEuro && !hasLei) {
    return '€';
  }
  if (hasLei && !hasEuro) {
    return currency.isNotEmpty ? currency : 'RON';
  }
  if (hasEuro && hasLei) {
    final euroCount =
        '€'.allMatches(trimmed).length +
        RegExp(r'\beuros?\b', caseSensitive: false).allMatches(trimmed).length;
    final leiCount = RegExp(
      r'(?:\d\s*)lei\b|\blei\b|\bron\b',
      caseSensitive: false,
    ).allMatches(trimmed).length;
    return euroCount >= leiCount
        ? '€'
        : (currency.isNotEmpty ? currency : 'RON');
  }
  return currency;
}

/// True for real EUR amounts — not Romanian "Europene" / "European".
bool _pageTextHasEuro(String text) {
  return text.contains('€') ||
      RegExp(r'\beuros?\b', caseSensitive: false).hasMatch(text) ||
      RegExp(r'\beur\b', caseSensitive: false).hasMatch(text);
}

/// True for lei/RON, including glued amounts like "900lei".
bool _pageTextHasLei(String text) {
  return RegExp(
    r'(?:\d[\d.\s]*)lei\b|\blei\b|\bron\b',
    caseSensitive: false,
  ).hasMatch(text);
}

/// Detects the real currency from multiple signals.
/// AI often returns wrong currency — this fixes it.
String _detectCurrency({
  required String raw,
  required String label,
  required double pMin,
}) {
  // Check price_label first — most reliable signal
  final l = label.toUpperCase();
  if (l.contains('RON') || l.contains('LEI')) return 'RON';
  if (l.contains('£')) return '£';
  if (l.contains('€')) return '€';
  if (l.contains(r'$')) return r'$';
  if (l.contains('TRY') || l.contains('₺')) return 'TRY';
  if (l.contains('PLN') || l.contains('ZŁ')) return 'PLN';
  if (l.contains('KRW') || l.contains('₩')) return 'KRW';
  if (l.contains('JPY') || l.contains('¥')) return 'JPY';
  if (l.contains('BRL') || l.contains(r'R$')) return 'BRL';
  if (l.contains('INR') || l.contains('₹')) return 'INR';
  if (l.contains('AUD')) return 'AUD';
  if (l.contains('CAD')) return 'CAD';
  if (l.contains('AED')) return 'AED';
  if (l.contains('BGN') ||
      RegExp(r'\bLV\.?\b').hasMatch(l) ||
      l.contains('ЛВ')) {
    return 'BGN';
  }
  if (l.contains('RON') || l.contains('LEI')) return 'RON';

  // Check raw currency field
  final r = raw.toUpperCase().trim();
  if (r == '£' || r == 'GBP') return '£';
  if (r == '€' ||
      r == 'EUR' ||
      r == 'EURO' ||
      raw.trim().toLowerCase() == 'euro') {
    return '€';
  }
  if (r == '\$' || r == 'USD') return r'$';
  if (r == 'RON' || r == 'LEI') return 'RON';
  if (r == 'BGN' || r == 'LV' || r == 'LV.') return 'BGN';
  if (r == 'TRY') return 'TRY';
  if (r == 'PLN') return 'PLN';
  if (r == 'KRW') return 'KRW';
  if (r == 'JPY') return 'JPY';
  if (r == 'BRL') return 'BRL';
  if (r == 'INR') return 'INR';
  if (r == 'AUD') return 'AUD';
  if (r == 'AED') return 'AED';

  // Return raw if it looks like a currency symbol
  if (raw.isNotEmpty) return raw;

  return '';
}

/// Parses a price value from any locale/format the AI may return.
/// Handles currency symbols, "from X", ranges "X–Y", and all thousand-separator styles.
/// WooCommerce Romanian format: "1.071 lei"→1071, "659 Lei"→659, "1.750 lei"→1750.
double? _parseAnyPrice(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  if (v is! String) return null;
  var s = v.trim();
  if (s.isEmpty) return null;

  // "4k" / "4.5k" / "$4k–$9k" → thousands
  final kMatch = RegExp(r'(\d+(?:[.,]\d+)?)\s*[kK]\b').firstMatch(s);
  if (kMatch != null) {
    final n = double.tryParse(kMatch.group(1)!.replaceAll(',', '.'));
    if (n != null && n > 0) return n * 1000;
  }

  // "1.000 lei", "1,200 lei", "1.750 lei" — never take the trailing
  // "200" out of "1,200 lei" (that made UpEstetique lips/cheeks = 200 RON).
  final leiMatch = RegExp(
    r'([\d]{1,3}(?:[.,\s]\d{3})+|\d+(?:[.,]\d{1,2})?)\s*(?:lei|LEI|Lei)\b',
    caseSensitive: false,
  ).firstMatch(s);
  if (leiMatch != null) {
    return _cleanNumber(leiMatch.group(1)!.trim());
  }

  // Handle "from X" / "de la X" / "ab X" / "desde X"
  final fromMatch = RegExp(
    r'(?:from|de\s+la|ab|desde|da|vanaf|od)\s*([\d\s.,]+)',
    caseSensitive: false,
  ).firstMatch(s);
  if (fromMatch != null) {
    return _cleanNumber(fromMatch.group(1)!.trim());
  }

  // DUAL CURRENCY FORMAT: "275€ (1375 lei)" or "650 € (3250 lei)"
  // The EUR value comes first, RON in brackets is just conversion.
  // Extract ONLY the EUR value and ignore the bracketed RON.
  final dualCurrencyMatch = RegExp(
    r'([\d.,]+)\s*€\s*\(\s*[\d.,]+\s*(?:lei|ron|RON)\s*\)',
    caseSensitive: false,
  ).firstMatch(s);
  if (dualCurrencyMatch != null) {
    return _cleanNumber(dualCurrencyMatch.group(1)!.trim());
  }

  // Also handle: "de la 400€ (2000 lei)"
  final dualFromMatch = RegExp(
    r'(?:de\s+la|from|ab|desde)\s*([\d.,]+)\s*€\s*\(',
    caseSensitive: false,
  ).firstMatch(s);
  if (dualFromMatch != null) {
    return _cleanNumber(dualFromMatch.group(1)!.trim());
  }

  // Handle ranges "X–Y" / "X-Y" / "X to Y" → take minimum
  // Use \u2013 for en-dash in a non-raw string
  final rangeMatch = RegExp(
    '([\\d\\s.,]+)\\s*(?:[-\u2013]|to)\\s*([\\d\\s.,]+)',
  ).firstMatch(s);
  if (rangeMatch != null) {
    return _cleanNumber(rangeMatch.group(1)!.trim());
  }

  // Strip everything that is not a digit, dot, comma, or whitespace
  final digits = s.replaceAll(RegExp(r'[^\d.,\s]'), '').trim();
  if (digits.isEmpty) return null;
  return _cleanNumber(digits);
}

/// Converts a digit string with locale-specific separators to a double.
double? _cleanNumber(String s) {
  s = s.trim();
  if (s.isEmpty) return null;

  // Remove space/NBSP thousand separators (Russian, Swedish style: "1 500")
  s = s.replaceAll(RegExp(r'[\s\u00a0]'), '');

  // Remove apostrophe/right-single-quote thousand separators (Swiss: "1'500")
  s = s.replaceAll("'", '').replaceAll('\u2019', '');

  if (s.isEmpty) return null;

  // Case 1: ends with ",XX" (1 or 2 digits) → comma is decimal separator (e.g. "1.500,50")
  if (RegExp(r',\d{1,2}$').hasMatch(s)) {
    s = s.replaceAll('.', '').replaceAll(',', '.');
    return double.tryParse(s);
  }

  // Case 2: ends with ".XX" (1 or 2 digits) → dot is decimal separator (e.g. "1,500.50")
  if (RegExp(r'\.\d{1,2}$').hasMatch(s)) {
    s = s.replaceAll(',', '');
    return double.tryParse(s);
  }

  // Case 3: dot is thousand separator (e.g. "1.500" or "1.500.000")
  if (RegExp(r'^\d{1,3}(\.\d{3})+$').hasMatch(s)) {
    return double.tryParse(s.replaceAll('.', ''));
  }

  // Case 4: comma is thousand separator (e.g. "1,500" or "1,500,000")
  if (RegExp(r'^\d{1,3}(,\d{3})+$').hasMatch(s)) {
    return double.tryParse(s.replaceAll(',', ''));
  }

  // Case 5: plain number — strip remaining separators
  s = s.replaceAll(',', '').replaceAll('.', '');
  return double.tryParse(s);
}
