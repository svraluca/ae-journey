import 'package:flutter/foundation.dart';

import 'saved_bookmarks_store.dart';

/// Procedure bookmarks facade over [SavedBookmarksStore].
class SavedProceduresStore extends ChangeNotifier {
  SavedProceduresStore._() {
    SavedBookmarksStore.instance.addListener(_onBookmarksChanged);
  }
  static final SavedProceduresStore instance = SavedProceduresStore._();

  void _onBookmarksChanged() => notifyListeners();

  List<SavedBookmarkEntry> get entries => SavedBookmarksStore.instance.items
      .where((e) => e.procedureName.trim().isNotEmpty)
      .toList();

  /// Legacy: procedure names only (compare pool).
  List<String> get items {
    final names = entries.map((e) => e.procedureName.trim()).where((s) => s.isNotEmpty).toSet();
    return names.toList()..sort();
  }

  bool containsClinicProcedure(String clinicName, String procedureName) =>
      SavedBookmarksStore.instance.containsProcedure(clinicName, procedureName);

  /// Legacy name-only check (any clinic).
  bool contains(String procedureName) {
    final key = SavedBookmarksStore.norm(procedureName);
    return entries.any((e) => SavedBookmarksStore.norm(e.procedureName) == key);
  }

  Future<void> toggleAtClinic({
    required String clinicName,
    required String procedureName,
    required String city,
    String country = '',
    String area = '',
    String priceLabel = '',
    double rating = 0,
  }) {
    return SavedBookmarksStore.instance.toggleProcedure(
      clinicName: clinicName,
      procedureName: procedureName,
      city: city,
      country: country,
      area: area,
      priceLabel: priceLabel,
      rating: rating,
    );
  }

  Future<void> remove(String procedureName) async {
    final key = SavedBookmarksStore.norm(procedureName);
    final matches = entries.where((e) => SavedBookmarksStore.norm(e.procedureName) == key).toList();
    for (final e in matches) {
      await SavedBookmarksStore.instance.remove(e.clinicName, procedureName: e.procedureName);
    }
  }

  Future<void> clear() async {
    for (final e in List<SavedBookmarkEntry>.from(entries)) {
      await SavedBookmarksStore.instance.remove(e.clinicName, procedureName: e.procedureName);
    }
  }
}
