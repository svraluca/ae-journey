import 'package:flutter_test/flutter_test.dart';

import 'package:glowpass/services/explore_clinic_identity.dart';
import 'package:glowpass/services/explore_comparison_session.dart';
import 'package:glowpass/services/explore_price_evidence.dart';
import 'package:glowpass/services/explore_price_sanity.dart';
import 'package:glowpass/services/explore_price_verification.dart';
import 'package:glowpass/services/explore_search_locale.dart';
import 'package:glowpass/services/openai_service.dart';
import 'package:glowpass/ui/clinic_compare_price_display.dart';

OpenAIClinic _clinic({
  required String name,
  double price = 0,
  String brand = 'Botox',
  String sourceUrl = 'https://clinic.example/botoks',
  String currency = 'TRY',
  String city = 'Ankara',
  PriceVerificationStatus status = PriceVerificationStatus.unverified,
  String rawPrice = '',
  String evidence = '',
  String extraction = '',
}) {
  return OpenAIClinic(
    rank: 1,
    name: name,
    area: city,
    distanceMi: 1,
    rating: 4.5,
    reviews: 20,
    priceGbp: price.round(),
    priceMin: price,
    priceMax: price,
    priceLabel: price > 0 ? '${price.round()} $currency' : '',
    currency: currency,
    brand: brand,
    badge: '',
    badgeVariant: 'mid',
    coord: const OpenAICoord(39.93, 32.86),
    hasProcedure: true,
    pricePending: false,
    priceSourceUrl: sourceUrl,
    rawPriceText: rawPrice,
    extractionMethod: extraction,
    priceEvidenceText: evidence,
    priceVerificationStatus: status,
  );
}

void main() {
  group('Turkish locale aliases + queries', () {
    test('TR price words include fiyat/ücret family', () {
      final loc = exploreCityPriceSearchTerms('Ankara');
      expect(loc.lang, 'tr');
      expect(loc.priceWords, contains('fiyat'));
      expect(loc.priceWords, contains('fiyatları'));
      expect(loc.priceWords, contains('ücret'));
      expect(loc.priceWords, contains('ücretleri'));
    });

    test('Turkish procedure aliases for botox/fillers/rhino/breast', () {
      final botox = exploreProcedureLocalSearchNames('Botox', 'tr');
      expect(botox, contains('botoks'));
      expect(botox.any((e) => e.contains('botulinum')), isTrue);

      final filler = exploreProcedureLocalSearchNames('Lip filler', 'tr');
      expect(filler.any((e) => e.contains('dudak dolgusu')), isTrue);

      final rhino = exploreProcedureLocalSearchNames('Rhinoplasty', 'tr');
      expect(rhino.any((e) => e.contains('rinoplasti')), isTrue);
      expect(rhino.any((e) => e.contains('burun')), isTrue);

      final breast =
          exploreProcedureLocalSearchNames('Breast augmentation', 'tr');
      expect(breast.any((e) => e.contains('meme')), isTrue);
    });

    test('bounded Turkish search queries — not every alias', () {
      final q = exploreLocalizedSearchQueries(
        procedure: 'Botox',
        city: 'Ankara',
        pill: 'Botox',
        countryCode: 'TR',
        maxQueries: 6,
      );
      expect(q.length, lessThanOrEqualTo(6));
      expect(
        q.any((e) =>
            e.toLowerCase().contains('botoks') &&
            e.toLowerCase().contains('fiyat')),
        isTrue,
      );
      expect(
        q.any((e) =>
            e.toLowerCase().contains('ücret') ||
            e.toLowerCase().contains('ucret')),
        isTrue,
      );
    });
  });

  group('Turkish TL price grammar', () {
    test('parses 100.000 TL and ranges', () {
      expect(parsePriceText('100.000 TL')?.priceMin, 100000);
      expect(parsePriceText('100.000 TL')?.currency, 'TRY');

      final range = parsePriceText('100.000–150.000 TL');
      expect(range?.priceMin, 100000);
      expect(range?.priceMax, 150000);
      expect(range?.currency, 'TRY');

      final ile = parsePriceText('100.000 TL ile 150.000 TL arasında');
      expect(ile?.priceMin, 100000);
      expect(ile?.priceMax, 150000);
      expect(ile?.currency, 'TRY');
    });

    test('parses from / itibaren / bin / lira symbol', () {
      final from1 = parsePriceText("100.000 TL'den başlayan");
      expect(from1?.priceMin, 100000);
      expect(from1?.currency, 'TRY');

      final from2 = parsePriceText("100.000 TL’den itibaren");
      expect(from2?.priceMin, 100000);
      expect(from2?.currency, 'TRY');

      final bin = parsePriceText('100 bin TL');
      expect(bin?.priceMin, 100000);
      expect(bin?.currency, 'TRY');

      final sym = parsePriceText('₺100.000');
      expect(sym?.priceMin, 100000);
      expect(sym?.currency, 'TRY');
    });

    test('rejects implant ratios, durations, percentages', () {
      expect(parsePriceText('1,00'), isNull);
      expect(parsePriceText('1,12'), isNull);
      expect(parsePriceText('1,20'), isNull);
      expect(parsePriceText('11 months'), isNull);
      expect(parsePriceText('50–60% less'), isNull);
      expect(parsePriceText('50-60% less'), isNull);
    });
  });

  group('SEO identity + guides', () {
    test('rejects Turkish SEO procedure headlines as clinic names', () {
      expect(
        looksLikeProcedureNameAsClinicIdentity('Ankara Botoks Fiyatları 2026'),
        isTrue,
      );
      expect(
        looksLikeProcedureNameAsClinicIdentity(
          'Meme Büyütme Ameliyatı Fiyatları Ankara',
        ),
        isTrue,
      );
      expect(
        looksLikeProcedureNameAsClinicIdentity('Kalıcı Botoks Fiyatları'),
        isTrue,
      );
      expect(
        clinicIdentityRejectReason('Ankara Botoks Fiyatları 2026'),
        isNotNull,
      );
    });

    test('guide/directory hosts never become clinics', () {
      expect(isMarketplaceOrDirectoryHost('trueclinic.com'), isTrue);
      expect(isMarketplaceOrDirectoryHost('www.mymeditravel.com'), isTrue);
      expect(isMarketplaceOrDirectoryHost('whatclinic.com'), isTrue);
      expect(isMarketplaceOrDirectoryHost('bookimed.com'), isTrue);
      expect(
        looksLikeMarketEstimateDirectoryUrl('https://trueclinic.com/guide'),
        isTrue,
      );
    });

    test('provider identity from JSON-LD prefers doctor over SEO title', () {
      const html = '''
<html><head>
<script type="application/ld+json">
{"@type":"Physician","name":"Op. Dr. Ayse Yilmaz"}
</script>
<meta property="og:site_name" content="Ayse Yilmaz Klinik">
<title>Ankara Botoks Fiyatlari 2026</title>
</head></html>
''';
      expect(
        looksLikeProcedureNameAsClinicIdentity('Ankara Botoks Fiyatlari 2026'),
        isTrue,
      );
      expect(
        clinicIdentityRejectReason('Op. Dr. Ayse Yilmaz'),
        isNull,
      );
      expect(html.contains('Physician'), isTrue);
      expect(html.contains('Ayse Yilmaz'), isTrue);
    });

    test('mutluadiguzel SEO title resolves to doctor, not headline', () {
      expect(
        looksLikeProcedureNameAsClinicIdentity('Kalıcı Botoks Fiyatları 2026'),
        isTrue,
      );
      const title =
          'Kalıcı Botoks Fiyatları 2026: Detaylı Rehber | Dr. Mutlu Adıgüzel';
      final right = title.split(RegExp(r'\s*[|–—]\s*')).last.trim();
      expect(right.toLowerCase(), contains('mutlu'));
      expect(looksLikeProcedureNameAsClinicIdentity(right), isFalse);
      expect(clinicIdentityRejectReason(right), isNull);
      expect(
        exploreClinicDisplayNameFromHost('mutluadiguzel.com').toLowerCase(),
        contains('mutlu'),
      );
      final table = parsePriceText('4.000 – 8.000 TL');
      expect(table?.priceMin, 4000);
      expect(table?.priceMax, 8000);
      expect(table?.currency, 'TRY');
      expect(
        looksLikeMarketAveragePriceBlurb(
          'genel piyasa değerlerini yansıtmaktadır. Tek bölge 4.000 – 8.000 TL',
        ),
        isTrue,
      );
    });
  });

  group('no_public_price pool + ordering', () {
    test('eligible no_public_price and ordered after verified', () {
      final priced = _clinic(
        name: 'Verified Klinik',
        price: 3500,
        sourceUrl: 'https://verifiedklinik.com/botoks',
        status: PriceVerificationStatus.officialWebsite,
        rawPrice: '3.500 TRY',
        evidence: 'Botoks 3.500 TRY',
        extraction: 'html_table',
      );
      final por = exploreMarkNoPublicPriceClinic(
        _clinic(
          name: 'Dr. Elif Klinik',
          sourceUrl: 'https://drelifklinik.com/botoks',
          evidence: 'Ankara botoks tedavisi sunuyoruz',
        ),
        sourceUrl: 'https://drelifklinik.com/botoks',
        evidence: 'Ankara botoks tedavisi sunuyoruz',
      );
      expect(
        exploreClinicEligibleAsNoPublicPrice(
          por,
          procedure: 'Botox',
          city: 'Ankara',
        ),
        isTrue,
      );
      final ordered = exploreOrderVerifiedThenNoPublicPrice(
        [por, priced],
        procedure: 'Botox',
        city: 'Ankara',
      );
      expect(ordered.any(exploreClinicIsNoPublicPrice), isTrue);
      // Compare UI never paints on-request rows — only listed prices.
      final shown = clinicsForCompareDisplay(
        [por, priced],
        procedure: 'Botox',
        city: 'Ankara',
      );
      expect(shown.any(exploreClinicIsNoPublicPrice), isFalse);
      if (ordered.length >= 2 &&
          exploreClinicEligibleForVerifiedPool(
            priced,
            procedure: 'Botox',
            city: 'Ankara',
          )) {
        expect(exploreClinicIsNoPublicPrice(ordered.first), isFalse);
        expect(exploreClinicIsNoPublicPrice(ordered.last), isTrue);
      }
    });

    test('summary copy', () {
      expect(
        exploreVerifiedAndOnRequestSummary(
          verifiedPriceCount: 1,
          noPublicPriceCount: 3,
        ),
        '1 verified price · 3 clinics without public prices',
      );
    });
  });
}
