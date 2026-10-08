import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'explore_city_identity.dart';
import 'filter_currency.dart';

class SessionPrefs {
  static const _kKeepSignedIn = 'keep_signed_in';
  static const _kCompareSearchCity = 'compare_search_city';
  static const _kCompareSearchCityIdentity = 'compare_search_city_identity';
  static const _kNotificationPromptCompleted = 'notification_prompt_completed';
  static const _kGlowUpNotificationPromptCompleted =
      'glow_up_notification_prompt_completed';
  static const _kExploreSavedCities = 'explore_saved_cities';
  static const _kExploreRecentCities = 'explore_recent_cities';
  static const _kExploreLastShownPrefix = 'explore_last_shown|';
  static const _kExploreInterestPills = 'explore_interest_pills';
  static const _kExploreInterestsCompleted = 'explore_interests_completed';
  static const _kMaxSavedCities = 24;
  static const _kMaxRecentCities = 5;
  static const _kMaxLastShownKeys = 24;

  /// Interests are per Firebase user so a new account always gets the picker.
  static String? get _authUid => FirebaseAuth.instance.currentUser?.uid;

  static String _interestCompletedKey(String? uid) =>
      uid == null || uid.isEmpty
          ? _kExploreInterestsCompleted
          : '$_kExploreInterestsCompleted|$uid';

  static String _interestPillsKey(String? uid) =>
      uid == null || uid.isEmpty
          ? _kExploreInterestPills
          : '$_kExploreInterestPills|$uid';

  static Future<bool> notificationPromptCompleted() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kNotificationPromptCompleted) ?? false;
  }

  static Future<void> setNotificationPromptCompleted(bool value) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kNotificationPromptCompleted, value);
  }

  static Future<bool> glowUpNotificationPromptCompleted() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kGlowUpNotificationPromptCompleted) ?? false;
  }

  static Future<void> setGlowUpNotificationPromptCompleted(bool value) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kGlowUpNotificationPromptCompleted, value);
  }

  static Future<String?> compareSearchCity() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kCompareSearchCity);
  }

  static Future<void> setCompareSearchCity(String city) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kCompareSearchCity, city.trim());
  }

  static Future<ExploreCityIdentity?> compareSearchCityIdentity() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kCompareSearchCityIdentity);
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return ExploreCityIdentity.fromJson(
        decoded.map((k, v) => MapEntry('$k', v)),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> setCompareSearchCityIdentity(
    ExploreCityIdentity? identity,
  ) async {
    final p = await SharedPreferences.getInstance();
    if (identity == null) {
      await p.remove(_kCompareSearchCityIdentity);
      return;
    }
    await p.setString(
      _kCompareSearchCityIdentity,
      jsonEncode(identity.toJson()),
    );
  }

  /// Cities the user added to the Explore location list.
  static Future<List<String>> exploreSavedCities() async {
    final p = await SharedPreferences.getInstance();
    return List<String>.from(p.getStringList(_kExploreSavedCities) ?? const []);
  }

  static Future<void> addExploreSavedCity(String city) async {
    final normalized = normalizeExploreCity(city.trim());
    if (normalized.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    final list = List<String>.from(
      p.getStringList(_kExploreSavedCities) ?? const [],
    );
    list.removeWhere(
      (c) => c.toLowerCase() == normalized.toLowerCase(),
    );
    list.insert(0, normalized);
    if (list.length > _kMaxSavedCities) {
      list.removeRange(_kMaxSavedCities, list.length);
    }
    await p.setStringList(_kExploreSavedCities, list);
  }

  static Future<void> removeExploreSavedCity(String city) async {
    final key = city.trim().toLowerCase();
    if (key.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    final list = List<String>.from(
      p.getStringList(_kExploreSavedCities) ?? const [],
    );
    list.removeWhere((c) => c.toLowerCase() == key);
    await p.setStringList(_kExploreSavedCities, list);
  }

  static Future<List<String>> exploreRecentCities() async {
    final p = await SharedPreferences.getInstance();
    final list = List<String>.from(
      p.getStringList(_kExploreRecentCities) ?? const [],
    );
    // Trim legacy lists that grew past the new cap.
    if (list.length > _kMaxRecentCities) {
      final trimmed = list.take(_kMaxRecentCities).toList();
      await p.setStringList(_kExploreRecentCities, trimmed);
      return trimmed;
    }
    return list;
  }

  static Future<void> pushExploreRecentCity(String city) async {
    final normalized = normalizeExploreCity(city.trim());
    if (normalized.isEmpty || normalized.toLowerCase() == 'near me') {
      return;
    }
    final p = await SharedPreferences.getInstance();
    final list = List<String>.from(
      p.getStringList(_kExploreRecentCities) ?? const [],
    );
    list.removeWhere(
      (c) => c.toLowerCase() == normalized.toLowerCase(),
    );
    list.insert(0, normalized);
    if (list.length > _kMaxRecentCities) {
      list.removeRange(_kMaxRecentCities, list.length);
    }
    await p.setStringList(_kExploreRecentCities, list);
  }

  static Future<bool> keepSignedIn() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kKeepSignedIn) ?? true;
  }

  static Future<void> setKeepSignedIn(bool value) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kKeepSignedIn, value);
  }

  /// Whether this signed-in user finished (or skipped) Explore personalization.
  /// Scoped by UID — never reuse another account's completion on this device.
  static Future<bool> exploreInterestsCompleted() async {
    final p = await SharedPreferences.getInstance();
    final uid = _authUid;
    if (uid == null || uid.isEmpty) return false;
    return p.getBool(_interestCompletedKey(uid)) ?? false;
  }

  static Future<void> setExploreInterestsCompleted(bool value) async {
    final p = await SharedPreferences.getInstance();
    final uid = _authUid;
    if (uid == null || uid.isEmpty) return;
    await p.setBool(_interestCompletedKey(uid), value);
  }

  /// Canonical Compare pill keys the user wants in the Explore tab strip.
  /// Empty means "not set" — callers should fall back to the full strip.
  static Future<List<String>> exploreInterestPills() async {
    final p = await SharedPreferences.getInstance();
    final uid = _authUid;
    if (uid == null || uid.isEmpty) return const [];
    return List<String>.from(
      p.getStringList(_interestPillsKey(uid)) ?? const [],
    );
  }

  static Future<void> setExploreInterestPills(List<String> pills) async {
    final p = await SharedPreferences.getInstance();
    final uid = _authUid;
    if (uid == null || uid.isEmpty) return;
    final cleaned = <String>[
      for (final pill in pills)
        if (pill.trim().isNotEmpty) pill.trim(),
    ];
    await p.setStringList(_interestPillsKey(uid), cleaned);
    await p.setBool(_interestCompletedKey(uid), true);
  }

  static String _exploreLastShownPrefKey(String city, String pill) {
    return '$_kExploreLastShownPrefix'
        '${city.trim().toLowerCase()}|${pill.trim()}';
  }

  /// Dedup keys shown last time for [city] + [pill], so Compare can rotate
  /// the cached half after a restart (in-memory last-shown is empty then).
  static Future<List<String>> exploreLastShownKeys(
    String city,
    String pill,
  ) async {
    if (city.trim().isEmpty || pill.trim().isEmpty) return const [];
    final p = await SharedPreferences.getInstance();
    return List<String>.from(
      p.getStringList(_exploreLastShownPrefKey(city, pill)) ?? const [],
    );
  }

  static Future<void> setExploreLastShownKeys({
    required String city,
    required String pill,
    required List<String> keys,
  }) async {
    if (city.trim().isEmpty || pill.trim().isEmpty) return;
    final p = await SharedPreferences.getInstance();
    final cleaned = <String>[
      for (final k in keys)
        if (k.trim().isNotEmpty) k.trim(),
    ];
    if (cleaned.isEmpty) return;
    final capped = cleaned.length <= _kMaxLastShownKeys
        ? cleaned
        : cleaned.sublist(0, _kMaxLastShownKeys);
    await p.setStringList(_exploreLastShownPrefKey(city, pill), capped);
  }
}
