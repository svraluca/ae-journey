import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards both halves of the regex-flag rule in `lib/`.
///
/// Dropping `unicode: true` across the codebase fixed a ~16x slowdown (see
/// `explore_extract_performance_test.dart`), but four patterns genuinely need
/// Unicode mode. `^[\u{1F1E6}-\u{1F1FF}\s]+` threw FormatException while
/// building a result card, so Compare rendered a red error box instead of the
/// Worldwide clinics — and `\p{L}` is worse: without the flag Dart reads it as
/// a literal "p{L}" and the pattern silently stops matching.
void main() {
  final dartFiles = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  /// Source with whole-line comments blanked out.
  ///
  /// The comments explaining this very rule quote `unicode: true` and
  /// `\p{L}`, which the scan would otherwise read as code. Only full-line
  /// comments are removed, so a `//` inside a pattern (`https?://`) is safe.
  String code(File f) {
    return f
        .readAsStringSync()
        .split('\n')
        .map((l) => l.trimLeft().startsWith('//') ? '' : l)
        .join('\n');
  }

  test('lib/ has dart files to scan', () {
    expect(dartFiles, isNotEmpty);
  });

  test(r'every \u{...} or \p{...} pattern passes unicode: true', () {
    final offenders = <String>[];
    for (final file in dartFiles) {
      final src = code(file);
      for (final m in RegExp(r'\\[up]\{').allMatches(src)) {
        // The flag sits in the same RegExp(...) call as the escape.
        final from = m.start;
        final to = (from + 400).clamp(0, src.length);
        final window = src.substring(from, to);
        final closed = window.indexOf(')');
        final call = closed == -1 ? window : window.substring(0, closed + 1);
        if (!call.contains('unicode: true')) {
          final line = src.substring(0, from).split('\n').length;
          offenders.add('${file.path}:$line');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'these need unicode: true or they throw / silently stop '
          'matching: ${offenders.join(", ")}',
    );
  });

  test('unicode: true is only used where the pattern needs it', () {
    // Anything else pays the slow caseInsensitive+unicode path for nothing.
    final unexplained = <String>[];
    for (final file in dartFiles) {
      final src = code(file);
      for (final m in RegExp('unicode: true').allMatches(src)) {
        final from = (m.start - 600).clamp(0, src.length);
        final window = src.substring(from, m.start);
        final open = window.lastIndexOf('RegExp(');
        final call = open == -1 ? window : window.substring(open);
        if (!RegExp(r'\\[up]\{').hasMatch(call)) {
          final line = src.substring(0, m.start).split('\n').length;
          unexplained.add('${file.path}:$line');
        }
      }
    }
    expect(
      unexplained,
      isEmpty,
      reason: 'drop unicode: true here — no \\u{} or \\p{} in the pattern, '
          'and with caseSensitive: false it is ~16x slower: '
          '${unexplained.join(", ")}',
    );
  });
}
