import 'dart:async';

import 'package:flutter/foundation.dart';

/// Session-wide Explore request coordinator for Serper, Places, backend
/// discovery, and website verification.
///
/// Budgets and concurrency are shared across All-preview pills and focused
/// searches so one All screen cannot fan out 17 Serper calls at once.
enum ExploreRequestMode {
  /// UI-critical path: one attempt, no Serper retry.
  foreground,

  /// Detached work: at most one controlled retry when budget remains.
  background,
}

class ExploreRequestCoordinator {
  ExploreRequestCoordinator._();
  static final ExploreRequestCoordinator instance = ExploreRequestCoordinator._();

  static const int maxSerperConcurrency = 2;
  static const int allScreenSerperBudget = 4;
  static const int focusedSerperBudget = 10;

  /// Website verification is scrape + DOM parse + LLM on the UI isolate, so
  /// this is a **session-wide** cap. Each fill wave used to run its own pool
  /// of four, and a city search runs several waves at once (foreground
  /// Google, city stubs, backend deep, All-preview pills) — Tirana peels hit
  /// double-digit concurrent scrapes and the screen stopped taking taps.
  static const int maxVerifyConcurrency = 6;

  int _serpInFlight = 0;
  int _serpCallsTotal = 0;
  int _providerConcurrencyPeak = 0;
  int _allSerpUsed = 0;
  final Map<String, int> _focusedSerpUsed = {};
  final Map<String, Future<dynamic>> _serpQueryFutures = {};
  final Map<String, Future<dynamic>> _hostFetchFutures = {};
  final Map<String, Future<dynamic>> _clinicVerifyFutures = {};
  int _verifyJoins = 0;
  int _verifyInFlight = 0;
  final List<Completer<void>> _serpWaiters = [];
  final List<Completer<void>> _verifyWaiters = [];

  /// Optional All-screen visit token. While non-null, Serper spends against
  /// [allScreenSerperBudget] instead of per-pill focused budgets.
  String? _allVisitId;

  int get serpCallsTotal => _serpCallsTotal;
  int get providerConcurrencyPeak => _providerConcurrencyPeak;
  int get serpInFlight => _serpInFlight;
  int get allSerpUsed => _allSerpUsed;

  @visibleForTesting
  void resetForTest() {
    _serpInFlight = 0;
    _serpCallsTotal = 0;
    _providerConcurrencyPeak = 0;
    _allSerpUsed = 0;
    _focusedSerpUsed.clear();
    _serpQueryFutures.clear();
    _hostFetchFutures.clear();
    _clinicVerifyFutures.clear();
    _verifyJoins = 0;
    _verifyInFlight = 0;
    for (final c in _serpWaiters) {
      if (!c.isCompleted) c.complete();
    }
    _serpWaiters.clear();
    for (final c in _verifyWaiters) {
      if (!c.isCompleted) c.complete();
    }
    _verifyWaiters.clear();
    _allVisitId = null;
  }

  void beginAllVisit(String visitId) {
    final id = visitId.trim();
    if (id.isEmpty) return;
    if (_allVisitId == id) return;
    _allVisitId = id;
    _allSerpUsed = 0;
    debugPrint('[PERF] allVisitStart id=$id serpBudget=$allScreenSerperBudget');
  }

  void endAllVisit(String visitId) {
    if (_allVisitId == visitId.trim()) {
      debugPrint(
        '[PERF] allVisitEnd id=$visitId serpCalls=$_allSerpUsed '
        'total=$_serpCallsTotal peak=$_providerConcurrencyPeak',
      );
      _allVisitId = null;
    }
  }

  bool get isAllVisitActive => _allVisitId != null;

  bool canSpendSerper({required String procedureKey, required bool allPreview}) {
    // Budget only — concurrency is gated by _acquireSerperSlot waiters.
    if (allPreview || _allVisitId != null) {
      return _allSerpUsed < allScreenSerperBudget;
    }
    final used = _focusedSerpUsed[procedureKey] ?? 0;
    return used < focusedSerperBudget;
  }

  void _noteSpend({required String procedureKey, required bool allPreview}) {
    _serpCallsTotal++;
    if (allPreview || _allVisitId != null) {
      _allSerpUsed++;
    } else {
      _focusedSerpUsed[procedureKey] = (_focusedSerpUsed[procedureKey] ?? 0) + 1;
    }
  }

  Future<void> _acquireSerperSlot() async {
    while (_serpInFlight >= maxSerperConcurrency) {
      final c = Completer<void>();
      _serpWaiters.add(c);
      await c.future;
    }
    _serpInFlight++;
    if (_serpInFlight > _providerConcurrencyPeak) {
      _providerConcurrencyPeak = _serpInFlight;
    }
  }

  void _releaseSerperSlot() {
    if (_serpInFlight > 0) _serpInFlight--;
    while (_serpWaiters.isNotEmpty && _serpInFlight < maxSerperConcurrency) {
      final c = _serpWaiters.removeAt(0);
      if (!c.isCompleted) c.complete();
    }
  }

  /// Run a Serper (or other SERP) query under global concurrency + budget.
  /// Identical [queryKey] futures are coalesced.
  Future<T> runSerpQuery<T>({
    required String queryKey,
    required String procedureKey,
    required ExploreRequestMode mode,
    required Future<T> Function() run,
    bool allPreview = false,
    T Function()? onBudgetExhausted,
  }) async {
    final key = queryKey.trim().toLowerCase();
    final pending = _serpQueryFutures[key];
    if (pending != null) {
      return (await pending) as T;
    }

    final all = allPreview || _allVisitId != null;
    if (!canSpendSerper(procedureKey: procedureKey, allPreview: all)) {
      debugPrint(
        '[PERF] serpBudgetExhausted · procedure=$procedureKey '
        'all=$all used=${all ? _allSerpUsed : _focusedSerpUsed[procedureKey]}',
      );
      if (onBudgetExhausted != null) return onBudgetExhausted();
      throw StateError('Explore Serper budget exhausted');
    }

    late final Future<T> fut;
    fut = () async {
      await _acquireSerperSlot();
      try {
        // Re-check budget after waiting for a concurrency slot.
        if (!canSpendSerper(procedureKey: procedureKey, allPreview: all)) {
          if (onBudgetExhausted != null) return onBudgetExhausted();
          throw StateError('Explore Serper budget exhausted');
        }
        _noteSpend(procedureKey: procedureKey, allPreview: all);
        return await run();
      } finally {
        _releaseSerperSlot();
        scheduleMicrotask(() {
          if (_serpQueryFutures[key] == fut) _serpQueryFutures.remove(key);
        });
      }
    }();
    _serpQueryFutures[key] = fut;
    return fut;
  }

  /// Deduplicate identical host page fetches.
  Future<T> runHostFetch<T>({
    required String hostKey,
    required Future<T> Function() run,
  }) async {
    final key = hostKey.trim().toLowerCase();
    final pending = _hostFetchFutures[key];
    if (pending != null) return (await pending) as T;
    late final Future<T> fut;
    fut = () async {
      try {
        return await run();
      } finally {
        scheduleMicrotask(() {
          if (_hostFetchFutures[key] == fut) _hostFetchFutures.remove(key);
        });
      }
    }();
    _hostFetchFutures[key] = fut;
    return fut;
  }

  int get verifyJoins => _verifyJoins;
  int get verifyInFlight => _verifyInFlight;

  /// One website verification per clinic + procedure, session-wide.
  ///
  /// The same clinic reaches this from several waves at once (a pill fill, the
  /// All preview, backend deep top-up, a re-entered search). Each pass repeats
  /// the whole chain — sitemap, Firecrawl map, fetch, DOM parse, LLM — so
  /// duplicates burned the discovery budget and the UI isolate without ever
  /// producing a new card. Callers with no stable identity still get the gate.
  Future<T> runClinicVerify<T>({
    required String clinicKey,
    required Future<T> Function() run,
  }) async {
    final key = clinicKey.trim().toLowerCase();
    if (key.isEmpty) return runWebsiteVerify(run: run);
    final pending = _clinicVerifyFutures[key];
    if (pending != null) {
      _verifyJoins++;
      debugPrint('[GP VERIFY] join in-flight · $key');
      return (await pending) as T;
    }
    late final Future<T> fut;
    fut = () async {
      try {
        return await runWebsiteVerify(run: run);
      } finally {
        scheduleMicrotask(() {
          if (_clinicVerifyFutures[key] == fut) {
            _clinicVerifyFutures.remove(key);
          }
        });
      }
    }();
    _clinicVerifyFutures[key] = fut;
    return fut;
  }

  Future<T> runWebsiteVerify<T>({
    required Future<T> Function() run,
  }) async {
    while (_verifyInFlight >= maxVerifyConcurrency) {
      final c = Completer<void>();
      _verifyWaiters.add(c);
      await c.future;
    }
    _verifyInFlight++;
    try {
      return await run();
    } finally {
      if (_verifyInFlight > 0) _verifyInFlight--;
      while (_verifyWaiters.isNotEmpty &&
          _verifyInFlight < maxVerifyConcurrency) {
        final c = _verifyWaiters.removeAt(0);
        if (!c.isCompleted) c.complete();
      }
    }
  }

  /// Whether a Serper timeout may retry (background only + budget left).
  bool mayRetrySerper({
    required ExploreRequestMode mode,
    required bool uiDeadlinePassed,
    required String procedureKey,
    bool allPreview = false,
  }) {
    if (mode == ExploreRequestMode.foreground) return false;
    if (uiDeadlinePassed) return false;
    return canSpendSerper(procedureKey: procedureKey, allPreview: allPreview);
  }

  void logPerfSnapshot({
    required String label,
    int? cachePaintMs,
    int? firstCardMs,
    int? targetReachedMs,
    int? uiCompletedMs,
    bool? backgroundDetached,
  }) {
    debugPrint(
      '[PERF] $label'
      '${cachePaintMs != null ? " cachePaintMs=$cachePaintMs" : ""}'
      '${firstCardMs != null ? " firstCardMs=$firstCardMs" : ""}'
      '${targetReachedMs != null ? " targetReachedMs=$targetReachedMs" : ""}'
      '${uiCompletedMs != null ? " uiCompletedMs=$uiCompletedMs" : ""}'
      ' serpCalls=$_serpCallsTotal'
      ' providerConcurrencyPeak=$_providerConcurrencyPeak'
      '${backgroundDetached != null ? " backgroundDetached=$backgroundDetached" : ""}',
    );
  }
}
