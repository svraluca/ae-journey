import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_html_price_extractor.dart';

const sourceUrl =
    'https://us-uk.bookimed.com/clinic/aster-clinic/procedure=chemical-peel/';
String page(
  int amount, {
  String label = 'Chemical Peel',
  bool options = true,
}) =>
    '<title>Aster Clinic</title><h1>Chemical Peel in Aster Clinic</h1>'
    '<div class="clinic-page__description">${options ? 'The package costs \$800. The standard chemical peel option costs \$300. Both options are available.' : 'The treatment costs \$700. Hotel \$90. Consultation \$50.'}</div>'
    '<table><tr><th>Treatment</th><th>Price</th></tr><tr><td>$label</td><td>\$$amount</td></tr></table>';

void main() {
  test('generic platform fee cannot choose between treatment options', () {
    final rows = extractPriceEvidence(html: page(700), sourceUrl: sourceUrl);
    expect(
      rows.where((r) => r.priceMin == 700),
      isEmpty,
    );
  });
  test('matching option and explicit scope keep the published price', () {
    for (final (amount, label) in [
      (300, 'Chemical Peel'),
      (700, 'Glycolic acid Chemical Peel'),
    ]) {
      final rows = extractPriceEvidence(
        html: page(amount, label: label),
        sourceUrl: sourceUrl,
      );
      expect(
        rows.where((r) => r.priceMin == amount && r.rawProcedureText.endsWith(label)),
        isNotEmpty,
      );
    }
  });
  test('hotel and consultation amounts do not cause an option conflict', () {
    final rows = extractPriceEvidence(
      html: page(700, options: false),
      sourceUrl: sourceUrl,
    );
    expect(
      rows.where(
        (r) => r.priceMin == 700 && r.rawProcedureText.endsWith('Chemical Peel'),
      ),
      isNotEmpty,
    );
  });
}
