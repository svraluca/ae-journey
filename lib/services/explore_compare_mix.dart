import 'dart:math';

/// Selection rules shared by the Python-first path and the legacy pool planner.
/// Kept independent of Flutter and Firebase so partial streams are testable.
const kExploreCompareDisplayLimit = 4;
const kExploreCompareGoodEnough = 4;
const kExploreCompareSavedTarget = 2;
const kExploreCompareFreshTarget = 2;

/// Fair exposure within a city. Ratings and prices never buy a display slot;
/// equally exposed providers are shuffled, and sibling tabs prefer variety.
/// The caller selects once per visit, then stabilizes progressive updates.
class ExploreCompareRotation {
  ExploreCompareRotation({Random? random}) : _random = random ?? Random();
  final Random _random;
  final Map<String, Map<String, int>> _exposures = {};
  final Map<String, Map<String, Set<String>>> _shown = {};

  List<T> select<T>({
    required String city,
    required String procedure,
    required Iterable<T> eligible,
    required String Function(T) providerKey,
  }) {
    final cityKey = city.trim().toLowerCase();
    final topic = procedure.trim().toLowerCase();
    final counts = _exposures.putIfAbsent('$cityKey|$topic', () => {});
    final siblings = _shown.putIfAbsent(cityKey, () => {});
    final otherProviders = <String>{
      for (final entry in siblings.entries)
        if (entry.key != topic) ...entry.value,
    };
    final unique = <String, T>{};
    for (final row in eligible) {
      final key = providerKey(row);
      if (key.isNotEmpty) unique.putIfAbsent(key, () => row);
    }
    final keys = unique.keys.toList()..shuffle(_random);
    keys.sort((a, b) {
      final exposure = (counts[a] ?? 0).compareTo(counts[b] ?? 0);
      if (exposure != 0) return exposure;
      return (otherProviders.contains(a) ? 1 : 0).compareTo(
        otherProviders.contains(b) ? 1 : 0,
      );
    });
    final selected = keys.take(kExploreCompareDisplayLimit).toList();
    siblings[topic] = selected.toSet();
    for (final key in selected) counts[key] = (counts[key] ?? 0) + 1;
    return [for (final key in selected) unique[key]!];
  }
}

/// Keep displayed providers in their slots. A verified newer tariff may update
/// its own slot; background pool order cannot rotate providers.
List<T> stabilizeExploreCompareRows<T>({
  required Iterable<T> shown,
  required Iterable<T> incoming,
  required bool Function(T row) stillEligible,
  required bool Function(T a, T b) sameProvider,
  bool Function(T previous, T incoming)? preferIncoming,
}) {
  final out = <T>[];
  for (final row in shown) {
    if (!stillEligible(row) || out.any((old) => sameProvider(old, row)))
      continue;
    out.add(row);
    if (out.length == kExploreCompareDisplayLimit) break;
  }
  for (final row in incoming) {
    if (!stillEligible(row)) continue;
    final index = out.indexWhere((old) => sameProvider(old, row));
    if (index >= 0) {
      if (preferIncoming?.call(out[index], row) == true) out[index] = row;
    } else if (out.length < kExploreCompareDisplayLimit) {
      out.add(row);
    }
  }
  return out;
}

class ExploreCompareTargets {
  const ExploreCompareTargets(this.saved, this.live);
  final int saved;
  final int live;
}

ExploreCompareTargets exploreCompareTargets(int savedCount) {
  final saved = savedCount.clamp(0, kExploreCompareSavedTarget);
  return ExploreCompareTargets(saved, kExploreCompareDisplayLimit - saved);
}

/// Upsert independently validated server rows without losing prior partials.
/// A newer row replaces its provider's old price and method in the same slot.
List<T> mergeExploreAcceptedRows<T>(
  Iterable<T> previous,
  Iterable<T> incoming, {
  required bool Function(T a, T b) sameProvider,
}) {
  final out = <T>[];
  for (final row in [...previous, ...incoming]) {
    final index = out.indexWhere((old) => sameProvider(old, row));
    if (index < 0) {
      out.add(row);
    } else {
      out[index] = row;
    }
  }
  return out;
}

/// Apply the display cap only after validation and provider deduplication.
/// Saved overflow may fill a fresh shortage; retained rows bridge partials.
List<T> selectExploreCompareRows<T>({
  required Iterable<T> saved,
  required Iterable<T> live,
  Iterable<T> retained = const [],
  required bool Function(T a, T b) sameProvider,
}) {
  final saves = mergeExploreAcceptedRows<T>(
    const [],
    saved,
    sameProvider: sameProvider,
  );
  final fresh = live.toList();
  final out = <T>[];
  bool add(T row) {
    if (out.length >= kExploreCompareDisplayLimit ||
        out.any((old) => sameProvider(old, row))) {
      return false;
    }
    out.add(row);
    return true;
  }

  for (final row in saves.take(kExploreCompareSavedTarget)) {
    add(row);
  }
  for (final row in fresh) {
    add(row);
  }
  for (final row in [...saves, ...retained]) {
    add(row);
  }
  return out;
}
