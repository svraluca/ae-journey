import 'dart:async';
import 'dart:convert';
import 'explore_discovery_transport.dart';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'explore_compare_mix.dart';

/// Compare tabs the Python hunter fills when the city changes.
const kDiscoveryToolCityPills = <String>[
  'Botox',
  'Fillers',
  'Rhinoplasty',
  'Peels',
  'Boob job',
  'Hair',
];

class ExploreDiscoveryToolRow {
  const ExploreDiscoveryToolRow({
    required this.clinicName,
    required this.priceMin,
    required this.currency,
    required this.sourceUrl,
    required this.rawProcedureText,
    required this.rawEvidence,
    required this.rawPriceText,
    required this.clinicOwnPrice,
    required this.cityMatch,
    required this.sourceType,
    required this.evidenceType,
    required this.procedureDisplayName,
    required this.qualifier,
    this.priceMax,
    this.officialWebsite = '',
    this.rating = 0,
    this.reviews = 0,
    this.origin = '',
    this.procedureCanonical = '',
    this.procedureDetail = '',
    this.unit = '',
    this.lastVerifiedAt,
  });

  final String clinicName;
  final double priceMin;
  final double? priceMax;
  final String currency;
  final String sourceUrl;
  final String officialWebsite;
  final String rawProcedureText;
  final String rawEvidence;
  final String rawPriceText;
  final bool clinicOwnPrice;
  final bool cityMatch;
  final String sourceType;
  final String evidenceType;
  final String procedureDisplayName;
  final String procedureCanonical;
  final String procedureDetail;
  final String unit;
  final DateTime? lastVerifiedAt;
  final String qualifier;
  final double rating;
  final int reviews;

  /// `firestore` or `live_search`. A cached fill is not a new clinic.
  final String origin;

  String get verificationPath =>
      '${origin.isEmpty ? 'verified' : origin} | $clinicName | '
      '$priceMin $currency | $sourceType/$evidenceType | $sourceUrl';
}

/// Result of one `/discover-hybrid` call.
///
/// [searchCompleted] is false when the server could not be reached, timed
/// out, or returned a body that is not the hybrid result. Those cases must
/// not be stored as a finished Compare search.
class ExploreDiscoveryToolOutcome {
  const ExploreDiscoveryToolOutcome({
    required this.rows,
    required this.searchCompleted,
    this.failure = '',
    this.fallbackReason = '',
    this.missingLiveSlots = 0,
    this.baseUrl = '',
    this.cardDiagnostics = const [],
    this.storedAvailable = 0,
    this.clientStoredAvailable = 0,
    this.persistedCount = 0,
    this.firestoreAvailable = false,
    this.novelLiveAvailable = 0,
    this.fallbackUsed = false,
    this.growthExhaustedReason = '',
    this.rejectionReasons = const [],
    this.invalidatedSourceUrls = const [],
  });

  final List<ExploreDiscoveryToolRow> rows;
  final bool searchCompleted;
  final String failure;
  final String fallbackReason;
  final int missingLiveSlots;
  final String baseUrl;
  final List<String> cardDiagnostics;
  final int storedAvailable;
  final int clientStoredAvailable;
  final int persistedCount;
  final bool firestoreAvailable;
  final int novelLiveAvailable;
  final bool fallbackUsed;
  final String growthExhaustedReason;
  final List<String> rejectionReasons;
  final List<String> invalidatedSourceUrls;

  String get pythonSummary =>
      'stored_available=$storedAvailable '
      'app_stored_available=$clientStoredAvailable '
      'firestore_available=$firestoreAvailable '
      'persisted_count=$persistedCount '
      'novel_live_available=$novelLiveAvailable '
      'fallback_used=$fallbackUsed '
      'growth_exhausted_reason=${growthExhaustedReason.isEmpty ? '-' : growthExhaustedReason}'
      '${rejectionReasons.isEmpty ? '' : ' · rejected=${rejectionReasons.join(' | ')}'}';

  String get verificationReport => cardDiagnostics.isNotEmpty
      ? cardDiagnostics.join('\n')
      : rows.map((row) => row.verificationPath).join('\n');
}

class ExploreDiscoveryJob {
  const ExploreDiscoveryJob({
    required this.id,
    required this.status,
    this.rows = const [],
    this.error = '',
    this.progress = const {},
    this.city = '',
    this.procedure = '',
  });
  final String id;
  final String status;
  final List<ExploreDiscoveryToolRow> rows;
  final String error;
  final Map<String, Object?> progress;
  final String city;
  final String procedure;
  bool get isFinished => status == 'completed' || status == 'failed';

  /// Progress counters can change without changing any price card.
  String get rowsFingerprint => jsonEncode(rows.map((row) => [
    row.clinicName, row.priceMin, row.priceMax, row.currency, row.sourceUrl,
    row.officialWebsite, row.rawProcedureText, row.rawEvidence, row.rawPriceText,
    row.clinicOwnPrice, row.cityMatch, row.sourceType, row.evidenceType,
    row.procedureDisplayName, row.procedureCanonical, row.procedureDetail,
    row.unit, row.qualifier, row.rating, row.reviews, row.origin,
    row.lastVerifiedAt?.toIso8601String(),
  ]).toList());

  factory ExploreDiscoveryJob.fromJson(Map<String, Object?> data) {
    final request = data['request'];
    return ExploreDiscoveryJob(
      id: '${data['job_id'] ?? ''}', status: '${data['status'] ?? ''}',
      rows: ExplorePriceDiscoveryTool._rowsFromPayload(data),
      error: '${data['error'] ?? ''}',
      city: request is Map ? '${request['city'] ?? ''}' : '',
      procedure: request is Map ? '${request['procedure'] ?? ''}' : '',
      progress: data['progress'] is Map
          ? (data['progress'] as Map).cast<String, Object?>() : const {},
    );
  }

  String get message {
    if (status == 'failed') return 'Search could not finish. Try Find more clinics again.';
    if (status == 'queued') return 'Preparing your clinic price search…';
    if (!isFinished) {
      final pages = (progress['fetched_pages'] as num?)?.toInt() ?? 0;
      return pages > 0
          ? 'Checking clinic websites… $pages pages checked.'
          : 'Searching for verified clinic prices…';
    }
    if (rows.isEmpty) return 'No verified public prices found yet.';
    if (rows.length < kExploreCompareDisplayLimit) return 'Search finished. No more verified public prices found this time.';
    return '';
  }
}

/// Hunter from `aesthetic_price_discovery_v11_67`.
///
/// `127.0.0.1:8080` reaches the Mac only for a desktop app or the iOS
/// Simulator on that Mac. A phone uses [PRICE_DISCOVERY_TOOL_URL]. Search
/// credentials stay on the server.
class ExplorePriceDiscoveryTool {
  static const compareDisplayLimit = kExploreCompareDisplayLimit;
  static const compareStoredTarget = kExploreCompareSavedTarget;
  static const compareFreshTarget = kExploreCompareFreshTarget;
  ExplorePriceDiscoveryTool({http.Client? client, String? baseUrl})
    : _client = client ?? http.Client(),
      _ownsDiscoverClients = client == null,
      _baseUrlOverride = baseUrl;

  static final ExplorePriceDiscoveryTool instance = ExplorePriceDiscoveryTool();

  final http.Client _client;
  // Injected clients cover every API and remain owned by their caller. Default
  // discovery requests use separate clients so cancellation leaves health and
  // index requests available.
  final bool _ownsDiscoverClients;
  final String? _baseUrlOverride;
  DateTime? _downUntil;
  Future<bool>? _healthInFlight;
  DateTime? _lastHealthyAt;
  final Map<String, String> _jobLogStates = {};
  final Map<String, ({DateTime started, Future<bool> request})>
      _cityCollectionRequests = {};
  static Future<({String id, int generation})>? _clientSession;

  static Future<({String id, int generation})> _loadClientSession() async {
    final fallback = 'flutter-${DateTime.now().microsecondsSinceEpoch}';
    try {
      final prefs = await SharedPreferences.getInstance();
      const idKey = 'explore.discovery.client_id.v1';
      const generationKey = 'explore.discovery.generation.v1';
      final id = prefs.getString(idKey) ?? fallback;
      final generation = (prefs.getInt(generationKey) ?? 0) + 1;
      await prefs.setString(idKey, id);
      await prefs.setInt(generationKey, generation);
      return (id: id, generation: generation);
    } catch (_) {
      // Platform storage may be absent in an isolated HTTP test.
      return (id: fallback, generation: 1);
    }
  }
  String _focusKey = '';
  int _focusSequence = 0;
  final Map<String, String> _foregroundJobs = {};
  final Map<String, int> _reportedDisplays = {};
  int _displayReportSequence = 0;

  /// Priority feedback only; the server still validates every price itself.
  Future<void> reportDisplayedCount({required String focusKey, required int count}) async {
    final jobId = _foregroundJobs[focusKey];
    if (jobId == null || focusKey != _focusKey) return;
    final focusSequence = _focusSequence;
    final displayed = count.clamp(0, compareDisplayLimit).toInt();
    final reportKey = '$jobId|$focusSequence';
    if (_reportedDisplays[reportKey] == displayed) return;
    final displaySequence = ++_displayReportSequence;
    final session = await (_clientSession ??= _loadClientSession());
    if (focusKey != _focusKey || focusSequence != _focusSequence) return;
    try {
      final response = await _client.post(
        Uri.parse('$baseUrl/discover-jobs/${Uri.encodeComponent(jobId)}/display'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({
          'client_id': session.id,
          'focus_seq': session.generation * 1000000 + focusSequence,
          'display_seq': displaySequence,
          'displayed_count': displayed,
        }),
      ).timeout(const Duration(seconds: 3));
      if (response.statusCode == 200 &&
          (jsonDecode(response.body) as Map)['accepted'] == true) {
        _reportedDisplays[reportKey] = displayed;
      }
    } catch (_) {
      // A missed acknowledgement keeps foreground priority and retries later.
    }
  }

  /// Called on selection, before any index/health request can finish late.
  void focusDiscovery(String key) {
    if (_focusKey == key) return;
    _focusKey = key;
    _focusSequence++;
  }
  String _activeBaseUrl = '';
  String lastFailure = '';
  bool? _loopbackKnown;
  String lastHardwareMachine = '';

  static const _healthTimeout = Duration(milliseconds: 2500);
  static const _discoverTimeout = Duration(seconds: 180);
  static const interactiveDeadline = Duration(seconds: 12);

  int _priorityDepth = 0;
  Future<void> _backgroundLane = Future<void>.value();
  bool lastSearchFinished = true;
  int _discoverEpoch = 0;
  http.Client? _liveDiscoverClient;

  /// Stops the in-flight POST /discover-hybrid. A city or pill change must
  /// not leave the previous search occupying the single hunter worker.
  void abortInFlightDiscover() {
    _discoverEpoch++;
    final live = _liveDiscoverClient;
    _liveDiscoverClient = null;
    if (live != null && _ownsDiscoverClients) {
      try {
        live.close();
      } catch (_) {}
    }
  }

  ExploreDiscoveryToolOutcome _cancelledDiscover() {
    return ExploreDiscoveryToolOutcome(
      rows: const [],
      searchCompleted: false,
      failure: 'cancelled',
      baseUrl: baseUrl,
    );
  }

  String get baseUrl {
    if (_activeBaseUrl.isNotEmpty) return _activeBaseUrl;
    final urls = candidateBaseUrls();
    return urls.isEmpty ? '' : urls.first;
  }

  /// URLs to try, in order. An explicit override is used alone.
  List<String> candidateBaseUrls({bool? loopbackReachesServer}) {
    final override = _baseUrlOverride?.trim() ?? '';
    if (override.isNotEmpty) {
      return [override.replaceAll(RegExp(r'/+$'), '')];
    }
    return urlsFor(
      loopbackReachesServer: loopbackReachesServer ?? _loopbackKnown ?? false,
      deployedUrl: _env('PRICE_DISCOVERY_TOOL_URL'),
      devUrl: _env('PRICE_DISCOVERY_TOOL_DEV_URL'),
      androidEmulator: !kIsWeb && Platform.isAndroid,
    );
  }

  /// Desktop and the iOS Simulator share the Mac's loopback. A physical
  /// phone does not, even when Dart's [Platform.environment] is empty.
  static List<String> urlsFor({
    required bool loopbackReachesServer,
    required String deployedUrl,
    required String devUrl,
    bool androidEmulator = false,
  }) {
    final out = <String>[];
    void add(String raw) {
      final url = raw.trim().replaceAll(RegExp(r'/+$'), '');
      if (url.isEmpty || out.contains(url)) return;
      out.add(url);
    }

    if (loopbackReachesServer) {
      add(devUrl.trim().isNotEmpty ? devUrl : 'http://127.0.0.1:8080');
      add(deployedUrl);
    } else {
      add(deployedUrl);
      add(devUrl);
      if (androidEmulator &&
          devUrl.trim().isEmpty &&
          deployedUrl.trim().isEmpty) {
        add('http://10.0.2.2:8080');
      }
    }
    return out;
  }

  /// `hw.machine` is `arm64` / `x86_64` in the simulator and `iPhone…` on a phone.
  static bool hardwareMachineIsIosSimulator(String machine) {
    final m = machine.trim().toLowerCase();
    return m == 'arm64' || m == 'x86_64' || m == 'i386';
  }

  static String? readIosHardwareMachine() {
    if (kIsWeb || !Platform.isIOS) return null;
    Pointer<Uint8>? name;
    Pointer<Uint64>? len;
    Pointer<Uint8>? buf;
    try {
      final malloc = DynamicLibrary.process()
          .lookupFunction<
            Pointer<Void> Function(IntPtr),
            Pointer<Void> Function(int)
          >('malloc');
      final free = DynamicLibrary.process()
          .lookupFunction<
            Void Function(Pointer<Void>),
            void Function(Pointer<Void>)
          >('free');
      final sysctlbyname = DynamicLibrary.process()
          .lookupFunction<
            Int32 Function(
              Pointer<Uint8>,
              Pointer<Uint8>,
              Pointer<Uint64>,
              Pointer<Void>,
              Uint64,
            ),
            int Function(
              Pointer<Uint8>,
              Pointer<Uint8>,
              Pointer<Uint64>,
              Pointer<Void>,
              int,
            )
          >('sysctlbyname');
      Pointer<Uint8> cstr(String value) {
        final p = malloc(value.length + 1).cast<Uint8>();
        for (var i = 0; i < value.length; i++) {
          p[i] = value.codeUnitAt(i);
        }
        p[value.length] = 0;
        return p;
      }

      name = cstr('hw.machine');
      len = malloc(8).cast<Uint64>();
      len.value = 0;
      sysctlbyname(name, nullptr, len, nullptr, 0);
      final size = len.value;
      if (size <= 0 || size > 128) return null;
      buf = malloc(size).cast<Uint8>();
      len.value = size;
      if (sysctlbyname(name, buf, len, nullptr, 0) != 0) return null;
      final bytes = <int>[];
      for (var i = 0; i < size; i++) {
        final b = buf[i];
        if (b == 0) break;
        bytes.add(b);
      }
      free(name.cast());
      free(len.cast());
      free(buf.cast());
      name = null;
      len = null;
      buf = null;
      return bytes.isEmpty ? null : String.fromCharCodes(bytes);
    } catch (_) {
      return null;
    }
  }

  Future<bool> _loopbackReachesServer() async {
    if (kIsWeb) return false;
    if (Platform.isMacOS || Platform.isLinux || Platform.isWindows) return true;
    if (!Platform.isIOS) return false;
    final machine = readIosHardwareMachine();
    if (machine != null && machine.isNotEmpty) {
      lastHardwareMachine = machine;
      final simulator = hardwareMachineIsIosSimulator(machine);
      debugPrint('[GP TOOL] ios machine=$machine · simulator=$simulator');
      return simulator;
    }
    try {
      final native = await const MethodChannel(
        'glowpass/runtime',
      ).invokeMethod<bool>('loopbackReachesHost');
      debugPrint('[GP TOOL] ios native loopback=$native');
      return native == true;
    } catch (e) {
      debugPrint(
        '[GP TOOL] ios simulator check failed · $e · '
        'not using 127.0.0.1',
      );
      return false;
    }
  }

  bool get enabled {
    final flag = _env('PRICE_DISCOVERY_TOOL').toLowerCase();
    if (flag.isEmpty) return true;
    return flag != '0' && flag != 'false' && flag != 'off' && flag != 'no';
  }

  String _env(String key) {
    try {
      if (!dotenv.isInitialized) return '';
      return (dotenv.env[key] ?? '').trim();
    } catch (_) {
      return '';
    }
  }

  /// Procedure string the Python canonicalizer already understands.
  ///
  /// The requested procedure wins over the category pill. Laser hair removal
  /// stays laser hair removal even when the Hair tab is selected, and a lip
  /// filler request is not widened into every filler area.
  static String procedureForTool(String procedure, {String pill = ''}) {
    final requested = procedure.trim();
    final p = requested.toLowerCase();
    if (p.contains('hair removal') ||
        (p.contains('laser') && p.contains('hair'))) {
      return 'laser hair removal';
    }
    if (p.contains('filler')) {
      final areas = <String>[
        if (p.contains('lip')) 'lip',
        if (p.contains('cheek')) 'cheek',
        if (p.contains('jaw')) 'jawline',
        if (p.contains('chin')) 'chin',
        if (p.contains('tear') ||
            p.contains('under-eye') ||
            p.contains('under eye'))
          'tear trough',
      ];
      if (areas.length == 1) return '${areas.single} filler';
      return 'dermal filler';
    }
    if (p.contains('botox') || p.contains('anti-wrinkle')) return 'botox';
    if (p.contains('peel')) return 'chemical peel';
    if (p.contains('rhino') || p.contains('nose job')) return 'rhinoplasty';
    if (p.contains('breast') ||
        p.contains('boob') ||
        p.contains('augmentation')) {
      return 'breast augmentation';
    }
    if (p.contains('transplant') ||
        RegExp(r'\bfue\b').hasMatch(p) ||
        RegExp(r'\bfut\b').hasMatch(p)) {
      return 'hair transplant';
    }
    if (p.contains('hair')) return 'hair transplant';
    if (requested.isEmpty) {
      return procedureForTool(pill);
    }
    return requested;
  }

  /// A lip-filler card is not a cheek-filler card, and laser hair removal is
  /// not a transplant.
  static bool rowMatchesRequestedProcedure(
    ExploreDiscoveryToolRow row,
    String procedure,
  ) {
    final requested = procedure.toLowerCase();
    final blob =
        '${row.rawProcedureText} ${row.procedureDisplayName} ${row.rawEvidence}'
            .toLowerCase();
    if (requested.contains('hair removal') ||
        (requested.contains('laser') && requested.contains('hair'))) {
      if (blob.contains('transplant') ||
          RegExp(r'\bfue\b').hasMatch(blob) ||
          RegExp(r'\bdhi\b').hasMatch(blob)) {
        return false;
      }
    }
    if (requested.contains('transplant') ||
        RegExp(r'\bfue\b').hasMatch(requested)) {
      if (blob.contains('hair removal') || blob.contains('laser hair')) {
        return false;
      }
    }
    if (requested.contains('lip') && requested.contains('filler')) {
      final cheekOnly =
          (blob.contains('cheek') || blob.contains('jaw')) &&
          !blob.contains('lip');
      if (cheekOnly) return false;
    }
    if (requested.contains('cheek') && requested.contains('filler')) {
      final lipOnly = blob.contains('lip') && !blob.contains('cheek');
      if (lipOnly) return false;
    }
    return true;
  }

  Future<bool> isReachable() async {
    if (!enabled) {
      lastFailure = 'PRICE_DISCOVERY_TOOL is off';
      return false;
    }
    final down = _downUntil;
    if (down != null && DateTime.now().isBefore(down)) return false;
    final healthy = _lastHealthyAt;
    if (_activeBaseUrl.isNotEmpty && healthy != null &&
        DateTime.now().difference(healthy) < const Duration(seconds: 20)) return true;
    final inflight = _healthInFlight;
    if (inflight != null) return inflight;
    final check = _ping();
    _healthInFlight = check;
    try {
      return await check;
    } finally {
      if (identical(_healthInFlight, check)) _healthInFlight = null;
    }
  }

  Future<bool> _ping() async {
    _loopbackKnown = await _loopbackReachesServer();
    final urls = candidateBaseUrls(loopbackReachesServer: _loopbackKnown);
    debugPrint(
      '[GP TOOL] urls · loopback=$_loopbackKnown · '
      'dev=${_env('PRICE_DISCOVERY_TOOL_DEV_URL').isEmpty ? '-' : _env('PRICE_DISCOVERY_TOOL_DEV_URL')} · '
      '${urls.isEmpty ? 'none' : urls.join(', ')}',
    );
    if (urls.isEmpty) {
      lastFailure =
          'Python search has no URL. Set PRICE_DISCOVERY_TOOL_URL to the '
          'deployed server. 127.0.0.1 only works on the Mac and the iOS Simulator.';
      debugPrint('[GP TOOL] health · no URL · failed');
      _downUntil = DateTime.now().add(const Duration(seconds: 2));
      return false;
    }
    final failures = <String>[];
    for (final url in urls) {
      final known = _activeBaseUrl == url;
      try {
        final res = await _client
            .get(Uri.parse('$url/health'))
            .timeout(_healthTimeout);
        final ok =
            res.statusCode == 200 &&
            (res.body.contains('"ok"') || res.body.contains('0.11'));
        if (ok) {
          _activeBaseUrl = url;
          _lastHealthyAt = DateTime.now();
          lastFailure = '';
          _downUntil = null;
          var serverVersion = 'unknown';
          try {
            final health = jsonDecode(res.body);
            if (health is Map) {
              serverVersion = '${health['version'] ?? 'unknown'}';
            }
          } catch (_) {}
          debugPrint('[GP TOOL] health · $url · ok · version=$serverVersion');
          return true;
        }
        failures.add('$url HTTP ${res.statusCode}');
        debugPrint('[GP TOOL] health · $url · failed · HTTP ${res.statusCode}');
      } catch (e) {
        final timedOut =
            e is TimeoutException || e.toString().contains('TimeoutException');
        final loopback = url.contains('127.0.0.1') || url.contains('localhost');
        // A search already running on this server can delay /health.
        // Keep using it. Falling through to the old search is what scraped
        // news sites and made a new city feel stuck.
        if (known || (timedOut && loopback)) {
          _activeBaseUrl = url;
          lastFailure = '';
          _downUntil = null;
          debugPrint('[GP TOOL] health · $url · busy · still using it');
          return true;
        }
        failures.add('$url $e');
        debugPrint('[GP TOOL] health · $url · failed · $e');
      }
    }
    lastFailure = failures.join('; ');
    if (_loopbackKnown != true &&
        !urls.any((url) => !url.contains('127.0.0.1'))) {
      lastFailure =
          '$lastFailure. This device cannot use 127.0.0.1. Set '
          'PRICE_DISCOVERY_TOOL_URL to the deployed server.';
    }
    _downUntil = DateTime.now().add(const Duration(seconds: 2));
    return false;
  }

  /// Queue a deep search. Returns when the job is accepted, not when it finishes.
  Future<ExploreDiscoveryJob?> enqueueDiscoveryJob({
    required String city,
    required String procedure,
    String countryCode = '',
    String pill = '',
    String reason = 'thin_market',
    bool foreground = false,
    String focusKey = '',
    int clientStoredCount = 0,
    List<String> knownClinicHosts = const [],
    List<String> knownClinicNames = const [],
    List<String> excludedSourceUrls = const [],
  }) async {
    final focusSequence = _focusSequence;
    if (!enabled || !await isReachable()) return null;
    final session = await (_clientSession ??= _loadClientSession());
    final toolProcedure = procedureForTool(procedure, pill: pill);
    if (city.trim().length < 2 || toolProcedure.length < 2) return null;
    final isForeground = (foreground || reason == 'user') &&
        focusSequence == _focusSequence &&
        (focusKey.isEmpty || focusKey == _focusKey);
    try {
      final response = await postExploreDiscoveryJobWithRetry(
            client: _client,
            uri: Uri.parse('$baseUrl/discover-jobs'),
            isCurrent: () => !isForeground ||
                (focusSequence == _focusSequence &&
                 (focusKey.isEmpty || focusKey == _focusKey)),
            body: jsonEncode({
              'city': city.trim(),
              'procedure': toolProcedure,
              if (countryCode.trim().isNotEmpty)
                'country_code': countryCode.trim().toUpperCase(),
              'mode': isForeground ? 'foreground' : 'background',
              'client_id': session.id,
              // The generation also orders focus across a hot restart.
              'focus_seq': session.generation * 1000000 + focusSequence,
              'display_limit': compareDisplayLimit,
              'collection_target': 12,
              'require_client_display_confirmation': true,
              'reason': reason == 'user' && isForeground ? 'user' : 'thin_market',
              'client_stored_count': clientStoredCount.clamp(0, 40),
              'client_known_clinic_hosts': knownClinicHosts.take(40).toList(),
              'client_known_clinic_names': knownClinicNames.take(40).toList(),
              'excluded_source_urls': excludedSourceUrls.take(40).toList(),
            }),
          );
      if (response == null) return null;
      if (response.statusCode != 200) {
        debugPrint(
          '[GP TOOL] discover-job · $city · $toolProcedure · '
          'HTTP ${response.statusCode}',
        );
        lastFailure = 'Discovery job HTTP ${response.statusCode}';
        return null;
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) return null;
      final status = '${decoded['status'] ?? ''}';
      final jobId = '${decoded['job_id'] ?? ''}';
      final active = decoded['enqueued'] == true ||
          status == 'queued' ||
          status == 'running';
      debugPrint(
        '[GP TOOL] discover-job · $city · $toolProcedure · '
        '${active ? status : decoded['reason']} · $jobId',
      );
      if (jobId.isEmpty) return null;
      if (isForeground && focusKey.isNotEmpty) _foregroundJobs[focusKey] = jobId;
      final job = ExploreDiscoveryJob.fromJson(decoded.cast<String, Object?>());
      _logJobState(job);
      return job;
    } catch (error) {
      debugPrint('[GP TOOL] discover-job · $city · $toolProcedure · $error');
      lastFailure = error.toString();
      return null;
    }
  }

  Future<bool> enqueueBackgroundDiscovery({
    required String city, required String procedure, String countryCode = '',
    String pill = '', String reason = 'thin_market',
  }) {
    Future<bool> submit() async {
      final job = await enqueueDiscoveryJob(
        city: city, procedure: procedure, countryCode: countryCode,
        pill: pill, reason: reason,
      );
      return job != null && job.status != 'failed';
    }
    if (reason != 'city_collection') return submit();
    final key = '${city.trim().toLowerCase()}|${countryCode.trim().toUpperCase()}|'
        '${procedureForTool(procedure, pill: pill)}';
    final now = DateTime.now();
    _cityCollectionRequests.removeWhere((_, entry) =>
        now.difference(entry.started) >= const Duration(minutes: 10));
    final previous = _cityCollectionRequests[key];
    if (previous != null) return previous.request;
    late final Future<bool> request;
    request = submit().then((accepted) {
      if (!accepted && identical(_cityCollectionRequests[key]?.request, request)) {
        _cityCollectionRequests.remove(key);
      }
      return accepted;
    }, onError: (Object error, StackTrace stack) {
      if (identical(_cityCollectionRequests[key]?.request, request)) {
        _cityCollectionRequests.remove(key);
      }
      Error.throwWithStackTrace(error, stack);
    });
    _cityCollectionRequests[key] = (started: now, request: request);
    return request;
  }

  Future<ExploreDiscoveryJob?> readDiscoveryJob(String jobId) async {
    if (jobId.isEmpty || !await isReachable()) return null;
    try {
      final response = await _client.get(
        Uri.parse('$baseUrl/discover-jobs/${Uri.encodeComponent(jobId)}'),
      ).timeout(const Duration(seconds: 4));
      if (response.statusCode != 200) return null;
      final data = jsonDecode(response.body);
      if (data is! Map) return null;
      final job = ExploreDiscoveryJob.fromJson(data.cast<String, Object?>());
      if (job.id != jobId || !{'queued', 'running', 'completed', 'failed'}.contains(job.status)) {
        lastFailure = 'Invalid discovery job response';
        return null;
      }
      _logJobState(job);
      return job;
    } catch (error) {
      lastFailure = error.toString();
      return null;
    }
  }

  Stream<ExploreDiscoveryJob> watchDiscoveryJob(
    ExploreDiscoveryJob job, {
    Duration budget = const Duration(minutes: 11),
    Duration pollInterval = const Duration(seconds: 3),
    String focusKey = '',
  }) async* {
    yield job;
    final wall = DateTime.now().add(budget);
    while (!job.isFinished && DateTime.now().isBefore(wall)) {
      final inactive = focusKey.isNotEmpty && focusKey != _focusKey;
      await Future<void>.delayed(inactive
          ? const Duration(seconds: 9) : pollInterval);
      final next = await readDiscoveryJob(job.id);
      if (next == null) continue;
      job = next;
      yield job;
    }
  }

  void _logJobState(ExploreDiscoveryJob job) {
    final p = job.progress;
    final report = '${job.status} · ${p['phase'] ?? '-'} · '
        'scheduling=${p['scheduling'] ?? '-'} '
        'round=${p['round'] ?? '-'} verified=${job.rows.length} '
        'fresh=${p['fresh_count'] ?? 0} pages=${p['fetched_pages'] ?? 0} '
        'serper=${p['serper_requests'] ?? 0} '
        'displayReady=${p['display_ready'] ?? false} '
        'collectionTarget=${p['collection_target'] ?? '-'} '
        'queries=${p['queries'] ?? const []} '
        'reason=${p['shortfall_reason'] ?? '-'} '
        'rejections=${jsonEncode(p['rejections'] ?? const {})}';
    if (_jobLogStates[job.id] == report) return;
    if (_jobLogStates.length >= 50) _jobLogStates.remove(_jobLogStates.keys.first);
    _jobLogStates[job.id] = report;
    debugPrint('[GP TOOL] job-state · ${job.city} · ${job.procedure} · ${job.id} · $report');
  }

  Future<ExploreDiscoveryToolOutcome> loadIndexedPrices({
    required String city, required String procedure, String countryCode = '',
    String pill = '', int limit = 20,
    Duration deadline = const Duration(seconds: 5),
  }) => _readPriceApi(
    '/price-index', city: city, procedure: procedure, countryCode: countryCode,
    pill: pill, limit: limit, deadline: deadline,
  );

  Future<ExploreDiscoveryToolOutcome> refreshKnownPrices({
    required String city, required String procedure, String countryCode = '',
    String pill = '', Duration deadline = interactiveDeadline,
  }) => _readPriceApi(
    '/refresh-prices', city: city, procedure: procedure, countryCode: countryCode,
    pill: pill, deadline: deadline,
  );

  Future<ExploreDiscoveryToolOutcome> _readPriceApi(
    String path, {
    required String city, required String procedure, String countryCode = '',
    String pill = '', int limit = 20, required Duration deadline,
  }) async {
    final wall = DateTime.now().add(deadline);
    if (!enabled) {
      return ExploreDiscoveryToolOutcome(
        rows: const [], searchCompleted: false, failure: 'Price search is disabled',
      );
    }
    try {
      if (!await isReachable().timeout(deadline)) {
        return ExploreDiscoveryToolOutcome(
          rows: const [], searchCompleted: false, failure: lastFailure,
        );
      }
      final remaining = wall.difference(DateTime.now());
      if (remaining <= Duration.zero) throw TimeoutException('Price API deadline');
      final response = await _client.post(
        Uri.parse('$baseUrl$path'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({
          'city': city.trim(), 'procedure': procedureForTool(procedure, pill: pill),
          'country_code': countryCode, 'limit': limit,
        }),
      ).timeout(remaining);
      if (response.statusCode != 200) {
        throw StateError('$path HTTP ${response.statusCode}');
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map || decoded['display_results'] is! List) {
        throw const FormatException('Invalid price-index response');
      }
      lastFailure = '';
      return ExploreDiscoveryToolOutcome(
        rows: _rowsFromPayload(decoded.cast<String, Object?>()),
        searchCompleted: true, baseUrl: baseUrl,
        invalidatedSourceUrls: [
          for (final url in decoded['invalidated_source_urls'] is List
              ? decoded['invalidated_source_urls'] as List : const [])
            if (url is String && url.isNotEmpty) url,
        ],
      );
    } catch (error) {
      lastFailure = error.toString();
      return ExploreDiscoveryToolOutcome(
        rows: const [], searchCompleted: false, failure: lastFailure,
      );
    }
  }

  Future<List<Map<String, Object?>>> searchClinics({
    required String query, required String city, String countryCode = '',
    int limit = 6,
    bool throwOnFailure = false,
  }) async {
    if (!enabled || !await isReachable()) {
      if (throwOnFailure) {
        throw StateError('Clinic search is unavailable. Please try again.');
      }
      return const [];
    }
    try {
      final response = await _client.post(
        Uri.parse('$baseUrl/search-clinics'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({
          'query': query, 'city': city, 'country_code': countryCode, 'limit': limit,
        }),
      ).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        throw StateError('Clinic search HTTP ${response.statusCode}');
      }
      final decoded = jsonDecode(response.body);
      final raw = decoded is Map ? decoded['results'] : null;
      if (raw is! List) throw const FormatException('Invalid clinic-search response');
      lastFailure = '';
      return [
        for (final row in raw)
          if (row is Map) row.map((key, value) => MapEntry('$key', value)),
      ];
    } catch (error) {
      lastFailure = error.toString();
      if (throwOnFailure) rethrow;
      return const [];
    }
  }

  /// Trusted display rows from `/discover-hybrid`.
  ///
  /// [priority] searches start immediately. Background tabs wait, so the
  /// procedure on screen is not stuck behind the other tabs.
  Future<ExploreDiscoveryToolOutcome> discoverHybrid({
    required String city,
    required String procedure,
    String countryCode = '',
    String pill = '',
    bool priority = true,
    List<String> excludedSourceUrls = const [],
    bool broadenSearch = false,
    int serperRequestBudget = 0,
    List<String> storedClinicHosts = const [],
    List<String> storedClinicNames = const [],
    void Function(List<ExploreDiscoveryToolRow> rows)? onPartial,
    Duration? deadline,
    bool completeOnDeadline = false,
    bool boundedInteractive = false,
  }) {
    if (priority) {
      _priorityDepth++;
      return _discoverHybridNow(
        city: city,
        procedure: procedure,
        countryCode: countryCode,
        pill: pill,
        onPartial: onPartial,
        excludedSourceUrls: excludedSourceUrls,
        broadenSearch: broadenSearch,
        serperRequestBudget: serperRequestBudget,
        storedClinicHosts: storedClinicHosts,
        storedClinicNames: storedClinicNames,
        deadline: deadline,
        completeOnDeadline: completeOnDeadline,
        boundedInteractive: boundedInteractive,
      ).whenComplete(() {
        _priorityDepth--;
      });
    }
    final gate = Completer<void>();
    final previous = _backgroundLane;
    _backgroundLane = gate.future;
    final epoch = _discoverEpoch;
    return previous.catchError((Object _) {}).then((_) async {
      try {
        while (_priorityDepth > 0) {
          if (epoch != _discoverEpoch) return _cancelledDiscover();
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
        if (epoch != _discoverEpoch) return _cancelledDiscover();
        return await _discoverHybridNow(
          city: city,
          procedure: procedure,
          countryCode: countryCode,
          pill: pill,
          onPartial: onPartial,
          excludedSourceUrls: excludedSourceUrls,
          broadenSearch: broadenSearch,
          serperRequestBudget: serperRequestBudget,
          storedClinicHosts: storedClinicHosts,
          storedClinicNames: storedClinicNames,
          deadline: deadline,
          completeOnDeadline: completeOnDeadline,
          boundedInteractive: boundedInteractive,
        );
      } finally {
        if (!gate.isCompleted) gate.complete();
      }
    });
  }

  Future<ExploreDiscoveryToolOutcome> _discoverHybridNow({
    required String city,
    required String procedure,
    String countryCode = '',
    String pill = '',
    void Function(List<ExploreDiscoveryToolRow> rows)? onPartial,
    bool allowRetry = true,
    List<String> excludedSourceUrls = const [],
    bool broadenSearch = false,
    int serperRequestBudget = 0,
    List<String> storedClinicHosts = const [],
    List<String> storedClinicNames = const [],
    Duration? deadline,
    bool completeOnDeadline = false,
    bool boundedInteractive = false,
  }) async {
    lastSearchFinished = false;
    if (!await isReachable()) {
      lastSearchFinished = true;
      return ExploreDiscoveryToolOutcome(
        rows: const [],
        searchCompleted: false,
        failure: lastFailure.isEmpty
            ? 'Python search is not reachable'
            : lastFailure,
        baseUrl: baseUrl,
      );
    }
    final toolProcedure = procedureForTool(procedure, pill: pill);
    if (city.trim().length < 2 || toolProcedure.length < 2) {
      lastSearchFinished = true;
      return ExploreDiscoveryToolOutcome(
        rows: const [],
        searchCompleted: false,
        failure: 'City or procedure is too short to search',
        baseUrl: baseUrl,
      );
    }
    final body = <String, Object?>{
      'city': city.trim(),
      'procedure': toolProcedure,
      if (countryCode.trim().isNotEmpty)
        'country_code': countryCode.trim().toUpperCase(),
      'stored_count': compareStoredTarget,
      'fresh_count': compareFreshTarget,
      'display_limit': compareDisplayLimit,
      'enable_growth_search': !boundedInteractive,
      'max_growth_rounds': boundedInteractive ? 1 : (broadenSearch ? 4 : 3),
      'force_full_growth_search': broadenSearch && !boundedInteractive,
      if (serperRequestBudget > 0)
        'serper_request_budget': serperRequestBudget,
      'client_stored_count': storedClinicNames.take(40).length,
      'client_known_clinic_hosts': storedClinicHosts.take(40).toList(),
      'client_known_clinic_names': storedClinicNames.take(40).toList(),
      if (excludedSourceUrls.isNotEmpty)
        'excluded_source_urls': excludedSourceUrls.take(40).toList(),
      'fast_interactive_search': true,
      'economical_growth': true,
      'stream_progress': true,
      // Prefer two saved clinics and two new ones. When a new clinic is not
      // verified, Python fills that slot from the other saved Firestore rows.
      'strict_new_clinics': false,
      'debug': false,
    };
    debugPrint(
      '[GP TOOL] discover-hybrid · $city · $toolProcedure · $baseUrl'
      '${boundedInteractive ? ' · bounded 12s' : ''}',
    );
    var latest = <ExploreDiscoveryToolRow>[];
    var fallbackReason = '';
    var missingLiveSlots = 0;
    var cardDiagnostics = <String>[];
    var storedAvailable = 0;
    var clientStoredAvailable = 0;
    var persistedCount = 0;
    var firestoreAvailable = false;
    var novelLiveAvailable = 0;
    var fallbackUsed = false;
    var growthExhaustedReason = '';
    var rejectionReasons = <String>[];
    var sawComplete = false;
    final request = http.Request('POST', Uri.parse('$baseUrl/discover-hybrid'));
    request.headers['Content-Type'] = 'application/json';
    request.headers['Accept'] = 'application/x-ndjson, application/json';
    request.body = jsonEncode(body);
    final epoch = _discoverEpoch;
    final live = _ownsDiscoverClients ? http.Client() : _client;
    _liveDiscoverClient = live;
    try {
      if (epoch != _discoverEpoch) return _cancelledDiscover();
      final streamed = await live
          .send(request)
          .timeout(const Duration(seconds: 30));
      if (epoch != _discoverEpoch) return _cancelledDiscover();
      if (streamed.statusCode != 200) {
        lastSearchFinished = true;
        return ExploreDiscoveryToolOutcome(
          rows: const [],
          searchCompleted: false,
          failure: 'discover-hybrid HTTP ${streamed.statusCode}',
          baseUrl: baseUrl,
        );
      }
      final buf = StringBuffer();
      final budget = deadline ?? _discoverTimeout;
      final wall = DateTime.now().add(budget);

      void takeMap(Map<String, Object?> event) {
        final kind = '${event['event'] ?? ''}';
        if (kind == 'error') {
          debugPrint('[GP TOOL] discover-hybrid error · ${event['detail']}');
          return;
        }
        if (kind == 'score') {
          final line = '${event['line'] ?? ''}'.trim();
          if (line.isNotEmpty) {
            debugPrint('[GP TOOL] $line');
          }
          return;
        }
        final meta = kind == 'done' && event['body'] is Map
            ? (event['body'] as Map).cast<String, Object?>()
            : event;
        final reason = '${meta['fallback_reason'] ?? ''}'.trim();
        if (reason.isNotEmpty) fallbackReason = reason;
        final missing = meta['adaptive_new_clinics_missing'];
        if (missing is num) missingLiveSlots = missing.round();
        final stored = meta['stored_available'];
        if (stored is num) storedAvailable = stored.round();
        final clientStored = meta['client_stored_available'];
        if (clientStored is num) clientStoredAvailable = clientStored.round();
        final persisted = meta['persisted_count'];
        if (persisted is num) persistedCount = persisted.round();
        firestoreAvailable = meta['firestore_available'] == true;
        final novel = meta['novel_live_available'];
        if (novel is num) novelLiveAvailable = novel.round();
        if (meta['fallback_used'] is bool) {
          fallbackUsed = meta['fallback_used'] as bool;
        }
        final growth = '${meta['growth_exhausted_reason'] ?? ''}'.trim();
        if (growth.isNotEmpty) growthExhaustedReason = growth;
        final rejects = meta['quality_reject_samples'];
        if (rejects is List) {
          rejectionReasons = [
            for (final line in rejects) '$line'.trim(),
          ].where((line) => line.isNotEmpty).take(8).toList();
        }
        final diagnostics = meta['card_diagnostics'];
        if (diagnostics is List) {
          cardDiagnostics = [
            for (final line in diagnostics) '$line'.trim(),
          ].where((line) => line.isNotEmpty).toList();
        }
        final rows = rowsFromEvent(event);
        if (rows.isEmpty && kind == 'partial') return;
        if (rows.isNotEmpty) latest = rows;
        if (kind == 'partial' && rows.isNotEmpty) {
          debugPrint('[GP TOOL] partial · $toolProcedure · ${rows.length}');
          onPartial?.call(rows);
        }
        if (kind == 'done' ||
            (kind.isEmpty && event['display_results'] is List)) {
          sawComplete = true;
        }
      }

      void takeText(String text, {required bool flush}) {
        buf.write(text);
        final raw = buf.toString();
        final lines = raw.split('\n');
        buf.clear();
        if (!flush && lines.isNotEmpty) buf.write(lines.removeLast());
        for (final line in lines) {
          final trimmed = line.trim();
          if (trimmed.isEmpty) continue;
          try {
            final decoded = jsonDecode(trimmed);
            if (decoded is! Map) continue;
            takeMap(decoded.cast<String, Object?>());
          } catch (e) {
            debugPrint('[GP TOOL] discover-hybrid bad line · $e');
          }
        }
      }

      // Decode UTF-8 across chunk boundaries (Hungarian clinic names).
      await for (final chunk
          in streamed.stream
              .transform(utf8.decoder)
              .timeout(budget)) {
        if (epoch != _discoverEpoch) return _cancelledDiscover();
        if (DateTime.now().isAfter(wall)) {
          throw TimeoutException('discover-hybrid');
        }
        takeText(chunk, flush: false);
      }
      takeText('', flush: true);
      if (!sawComplete) {
        lastSearchFinished = true;
        return ExploreDiscoveryToolOutcome(
          rows: latest,
          searchCompleted: false,
          failure: latest.isEmpty
              ? 'discover-hybrid returned a malformed response'
              : 'discover-hybrid closed before the search finished',
          fallbackReason: fallbackReason,
          missingLiveSlots: missingLiveSlots,
          baseUrl: baseUrl,
          cardDiagnostics: cardDiagnostics,
        );
      }
      if (fallbackReason == 'missing_live_slot' && missingLiveSlots == 0) {
        final liveCount = latest
            .where(
              (row) =>
                  row.origin == 'live_search' || row.origin == 'live_fallback',
            )
            .length;
        missingLiveSlots = liveCount >= 2 ? 0 : 2 - liveCount;
      }
      lastSearchFinished = true;
      lastFailure = '';
      debugPrint(
        '[GP TOOL] discover-hybrid · $baseUrl · ok · rows=${latest.length} · '
        'stored_available=$storedAvailable · '
        'novel_live_available=$novelLiveAvailable · '
        'fallback_used=$fallbackUsed · '
        'growth_exhausted_reason=${growthExhaustedReason.isEmpty ? '-' : growthExhaustedReason}',
      );
      if (rejectionReasons.isNotEmpty) {
        debugPrint('[GP TOOL] rejections · ${rejectionReasons.join(' | ')}');
      }
      return ExploreDiscoveryToolOutcome(
        rows: latest,
        searchCompleted: true,
        fallbackReason: fallbackReason,
        missingLiveSlots: missingLiveSlots,
        baseUrl: baseUrl,
        cardDiagnostics: cardDiagnostics,
        storedAvailable: storedAvailable,
        clientStoredAvailable: clientStoredAvailable,
        persistedCount: persistedCount,
        firestoreAvailable: firestoreAvailable,
        novelLiveAvailable: novelLiveAvailable,
        fallbackUsed: fallbackUsed,
        growthExhaustedReason: growthExhaustedReason,
        rejectionReasons: rejectionReasons,
      );
    } on TimeoutException {
      debugPrint(
        '[GP TOOL] discover-hybrid timed out · keeping ${latest.length}',
      );
      lastSearchFinished = true;
      if (completeOnDeadline) {
        return ExploreDiscoveryToolOutcome(
          rows: latest,
          searchCompleted: true,
          fallbackReason: '',
          baseUrl: baseUrl,
          cardDiagnostics: cardDiagnostics,
        );
      }
      return ExploreDiscoveryToolOutcome(
        rows: latest,
        searchCompleted: false,
        failure: 'discover-hybrid timed out',
        fallbackReason: fallbackReason,
        missingLiveSlots: missingLiveSlots,
        baseUrl: baseUrl,
        cardDiagnostics: cardDiagnostics,
      );
    } catch (e) {
      if (epoch != _discoverEpoch) return _cancelledDiscover();
      final message = e.toString();
      final dropped =
          message.contains('Connection closed') ||
          message.contains('Connection refused') ||
          message.contains('Connection reset');
      if (allowRetry && dropped && latest.isEmpty) {
        _downUntil = null;
        debugPrint('[GP TOOL] discover-hybrid retry after disconnect');
        return _discoverHybridNow(
          city: city,
          procedure: procedure,
          countryCode: countryCode,
          pill: pill,
          onPartial: onPartial,
          excludedSourceUrls: excludedSourceUrls,
          broadenSearch: broadenSearch,
          serperRequestBudget: serperRequestBudget,
          storedClinicHosts: storedClinicHosts,
          storedClinicNames: storedClinicNames,
          deadline: deadline,
          completeOnDeadline: completeOnDeadline,
          boundedInteractive: boundedInteractive,
          allowRetry: false,
        );
      }
      debugPrint('[GP TOOL] discover-hybrid failed · $e');
      lastSearchFinished = true;
      lastFailure = message;
      return ExploreDiscoveryToolOutcome(
        rows: latest,
        searchCompleted: false,
        failure: message,
        fallbackReason: fallbackReason,
        missingLiveSlots: missingLiveSlots,
        baseUrl: baseUrl,
        cardDiagnostics: cardDiagnostics,
      );
    } finally {
      if (identical(_liveDiscoverClient, live)) {
        _liveDiscoverClient = null;
      }
      if (_ownsDiscoverClients) {
        try {
          live.close();
        } catch (_) {}
      }
    }
  }

  /// Rows from one progress event, or from a plain `/discover-hybrid` body.
  static List<ExploreDiscoveryToolRow> rowsFromEvent(
    Map<String, Object?> event,
  ) {
    final kind = '${event['event'] ?? ''}';
    if (kind == 'partial') {
      return _rowsFromPayload({
        'display_results': event['display_results'],
        'candidate_results': event['candidate_results'],
      });
    }
    if (kind == 'done') {
      final body = event['body'];
      if (body is Map) {
        return _rowsFromPayload(body.cast<String, Object?>());
      }
      return const [];
    }
    if (event['display_results'] is List) return _rowsFromPayload(event);
    return const [];
  }

  static List<ExploreDiscoveryToolRow> _rowsFromPayload(
    Map<String, Object?> payload,
  ) {
    final raw =
        payload['candidate_results'] is List &&
            (payload['candidate_results'] as List).isNotEmpty
        ? payload['candidate_results']
        : payload['display_results'];
    if (raw is! List) return const [];
    final parsed = <ExploreDiscoveryToolRow>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final row = rowFromJson(item.cast<String, Object?>());
      if (row != null) parsed.add(row);
    }
    return _limitMix(parsed);
  }

  /// Python orders the preferred mix and its verified overflow. Keep that
  /// order; OpenAIService validates prices before applying the display cap.
  /// Capping live_search + live_fallback at two discarded valid fallback slots.
  static List<ExploreDiscoveryToolRow> _limitMix(
    List<ExploreDiscoveryToolRow> rows,
  ) {
    final seen = <String>{};
    final out = <ExploreDiscoveryToolRow>[];
    for (final row in rows) {
      final key = _clinicKey(row.clinicName);
      if (key.isNotEmpty && !seen.add(key)) continue;
      out.add(row);
      if (out.length >= 20) break;
    }
    return out;
  }

  static String _clinicKey(String name) =>
      name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');

  static bool _countryPriceGuide(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase().replaceAll('_', '-') ?? '';
    if (RegExp(r'(?:cuanto-cuesta|precio).{0,65}(?:espana|espanya)(?:/|$)').hasMatch(path)) return true;
    return RegExp(
      r'(?:cost|price)s?.{0,48}(?:usa|uk|canada|australia|united-states|united-kingdom)\b',
    ).hasMatch(path);
  }

  static bool _doctorDirectoryHost(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase().replaceFirst(
          RegExp(r'^www\.'),
          '',
        ) ??
        '';
    const directories = {
      'miodottore.it',
      'dottori.it',
      'doctoralia.it',
      'doctoralia.com',
      'doctolib.it',
      'doctolib.fr',
      'docplanner.com',
      'injectablesbooking.it',
    };
    return directories.any((d) => host == d || host.endsWith('.$d'));
  }

  static bool _bookableMenu(String sourceType, String evidence, String url) {
    if (sourceType != 'marketplace') return false;
    if (url.trim().isEmpty) return false;
    return evidence == 'marketplace_service_menu' ||
        evidence == 'marketplace_profile';
  }

  /// Only a clinic's validated service menu can use a marketplace URL.
  /// Directory hubs and generic market-price pages remain discovery leads.
  static bool canUseMarketplacePrice(ExploreDiscoveryToolRow row) =>
      row.cityMatch && row.priceMin > 0 && row.rawEvidence.trim().isNotEmpty &&
      row.sourceType == 'marketplace' && row.evidenceType == 'marketplace_service_menu';

  static ExploreDiscoveryToolRow? rowFromJson(Map<String, Object?> json) {
    if (json['city_match'] != true) return null;
    final sourceType = '${json['source_type'] ?? ''}'.trim().toLowerCase();
    if (sourceType == 'directory' || sourceType == 'social') return null;
    final name = '${json['clinic_name'] ?? ''}'.trim();
    final url = '${json['source_url'] ?? ''}'.trim();
    if (_countryPriceGuide(url) || _doctorDirectoryHost(url)) return null;
    final evidence = '${json['evidence_type'] ?? ''}'.trim();
    final own = json['clinic_own_price'] == true;
    if (!own && !_bookableMenu(sourceType, evidence, url)) return null;
    final currency = '${json['currency'] ?? ''}'.trim().toUpperCase();
    final priceMin = _asDouble(json['price_min']);
    if (name.length < 2 || url.isEmpty || currency.isEmpty || priceMin <= 0) {
      return null;
    }
    final priceMax = _asDouble(json['price_max']);
    final rawProcedure = '${json['raw_procedure_text'] ?? ''}'.trim();
    final rawEvidence = '${json['raw_evidence'] ?? ''}'.trim();
    final rawPrice = '${json['raw_price_text'] ?? ''}'.trim();
    return ExploreDiscoveryToolRow(
      clinicName: name,
      priceMin: priceMin,
      priceMax: priceMax > priceMin ? priceMax : null,
      currency: currency,
      sourceUrl: url,
      officialWebsite: '${json['official_website'] ?? ''}'.trim(),
      rawProcedureText: rawProcedure,
      rawEvidence: rawEvidence,
      rawPriceText: rawPrice.isNotEmpty
          ? rawPrice
          : _priceText(
              priceMin,
              priceMax > priceMin ? priceMax : null,
              currency,
            ),
      clinicOwnPrice: own,
      cityMatch: true,
      sourceType: sourceType,
      evidenceType: evidence,
      procedureDisplayName: '${json['procedure_display_name'] ?? ''}'.trim(),
      procedureCanonical: '${json['procedure_canonical'] ?? ''}'.trim(),
      procedureDetail: '${json['procedure_detail'] ?? ''}'.trim(),
      unit: '${json['unit'] ?? ''}'.trim(),
      qualifier: '${json['qualifier'] ?? ''}'.trim(),
      rating: _asDouble(json['rating']),
      reviews: _asDouble(json['user_rating_count']).round(),
      lastVerifiedAt: DateTime.tryParse('${json['last_verified_at'] ?? ''}'),
      origin: '${json['origin'] ?? ''}'.trim(),
    );
  }

  static String _priceText(double min, double? max, String currency) {
    if (max != null && max > min) {
      return '${_trimNum(min)}–${_trimNum(max)} $currency';
    }
    return '${_trimNum(min)} $currency';
  }

  static String _trimNum(double n) {
    if (n == n.roundToDouble()) return n.round().toString();
    return n.toString();
  }

  static double _asDouble(Object? raw) {
    if (raw is num) return raw.toDouble();
    return double.tryParse('$raw'.trim()) ?? 0;
  }
}
