import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Tunable Explore pipeline budgets (Flutter reads dotenv; Functions use env).
///
/// These control *how many candidates to inspect*, not verification strictness.
abstract final class ExplorePipelineConfig {
  static int _intEnv(String key, int fallback, {int min = 1, int max = 100}) {
    String raw = '';
    try {
      raw = dotenv.env[key]?.trim() ?? '';
    } catch (_) {
      raw = '';
    }
    if (raw.isEmpty) {
      raw = String.fromEnvironment(key, defaultValue: '');
    }
    final n = int.tryParse(raw);
    if (n == null) return fallback;
    if (n < min) return min;
    if (n > max) return max;
    return n;
  }

  static bool _boolEnv(String key, bool fallback) {
    String raw = '';
    try {
      raw = (dotenv.env[key] ?? '').trim().toLowerCase();
    } catch (_) {
      raw = '';
    }
    if (raw.isEmpty) {
      raw = String.fromEnvironment(key).trim().toLowerCase();
    }
    if (raw.isEmpty) return fallback;
    if (const {'1', 'true', 'yes', 'on'}.contains(raw)) return true;
    if (const {'0', 'false', 'no', 'off'}.contains(raw)) return false;
    return fallback;
  }

  /// Cards the UI aims to show.
  static int get visibleTarget =>
      _intEnv('EXPLORE_VISIBLE_TARGET', 4, min: 1, max: 8);

  /// Max candidates to website-verify per search wave.
  static int get candidateVerifyLimit =>
      _intEnv('EXPLORE_CANDIDATE_VERIFY_LIMIT', 16, min: 4, max: 40);

  /// Max discovery leads to collect before verify.
  static int get discoveryLimit =>
      _intEnv('EXPLORE_DISCOVERY_LIMIT', 30, min: 8, max: 80);

  /// Soft cap on Places/Serper calls per live search.
  static int get maxProviderRequests =>
      _intEnv('EXPLORE_MAX_PROVIDER_REQUESTS', 20, min: 4, max: 60);

  static bool get useZyteFallback =>
      _boolEnv('USE_ZYTE_FALLBACK', false);

  static int get maxZyteAttemptsPerClinic =>
      _intEnv('MAX_ZYTE_ATTEMPTS_PER_CLINIC', 1, min: 0, max: 3);
}
