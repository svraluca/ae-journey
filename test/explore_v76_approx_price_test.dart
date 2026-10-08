import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_price_sanity.dart';

void main() {
  test('clinic approximate starting price stays owned', () {
    const evidence = 'At Novomed, Botox prices start from approximately AED 1,500 per area.';
    expect(
      isValidExtractedPriceCandidate(
        rawPriceText: '1500 AED',
        priceMin: 1500,
        currency: 'AED',
        extractionMethod: 'html_paragraph',
        rawEvidence: evidence,
        procedure: 'botox',
        sourceUrl: 'https://novomed.com/services/cosmetic-dermatology/botox/',
      ),
      isTrue,
    );
  });
}
