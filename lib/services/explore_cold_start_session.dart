import 'dart:async';

import 'explore_city_identity.dart';
import 'explore_pipeline_config.dart';
import 'openai_service.dart';

/// In-memory progressive cold-city discovery session for integration tests
/// and as the contract the live Explore path must honour.
///
/// Backend work continues after [detachUi] — leaving the screen does not
/// cancel [backendContinuing].
class ExploreColdStartSession {
  ExploreColdStartSession({
    required this.city,
    required this.procedure,
    this.visibleTarget = 4,
  });

  final ExploreCityIdentity city;
  final String procedure;
  final int visibleTarget;

  final _uiController = StreamController<List<OpenAIClinic>>.broadcast();
  final List<OpenAIClinic> _store = [];
  final List<OpenAIClinic> _uiVisible = [];
  bool _uiAttached = true;
  bool _discoveryStarted = false;
  bool _backendCancelled = false;
  Completer<void>? _backendDone;

  Stream<List<OpenAIClinic>> get uiResults => _uiController.stream;
  List<OpenAIClinic> get firestoreStore => List.unmodifiable(_store);
  List<OpenAIClinic> get uiVisible => List.unmodifiable(_uiVisible);
  bool get discoveryStarted => _discoveryStarted;
  bool get backendCancelled => _backendCancelled;
  bool get backendContinuing =>
      _discoveryStarted && !(_backendDone?.isCompleted ?? true);

  /// Detach the Flutter screen. Backend must keep writing.
  void detachUi() {
    _uiAttached = false;
  }

  /// Re-attach and load stored results immediately (warm return).
  List<OpenAIClinic> reattachAndLoadStored() {
    _uiAttached = true;
    _uiVisible
      ..clear()
      ..addAll(_store.take(visibleTarget));
    if (!_uiController.isClosed) {
      _uiController.add(List.unmodifiable(_uiVisible));
    }
    return uiVisible;
  }

  /// Simulate cold discovery that verifies candidates progressively.
  Future<void> runDiscovery({
    required List<OpenAIClinic> verifiedInOrder,
    Duration stepDelay = Duration.zero,
  }) async {
    if (!city.isResolved) {
      throw StateError('city_unresolved');
    }
    if (_store.isNotEmpty) {
      reattachAndLoadStored();
      return;
    }
    _discoveryStarted = true;
    _backendDone = Completer<void>();
    final budget = ExplorePipelineConfig.candidateVerifyLimit;
    final toVerify = verifiedInOrder.take(budget).toList();
    try {
      for (final clinic in toVerify) {
        if (_backendCancelled) break;
        if (stepDelay > Duration.zero) {
          await Future<void>.delayed(stepDelay);
        }
        // Persist immediately (idempotent upsert by identity).
        final exists = _store.any(
          (e) =>
              (e.placeId.isNotEmpty && e.placeId == clinic.placeId) ||
              e.name == clinic.name,
        );
        if (!exists) {
          _store.add(clinic);
        }
        if (_uiAttached && _uiVisible.length < visibleTarget) {
          _uiVisible.add(clinic);
          if (!_uiController.isClosed) {
            _uiController.add(List.unmodifiable(_uiVisible));
          }
        }
        if (_store.length >= visibleTarget) break;
      }
    } finally {
      _backendDone?.complete();
    }
  }

  /// Explicit cancel is only for tests of failure paths — UI leave must not call this.
  void cancelBackendForTest() {
    _backendCancelled = true;
  }

  Future<void> get whenBackendSettled =>
      _backendDone?.future ?? Future<void>.value();

  Future<void> dispose() async {
    await _uiController.close();
  }
}
