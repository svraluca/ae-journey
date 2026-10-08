import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

import '../services/explore_pipeline_config.dart';
import 'explore_city_identity.dart';

/// Calls the 2nd-gen Explore price function. Firestore is still painted
/// immediately by the client; this only requests fresh verified rows.
class ExploreBackendService {
  ExploreBackendService._();
  static final ExploreBackendService instance = ExploreBackendService._();

  static const region = 'us-central1';

  /// Cities that successfully started Bright Data discovery this session.
  static final Set<String> _cityDiscoveryOk = <String>{};
  static final Set<String> _cityDiscoveryInFlight = <String>{};
  static final Map<String, ({int? candidateCount, String discoveryStatus})>
      _coverageByKey = {};

  /// Active Explore locality from the location picker (Places-resolved).
  ExploreCityIdentity? _activeCityIdentity;

  /// Client + Functions contract version — log on every discovery call.
  static const discoveryPipelineVersion = '2026.09.17.city-discovery.v2';

  void setActiveCityIdentity(ExploreCityIdentity? identity) {
    _activeCityIdentity = identity;
  }

  ExploreCityIdentity? get activeCityIdentity => _activeCityIdentity;

  static String _coverageKey(String city, String procedure) =>
      '${city.trim().toLowerCase()}|${procedure.trim().toLowerCase()}';

  void rememberCoverage({
    required String city,
    required String procedure,
    int? candidateCount,
    String discoveryStatus = '',
  }) {
    _coverageByKey[_coverageKey(city, procedure)] = (
      candidateCount: candidateCount,
      discoveryStatus: discoveryStatus,
    );
  }

  ({int? candidateCount, String discoveryStatus})? lastCoverage({
    required String city,
    required String procedure,
  }) =>
      _coverageByKey[_coverageKey(city, procedure)];

  FirebaseFunctions get _fn => FirebaseFunctions.instanceFor(region: region);

  /// Returns null when the callable is missing/unavailable so the client
  /// can fall back to deterministic on-device fetch.
  Future<({
    List<Map<String, Object?>> cached,
    List<Map<String, Object?>> fresh,
    Map<String, Object?> coverage,
  })?> fetchFresh({
    required String city,
    required String procedure,
    List<String> excludeClinicKeys = const [],
    int freshLimit = 2,
    String mode = 'interactive',
  }) async {
    final deep = mode.trim().toLowerCase() == 'deep';
    final active = _activeCityIdentity;
    try {
      debugPrint(
        deep ? '[BACKEND DEEP] $city · $procedure' : '[BACKEND QUICK] $city · $procedure',
      );
      final callable = _fn.httpsCallable(
        'getExploreProcedurePrices',
        options: HttpsCallableOptions(
          timeout: deep
              ? const Duration(seconds: 110)
              : const Duration(seconds: 12),
        ),
      );
      final payload = <String, Object?>{
        'city': city,
        'procedure': procedure,
        'excludeClinicKeys': excludeClinicKeys,
        'freshLimit': freshLimit,
        'mode': deep ? 'deep' : 'interactive',
      };
      if (active != null) {
        if (active.cityId.isNotEmpty) payload['cityId'] = active.cityId;
        if (active.countryCode.isNotEmpty) {
          payload['countryCode'] = active.countryCode;
        }
        if (active.countryName.isNotEmpty) {
          payload['countryName'] = active.countryName;
        }
        if (active.adminArea.isNotEmpty) payload['adminArea'] = active.adminArea;
        if (active.placeId.isNotEmpty) payload['placeId'] = active.placeId;
        if (active.latitude != null) payload['latitude'] = active.latitude;
        if (active.longitude != null) payload['longitude'] = active.longitude;
        if (active.languageCodes.isNotEmpty) {
          payload['languageCodes'] = active.languageCodes;
        }
        if (active.currencyCode.isNotEmpty) {
          payload['currencyCode'] = active.currencyCode;
        }
        if (active.canonicalName.isNotEmpty) {
          payload['canonicalName'] = active.canonicalName;
        }
        if (active.localName.isNotEmpty) payload['localName'] = active.localName;
      }
      final result = await callable.call(payload);
      final data = result.data;
      if (data is! Map) return null;
      List<Map<String, Object?>> parse(Object? raw) {
        if (raw is! List) return const [];
        return [
          for (final row in raw)
            if (row is Map)
              row.map((k, v) => MapEntry('$k', v)),
        ];
      }

      final fresh = parse(data['fresh']);
      final cached = parse(data['cached']);
      final coverageRaw = data['coverage'];
      final coverage = coverageRaw is Map
          ? coverageRaw.map((k, v) => MapEntry('$k', v))
          : <String, Object?>{};
      debugPrint(
        '[GP] Backend explore: cached=${cached.length} fresh=${fresh.length}'
        '${coverage.isNotEmpty ? " · candidates=${coverage["candidateCount"]}" : ""}',
      );
      final rawCount = coverage['candidateCount'];
      rememberCoverage(
        city: city,
        procedure: procedure,
        candidateCount: rawCount is num ? rawCount.toInt() : null,
        discoveryStatus: '${coverage['discoveryStatus'] ?? ''}',
      );
      return (cached: cached, fresh: fresh, coverage: coverage);
    } on FirebaseFunctionsException catch (e, st) {
      debugPrint(
        '[GP] Backend explore skipped · stage=getExploreProcedurePrices '
        '· type=${e.runtimeType} · code=${e.code} · message=${e.message} '
        '· city=$city · procedure=$procedure '
        '· candidates=${lastCoverage(city: city, procedure: procedure)?.candidateCount ?? "?"}',
      );
      if (kDebugMode) {
        debugPrint('[GP] Backend explore stack: $st');
      }
      return null;
    } catch (e, st) {
      debugPrint(
        '[GP] Backend explore failed · stage=getExploreProcedurePrices '
        '· type=${e.runtimeType} · message=$e '
        '· city=$city · procedure=$procedure',
      );
      if (kDebugMode) {
        debugPrint('[GP] Backend explore stack: $st');
      }
      return null;
    }
  }

  static final Set<String> _verifyInFlight = <String>{};

  /// Fire-and-forget city discovery when coverage is unknown or thin.
  ///
  /// **Unknown coverage is the strongest reason to start discovery** — a never
  /// searched city must not be treated as "nothing to search."
  /// Backend skips the paid sweep when Firestore already has healthy coverage.
  /// Never blocks Explore UI; never exposes Bright Data credentials.
  void requestCityDiscoveryIfNeeded({
    required String city,
    required String procedure,
    required int verifiedPoolCount,
    int? candidateCount,
    String discoveryStatus = '',
    bool coverageDocumentExists = false,
    String cityId = '',
    String countryCode = '',
    String adminArea = '',
    double? latitude,
    double? longitude,
    String placeId = '',
  }) {
    final c = city.trim();
    if (c.isEmpty || c.toLowerCase() == 'worldwide') return;

    final status = exploreCoverageStatusFromWire(discoveryStatus);
    // Post-validation visible count below target always needs discovery —
    // never treat raw candidateCount as pool_healthy on the client.
    final belowVisibleTarget =
        verifiedPoolCount < ExplorePipelineConfig.visibleTarget;
    final needsDiscovery = belowVisibleTarget ||
        exploreCoverageNeedsDiscovery(
          status: status,
          candidateCount: candidateCount,
          verifiedVisibleCount: verifiedPoolCount,
          coverageDocumentExists: coverageDocumentExists ||
              candidateCount != null ||
              discoveryStatus.trim().isNotEmpty,
        );
    if (!needsDiscovery) {
      requestCandidateVerifyIfNeeded(city: c, procedure: procedure);
      return;
    }

    final active = _activeCityIdentity;
    final resolvedCityId = cityId.trim().isNotEmpty
        ? cityId.trim()
        : (active != null &&
                active.displayName.trim().toLowerCase() == c.toLowerCase()
            ? active.cityId
            : '');
    final resolvedCc = countryCode.trim().isNotEmpty
        ? countryCode.trim()
        : (active != null &&
                active.displayName.trim().toLowerCase() == c.toLowerCase()
            ? active.countryCode
            : '');
    final resolvedAdmin = adminArea.trim().isNotEmpty
        ? adminArea.trim()
        : (active != null &&
                active.displayName.trim().toLowerCase() == c.toLowerCase()
            ? active.adminArea
            : '');
    final resolvedPlaceId = placeId.trim().isNotEmpty
        ? placeId.trim()
        : (active != null &&
                active.displayName.trim().toLowerCase() == c.toLowerCase()
            ? active.placeId
            : '');
    final resolvedLat = latitude ??
        (active != null &&
                active.displayName.trim().toLowerCase() == c.toLowerCase()
            ? active.latitude
            : null);
    final resolvedLng = longitude ??
        (active != null &&
                active.displayName.trim().toLowerCase() == c.toLowerCase()
            ? active.longitude
            : null);

    final key = resolvedCityId.isNotEmpty
        ? '${resolvedCityId}|${procedure.trim().toLowerCase()}'
        : '${c.toLowerCase()}|${procedure.trim().toLowerCase()}';
    if (_cityDiscoveryOk.contains(key) || _cityDiscoveryInFlight.contains(key)) {
      requestCandidateVerifyIfNeeded(city: c, procedure: procedure);
      return;
    }
    _cityDiscoveryInFlight.add(key);
    final reason = !coverageDocumentExists &&
            candidateCount == null &&
            discoveryStatus.trim().isEmpty
        ? 'unknown_coverage'
        : (status == ExploreCoverageStatus.thin
            ? 'thin'
            : 'partial_or_retry');
    debugPrint(
      '[BRIGHTDATA DISCOVERY] request background · $c · $procedure · '
      'pipeline=$discoveryPipelineVersion · '
      'reason=$reason · candidates=${candidateCount ?? "?"} '
      'verified=$verifiedPoolCount · status=${status.name}'
      '${resolvedCityId.isNotEmpty ? " · cityId=$resolvedCityId" : ""}'
      '${resolvedCc.isNotEmpty ? " · cc=$resolvedCc" : ""}'
      '${resolvedPlaceId.isNotEmpty ? " · placeId=$resolvedPlaceId" : ""}',
    );
    Future<void>(() async {
      try {
        final callable = _fn.httpsCallable(
          'requestExploreCityDiscovery',
          options: HttpsCallableOptions(
            timeout: const Duration(seconds: 20),
          ),
        );
        final result = await callable.call(<String, Object?>{
          'city': c,
          'procedure': procedure,
          'seedAll': (candidateCount ?? 0) == 0 && verifiedPoolCount <= 1,
          if (resolvedCityId.isNotEmpty) 'cityId': resolvedCityId,
          if (resolvedCc.isNotEmpty) 'countryCode': resolvedCc,
          if (resolvedAdmin.isNotEmpty) 'adminArea': resolvedAdmin,
          if (resolvedPlaceId.isNotEmpty) 'placeId': resolvedPlaceId,
          if (resolvedLat != null) 'latitude': resolvedLat,
          if (resolvedLng != null) 'longitude': resolvedLng,
        });
        final data = result.data;
        final map = data is Map
            ? data.map((k, v) => MapEntry('$k', v))
            : <String, Object?>{};
        debugPrint(
          '[BRIGHTDATA DISCOVERY] result · ok=${map['ok']} · '
          'pipeline=${map['pipelineVersion'] ?? discoveryPipelineVersion} · '
          'skipped=${map['skipped']} · reason=${map['reason']} · '
          'status=${map['status']} · cityId=${map['cityId']} · '
          'candidates=${map['candidates'] ?? map['candidatesStored']} · '
          'discovered=${map['candidatesDiscovered']} · '
          'visible=${map['verifiedVisibleCount']} · '
          'noPublicPrice=${map['noPublicPriceCount']} · '
          'jobId=${map['jobId']}',
        );
        final discovered = map['candidatesStored'] ?? map['candidates'];
        if (discovered is num ||
            map['candidatesDiscovered'] is num ||
            '${map['status'] ?? ''}'.isNotEmpty) {
          rememberCoverage(
            city: c,
            procedure: procedure,
            candidateCount: discovered is num
                ? discovered.toInt()
                : (map['candidatesDiscovered'] is num
                    ? (map['candidatesDiscovered'] as num).toInt()
                    : candidateCount),
            discoveryStatus: '${map['status'] ?? discoveryStatus}',
          );
        }
        final skipped = map['skipped'] == true;
        final skipReason = '${map['reason'] ?? ''}';
        if (skipped &&
            (skipReason == 'ttl_fresh' ||
                skipReason == 'already_running' ||
                skipReason == 'lease_held' ||
                skipReason == 'pool_healthy')) {
          _cityDiscoveryOk.add(key);
        } else if (map['ok'] == true && !skipped) {
          _cityDiscoveryOk.add(key);
        }
        requestCandidateVerifyIfNeeded(city: c, procedure: procedure);
      } on FirebaseFunctionsException catch (e) {
        debugPrint('[BRIGHTDATA DISCOVERY] ack · ${e.code}');
        // Deadline = job accepted / still running server-side — do not treat
        // as "city has no clinics."
        if (e.code == 'deadline-exceeded') {
          _cityDiscoveryOk.add(key);
          rememberCoverage(
            city: c,
            procedure: procedure,
            candidateCount: candidateCount,
            discoveryStatus: 'running',
          );
        }
      } catch (e) {
        debugPrint('[BRIGHTDATA DISCOVERY] failed · $e');
        rememberCoverage(
          city: c,
          procedure: procedure,
          candidateCount: candidateCount,
          discoveryStatus: 'failed',
        );
      } finally {
        _cityDiscoveryInFlight.remove(key);
      }
    });
  }

  /// Persist client-discovered official clinic identities for later verify.
  void enqueueDiscoveredCandidates({
    required String city,
    required String procedure,
    required List<Map<String, Object?>> candidates,
  }) {
    final c = city.trim();
    if (c.isEmpty || candidates.isEmpty) return;
    final active = _activeCityIdentity;
    final payload = <String, Object?>{
      'city': c,
      'procedure': procedure,
      'candidates': candidates.take(40).toList(growable: false),
      if (active != null &&
          active.displayName.trim().toLowerCase() == c.toLowerCase()) ...{
        if (active.cityId.isNotEmpty) 'cityId': active.cityId,
        if (active.countryCode.isNotEmpty) 'countryCode': active.countryCode,
        if (active.placeId.isNotEmpty) 'placeId': active.placeId,
        if (active.latitude != null) 'latitude': active.latitude,
        if (active.longitude != null) 'longitude': active.longitude,
      },
    };
    debugPrint(
      '[ENQUEUE CANDIDATES] pipeline=$discoveryPipelineVersion · '
      '$c · $procedure · n=${candidates.length}',
    );
    Future<void>(() async {
      try {
        final callable = _fn.httpsCallable(
          'enqueueExploreClinicCandidates',
          options: HttpsCallableOptions(
            timeout: const Duration(seconds: 20),
          ),
        );
        final result = await callable.call(payload);
        final data = result.data;
        final map = data is Map
            ? data.map((k, v) => MapEntry('$k', v))
            : <String, Object?>{};
        debugPrint(
          '[ENQUEUE CANDIDATES] result · ok=${map['ok']} · '
          'stored=${map['candidatesStored']} · '
          'noPublic=${map['noPublicPriceCount']} · '
          'cityId=${map['cityId']}',
        );
      } catch (e) {
        debugPrint('[ENQUEUE CANDIDATES] failed · $e');
      }
    });
  }

  /// Fire-and-forget server-side verification of stored candidates.
  void requestCandidateVerifyIfNeeded({
    required String city,
    required String procedure,
  }) {
    final c = city.trim();
    if (c.isEmpty || c.toLowerCase() == 'worldwide') return;
    final key = '${c.toLowerCase()}|${procedure.trim().toLowerCase()}';
    if (_verifyInFlight.contains(key)) return;
    _verifyInFlight.add(key);
    Future<void>(() async {
      try {
        final callable = _fn.httpsCallable(
          'verifyExploreCandidates',
          options: HttpsCallableOptions(
            timeout: const Duration(seconds: 25),
          ),
        );
        await callable.call(<String, Object?>{
          'city': c,
          'procedure': procedure,
        });
      } on FirebaseFunctionsException catch (e) {
        if (e.code == 'not-found') {
          debugPrint(
            '[VERIFY QUEUE] not-found · verifyExploreCandidates is not '
            'deployed in $region',
          );
        } else {
          debugPrint('[VERIFY QUEUE] ack · ${e.code}');
        }
      } catch (e) {
        debugPrint('[VERIFY QUEUE] failed · $e');
      } finally {
        _verifyInFlight.remove(key);
      }
    });
  }

  @Deprecated('Fresha/Apify marketplace seed disabled — use requestCityDiscoveryIfNeeded')
  void requestMarketplaceSeedIfNeeded({
    required String city,
    required int verifiedPoolCount,
  }) {
    debugPrint(
      '[FRESHA SEED] disabled · USE_APIFY_FRESHA=false · city=$city · '
      'pool=$verifiedPoolCount',
    );
  }
}
