import 'package:flutter/foundation.dart';

import 'saved_bookmarks_store.dart';

class SavedClinicEntry {
  const SavedClinicEntry({
    required this.name,
    this.area = '',
    this.rating = 0,
    this.tags = const [],
    this.avatarColor = 0xFF1A1A2E,
    this.procedure = '',
    this.city = '',
    this.country = '',
    this.priceLabel = '',
  });

  final String name;
  final String area;
  final double rating;
  final List<String> tags;
  final int avatarColor;
  final String procedure;
  final String city;
  final String country;
  final String priceLabel;

  String get initials {
    final parts = name.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).take(2);
    return parts.map((p) => p[0].toUpperCase()).join();
  }

  factory SavedClinicEntry.fromBookmark(SavedBookmarkEntry e) {
    return SavedClinicEntry(
      name: e.clinicName,
      area: e.area,
      rating: e.rating,
      tags: e.tags,
      avatarColor: e.avatarColor,
      procedure: e.procedureName,
      city: e.city,
      country: e.country,
      priceLabel: e.priceLabel,
    );
  }
}

class SavedClinicsStore extends ChangeNotifier {
  SavedClinicsStore._() {
    SavedBookmarksStore.instance.addListener(_onBookmarksChanged);
  }
  static final SavedClinicsStore instance = SavedClinicsStore._();

  void _onBookmarksChanged() => notifyListeners();

  List<SavedClinicEntry> get items => SavedBookmarksStore.instance.items
      .map(SavedClinicEntry.fromBookmark)
      .toList();

  bool contains(String name, [String procedure = '']) =>
      SavedBookmarksStore.instance.containsProcedure(name, procedure) ||
      (procedure.trim().isEmpty && SavedBookmarksStore.instance.containsClinic(name));

  Future<void> add(SavedClinicEntry e) {
    final proc = e.procedure.trim();
    final loc = SavedBookmarksStore.splitLocation(e.city.isNotEmpty ? e.city : e.area);
    return SavedBookmarksStore.instance.save(
      SavedBookmarkEntry(
        id: SavedBookmarksStore.bookmarkId(e.name, proc),
        clinicName: e.name.trim(),
        procedureName: proc,
        city: e.city.isNotEmpty ? e.city : loc.$1,
        country: e.country.isNotEmpty ? e.country : loc.$2,
        area: e.area,
        priceLabel: e.priceLabel,
        rating: e.rating,
        tags: e.tags,
        avatarColor: e.avatarColor,
        savedAt: DateTime.now(),
      ),
    );
  }

  Future<void> remove(String name, [String procedure = '']) =>
      SavedBookmarksStore.instance.remove(name, procedureName: procedure);

  Future<void> removeNamed(String name) => remove(name);
}
