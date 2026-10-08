import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// One successful price-page discovery for a clinic host.
class ExploreCachedSiteUrl {
  const ExploreCachedSiteUrl({
    required this.url,
    this.extractionMethod = '',
    this.procedureFamily = '',
  });

  final String url;
  final String extractionMethod;
  final String procedureFamily;

  Map<String, Object?> toJson() => {
        'url': url,
        if (extractionMethod.isNotEmpty) 'extractionMethod': extractionMethod,
        if (procedureFamily.isNotEmpty) 'procedureFamily': procedureFamily,
      };

  static ExploreCachedSiteUrl? fromJson(Object? raw) {
    if (raw is String && raw.trim().isNotEmpty) {
      return ExploreCachedSiteUrl(url: raw.trim());
    }
    if (raw is Map) {
      final url = '${raw['url'] ?? ''}'.trim();
      if (url.isEmpty) return null;
      return ExploreCachedSiteUrl(
        url: url,
        extractionMethod: '${raw['extractionMethod'] ?? ''}'.trim(),
        procedureFamily: '${raw['procedureFamily'] ?? ''}'.trim(),
      );
    }
    return null;
  }
}

/// Cached useful clinic-site URLs (+ extraction method when known).
///
/// Host-keyed so later Compare users skip repeating site discovery.
/// Never stores a trusted numeric price — only URLs / method labels.
class ExploreSiteUrlCacheStore {
  ExploreSiteUrlCacheStore._();
  static final ExploreSiteUrlCacheStore instance = ExploreSiteUrlCacheStore._();

  static const collection = 'clinic_site_urls';
  static const ttl = Duration(days: 14);

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final Map<String, _CachedUrls> _memory = {};

  static String docId(String host) {
    final h = host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '').trim();
    final encoded = Uri.encodeComponent(h).replaceAll('%', '_');
    if (encoded.length <= 400) return encoded;
    return encoded.substring(0, 400);
  }

  Future<List<String>> load(String host) async {
    final entries = await loadEntries(host);
    return [for (final e in entries) e.url];
  }

  Future<List<ExploreCachedSiteUrl>> loadEntries(String host) async {
    final key = host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '').trim();
    if (key.isEmpty) return const [];
    final mem = _memory[key];
    if (mem != null && mem.isFresh) return List<ExploreCachedSiteUrl>.from(mem.entries);

    if (FirebaseAuth.instance.currentUser == null) {
      return mem != null ? List<ExploreCachedSiteUrl>.from(mem.entries) : const [];
    }
    try {
      final snap = await _db.collection(collection).doc(docId(key)).get();
      if (!snap.exists) return const [];
      final data = snap.data();
      if (data == null) return const [];
      final ms = (data['updatedAtMs'] as num?)?.toInt();
      final updated = ms != null
          ? DateTime.fromMillisecondsSinceEpoch(ms)
          : DateTime.now();
      if (DateTime.now().difference(updated) > ttl) return const [];
      final entries = <ExploreCachedSiteUrl>[];
      final rawEntries = data['entries'];
      if (rawEntries is List) {
        for (final row in rawEntries) {
          final e = ExploreCachedSiteUrl.fromJson(row);
          if (e != null) entries.add(e);
        }
      }
      if (entries.isEmpty) {
        for (final u in (data['urls'] as List?) ?? const []) {
          final e = ExploreCachedSiteUrl.fromJson(u);
          if (e != null) entries.add(e);
        }
      }
      _memory[key] = _CachedUrls(entries: entries, fetchedAt: updated);
      return entries;
    } catch (e) {
      debugPrint('[GP] Site URL cache read error: $e');
      return const [];
    }
  }

  Future<void> save({
    required String host,
    required List<String> urls,
    String procedure = '',
    String city = '',
    String clinicName = '',
    String source = 'firecrawl',
    String extractionMethod = '',
    String procedureFamily = '',
  }) async {
    await saveEntries(
      host: host,
      entries: [
        for (final u in urls)
          if (u.trim().isNotEmpty)
            ExploreCachedSiteUrl(
              url: u.trim(),
              extractionMethod: extractionMethod,
              procedureFamily: procedureFamily,
            ),
      ],
      procedure: procedure,
      city: city,
      clinicName: clinicName,
      source: source,
    );
  }

  Future<void> saveEntries({
    required String host,
    required List<ExploreCachedSiteUrl> entries,
    String procedure = '',
    String city = '',
    String clinicName = '',
    String source = 'discovery',
  }) async {
    final key = host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '').trim();
    final clean = <ExploreCachedSiteUrl>[];
    final seen = <String>{};
    for (final e in entries) {
      final u = e.url.trim();
      if (u.isEmpty || !seen.add(u)) continue;
      clean.add(e);
    }
    if (key.isEmpty || clean.isEmpty) return;
    final prev = await loadEntries(key);
    final mergedMap = <String, ExploreCachedSiteUrl>{
      for (final e in prev) e.url: e,
    };
    for (final e in clean) {
      final prevE = mergedMap[e.url];
      mergedMap[e.url] = ExploreCachedSiteUrl(
        url: e.url,
        extractionMethod: e.extractionMethod.isNotEmpty
            ? e.extractionMethod
            : (prevE?.extractionMethod ?? ''),
        procedureFamily: e.procedureFamily.isNotEmpty
            ? e.procedureFamily
            : (prevE?.procedureFamily ?? ''),
      );
    }
    final merged = mergedMap.values.take(60).toList();
    _memory[key] = _CachedUrls(entries: merged, fetchedAt: DateTime.now());
    if (FirebaseAuth.instance.currentUser == null) return;
    try {
      await _db.collection(collection).doc(docId(key)).set({
        'host': key,
        'clinicName': clinicName,
        'city': city,
        'lastProcedure': procedure,
        'source': source,
        'urls': [for (final e in merged) e.url],
        'entries': [for (final e in merged) e.toJson()],
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedAtMs': DateTime.now().millisecondsSinceEpoch,
      }, SetOptions(merge: true));
      debugPrint('[GP] Site URL cache saved ${merged.length} · $key');
    } catch (e) {
      debugPrint('[GP] Site URL cache write error: $e');
    }
  }
}

class _CachedUrls {
  _CachedUrls({required this.entries, required this.fetchedAt});
  final List<ExploreCachedSiteUrl> entries;
  final DateTime fetchedAt;
  bool get isFresh =>
      DateTime.now().difference(fetchedAt) < ExploreSiteUrlCacheStore.ttl;
}
