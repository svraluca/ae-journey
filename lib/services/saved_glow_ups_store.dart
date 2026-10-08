import 'package:flutter/foundation.dart';

class SavedGlowUpEntry {
  const SavedGlowUpEntry({
    required this.procedure,
    required this.duration,
    this.area = '',
    this.userName = '',
    this.iconAsset = 'assets/staricon.png',
  });

  final String procedure;
  final String duration;
  final String area;
  final String userName;
  final String iconAsset;

  String get id =>
      '${procedure.trim().toLowerCase()}|${duration.trim().toLowerCase()}|${userName.trim().toLowerCase()}';
}

/// In-memory favorites for community Glow Up results.
class SavedGlowUpsStore extends ChangeNotifier {
  SavedGlowUpsStore._();
  static final SavedGlowUpsStore instance = SavedGlowUpsStore._();

  final List<SavedGlowUpEntry> _items = [];

  List<SavedGlowUpEntry> get items => List.unmodifiable(_items);

  bool contains(SavedGlowUpEntry e) => _items.any((x) => x.id == e.id);

  bool containsId(String id) => _items.any((x) => x.id == id);

  void toggle(SavedGlowUpEntry e) {
    final i = _items.indexWhere((x) => x.id == e.id);
    if (i >= 0) {
      _items.removeAt(i);
    } else {
      _items.insert(0, e);
    }
    notifyListeners();
  }

  void remove(SavedGlowUpEntry e) {
    final i = _items.indexWhere((x) => x.id == e.id);
    if (i >= 0) {
      _items.removeAt(i);
      notifyListeners();
    }
  }

  void clear() {
    if (_items.isEmpty) return;
    _items.clear();
    notifyListeners();
  }
}
