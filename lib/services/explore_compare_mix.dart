/// Selection rules shared by the Python-first path and the legacy pool planner.
/// Kept independent of Flutter and Firebase so partial streams are testable.
const kExploreCompareDisplayLimit = 4;
const kExploreCompareGoodEnough = 4;
const kExploreCompareSavedTarget = 2;
const kExploreCompareFreshTarget = 2;

/// A displayed tariff is a snapshot until the user explicitly refreshes.
/// Valid newcomers fill empty slots; background pool order cannot rotate it.
List<T> stabilizeExploreCompareRows<T>({
  required Iterable<T> shown,
  required Iterable<T> incoming,
  required bool Function(T row) stillEligible,
  required bool Function(T a, T b) sameProvider,
}) {
  final out = <T>[];
  for (final row in [...shown, ...incoming]) {
    if (!stillEligible(row) || out.any((old) => sameProvider(old, row))) continue;
    out.add(row);
    if (out.length == kExploreCompareDisplayLimit) break;
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
