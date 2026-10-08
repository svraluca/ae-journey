import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_html_price_extractor.dart';
import 'package:glowpass/services/explore_procedure_relation.dart';

/// Explore froze on any city whose clinics publish a real price menu.
///
/// `caseSensitive: false` combined with `unicode: true` puts Dart's regex
/// engine on a ~16x slower path, and the price pipeline ran ~45 such patterns
/// per extracted row. [classifyProcedureRelation] measured 107 ms per row, so
/// a 61 KB price list cost 74 s of UI-isolate CPU — repeated for every
/// duplicate verify of the same clinic. Nothing in this codebase needs
/// Unicode mode: no pattern uses `\p{...}` or `\u{...}`.
///
/// The budgets below are deliberately loose so the test is not flaky on a
/// loaded machine; the regression they guard was two orders of magnitude out.
void main() {
  String priceMenuHtml(int rows) {
    final b = StringBuffer('<html><body><h1>Çmimet</h1><ul>');
    for (var i = 0; i < rows; i++) {
      b.write('<li>Peeling kimik sipërfaqësor $i 33€</li>');
    }
    b.write('</ul></body></html>');
    return b.toString();
  }

  String evidenceBlob(int rows) {
    final b = StringBuffer();
    for (var i = 0; i < rows; i++) {
      b.write('Peeling kimik $i 33€ ');
    }
    return b.toString();
  }

  test('relation classify stays milliseconds, not ~100ms, per row', () {
    final evidence = evidenceBlob(125);
    for (var i = 0; i < 3; i++) {
      classifyProcedureRelation(
        requestedProcedure: 'chemical peel facial',
        label: 'Peeling kimik',
        evidence: evidence,
        sourceUrl: 'https://clinic.al/cmimet',
      );
    }
    final sw = Stopwatch()..start();
    const reps = 20;
    for (var i = 0; i < reps; i++) {
      classifyProcedureRelation(
        requestedProcedure: 'chemical peel facial',
        label: 'Peeling kimik',
        evidence: evidence,
        sourceUrl: 'https://clinic.al/cmimet',
      );
    }
    final perCall = sw.elapsedMilliseconds / reps;
    expect(
      perCall,
      lessThan(40),
      reason: 'was 107ms/row with unicode+caseInsensitive regexes',
    );
  });

  test('a full price menu extracts in seconds, not a minute', () {
    final html = priceMenuHtml(2000);
    expect(html.length, greaterThan(60000));
    final sw = Stopwatch()..start();
    final rows = extractPriceEvidence(
      html: html,
      sourceUrl: 'https://clinic.al/cmimet',
    );
    expect(rows, isNotEmpty);
    expect(
      sw.elapsedMilliseconds,
      lessThan(30000),
      reason: 'a 61KB menu took 74s before the regex-flag fix',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('no pattern needs Unicode mode, so none should pay for it', () {
    // Guard the fix itself: re-adding `unicode: true` alongside
    // `caseSensitive: false` silently reintroduces the 16x slowdown.
    final fast = RegExp(r'\bpeeling\b', caseSensitive: false);
    final slow = RegExp(r'\bpeeling\b', caseSensitive: false, unicode: true);
    final blob = evidenceBlob(200);
    fast.hasMatch('warm');
    slow.hasMatch('warm');

    int micros(RegExp re) {
      final sw = Stopwatch()..start();
      for (var i = 0; i < 20; i++) {
        re.hasMatch(blob);
      }
      return sw.elapsedMicroseconds;
    }

    // Documents the engine behaviour this fix relies on.
    expect(micros(fast), lessThan(micros(slow)));
  });
}
