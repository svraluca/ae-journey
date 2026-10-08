import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Shared Google Places rating lookup, keyed by city + clinic — not procedure.
///
/// Botox / Fillers / Laser for the same clinic reuse one Maps lookup.
class ExplorePlaceCacheStore {
  ExplorePlaceCacheStore._();
  static final ExplorePlaceCacheStore instance = ExplorePlaceCacheStore._();

  static const collection = 'place_cache';
  static const memoryTtl = Duration(hours: 12);
  static const missMemoryTtl = Duration(minutes: 2);
  static const firestoreTtl = Duration(days: 90);

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final Map<String, ExplorePlaceCacheEntry> _memory = {};
  final Map<String, Future<ExplorePlaceCacheEntry?>> _readCoalesce = {};

  static String docId({required String city, required String clinicName}) {
    final raw =
        '${city.trim().toLowerCase()}|${normalizeClinicKey(clinicName)}';
    final encoded = Uri.encodeComponent(raw).replaceAll('%', '_');
    if (encoded.length <= 400) return encoded;
    return encoded.substring(0, 400);
  }

  /// Lowercase, trim, punctuation-insensitive clinic key.
  static String normalizeClinicKey(String name) {
    var n = name.toLowerCase().trim();
    n = n.replaceAll(RegExp(r'[^\w\sà-ÿăâîșțÁ-ÝĂÂÎȘȚ]+'), ' ');
    return n.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static List<String> aliasNames({
    required String clinicName,
    String mapsName = '',
    String websiteHost = '',
  }) {
    final out = <String>[];
    void add(String raw) {
      final t = raw.trim();
      if (t.length < 3) return;
      final key = normalizeClinicKey(t);
      if (key.isEmpty) return;
      if (out.any((e) => normalizeClinicKey(e) == key)) return;
      out.add(t);
    }

    add(clinicName);
    add(mapsName);
    var host = websiteHost.trim().toLowerCase();
    host = host.replaceFirst(RegExp(r'^https?://'), '');
    host = host.replaceFirst(RegExp(r'^www\.'), '');
    host = host.split('/').first.split(':').first.trim();
    if (host.contains('.')) {
      add('host:$host');
      add(host.split('.').first);
    }
    return out;
  }

  /// Fresh in-memory entry only — used to skip confirmed Places misses
  /// without a Firestore round-trip. Returns null if absent or expired.
  ExplorePlaceCacheEntry? peekMemory({
    required String city,
    required String clinicName,
  }) {
    final id = docId(city: city, clinicName: clinicName);
    final mem = _memory[id];
    if (mem == null || !mem.isFresh) return null;
    return mem;
  }

  Future<ExplorePlaceCacheEntry?> lookup({
    required String city,
    required String clinicName,
  }) {
    return lookupAny(city: city, clinicNames: [clinicName]);
  }

  /// Same Maps rating under host brand ("Tajmeels") and Maps name.
  Future<ExplorePlaceCacheEntry?> lookupAny({
    required String city,
    required List<String> clinicNames,
  }) async {
    ExplorePlaceCacheEntry? lastMiss;
    for (final name in clinicNames) {
      if (name.trim().isEmpty) continue;
      final hit = await _lookupExact(city: city, clinicName: name);
      if (hit == null) continue;
      if (hit.matched && hit.rating > 0) return hit;
      lastMiss = hit;
    }
    return lastMiss;
  }

  Future<ExplorePlaceCacheEntry?> _lookupExact({
    required String city,
    required String clinicName,
  }) {
    final id = docId(city: city, clinicName: clinicName);
    final mem = _memory[id];
    if (mem != null && mem.isFresh) return Future.value(mem);

    return _readCoalesce.putIfAbsent(id, () async {
      try {
        if (FirebaseAuth.instance.currentUser == null) {
          return (mem != null && mem.isFresh) ? mem : null;
        }
        final doc = await _db.collection(collection).doc(id).get();
        if (!doc.exists) {
          return (mem != null && mem.isFresh) ? mem : null;
        }
        final data = doc.data();
        if (data == null) {
          return (mem != null && mem.isFresh) ? mem : null;
        }
        final entry = ExplorePlaceCacheEntry.fromFirestore(data);
        if (!entry.isFresh) {
          return (mem != null && mem.isFresh) ? mem : null;
        }
        _memory[id] = entry;
        return entry;
      } catch (e) {
        debugPrint('[GP] Place cache read error: $e');
        return (mem != null && mem.isFresh) ? mem : null;
      } finally {
        scheduleMicrotask(() => _readCoalesce.remove(id));
      }
    });
  }

  void rememberMiss({required String city, required String clinicName}) {
    final id = docId(city: city, clinicName: clinicName);
    _memory[id] = ExplorePlaceCacheEntry.miss();
  }

  Future<void> put({
    required String city,
    required String clinicName,
    required double rating,
    required int reviews,
    required String websiteHost,
    required double lat,
    required double lng,
    String mapsName = '',
  }) async {
    final host = websiteHost.trim().toLowerCase();
    final entry = ExplorePlaceCacheEntry(
      matched: true,
      rating: rating,
      reviews: reviews,
      websiteHost: host,
      mapsName: mapsName.trim(),
      lat: lat,
      lng: lng,
      fetchedAt: DateTime.now(),
      memoryOnly: true,
    );
    final names = aliasNames(
      clinicName: clinicName,
      mapsName: mapsName,
      websiteHost: host,
    );
    for (final name in names) {
      _memory[docId(city: city, clinicName: name)] = entry;
    }
    if (FirebaseAuth.instance.currentUser == null) return;
    if (rating <= 0 && reviews <= 0 && host.isEmpty) return;
    try {
      for (final name in names) {
        await _db.collection(collection).doc(docId(city: city, clinicName: name)).set({
          'city': city.trim(),
          'clinicName': name.trim(),
          'rating': rating,
          'reviews': reviews,
          'websiteHost': host,
          'mapsName': mapsName.trim(),
          'lat': lat,
          'lng': lng,
          'matched': true,
          'cachedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
    } catch (e) {
      debugPrint('[GP] Place cache write error: $e');
    }
  }
}

class ExplorePlaceCacheEntry {
  const ExplorePlaceCacheEntry({
    required this.matched,
    required this.rating,
    required this.reviews,
    required this.websiteHost,
    this.mapsName = '',
    required this.lat,
    required this.lng,
    required this.fetchedAt,
    required this.memoryOnly,
  });

  factory ExplorePlaceCacheEntry.miss() => ExplorePlaceCacheEntry(
        matched: false,
        rating: 0,
        reviews: 0,
        websiteHost: '',
        mapsName: '',
        lat: 0,
        lng: 0,
        fetchedAt: DateTime.now(),
        memoryOnly: true,
      );

  factory ExplorePlaceCacheEntry.fromFirestore(Map<String, dynamic> data) {
    final ts = data['cachedAt'];
    final cachedAt = ts is Timestamp
        ? ts.toDate()
        : DateTime.tryParse('$ts') ?? DateTime.now();
    return ExplorePlaceCacheEntry(
      matched: data['matched'] != false,
      rating: (data['rating'] as num?)?.toDouble() ?? 0,
      reviews: (data['reviews'] as num?)?.toInt() ?? 0,
      websiteHost: '${data['websiteHost'] ?? ''}'.trim().toLowerCase(),
      mapsName: '${data['mapsName'] ?? ''}'.trim(),
      lat: (data['lat'] as num?)?.toDouble() ?? 0,
      lng: (data['lng'] as num?)?.toDouble() ?? 0,
      fetchedAt: cachedAt,
      memoryOnly: false,
    );
  }

  final bool matched;
  final double rating;
  final int reviews;
  final String websiteHost;
  final String mapsName;
  final double lat;
  final double lng;
  final DateTime fetchedAt;
  final bool memoryOnly;

  bool get isFresh {
    final limit = memoryOnly
        ? (!matched
            ? ExplorePlaceCacheStore.missMemoryTtl
            : ExplorePlaceCacheStore.memoryTtl)
        : ExplorePlaceCacheStore.firestoreTtl;
    return DateTime.now().difference(fetchedAt) <= limit;
  }
}
