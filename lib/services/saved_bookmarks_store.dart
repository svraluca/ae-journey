import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// A saved clinic and/or procedure bookmark synced to Firestore.
class SavedBookmarkEntry {
  const SavedBookmarkEntry({
    required this.id,
    required this.clinicName,
    this.procedureName = '',
    this.city = '',
    this.country = '',
    this.priceLabel = '',
    this.area = '',
    this.rating = 0,
    this.tags = const [],
    this.avatarColor = 0xFF1A1A2E,
    required this.savedAt,
  });

  final String id;
  final String clinicName;
  final String procedureName;
  final String city;
  final String country;
  final String priceLabel;
  final String area;
  final double rating;
  final List<String> tags;
  final int avatarColor;
  final DateTime savedAt;

  bool get isClinicOnly => procedureName.trim().isEmpty;

  String get initials {
    final parts = clinicName.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).take(2);
    return parts.map((p) => p[0].toUpperCase()).join();
  }

  String get locationLabel {
    final c = city.trim();
    final co = country.trim();
    if (c.isNotEmpty && co.isNotEmpty) return '$c, $co';
    if (c.isNotEmpty) return c;
    if (co.isNotEmpty) return co;
    final a = area.trim();
    return a.isEmpty ? '—' : a;
  }

  SavedBookmarkEntry copyWith({
    String? priceLabel,
    String? city,
    String? country,
    String? area,
    double? rating,
    List<String>? tags,
    DateTime? savedAt,
  }) {
    return SavedBookmarkEntry(
      id: id,
      clinicName: clinicName,
      procedureName: procedureName,
      city: city ?? this.city,
      country: country ?? this.country,
      priceLabel: priceLabel ?? this.priceLabel,
      area: area ?? this.area,
      rating: rating ?? this.rating,
      tags: tags ?? this.tags,
      avatarColor: avatarColor,
      savedAt: savedAt ?? this.savedAt,
    );
  }

  Map<String, dynamic> toFirestore() => {
        'clinicName': clinicName,
        'procedureName': procedureName,
        'city': city,
        'country': country,
        'priceLabel': priceLabel,
        'area': area,
        'rating': rating,
        'tags': tags,
        'avatarColor': avatarColor,
        'savedAt': Timestamp.fromDate(savedAt.toUtc()),
      };

  factory SavedBookmarkEntry.fromFirestore(String id, Map<String, dynamic> data) {
    final savedAtRaw = data['savedAt'];
    final savedAt = savedAtRaw is Timestamp
        ? savedAtRaw.toDate().toLocal()
        : DateTime.tryParse('$savedAtRaw') ?? DateTime.now();
    final tagsRaw = data['tags'];
    return SavedBookmarkEntry(
      id: id,
      clinicName: (data['clinicName'] as String? ?? '').trim(),
      procedureName: (data['procedureName'] as String? ?? '').trim(),
      city: (data['city'] as String? ?? '').trim(),
      country: (data['country'] as String? ?? '').trim(),
      priceLabel: (data['priceLabel'] as String? ?? '').trim(),
      area: (data['area'] as String? ?? '').trim(),
      rating: (data['rating'] as num?)?.toDouble() ?? 0,
      tags: tagsRaw is List ? tagsRaw.map((e) => '$e').toList() : const [],
      avatarColor: (data['avatarColor'] as num?)?.toInt() ?? 0xFF1A1A2E,
      savedAt: savedAt,
    );
  }
}

/// Firestore-backed favorites under `users/{uid}/saved_bookmarks`.
class SavedBookmarksStore extends ChangeNotifier {
  SavedBookmarksStore._();
  static final SavedBookmarksStore instance = SavedBookmarksStore._();

  static const firestoreCollection = 'saved_bookmarks';

  final List<SavedBookmarkEntry> _items = [];
  StreamSubscription<User?>? _authSub;
  String? _uid;
  bool _loading = false;

  List<SavedBookmarkEntry> get items => List.unmodifiable(_items);
  bool get isLoading => _loading;

  static String norm(String s) => s.trim().toLowerCase();

  static (String city, String country) splitLocation(String raw) {
    final parts = raw.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    if (parts.length >= 2) {
      return (parts.first, parts.sublist(1).join(', '));
    }
    return (raw.trim(), '');
  }

  static String bookmarkId(String clinicName, String procedureName) {
    final c = norm(clinicName);
    final p = norm(procedureName);
    if (p.isEmpty) return 'clinic::$c';
    return 'proc::$c::$p';
  }

  void startListening() {
    if (_authSub != null) return;
    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      final uid = user?.uid;
      if (uid == _uid) return;
      _uid = uid;
      if (uid == null) {
        _items.clear();
        notifyListeners();
        return;
      }
      unawaited(_loadFromFirestore(uid));
    });
    final current = FirebaseAuth.instance.currentUser?.uid;
    if (current != null && current != _uid) {
      _uid = current;
      unawaited(_loadFromFirestore(current));
    }
  }

  Future<void> _loadFromFirestore(String uid) async {
    _loading = true;
    notifyListeners();
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection(firestoreCollection)
          .orderBy('savedAt', descending: true)
          .get();
      _items
        ..clear()
        ..addAll([
          for (final doc in snap.docs)
            SavedBookmarkEntry.fromFirestore(doc.id, doc.data()),
        ]);
    } catch (e) {
      debugPrint('[SavedBookmarks] load error: $e');
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  SavedBookmarkEntry? _find(String clinicName, String procedureName) {
    final id = bookmarkId(clinicName, procedureName);
    for (final item in _items) {
      if (item.id == id) return item;
    }
    return null;
  }

  bool containsClinic(String clinicName) => _find(clinicName, '') != null;

  bool containsProcedure(String clinicName, String procedureName) =>
      _find(clinicName, procedureName) != null;

  Future<void> save(SavedBookmarkEntry entry) async {
    final existing = _find(entry.clinicName, entry.procedureName);
    final resolved = existing == null
        ? entry
        : entry.copyWith(savedAt: DateTime.now(), priceLabel: entry.priceLabel.isNotEmpty ? entry.priceLabel : existing.priceLabel);
    final idx = _items.indexWhere((e) => e.id == resolved.id);
    if (idx >= 0) {
      _items[idx] = resolved;
    } else {
      _items.insert(0, resolved);
    }
    notifyListeners();

    final uid = _uid ?? FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection(firestoreCollection)
          .doc(resolved.id)
          .set(resolved.toFirestore(), SetOptions(merge: true));
    } catch (e) {
      debugPrint('[SavedBookmarks] save error: $e');
    }
  }

  Future<void> remove(String clinicName, {String procedureName = ''}) async {
    final id = bookmarkId(clinicName, procedureName);
    _items.removeWhere((e) => e.id == id);
    notifyListeners();

    final uid = _uid ?? FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection(firestoreCollection)
          .doc(id)
          .delete();
    } catch (e) {
      debugPrint('[SavedBookmarks] remove error: $e');
    }
  }

  Future<void> toggleProcedure({
    required String clinicName,
    required String procedureName,
    required String city,
    String country = '',
    String area = '',
    String priceLabel = '',
    double rating = 0,
    List<String> tags = const [],
    int avatarColor = 0xFF1A1A2E,
  }) async {
    final name = procedureName.trim();
    final clinic = clinicName.trim();
    if (clinic.isEmpty || name.isEmpty) return;
    if (containsProcedure(clinic, name)) {
      await remove(clinic, procedureName: name);
      return;
    }
    final loc = splitLocation(city);
    await save(
      SavedBookmarkEntry(
        id: bookmarkId(clinic, name),
        clinicName: clinic,
        procedureName: name,
        city: loc.$1.isNotEmpty ? loc.$1 : city.trim(),
        country: country.trim().isNotEmpty ? country.trim() : loc.$2,
        priceLabel: priceLabel.trim(),
        area: area.trim(),
        rating: rating,
        tags: tags,
        avatarColor: avatarColor,
        savedAt: DateTime.now(),
      ),
    );
  }

  Future<void> toggleClinic({
    required String clinicName,
    required String city,
    String country = '',
    String area = '',
    double rating = 0,
    List<String> tags = const [],
    int avatarColor = 0xFF1A1A2E,
  }) async {
    final clinic = clinicName.trim();
    if (clinic.isEmpty) return;
    if (containsClinic(clinic)) {
      await remove(clinic);
      return;
    }
    final loc = splitLocation(city);
    await save(
      SavedBookmarkEntry(
        id: bookmarkId(clinic, ''),
        clinicName: clinic,
        city: loc.$1.isNotEmpty ? loc.$1 : city.trim(),
        country: country.trim().isNotEmpty ? country.trim() : loc.$2,
        area: area.trim(),
        rating: rating,
        tags: tags,
        avatarColor: avatarColor,
        savedAt: DateTime.now(),
      ),
    );
  }
}
