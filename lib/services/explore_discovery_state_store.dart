import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Persisted Places discovery memory per city + canonical procedure.
class ExploreDiscoveryStateStore {
  ExploreDiscoveryStateStore._();
  static final ExploreDiscoveryStateStore instance =
      ExploreDiscoveryStateStore._();

  static const collection = 'explore_discovery_state';
  static const revision = 'v1';
  static const tempCooldown = Duration(hours: 6);

  /// How long a host that published no price for this procedure is left alone.
  ///
  /// Learned, never hardcoded: the entry is written only after the pipeline
  /// itself fetched the site and concluded there is no price for this
  /// procedure, and it is cleared the moment a price is found. Without it
  /// every Tirana peel search re-scraped the same ~20 priceless hosts and the
  /// deadline expired before any *new* candidate got verified.
  static const noPriceCooldown = Duration(days: 14);

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final Map<String, ExploreDiscoveryState> _memory = {};
  final Map<String, Future<void>> _locks = {};

  static String docId({required String city, required String procedure}) {
    final raw =
        '$revision|${city.trim().toLowerCase()}|${procedure.trim().toLowerCase()}';
    final encoded = Uri.encodeComponent(raw).replaceAll('%', '_');
    return encoded.length <= 400 ? encoded : encoded.substring(0, 400);
  }

  Future<ExploreDiscoveryState> load({
    required String city,
    required String procedure,
  }) async {
    final id = docId(city: city, procedure: procedure);
    final hit = _memory[id];
    if (hit != null) return hit;
    if (FirebaseAuth.instance.currentUser == null) {
      return _memory[id] = ExploreDiscoveryState.empty;
    }
    try {
      final snap = await _db.collection(collection).doc(id).get();
      final data = snap.data() ?? const <String, dynamic>{};
      final tempRaw = data['temporaryRejected'];
      final temp = <String, DateTime>{};
      if (tempRaw is Map) {
        final now = DateTime.now();
        for (final e in tempRaw.entries) {
          final row = e.value;
          if (row is! Map) continue;
          final ms = (row['retryAfter'] as num?)?.toInt() ?? 0;
          final until = DateTime.fromMillisecondsSinceEpoch(ms);
          if (until.isAfter(now)) {
            temp['${e.key}'] = until;
          }
        }
      }
      final noPriceRaw = data['noPriceHosts'];
      final noPrice = <String, DateTime>{};
      if (noPriceRaw is Map) {
        final now = DateTime.now();
        for (final e in noPriceRaw.entries) {
          final row = e.value;
          if (row is! Map) continue;
          final ms = (row['retryAfter'] as num?)?.toInt() ?? 0;
          final until = DateTime.fromMillisecondsSinceEpoch(ms);
          if (until.isAfter(now)) noPrice['${e.key}'] = until;
        }
      }
      final state = ExploreDiscoveryState(
        acceptedPlaceIds: {
          for (final v in (data['acceptedPlaceIds'] as List?) ?? const [])
            '$v',
        }..removeWhere((s) => s.isEmpty),
        permanentRejectedPlaceIds: {
          for (final v
              in (data['permanentRejectedPlaceIds'] as List?) ?? const [])
            '$v',
        }..removeWhere((s) => s.isEmpty),
        temporaryRejectedUntil: temp,
        noPriceHostsUntil: noPrice,
      );
      _memory[id] = state;
      return state;
    } catch (e) {
      debugPrint('[GP] Discovery state load error: $e');
      return _memory[id] ?? ExploreDiscoveryState.empty;
    }
  }

  bool shouldSkipPlaceId(ExploreDiscoveryState state, String placeId) {
    final id = placeId.trim();
    if (id.isEmpty) return false;
    if (state.permanentRejectedPlaceIds.contains(id)) return true;
    if (state.acceptedPlaceIds.contains(id)) return true;
    final until = state.temporaryRejectedUntil[id];
    return until != null && until.isAfter(DateTime.now());
  }

  Future<void> markAccepted({
    required String city,
    required String procedure,
    required String placeId,
  }) {
    return _patch(
      city: city,
      procedure: procedure,
      mutate: (s) => s.copyWith(
        acceptedPlaceIds: {...s.acceptedPlaceIds, placeId.trim()},
        temporaryRejectedUntil: {
          for (final e in s.temporaryRejectedUntil.entries)
            if (e.key != placeId.trim()) e.key: e.value,
        },
      ),
    );
  }

  Future<void> markPermanentReject({
    required String city,
    required String procedure,
    required String placeId,
  }) {
    return _patch(
      city: city,
      procedure: procedure,
      mutate: (s) => s.copyWith(
        permanentRejectedPlaceIds: {
          ...s.permanentRejectedPlaceIds,
          placeId.trim(),
        },
      ),
    );
  }

  Future<void> markTemporaryReject({
    required String city,
    required String procedure,
    required String placeId,
    Duration cooldown = tempCooldown,
  }) {
    return _patch(
      city: city,
      procedure: procedure,
      mutate: (s) => s.copyWith(
        temporaryRejectedUntil: {
          ...s.temporaryRejectedUntil,
          placeId.trim(): DateTime.now().add(cooldown),
        },
      ),
    );
  }

  Future<void> _patch({
    required String city,
    required String procedure,
    required ExploreDiscoveryState Function(ExploreDiscoveryState) mutate,
  }) async {
    final id = docId(city: city, procedure: procedure);
    final prev = _locks[id] ?? Future<void>.value();
    final done = Completer<void>();
    _locks[id] = done.future;
    try {
      await prev;
      final cur = _memory[id] ?? await load(city: city, procedure: procedure);
      final next = mutate(cur);
      _memory[id] = next;
      if (FirebaseAuth.instance.currentUser == null) return;
      await _db.collection(collection).doc(id).set({
        'city': city.trim(),
        'procedure': procedure.trim(),
        'revision': revision,
        'acceptedPlaceIds': next.acceptedPlaceIds.take(200).toList(),
        'permanentRejectedPlaceIds':
            next.permanentRejectedPlaceIds.take(400).toList(),
        'temporaryRejected': {
          for (final e in next.temporaryRejectedUntil.entries)
            e.key: {'retryAfter': e.value.millisecondsSinceEpoch},
        },
        'noPriceHosts': {
          for (final e in next.noPriceHostsUntil.entries)
            e.key: {'retryAfter': e.value.millisecondsSinceEpoch},
        },
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('[GP] Discovery state write error: $e');
    } finally {
      done.complete();
      if (_locks[id] == done.future) _locks.remove(id);
    }
  }
}

class ExploreDiscoveryState {
  const ExploreDiscoveryState({
    required this.acceptedPlaceIds,
    required this.permanentRejectedPlaceIds,
    required this.temporaryRejectedUntil,
    this.noPriceHostsUntil = const {},
  });

  static const empty = ExploreDiscoveryState(
    acceptedPlaceIds: {},
    permanentRejectedPlaceIds: {},
    temporaryRejectedUntil: {},
    noPriceHostsUntil: {},
  );

  final Set<String> acceptedPlaceIds;
  final Set<String> permanentRejectedPlaceIds;
  final Map<String, DateTime> temporaryRejectedUntil;

  /// Hosts the pipeline already read and found no price for this procedure.
  final Map<String, DateTime> noPriceHostsUntil;

  ExploreDiscoveryState copyWith({
    Set<String>? acceptedPlaceIds,
    Set<String>? permanentRejectedPlaceIds,
    Map<String, DateTime>? temporaryRejectedUntil,
    Map<String, DateTime>? noPriceHostsUntil,
  }) {
    return ExploreDiscoveryState(
      acceptedPlaceIds: acceptedPlaceIds ?? this.acceptedPlaceIds,
      permanentRejectedPlaceIds:
          permanentRejectedPlaceIds ?? this.permanentRejectedPlaceIds,
      temporaryRejectedUntil:
          temporaryRejectedUntil ?? this.temporaryRejectedUntil,
      noPriceHostsUntil: noPriceHostsUntil ?? this.noPriceHostsUntil,
    );
  }
}
