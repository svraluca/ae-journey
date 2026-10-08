import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'explore_price_sanity.dart';
import 'explore_clinic_identity.dart';
import 'explore_search_locale.dart';
import 'explore_backend_service.dart';

/// Shared Explore prices from Google (search / clinic websites).
///
/// First user for a city + procedure pays the Google lookup; everyone else
/// reads Firestore so we do not call AI on every open.
class ExploreGooglePriceStore {
  ExploreGooglePriceStore._();
  static final ExploreGooglePriceStore instance = ExploreGooglePriceStore._();

  static const collection = 'explore_google_prices';
  // v14: lockstep with functions/explore/firestoreStore.js REVISION.
  static const revision = 'v14';
  static const _previousRevisions = ['v13', 'v12', 'v11', 'v10'];
  static const ttl = Duration(days: 14);
  static const ratingTtl = Duration(days: 90);
  static const maxClinics = 30;

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final Map<String, List<Map<String, Object?>>> _memory = {};
  final Map<String, Future<List<Map<String, Object?>>>> _readCoalesce = {};
  final Map<String, String> _writeFingerprints = {};
  final Map<String, Future<void>> _writeLocks = {};
  final Map<String, bool> _cleanupDirty = {};

  static String docId({
    required String city,
    required String procedure,
    String? revisionOverride,
    String cityId = '',
  }) {
    final rev = revisionOverride ?? revision;
    final locality = cityId.trim().isNotEmpty
        ? cityId.trim()
        : city.trim().toLowerCase();
    final raw = '$rev|$locality|${procedure.trim().toLowerCase()}';
    final encoded = Uri.encodeComponent(raw).replaceAll('%', '_');
    if (encoded.length <= 400) return encoded;
    return encoded.substring(0, 400);
  }

  String _resolvedCityId(String city, String explicit) {
    if (explicit.trim().isNotEmpty) return explicit.trim();
    final active = ExploreBackendService.instance.activeCityIdentity;
    // A job for a previously selected city may finish after the user moves.
    // Never write it under the newly selected city's place ID.
    if (active == null ||
        active.displayName.trim().toLowerCase() != city.trim().toLowerCase()) {
      return '';
    }
    return active.cityId.trim();
  }

  Future<List<Map<String, Object?>>> load({
    required String city,
    required String procedure,
    bool forceReload = false,
    String cityId = '',
  }) {
    final resolvedCityId = _resolvedCityId(city, cityId);
    final id = docId(city: city, procedure: procedure, cityId: resolvedCityId);
    final legacyId = resolvedCityId.isNotEmpty
        ? docId(city: city, procedure: procedure, revisionOverride: 'v12')
        : '';
    if (!forceReload && _memory.containsKey(id)) {
      return Future.value(_memory[id] ?? const []);
    }
    if (forceReload) {
      _memory.remove(id);
      _readCoalesce.remove(id);
    }

    return _readCoalesce.putIfAbsent(id, () async {
      try {
        if (FirebaseAuth.instance.currentUser == null) {
          return const [];
        }

        Future<DocumentSnapshot<Map<String, dynamic>>> readId(String docKey) =>
            _db.collection(collection).doc(docKey).get();

        var doc = await readId(id);
        final namedId = docId(city: city, procedure: procedure);
        if (!doc.exists && namedId != id) {
          doc = await readId(namedId);
        }
        if (!doc.exists && legacyId.isNotEmpty && legacyId != id) {
          doc = await readId(legacyId);
        }
        for (final prev in _previousRevisions) {
          if (doc.exists) break;
          final prevId = docId(
            city: city,
            procedure: procedure,
            revisionOverride: prev,
          );
          if (prevId == id || prevId == legacyId) continue;
          doc = await readId(prevId);
        }

        List<Map<String, Object?>> clinicsFrom(
          DocumentSnapshot<Map<String, dynamic>> doc,
        ) {
          if (!doc.exists) return const [];
          final data = doc.data();
          if (data == null) return const [];
          final ts = data['cachedAt'];
          final cachedAt = ts is Timestamp
              ? ts.toDate()
              : DateTime.tryParse('$ts');
          final raw = data['clinics'];
          if (raw is! List) return const [];
          final parsed = <Map<String, Object?>>[
            for (final row in raw)
              if (row is Map) row.map((k, v) => MapEntry('$k', v)),
          ];
          if (parsed.isEmpty) return const [];

          final now = DateTime.now();
          final priceExpired =
              cachedAt != null && now.difference(cachedAt) > ttl;
          // Age schedules refresh; it does not invalidate a verified quote.
          // All ages go through the same evidence/city/revision trust gates.
          final usable = <Map<String, Object?>>[];
          var dirty = false;
          for (final row in parsed) {
            final cleaned = stripInvalidCachedPriceJson(
              row, procedure: procedure, city: city, logRejects: false,
            );
            final source =
                '${cleaned['price_source_url'] ?? cleaned['source_url'] ?? ''}'.trim();
            if ((source.isNotEmpty && exploreUrlConflictsWithSearchCity(source, city)) ||
                !_cachedRowHasUsablePrice(cleaned) ||
                clinicIdentityRejectReason('${cleaned['name'] ?? ''}') != null) {
              dirty = true;
              continue;
            }
            cleaned['price_is_stale'] = priceExpired;
            usable.add(cleaned);
          }
          if (dirty) _cleanupDirty[id] = true;
          return usable;
        }

        final clinics = clinicsFrom(doc);
        _memory[id] = clinics;
        return clinics;
      } catch (e) {
        debugPrint('[GP] Google prices load error: $e');
        return const [];
      } finally {
        _readCoalesce.remove(id);
      }
    });
  }

  /// Merge Google-sourced clinic JSON into the shared doc (by canonical identity).
  Future<void> upsert({
    required String city,
    required String procedure,
    required List<Map<String, Object?>> clinics,
    String cityId = '',
    Set<String> dropKeys = const {},
  }) async {
    final resolvedCityId = _resolvedCityId(city, cityId);
    final incoming = clinics.where((c) {
      final name = '${c['name'] ?? ''}'.trim();
      if (name.isEmpty) return false;
      if (clinicIdentityRejectReason(name) != null) return false;
      final source = '${c['price_source_url'] ?? c['source_url'] ?? ''}'.trim();
      if (source.isNotEmpty &&
          exploreUrlConflictsWithSearchCity(source, city)) {
        return false;
      }
      final reject = '${c['price_rejection_reason'] ?? ''}'.trim();
      if (reject == 'other_city_source_url' ||
          reject == 'city_fit_rejected' ||
          reject == 'superseded_other_city') {
        return false;
      }
      final min = (c['price_min'] as num?)?.toDouble() ?? 0;
      if (min > 0) {
        final status = '${c['price_verification_status'] ?? ''}'
            .trim()
            .toLowerCase();
        if (status == 'legacy_untrusted' ||
            status == 'legacy_unverified' ||
            c['needs_reverification'] == true) {
          return false;
        }
        final rawPrice = '${c['raw_price_text'] ?? ''}'.trim();
        final rawProc = '${c['raw_procedure_text'] ?? c['brand'] ?? ''}'.trim();
        final method = '${c['extraction_method'] ?? ''}'.trim();
        final verified =
            c['price_verified'] == true ||
            status == 'official_website' ||
            (c['marketplace_identity_verified'] == true &&
                (status == 'fresha_marketplace' ||
                    status == 'booksy_marketplace' ||
                    '${c['source_type'] ?? ''}' == 'marketplace'));
        final sane = isValidExtractedPriceCandidate(
          rawPriceText: rawPrice.isNotEmpty
              ? rawPrice
              : '${c['price_label'] ?? ''}'.trim(),
          priceMin: min,
          currency: '${c['currency'] ?? ''}'.trim(),
          extractionMethod: method,
          rawEvidence: '${c['price_evidence_text'] ?? ''}'.trim(),
          procedure: rawProc,
          sourceUrl: source,
          logRejects: false,
        );
        if (rawPrice.isEmpty ||
            rawProc.isEmpty ||
            source.isEmpty ||
            method.isEmpty ||
            !verified ||
            !sane ||
            '${c['price_extract_revision'] ?? ''}'.trim() !=
                kExplorePriceExtractRevision) {
          return false;
        }
      }
      return min > 0;
    }).toList();
    final cleanupKey = docId(
      city: city,
      procedure: procedure,
      cityId: resolvedCityId,
    );
    if (incoming.isEmpty && _cleanupDirty[cleanupKey] != true) {
      return;
    }

    final id = cleanupKey;
    final prevLock = _writeLocks[id] ?? Future<void>.value();
    final gate = Completer<void>();
    _writeLocks[id] = gate.future;
    try {
      await prevLock;
      final existing = List<Map<String, Object?>>.from(
        _memory[id] ?? await load(city: city, procedure: procedure),
      );
      final byKey = <String, Map<String, Object?>>{};
      for (final c in existing) {
        final cleaned = stripInvalidCachedPriceJson(
          c,
          procedure: procedure,
          city: city,
          logRejects: false,
        );
        if (!_cachedRowHasUsablePrice(cleaned)) continue;
        if (clinicIdentityRejectReason('${cleaned['name'] ?? ''}') != null) {
          continue;
        }
        final k = _rowMergeKey(cleaned);
        if (k.isEmpty || dropKeys.contains(k)) continue;
        byKey[k] = cleaned;
      }
      final nowIso = DateTime.now().toUtc().toIso8601String();
      for (final c in incoming) {
        final k = _rowMergeKey(c);
        if (k.isEmpty) continue;
        final prev = byKey[k];
        if (prev == null) {
          final created = Map<String, Object?>.from(c);
          final createdRating = (created['rating'] as num?)?.toDouble() ?? 0;
          final createdReviews = (created['reviews'] as num?)?.toInt() ?? 0;
          if (createdRating > 0 || createdReviews > 0) {
            created['rating_updated_at'] = nowIso;
          }
          byKey[k] = created;
          continue;
        }
        final next = Map<String, Object?>.from(prev);
        for (final key in c.keys) {
          final v = c[key];
          if (v == null) continue;
          next[key] = v;
        }
        final rating = (c['rating'] as num?)?.toDouble() ?? 0;
        final reviews = (c['reviews'] as num?)?.toInt() ?? 0;
        if (rating > ((prev['rating'] as num?)?.toDouble() ?? 0)) {
          next['rating'] = rating;
        }
        if (reviews > ((prev['reviews'] as num?)?.toInt() ?? 0)) {
          next['reviews'] = reviews;
        }
        byKey[k] = next;
      }
      var merged = byKey.values.where(_cachedRowHasUsablePrice).toList();
      if (merged.length > maxClinics) {
        merged = merged.take(maxClinics).toList();
      }
      if (merged.isEmpty) {
        debugPrint(
          '[GP] Google prices skip empty overwrite · $procedure · $city',
        );
        return;
      }
      _memory[id] = merged;

      final fingerprint = merged.map(_rowFingerprint).toList()..sort();
      final joined = fingerprint.join(';;');
      if (_writeFingerprints[id] == joined && _cleanupDirty[id] != true) {
        debugPrint('[GP] Firestore write skipped · unchanged');
        return;
      }
      if (FirebaseAuth.instance.currentUser == null) return;

      await _db.collection(collection).doc(id).set({
        'city': city.trim(),
        if (resolvedCityId.isNotEmpty) 'cityId': resolvedCityId,
        'procedure': procedure.trim(),
        'revision': revision,
        'source': 'google',
        'clinicCount': merged.length,
        'cachedAt': FieldValue.serverTimestamp(),
        'ttlHours': ttl.inHours,
        'cleanupDirty': false,
        'clinics': merged.take(maxClinics).toList(),
      }, SetOptions(merge: true));
      _writeFingerprints[id] = joined;
      _cleanupDirty[id] = false;
      debugPrint(
        '[GP] Google prices WRITE: ${merged.length} clinics · $procedure · $city',
      );
    } catch (e) {
      debugPrint('[GP] Google prices write error: $e');
    } finally {
      gate.complete();
      if (_writeLocks[id] == gate.future) _writeLocks.remove(id);
    }
  }

  static bool _cachedRowHasUsablePrice(Map<String, Object?> row) {
    final min = (row['price_min'] as num?)?.toDouble() ?? 0;
    if (min <= 0) return false;
    final status = '${row['price_verification_status'] ?? ''}'
        .trim()
        .toLowerCase();
    if (status == 'legacy_untrusted' ||
        status == 'legacy_unverified' ||
        row['needs_reverification'] == true) {
      return false;
    }
    final marketplaceOk =
        row['marketplace_identity_verified'] == true &&
        (status == 'fresha_marketplace' ||
            status == 'booksy_marketplace' ||
            '${row['source_type'] ?? ''}' == 'marketplace');
    final verified =
        row['price_verified'] == true ||
        row['verified'] == true ||
        status == 'official_website' ||
        marketplaceOk;
    if (!verified) return false;
    final raw = '${row['raw_price_text'] ?? ''}'.trim();
    final rawProc = '${row['raw_procedure_text'] ?? row['brand'] ?? ''}'.trim();
    final source = '${row['price_source_url'] ?? row['source_url'] ?? ''}'
        .trim();
    final method = '${row['extraction_method'] ?? ''}'.trim();
    if (raw.isEmpty || rawProc.isEmpty || source.isEmpty || method.isEmpty) {
      return false;
    }
    return '${row['price_extract_revision'] ?? ''}'.trim() ==
        kExplorePriceExtractRevision;
  }

  static String mergeKey(Map<String, Object?> row) => _rowMergeKey(row);

  static String _rowMergeKey(Map<String, Object?> row) {
    final placeId = '${row['place_id'] ?? row['placeId'] ?? ''}'.trim();
    if (placeId.isNotEmpty) return 'id:$placeId';
    final host = normalizeExploreHost(
      '${row['price_source_url'] ?? row['source_url'] ?? row['area'] ?? ''}',
    );
    if (host.isNotEmpty && !isMarketplaceOrDirectoryHost(host)) {
      return 'host:$host';
    }
    final packed = packedCanonicalClinicName('${row['name'] ?? ''}');
    return packed.isEmpty ? '' : 'name:$packed';
  }

  static String _rowFingerprint(Map<String, Object?> row) {
    return [
      _rowMergeKey(row),
      '${row['name'] ?? ''}'.trim().toLowerCase(),
      '${row['price_min'] ?? ''}',
      '${row['price_max'] ?? ''}',
      '${row['currency'] ?? ''}',
      '${row['price_verified_at'] ?? ''}',
      '${row['price_source_url'] ?? row['source_url'] ?? ''}'.trim(),
      '${row['price_verification_status'] ?? ''}',
    ].join('|');
  }

  /// Drop clinics that failed city/branch validation from the Google-price
  /// cache so a later hydrate cannot resurrect them.
  Future<void> purgeRejectedCityClinics({
    required String city,
    required String procedure,
    required List<Map<String, Object?>> rejected,
    String cityId = '',
  }) async {
    if (rejected.isEmpty) return;
    final resolvedCityId = _resolvedCityId(city, cityId);
    final id = docId(city: city, procedure: procedure, cityId: resolvedCityId);
    final rejectKeys = <String>{
      for (final row in rejected)
        if (_rowMergeKey(row).isNotEmpty) _rowMergeKey(row),
    };
    if (rejectKeys.isEmpty) return;
    final existing = List<Map<String, Object?>>.from(
      _memory[id] ?? await load(city: city, procedure: procedure),
    );
    final kept = <Map<String, Object?>>[];
    var removed = 0;
    for (final row in existing) {
      final k = _rowMergeKey(row);
      if (k.isNotEmpty && rejectKeys.contains(k)) {
        removed++;
        continue;
      }
      final source = '${row['price_source_url'] ?? row['source_url'] ?? ''}'
          .trim();
      if (source.isNotEmpty &&
          exploreUrlConflictsWithSearchCity(source, city)) {
        removed++;
        continue;
      }
      kept.add(row);
    }
    if (removed == 0) return;
    _memory[id] = kept;
    _cleanupDirty[id] = true;
    _writeFingerprints.remove(id);
    if (FirebaseAuth.instance.currentUser == null) return;
    try {
      await _db.collection(collection).doc(id).set({
        'city': city.trim(),
        'procedure': procedure.trim(),
        'revision': revision,
        'source': 'google',
        'clinicCount': kept.length,
        'cachedAt': FieldValue.serverTimestamp(),
        'ttlHours': ttl.inHours,
        'cleanupDirty': false,
        'clinics': kept.take(maxClinics).toList(),
        'purgedOtherCity': true,
      }, SetOptions(merge: true));
      _cleanupDirty[id] = false;
      debugPrint(
        '[GP] Google prices PURGE: removed $removed other-city · '
        '${kept.length} kept · $procedure · $city',
      );
    } catch (e) {
      debugPrint('[GP] Google prices purge error: $e');
    }
  }

  static DateTime? _ratingUpdatedAt(
    Map<String, Object?> row,
    DateTime? docCachedAt,
  ) {
    final raw = row['rating_updated_at'];
    if (raw is Timestamp) return raw.toDate();
    if (raw is DateTime) return raw;
    if (raw is String && raw.trim().isNotEmpty) {
      return DateTime.tryParse(raw);
    }
    return docCachedAt;
  }
}
