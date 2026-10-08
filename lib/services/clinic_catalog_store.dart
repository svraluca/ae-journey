import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'openai_service.dart';

/// Shared clinic procedures/prices catalog.
///
/// First user to open a clinic pays the AI scrape cost; later users get an
/// instant Firestore hit. Soft TTL enables stale-while-revalidate (show fast,
/// refresh quietly). Hard TTL forces a refresh but can still paint stale data.
class ClinicCatalogStore {
  ClinicCatalogStore._();
  static final ClinicCatalogStore instance = ClinicCatalogStore._();

  static const collection = 'clinic_catalog';
  static const cacheRevision = 'v1';

  /// Show cached data without forcing refresh.
  static const softTtl = Duration(days: 7);

  /// After this, prefer a fresh scrape (still may paint stale briefly).
  static const hardTtl = Duration(days: 30);

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final Map<String, ClinicCatalogEntry> _memory = {};
  final Map<String, Future<ClinicCatalogEntry?>> _readCoalesce = {};

  static String catalogId({
    required String clinicName,
    required String city,
    String? websiteUrl,
  }) {
    final c = clinicName.trim().toLowerCase();
    final cityKey = city.trim().toLowerCase();
    final host = _hostKey(websiteUrl);
    final raw = host.isNotEmpty
        ? '$cacheRevision|$c|$cityKey|$host'
        : '$cacheRevision|$c|$cityKey';
    final encoded = Uri.encodeComponent(raw).replaceAll('%', '_');
    if (encoded.length <= 400) return encoded;
    return encoded.substring(0, 400);
  }

  static String _hostKey(String? websiteUrl) {
    final w = (websiteUrl ?? '').trim();
    if (w.isEmpty) return '';
    try {
      final uri = Uri.parse(w.contains('://') ? w : 'https://$w');
      return uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
    } catch (_) {
      return w.toLowerCase();
    }
  }

  Future<ClinicCatalogEntry?> get({
    required String clinicName,
    required String city,
    String? websiteUrl,
  }) {
    final id = catalogId(
      clinicName: clinicName,
      city: city,
      websiteUrl: websiteUrl,
    );
    final mem = _memory[id];
    if (mem != null && !mem.isHardExpired) {
      return Future.value(mem);
    }

    return _readCoalesce.putIfAbsent(id, () async {
      try {
        if (FirebaseAuth.instance.currentUser == null) return mem;

        final doc = await _db.collection(collection).doc(id).get();
        if (!doc.exists) return mem;
        final data = doc.data();
        if (data == null) return mem;

        final entry = ClinicCatalogEntry.fromFirestore(id, data);
        if (entry.page.procedures.isEmpty) return mem;

        final repaired = ClinicCatalogEntry(
          id: entry.id,
          page: _normalizePagePrices(entry.page),
          cachedAt: entry.cachedAt,
          pricedCount: entry.pricedCount,
          websiteUrl: entry.websiteUrl,
        );
        _memory[id] = repaired;
        debugPrint(
          '[ClinicCatalog] HIT $clinicName @ $city '
          '(procs: ${repaired.page.procedures.length}, '
          'fresh: ${repaired.isFresh}, stale: ${repaired.isStale})',
        );
        return repaired;
      } catch (e) {
        debugPrint('[ClinicCatalog] read error: $e');
        return mem;
      } finally {
        scheduleMicrotask(() => _readCoalesce.remove(id));
      }
    });
  }

  /// Persist a clinic page once it has usable procedure prices.
  Future<void> savePage({
    required OpenAIClinicProfilePage page,
    String? websiteUrl,
  }) async {
    final clinicName = page.clinicName.trim();
    final city = page.city.trim();
    if (clinicName.isEmpty || city.isEmpty) return;

    final normalized = _normalizePagePrices(page);
    final priced = normalized.procedures.where((p) => p.priceMin > 0).length;
    if (normalized.procedures.isEmpty || priced == 0) {
      debugPrint(
        '[ClinicCatalog] skip save $clinicName — '
        'no priced procedures yet',
      );
      return;
    }

    final evidencePriced = normalized.procedures
        .where(
          (p) =>
              p.priceMin > 0 &&
              p.tags.any((t) => t == 'evidence' || t.startsWith('html_')),
        )
        .length;
    if (evidencePriced == 0) {
      debugPrint(
        '[ClinicCatalog] skip save $clinicName — no HTML evidence prices',
      );
      return;
    }

    final id = catalogId(
      clinicName: clinicName,
      city: city,
      websiteUrl: websiteUrl ?? normalized.contact.website,
    );

    final entry = ClinicCatalogEntry(
      id: id,
      page: normalized,
      cachedAt: DateTime.now(),
      pricedCount: priced,
      websiteUrl: (websiteUrl ?? normalized.contact.website).trim(),
    );
    _memory[id] = entry;

    if (FirebaseAuth.instance.currentUser == null) return;

    try {
      await _db.collection(collection).doc(id).set({
        'clinicName': clinicName,
        'city': city,
        'websiteUrl': entry.websiteUrl,
        'pricedCount': priced,
        'procedureCount': normalized.procedures.length,
        'revision': cacheRevision,
        'cachedAt': FieldValue.serverTimestamp(),
        'softTtlHours': softTtl.inHours,
        'hardTtlHours': hardTtl.inHours,
        'page': _pageToJson(normalized),
      }, SetOptions(merge: true));
      debugPrint(
        '[ClinicCatalog] WRITE $clinicName @ $city '
        '(${normalized.procedures.length} procs, $priced priced)',
      );
    } catch (e) {
      debugPrint('[ClinicCatalog] write error: $e');
    }
  }

  /// Ensure every priced row keeps a digit-bearing label for fast UI paint.
  static OpenAIClinicProfilePage _normalizePagePrices(OpenAIClinicProfilePage page) {
    final currency = page.currency.trim().isNotEmpty ? page.currency.trim() : 'RON';
    final fixed = <OpenAIProfileProcedureRow>[];
    for (final r in page.procedures) {
      final label = r.priceLabel.trim();
      final hasDigits = RegExp(r'\d').hasMatch(label);
      var min = r.priceMin;
      var max = r.priceMax;

      // Recover numeric prices from label when Firestore/AI left price_min at 0.
      if (min <= 0 && hasDigits) {
        final nums = RegExp(r'(\d+(?:[.,]\d+)?)')
            .allMatches(label)
            .map((m) {
              final t = m.group(1)!;
              if (RegExp(r'^\d{1,3}([.,]\d{3})+$').hasMatch(t)) {
                return double.tryParse(t.replaceAll('.', '').replaceAll(',', ''));
              }
              return double.tryParse(t.replaceAll(',', '.'));
            })
            .whereType<double>()
            .where((n) => n > 0)
            .toList();
        if (nums.isNotEmpty) {
          min = nums.reduce((a, b) => a < b ? a : b);
          max = nums.reduce((a, b) => a > b ? a : b);
        }
      }

      if (min > 0 && !hasDigits) {
        fixed.add(
          OpenAIProfileProcedureRow(
            name: r.name,
            detail: r.detail,
            category: r.category,
            iconKind: r.iconKind,
            priceMin: min,
            priceMax: max > 0 ? max : min,
            priceLabel: _formatCatalogPrice(min, max > 0 ? max : min, currency),
            tags: r.tags,
            featured: r.featured,
          ),
        );
      } else if (min != r.priceMin || max != r.priceMax) {
        fixed.add(
          OpenAIProfileProcedureRow(
            name: r.name,
            detail: r.detail,
            category: r.category,
            iconKind: r.iconKind,
            priceMin: min,
            priceMax: max > 0 ? max : min,
            priceLabel: hasDigits
                ? label
                : _formatCatalogPrice(min, max > 0 ? max : min, currency),
            tags: r.tags,
            featured: r.featured,
          ),
        );
      } else {
        fixed.add(r);
      }
    }
    return OpenAIClinicProfilePage(
      clinicName: page.clinicName,
      city: page.city,
      clinicTypeLabel: page.clinicTypeLabel,
      area: page.area,
      distanceMi: page.distanceMi,
      lat: page.lat,
      lng: page.lng,
      rating: page.rating,
      reviewsTotal: page.reviewsTotal,
      googlePlaceUrl: page.googlePlaceUrl,
      procedureCount: fixed.length,
      doctorCount: page.doctors.length,
      isVerified: page.isVerified,
      isDoctorLed: page.isDoctorLed,
      heroTags: page.heroTags,
      about: page.about,
      currency: page.currency,
      priceRangeLabel: page.priceRangeLabel,
      priceMin: page.priceMin,
      priceMax: page.priceMax,
      categories: page.categories,
      procedures: fixed,
      doctors: page.doctors,
      contact: page.contact,
      reviews: page.reviews,
    );
  }

  static String _formatCatalogPrice(double min, double max, String currency) {
    final lo = min.round();
    final hi = max > min ? max.round() : lo;
    final cur = currency.trim().isEmpty ? 'RON' : currency.trim();
    if (cur == '£' || cur == '€' || cur == r'$') {
      return hi == lo ? '$cur$lo' : '$cur$lo–$hi';
    }
    return hi == lo ? '$lo $cur' : '$lo–$hi $cur';
  }

  /// Convert a cached profile page into the detail-screen profile shape.
  static OpenAIClinicProfile profileFromPage(
    OpenAIClinicProfilePage page, {
    String procedureContext = '',
  }) {
    final focus = procedureContext.trim();
    final treatments = page.procedures.map((r) {
      final featured = focus.isNotEmpty &&
          r.name.toLowerCase().contains(focus.toLowerCase());
      return OpenAIClinicTreatment(
        name: r.name,
        brand: '',
        dose: '',
        description: r.detail,
        priceLabel: r.priceLabel,
        badge: '',
        tags: r.tags,
        featured: featured || r.featured,
      );
    }).toList(growable: false);

    return OpenAIClinicProfile(
      clinicName: page.clinicName,
      city: page.city,
      area: page.area,
      distanceMi: page.distanceMi,
      rating: page.rating,
      reviewsCount: page.reviewsTotal,
      isTopRated: page.rating >= 4.7,
      isDoctorLed: page.isDoctorLed,
      isVerified: page.isVerified,
      about: page.about,
      currency: page.currency,
      procedureFocus: focus,
      procedureFocusLocal: '',
      treatments: treatments,
      contact: page.contact,
      reviews: page.reviews,
    );
  }

  static Map<String, dynamic> _pageToJson(OpenAIClinicProfilePage p) {
    return {
      'clinic_name': p.clinicName,
      'city': p.city,
      'clinic_type_label': p.clinicTypeLabel,
      'area': p.area,
      'distance_mi': p.distanceMi,
      'lat': p.lat,
      'lng': p.lng,
      'rating': p.rating,
      'reviews_total': p.reviewsTotal,
      'google_place_url': p.googlePlaceUrl,
      'procedure_count': p.procedures.length,
      'doctor_count': p.doctors.length,
      'is_verified': p.isVerified,
      'is_doctor_led': p.isDoctorLed,
      'hero_tags': p.heroTags,
      'about': p.about,
      'currency': p.currency,
      'price_range_label': p.priceRangeLabel,
      'price_min': p.priceMin,
      'price_max': p.priceMax,
      'categories': p.categories,
      'procedures': [
        for (final r in p.procedures) _procedureToJson(r),
      ],
      'doctors': [
        for (final d in p.doctors) _doctorToJson(d),
      ],
      'contact': _contactToJson(p.contact),
      'reviews': [
        for (final r in p.reviews) _reviewToJson(r),
      ],
    };
  }

  static Map<String, dynamic> _procedureToJson(OpenAIProfileProcedureRow r) => {
        'name': r.name,
        'detail': r.detail,
        'category': r.category,
        'icon_kind': r.iconKind,
        'price_min': r.priceMin,
        'price_max': r.priceMax,
        'price_label': r.priceLabel,
        'tags': r.tags,
        'featured': r.featured,
      };

  static Map<String, dynamic> _doctorToJson(OpenAIProfileDoctor d) => {
        'name': d.name,
        'initials': d.initials,
        'specialty': d.specialty,
        'badge': d.badge,
        'years_experience': d.yearsExperience,
      };

  static Map<String, dynamic> _contactToJson(OpenAIClinicContact c) => {
        'address': c.address,
        'phone': c.phone,
        'website': c.website,
        'instagram': c.instagram,
        'opening_hours': c.openingHours,
        'is_open_now': c.isOpenNow,
      };

  static Map<String, dynamic> _reviewToJson(OpenAIClinicReview r) => {
        'author_name': r.authorName,
        'initials': r.initials,
        'date': r.date,
        'date_iso': r.dateIso,
        'rating': r.rating,
        'text': r.text,
      };
}

class ClinicCatalogEntry {
  const ClinicCatalogEntry({
    required this.id,
    required this.page,
    required this.cachedAt,
    required this.pricedCount,
    this.websiteUrl = '',
  });

  final String id;
  final OpenAIClinicProfilePage page;
  final DateTime cachedAt;
  final int pricedCount;
  final String websiteUrl;

  bool get isFresh =>
      DateTime.now().difference(cachedAt) <= ClinicCatalogStore.softTtl;

  bool get isStale => !isFresh && !isHardExpired;

  bool get isHardExpired =>
      DateTime.now().difference(cachedAt) > ClinicCatalogStore.hardTtl;

  factory ClinicCatalogEntry.fromFirestore(String id, Map<String, dynamic> data) {
    final cachedAtRaw = data['cachedAt'];
    final cachedAt = cachedAtRaw is Timestamp
        ? cachedAtRaw.toDate().toLocal()
        : DateTime.tryParse('$cachedAtRaw') ?? DateTime.now();
    final pageRaw = data['page'];
    final pageMap = pageRaw is Map
        ? pageRaw.cast<String, Object?>()
        : <String, Object?>{};
    return ClinicCatalogEntry(
      id: id,
      page: OpenAIClinicProfilePage.fromJson(pageMap),
      cachedAt: cachedAt,
      pricedCount: (data['pricedCount'] as num?)?.toInt() ?? 0,
      websiteUrl: (data['websiteUrl'] as String? ?? '').trim(),
    );
  }
}
