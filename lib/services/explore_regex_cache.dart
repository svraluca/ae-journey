/// Reuse compiled patterns across price-validation rows.
///
/// Dart has no pattern cache: `RegExp(r'...')` written inside a function body
/// recompiles that pattern on every call. The price pipeline runs a few dozen
/// of them per extracted row, which measured at ~107 ms per row in
/// [classifyProcedureRelation] — a 3.7 KB price list with 80 priced rows took
/// eight seconds of pure UI-isolate CPU, and a full price menu took over a
/// minute. That is what froze Explore while the terminal kept logging.
///
/// Safe to share: a Dart [RegExp] holds no match state (unlike JavaScript's
/// `lastIndex`), so one instance can serve concurrent `hasMatch` /
/// `firstMatch` / `allMatches` calls.
///
/// Dynamic patterns (escaped city/price tokens) use the same bounded cache.
/// Long patterns bypass retention so scraped input cannot grow memory.
library;

final Map<String, RegExp> _cache = <String, RegExp>{};

RegExp cachedRegExp(
  String pattern, {
  bool caseSensitive = true,
  bool unicode = false,
  bool multiLine = false,
  bool dotAll = false,
}) {
  final key =
      '$pattern\u0000$caseSensitive$unicode$multiLine$dotAll';
  final hit = _cache[key];
  if (hit != null) return hit;
  final compiled = RegExp(
    pattern,
    caseSensitive: caseSensitive,
    unicode: unicode,
    multiLine: multiLine,
    dotAll: dotAll,
  );
  if (pattern.length <= 8192) {
    if (_cache.length >= 2048) _cache.remove(_cache.keys.first);
    _cache[key] = compiled;
  }
  return compiled;
}

/// Patterns compiled so far. Test-only visibility into the cache.
int get cachedRegExpCount => _cache.length;
