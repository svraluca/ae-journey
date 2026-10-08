import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_price_evidence.dart';

/// Tirana peels returned 2 cards while myspatirana.com/services/relax and
/// innerbeauty.al listed real fees. Every row was rejected as
/// `implausible_amount` with priceMin=1..6 — the parser had picked the list
/// ordinal ("1.") or a duration ("2 ore") instead of the amount beside €.
void main() {
  group('menu rows numbered as a list keep the fee, not the ordinal', () {
    test('"1. Paketa 33€ 👉🏻 90 min" is 33 EUR, not 1', () {
      final parsed = parsePriceText('1. Paketa 33€ 👉🏻 90 min');
      expect(parsed?.priceMin, 33);
      expect(parsed?.currency, 'EUR');
    });

    test('"3. Paketa 45€ 2 ore" is 45 EUR, not 3', () {
      final parsed = parsePriceText('3. Paketa 45€ 2 ore');
      expect(parsed?.priceMin, 45);
    });

    test('"6. Paketa 70€ 👉🏻 3 ore" is 70 EUR, not 6', () {
      final parsed = parsePriceText('6. Paketa 70€ 👉🏻 3 ore');
      expect(parsed?.priceMin, 70);
    });

    test('"4) Peeling 58 € · 2 ore e 30 min" is 58 EUR', () {
      final parsed = parsePriceText('4) Peeling 58 € · 2 ore e 30 min');
      expect(parsed?.priceMin, 58);
    });

    test('duration after the fee never becomes the price', () {
      expect(parsePriceText('Chemical peel 60 € / 45 minutes')?.priceMin, 60);
      expect(parsePriceText('Peeling facial 80€ (60 min)')?.priceMin, 80);
    });

    test('package copy keeps the euro amount', () {
      final parsed = parsePriceText(
        '💖 Package 1: Bikini Bliss – €60 💖 Indulge in 3 luxurious sessions',
      );
      expect(parsed?.priceMin, 60);
    });
  });

  group('existing parses are unchanged', () {
    test('a decimal thousand separator is not an ordinal', () {
      expect(parsePriceText('Rinoplastia desde 4.500 €')?.priceMin, 4500);
      expect(parsePriceText('1.500 €')?.priceMin, 1500);
    });

    test('ranges still parse as ranges', () {
      final parsed = parsePriceText('Peeling 120 - 180 €');
      expect(parsed?.priceMin, 120);
      expect(parsed?.priceMax, 180);
    });

    test('quantity prefixes are still skipped', () {
      expect(parsePriceText('Filler 1 ml 250 €')?.priceMin, 250);
    });

    test('bare minute counts with no fee stay unparsed as a price', () {
      expect(parsePriceText('90 min')?.priceMin, isNull);
    });
  });
}
