import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_currency_tokens.dart';
import 'package:glowpass/services/explore_price_evidence.dart';
import 'package:glowpass/services/explore_search_locale.dart';

/// A Tirana search ran entirely in English — Albania was in neither the
/// locale table nor the currency table, and no Albanian price-page word was
/// scored — so discovery reported "no ranked urls" and "Serper results: 0"
/// against clinics that publish a full Çmimet menu.
void main() {
  group('a searched market has a language', () {
    test('Albania and Kosovo resolve to Albanian', () {
      for (final cc in ['AL', 'XK']) {
        final locale = exploreLocaleFromCountryCode(cc);
        expect(locale, isNotNull, reason: cc);
        expect(locale!.lang, 'sq');
        expect(locale.priceWords, contains('cmimet'));
      }
    });

    test('Tirana resolves without a country code', () {
      final locale = exploreCityPriceSearchTerms('Tiranë');
      expect(locale.lang, 'sq');
      expect(locale.priceWords, contains('çmimet'));
      expect(exploreCityPriceSearchTerms('Tirana, Albania').lang, 'sq');
      expect(exploreCityPriceSearchTerms('Pristina, Kosovo').lang, 'sq');
    });

    test('an unknown city still falls back to English, not to nothing', () {
      expect(exploreCityPriceSearchTerms('Nowhereville').lang, 'en');
    });

    test('markets the table already claimed now resolve', () {
      expect(exploreLocaleFromCountryCode('MK')?.lang, 'mk');
      expect(exploreLocaleFromCountryCode('BA')?.lang, 'bs');
      expect(exploreLocaleFromCountryCode('SI')?.lang, 'sl');
      expect(exploreLocaleFromCountryCode('SK')?.lang, 'sk');
      expect(exploreLocaleFromCountryCode('ME')?.lang, 'sr');
    });

    test('established locales are unchanged', () {
      expect(exploreLocaleFromCountryCode('RO')?.lang, 'ro');
      expect(exploreLocaleFromCountryCode('TR')?.lang, 'tr');
      expect(exploreLocaleFromCountryCode('AE')?.lang, 'ar');
      expect(exploreLocaleFromCountryCode('RS')?.lang, 'sr');
    });
  });

  group('a searched market has a currency', () {
    test('Albanian lek is read from the local spelling', () {
      expect(detectExploreCurrencyToken('Peeling 3500 Lekë'), 'ALL');
      expect(detectExploreCurrencyToken('Peeling 3.500 leke'), 'ALL');
      expect(detectExploreCurrencyToken('3500 ALL'), 'ALL');
      expect(parsePriceText('Peeling kimik 3500 Lekë')?.priceMin, 3500);
    });

    test('a bare "ALL" in prose is still the English word', () {
      expect(detectExploreCurrencyToken('ALL TREATMENTS'), '');
      expect(detectExploreCurrencyToken('All our services'), '');
    });

    test('Albanian lek is not confused with the Romanian leu', () {
      expect(detectExploreCurrencyToken('3500 Lekë'), 'ALL');
      expect(detectExploreCurrencyToken('3500 lei'), 'RON');
    });

    test('Balkan and Caucasus currencies are read', () {
      expect(detectExploreCurrencyToken('Peeling 12.000 din.'), 'RSD');
      expect(detectExploreCurrencyToken('Botoks 15000 MKD'), 'MKD');
      expect(detectExploreCurrencyToken('Filer 250 KM'), 'BAM');
      expect(detectExploreCurrencyToken('Ботокс 5000 грн'), 'UAH');
      expect(detectExploreCurrencyToken('Peeling 250 GEL'), 'GEL');
    });

    test('established currencies are unchanged', () {
      expect(detectExploreCurrencyToken('Peeling 120 €'), 'EUR');
      expect(detectExploreCurrencyToken('Botox £250'), 'GBP');
      expect(detectExploreCurrencyToken('Peeling 850 RON'), 'RON');
      expect(detectExploreCurrencyToken('Botoks 4500 TL'), 'TRY');
      expect(detectExploreCurrencyToken('1200 AED'), 'AED');
      expect(detectExploreCurrencyToken('Peeling 300 lv.'), 'BGN');
    });
  });

  group('a clinic price page is recognised in any language', () {
    test('Albanian price pages score', () {
      expect(looksLikePriceMenuUrl('https://clinic.al/cmimet/'), isTrue);
      expect(looksLikePriceMenuUrl('https://clinic.al/sq/cmime'), isTrue);
      expect(looksLikeOfficialPriceListUrl('https://clinic.al/cmimet'), isTrue);
    });

    test('previously missing European price pages score', () {
      expect(looksLikePriceMenuUrl('https://k.cz/cenik/'), isTrue);
      expect(looksLikePriceMenuUrl('https://k.rs/cenovnik/'), isTrue);
      expect(looksLikePriceMenuUrl('https://k.nl/tarieven/'), isTrue);
      expect(looksLikePriceMenuUrl('https://k.se/priser/'), isTrue);
      expect(looksLikePriceMenuUrl('https://k.fi/hinnasto/'), isTrue);
      expect(looksLikePriceMenuUrl('https://k.hu/arlista/'), isTrue);
      expect(looksLikePriceMenuUrl('https://k.it/listino-prezzi/'), isTrue);
    });

    test('the established set still scores', () {
      expect(looksLikePriceMenuUrl('https://k.ro/preturi/'), isTrue);
      expect(looksLikePriceMenuUrl('https://k.com/price-list/'), isTrue);
      expect(looksLikePriceMenuUrl('https://k.es/precios'), isTrue);
      expect(looksLikePriceMenuUrl('https://k.tr/fiyatlar/'), isTrue);
      expect(looksLikePriceMenuUrl('https://k.com/book-online'), isTrue);
      expect(
        looksLikeOfficialPriceListUrl('https://k.com/book-online'),
        isFalse,
      );
    });

    test('non-price pages still do not score', () {
      expect(looksLikePriceMenuUrl('https://k.al/kontakt'), isFalse);
      expect(looksLikePriceMenuUrl('https://k.al/rreth-nesh'), isFalse);
      expect(looksLikePriceMenuUrl('https://k.com/about-us'), isFalse);
    });
  });
}
