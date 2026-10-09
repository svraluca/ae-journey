import 'dart:async';

import 'explore_price_discovery_tool.dart';

/// Keep specific requests specific while reading older procedure cache keys.
List<String> exploreSavedProcedureKeys(String procedure) => <String>{
  procedure.trim(),
  ExplorePriceDiscoveryTool.procedureForTool(procedure),
}.where((key) => key.isNotEmpty).toList();

/// Publish each validated cache source as it arrives. A slow or unavailable
/// store must not hold back rows already available from another store.
Future<List<T>> loadExploreSavedPrices<T>({
  required Map<String, Future<List<T>>> sources,
  required List<T> Function(List<T>) select,
  void Function(List<T>)? onProgress,
  void Function(String source, int rows)? onSource,
  void Function(String source, Object error)? onError,
  Duration deadline = const Duration(seconds: 3),
}) async {
  final collected = <T>[];
  final pending = <Future<void>>[
    for (final entry in sources.entries)
      () async {
        try {
          final rows = await entry.value;
          collected.addAll(rows);
          onSource?.call(entry.key, rows.length);
          final verified = select(List<T>.of(collected));
          if (verified.isNotEmpty) onProgress?.call(verified);
        } catch (error) {
          onError?.call(entry.key, error);
        }
      }(),
  ];
  await Future.wait(pending).timeout(deadline, onTimeout: () => const []);
  // Late reads still publish through onProgress; callers guard the active
  // city/procedure and display generation before accepting an update.
  return select(List<T>.of(collected));
}
