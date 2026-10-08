import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_html_price_extractor.dart';
import 'package:glowpass/services/explore_price_evidence.dart';
import 'package:glowpass/services/explore_search_locale.dart';
import 'package:glowpass/services/openai_service.dart';

/// Minimal Elementor/WCF pattern: treatment name and fee in adjacent h4s
/// (as on botoxtirana.com/sq/ for BioRePeel / PRX).
const _kElementorAdjacentPeelHtml = '''
<html><body>
<div class="elementor">
  <h4 class="wcf--title">Qërimi</h4>
  <h4 class="wcf--title">1</h4>
  <h4 class="wcf--title">Peeling Biorepell Cl3</h4>
  <h4 class="wcf--title">70€</h4>
  <h4 class="wcf--title">Lini një takim</h4>
  <h4 class="wcf--title">2</h4>
  <h4 class="wcf--title">Peeling Prx-t33</h4>
  <h4 class="wcf--title">80€</h4>
  <h4 class="wcf--title">3</h4>
  <h4 class="wcf--title">Cosmelan Peel</h4>
  <h4 class="wcf--title">600€</h4>
</div>
</body></html>
''';

void main() {
  group('adjacent Elementor heading price pairs', () {
    test('pairs BioRePeel/PRX fees while excluding the Cosmelan package', () {
      final rows = extractPriceEvidence(
        html: _kElementorAdjacentPeelHtml,
        sourceUrl: 'https://botoxtirana.com/sq/',
      );
      expect(
        rows.any(
          (r) =>
              r.priceMin == 70 &&
              r.rawProcedureText.toLowerCase().contains('biorep'),
        ),
        isTrue,
      );
      expect(
        rows.any(
          (r) =>
              r.priceMin == 80 &&
              r.rawProcedureText.toLowerCase().contains('prx'),
        ),
        isTrue,
      );
      expect(
        rows.any(
          (r) =>
              r.priceMin == 600 &&
              r.rawProcedureText.toLowerCase().contains('cosmelan'),
        ),
        isFalse,
      );
    });
  });

  group('Albanian peel discovery locale', () {
    test('sq has peeling kimik / biorepeel search names', () {
      final names = exploreProcedureNamesForLang('peel', 'sq');
      expect(names, isNotEmpty);
      final blob = names.join(' ').toLowerCase();
      expect(blob.contains('peeling kimik') || blob.contains('qërimi'), isTrue);
      expect(blob.contains('biorepeel') || blob.contains('prx'), isTrue);
    });

    test('sq prefers local search first', () {
      expect(explorePrefersLocalSearchFirst('sq'), isTrue);
    });

    test('Tirana peel queries include Albanian + brand cues', () {
      final qs = exploreLocalizedSearchQueries(
        procedure: 'chemical peel facial',
        city: 'Tiranë',
        pill: 'Peels',
        countryCode: 'AL',
        maxQueries: 10,
      );
      expect(qs, isNotEmpty);
      final blob = qs.join(' ').toLowerCase();
      expect(
        blob.contains('peeling') ||
            blob.contains('kimik') ||
            blob.contains('biorepeel') ||
            blob.contains('prx') ||
            blob.contains('çmim') ||
            blob.contains('cmim'),
        isTrue,
        reason: 'queries=$qs',
      );
    });

    test('local locale homepage prefers /sq/ for Albanian', () {
      expect(
        exploreLocalLocaleHomepageUrl(
          'https://botoxtirana.com/',
          lang: 'sq',
        ),
        'https://botoxtirana.com/sq/',
      );
    });
  });

  group('peel brand discovery cues', () {
    test('returns BioRePeel / PRX / Cosmelan for peel searches', () {
      final cues = explorePeelBrandDiscoveryCues(
        procedure: 'chemical peel facial',
        pill: 'Peels',
      );
      expect(cues, isNotEmpty);
      final blob = cues.join(' ').toLowerCase();
      expect(
        blob.contains('biorepeel') ||
            blob.contains('prx') ||
            blob.contains('cosmelan'),
        isTrue,
      );
    });

    test('empty for non-peel procedures', () {
      expect(
        explorePeelBrandDiscoveryCues(
          procedure: 'botox anti-wrinkle',
          pill: 'Botox',
        ),
        isEmpty,
      );
    });
  });
}
